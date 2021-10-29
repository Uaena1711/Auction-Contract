// SPDX-License-Identifier: No 

import "./PausAble.sol";
import "../library/OrderAuctionList.sol";
import "../library/SafeCast.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC721, IERC165 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Counters} from "@openzeppelin/contracts/utils/Counters.sol";

pragma solidity >=0.4.22 <0.9.0;

contract NFTAuction is PausAble {

    using SafeERC20 for IERC20;
    using SafeMath for uint64;
    using SafeMath for uint96;
    using SafeMath for uint256;
    using SafeCast for uint256;
    using IterableOrderedOrderSet for IterableOrderedOrderSet.Data;
    using IterableOrderedOrderSet for bytes32;
    using Counters for Counters.Counter;

    bytes4 constant interfaceId = 0x80ac58cd; // 721 interface id

    bytes32 internal init_last_element = 0x0000000000000000000000000000000000000000000000000000000000000001; // first data in queue

    uint256 constant FEE_DENOMINATOR = 1000;

    Counters.Counter private _auctionIdTracker;

    modifier auctionExists(uint256 auctionId) {
        require(_exists(auctionId), "Auction doesn't exist");
            _;
    }

    modifier OnGoingAuctionRequired(uint256 auctionId) {
        require(auctionData[auctionId].approved, 'Auction must be approved by owner');

        require(auctionData[auctionId].start_time.add(auctionData[auctionId].duration) > block.timestamp,
            'Auction expired'
        );
            _;
    }


    event AuctionCreated(
        uint256 indexed auctionId,
        uint256 indexed tokenId,
        address indexed tokenContract,
        uint256 duration,
        bool approved,
        uint256 reservePrice,
        address tokenOwner,
        uint8 minBidIncrementPerOrder
    );

    event NewBid(
        uint256 indexed auctionId,
        address indexed userAddress,
        uint256 buyAmount
    );

    event ForceCancelAuction (
        uint256 indexed auctionId
    );

    event CancellationBid(
        uint256 indexed auctionId,
        address  cancelledBy
    );

    event AuctionApprovalUpdated(
        uint256 indexed auctionId,
        uint256 indexed tokenId,
        address indexed tokenContract,
        bool approved
    );

    event AuctionCanceled(
        uint256 indexed auctionId,
        uint256 indexed tokenId,
        address indexed tokenContract,
        address tokenOwner
    );

    event AuctionEnded(
        uint256 indexed auctionId,
        address indexed winner,
        uint256 indexed winAmount
    );

    struct Auction {
        // ID for the ERC721 token
        uint256 tokenId;
        // Bid token address
        IERC20 ERC20Address;
        // Address for the ERC721 contract
        address tokenContract;
        // The length of time to run the auction for, after the first bid was made
        uint256 duration;
        // Whether or not the auction curator has approved the auction to start
        bool approved;
        // Start open auction time
        uint256 start_time;
        // Bytecode for last bidder infomation
        bytes32  last_element;
        // The minimum price of the first bid
        uint256 reservePrice;
        // The sale percentage to send to the curator
        uint8 minBidIncrementPerOrder;
        // The address that should receive the funds once the NFT is sold.
        address tokenOwner;
        // The address of the current highest bid
        address bidder;
        //Amout of highest bid price
        uint96 amount;
    }

    uint256 feeNumerator;
    address public feeTo;
    mapping(uint256 => Auction) public auctionData;
    mapping(uint256 => IterableOrderedOrderSet.Data) internal sellOrders;

    constructor() public PausAble() {}

    /**
     * @notice Auction owner must pay some fee for this contract owner, and this fee will be send to this address
     * @dev set feeTo address, can only call by owner, if feeTo = address(0) => free
     */
    function setFeeTo(address _feeTo)
    external
    onlyOwner {
        feeTo = _feeTo;
    }

    /**
     * @notice Auction owner must pay some fee for this contract owner
     * @dev set feeTo address, can only call by owner
     */
    function setFeeParameters(uint256 newFeeNumerator)
    public
    onlyOwner {
        require(
            newFeeNumerator <= 15,
            "Fee is not allowed to be set higher than 1.5%"
        );

        feeNumerator = newFeeNumerator;
    }

    /**
     * @notice Create an auction.
     * @dev Store the auction details in the auctions mapping and emit an AuctionCreated event.
     */
    function createAuction(
        uint256 tokenId,
        address tokenContract,
        IERC20 biddingToken,
        uint256 duration,
        bool approved,
        uint256 reservePrice,
        uint8 minBidIncrementPerOrder
    ) public  whenNotPaused returns (uint256) {
        require(
            IERC165(tokenContract).supportsInterface(interfaceId),
            "tokenContract does not support ERC721 interface"
        );

        address tokenOwner = IERC721(tokenContract).ownerOf(tokenId);

        require(
            msg.sender == IERC721(tokenContract).getApproved(tokenId) ||
            msg.sender == tokenOwner,
            "Caller must be approved or owner for token id"
        );

        require(
            reservePrice > 0,
            'Can not open an auction with 0 value at the first time'
        );

        require(
            minBidIncrementPerOrder > 0,
            'Can not open an auction with 0 increment per order'
        );

        uint256 auctionId = _auctionIdTracker.current();
        sellOrders[auctionId].initializeEmptyList();

        auctionData[auctionId] = Auction (
            tokenId,
            biddingToken,
            tokenContract,
            duration,
            approved,
            block.timestamp,
            init_last_element,
            reservePrice,
            minBidIncrementPerOrder,
            tokenOwner,
            address(0),
            0
        );

        IERC721(tokenContract).transferFrom(tokenOwner, address(this), tokenId);

        _auctionIdTracker.increment();

        emit AuctionCreated (
            auctionId,
            tokenId,
            tokenContract,
            duration,
            approved,
            reservePrice,
            tokenOwner,
            minBidIncrementPerOrder
        );

        return auctionId;
    }

    function createBid(uint256 auctionId, uint256 amount)
    external
    whenNotPaused
    auctionExists(auctionId)
    OnGoingAuctionRequired(auctionId)
    returns(bool) {

        require(msg.sender != auctionData[auctionId].tokenOwner, "A user can not bid their own Auction");

        require(
            amount >= auctionData[auctionId].reservePrice,
            'Must send at least reservePrice'
        );

        require(
            amount >= auctionData[auctionId].amount.add(auctionData[auctionId].minBidIncrementPerOrder),
            'Must send more than last bid by minBidIncrementPercentage amount'
        );

        bytes32 _currentEncode = IterableOrderedOrderSet.encodeOrder(msg.sender, amount.toUint96());

        if(
            sellOrders[auctionId].insert(
                _currentEncode,
                auctionData[auctionId].last_element
            )
        )
        {
            auctionData[auctionId].amount = amount.toUint96();
            auctionData[auctionId].bidder = msg.sender;
            auctionData[auctionId].last_element = _currentEncode;

            auctionData[auctionId].ERC20Address.transferFrom(
                msg.sender,
                address(this),
                amount
            );

            emit NewBid(auctionId, msg.sender, amount);

            return true;
        }

        return false;
    }

    /**
     * @notice Cancel a bid of an auction.
     * @dev Only callable by the who createBid. Can on;y be called if the auction still open.
     */

    function cancelBid(uint256 auctionId, uint96 amount)
    public
    whenNotPaused
    auctionExists(auctionId)
    OnGoingAuctionRequired(auctionId)
    returns(bool) {

        bytes32 _order = IterableOrderedOrderSet.encodeOrder(msg.sender, amount);

        if(_cancelBid(auctionId, _order)) {

            emit CancellationBid(auctionId, msg.sender);
            return true;
        }

        revert('cannot remove orders, check order info again');

    }

    /**
     * @notice Cancel all user bid of an auction.
     * @dev Only callable by the who createBid. Can only be called if the auction still open.
     */

    function cancelAllBid(uint256 auctionId)
    public
    whenNotPaused
    auctionExists(auctionId)
    OnGoingAuctionRequired(auctionId)
    returns(bool) {

        bytes32 _last_element = auctionData[auctionId].last_element;

        while(_last_element != IterableOrderedOrderSet.QUEUE_START) {
            (
                address _userAddress,

            ) = _last_element.decodeOrder();

            if(msg.sender == _userAddress) {

                bool _success = _cancelBid(auctionId, _last_element);

                if(_success) emit CancellationBid(auctionId, msg.sender);
                else revert('cannot remove orders, check order info again');

            }

            _last_element = sellOrders[auctionId].prev(_last_element);
        }

        return true;
    }

    /**
     * @notice Approve an auction, opening up the auction for bids.
     * @dev Only callable by the curator. Cannot be called if the auction has already started.
     */
    function setAuctionApproval(uint256 auctionId, bool approved)
    external
    whenNotPaused
    auctionExists(auctionId) {
        require(msg.sender == auctionData[auctionId].tokenOwner, "Must be auction owner");
        require(auctionData[auctionId].approved == false, "Auction hasn't started yet");
        _approveAuction(auctionId, approved);
    }

    /**
     * @notice Set duration for an auction, only when auction haven't start.
     * @dev Only callable by the curator. Cannot be called if the auction has already started.
     */
    function setAuctionDuration(uint256 auctionId, uint256 duration)
    external
    whenNotPaused
    auctionExists(auctionId) {
        require(msg.sender == auctionData[auctionId].tokenOwner, "Must be auction owner");
        require(auctionData[auctionId].approved == false, "Auction hasn't started yet");
        _setDurationAuction(auctionId, duration);
    }


    /**
     * @notice Cancel an auction when it haven't started yet.
     * @dev Transfers the NFT back to the auction creator and emits an AuctionCanceled event
     */
    function cancelAuctionWhenNotStart(uint256 auctionId)
    external
    whenNotPaused
    auctionExists(auctionId) {
        require(
            auctionData[auctionId].tokenOwner == msg.sender,
            "Can only be called by auction creator"
        );
        require(
            auctionData[auctionId].approved == false,
            "Can't cancel an auction when it haven't been started yet with this method"
        );

        _cancelAuction(auctionId);
    }

    /**
     * @notice Cancel an auction when it's ongoing.
     * @dev Transfers the NFT back to the auction creator, trans back ERC20 token for bidder and emits an AuctionCanceled event
     */
    function cancelAuctionWhenOngoing(uint256 auctionId)
    external
    whenNotPaused
    auctionExists(auctionId)
    OnGoingAuctionRequired(auctionId) {
        require(
            auctionData[auctionId].tokenOwner == msg.sender,
            "Can only be called by auction creator"
        );

        bool _success = _forceCancelAllBid(auctionId);

        if(!_success) revert('Bid order to remove has wrong infomation');
        _cancelAuction(auctionId);
    }

    /**
     * @notice Call when auction ended to exhange ERC20 and ERC721 between auction creator and auction winner .
     * @dev Transfers the NFT to the auction winner, trans ERC20 token for auction owner and return alll ERC20 for lost users
     */
    function endAuction(uint256 auctionId)
    external
    whenNotPaused
    auctionExists(auctionId)
    {
        require(
            auctionData[auctionId].tokenOwner == msg.sender ||
            (_tooLongAuction(auctionId) && isOwner()) ,
            "Not authorized"
        );

        require(
            auctionData[auctionId].approved == true,
            "Auction haven't started"
        );

        require(
            auctionData[auctionId].start_time.add(auctionData[auctionId].duration) <= block.timestamp,
            "Action haven't ended"
        );

        address winner = auctionData[auctionId].bidder;
        address _tokenOwner = auctionData[auctionId].tokenOwner;
        uint256 winAmount = auctionData[auctionId].amount;
        bytes32 _last_element = auctionData[auctionId].last_element;

        if(feeTo != address(0)) {
            uint256 _fee = winAmount.mul(feeNumerator)
                                    .div(FEE_DENOMINATOR);
            winAmount = winAmount.sub(_fee);
        }

        auctionData[auctionId].ERC20Address.transfer(
                _tokenOwner,
                winAmount
            );

        IERC721(auctionData[auctionId].tokenContract).safeTransferFrom(
                address(this),
                winner,
                auctionData[auctionId].tokenId
            );

        // remove winner from pay back list
        auctionData[auctionId].last_element = sellOrders[auctionId].prev(_last_element);

        // pay back list: return ERC20 for lost bidder list
        bool success = _forceCancelAllBid(auctionId);

        if(!_success) revert('Bid order to remove has wrong infomation');

        // delete auction informations
        delete auctionData[auctionId];
        delete sellOrders[auctionId];

        emit AuctionEnded(auctionId, winner, winAmount);
    }

    function _cancelAuction(uint256 auctionId)
    internal {
        address tokenOwner = auctionData[auctionId].tokenOwner;
        IERC721(auctionData[auctionId].tokenContract).safeTransferFrom(address(this), tokenOwner, auctionData[auctionId].tokenId);

        delete auctionData[auctionId];
        delete sellOrders[auctionId];
        emit AuctionCanceled(auctionId, auctionData[auctionId].tokenId, auctionData[auctionId].tokenContract, tokenOwner);
    }

    function _setDurationAuction(uint256 auctionId, uint256 duration)
    internal {
        auctionData[auctionId].duration = duration;
    }

    function _approveAuction(uint256 auctionId, bool approved)
    internal {
        auctionData[auctionId].approved = approved;
        auctionData[auctionId].start_time = block.timestamp;
        emit AuctionApprovalUpdated(auctionId, auctionData[auctionId].tokenId, auctionData[auctionId].tokenContract, approved);
    }

    function _tooLongAuction(uint256 auctionId)
    internal
    view
    returns(bool) {
        if(block.timestamp >= auctionData[auctionId].start_time.add(2592000)) return true;

        return false;
    }

    function _exists(uint256 auctionId)
    internal
    view
    returns(bool) {
        return auctionData[auctionId].tokenOwner != address(0);
    }

    function _cancelBid(uint256 auctionId, bytes32 _orderInfo)
    internal
    returns(bool) {

        bool success = sellOrders[auctionId].removeKeepHistory(_orderInfo);
        bytes32 _last_element = auctionData[auctionId].last_element;
        if(success) {
            (
                address _userAddress,
                uint96 _amount
            ) = _orderInfo.decodeOrder();

            require(_userAddress == msg.sender, 'Only the user can cancel their orders');

            if(_orderInfo == _last_element) {
                auctionData[auctionId].last_element = sellOrders[auctionId].prev(_last_element);

                (
                    address _currentAddress,
                    uint96 _currentAmount
                ) = auctionData[auctionId].last_element.decodeOrder();

                auctionData[auctionId].bidder = _currentAddress;
                auctionData[auctionId].amount = _currentAmount;
            }

            auctionData[auctionId].ERC20Address.transfer(
                msg.sender,
                _amount
            );

            return true;
        }

        return false;
    }

    function _forceCancelAllBid(uint256 auctionId)
    internal
    returns(bool) {

        bool isDone = true;
        bytes32 _last_element = auctionData[auctionId].last_element;

        while(_last_element != IterableOrderedOrderSet.QUEUE_START) {
            (
                address _userAddress,
                uint96 _amount
            ) = _last_element.decodeOrder();

            bool _success = sellOrders[auctionId].removeKeepHistory(_last_element);

            if(_success)  {

                auctionData[auctionId].ERC20Address.transfer(
                    _userAddress,
                    _amount
                );

                emit CancellationBid(auctionId, msg.sender);

            }
            else {
                isDone = false;
            }

            _last_element = sellOrders[auctionId].prev(_last_element);
        }

        return isDone;
    }
}