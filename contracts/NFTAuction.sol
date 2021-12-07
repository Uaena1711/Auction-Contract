// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./PausAble.sol";
import "../library/OrderAuctionList.sol";
import "../library/SafeCast.sol";
import "../library/ReentrancyGuard.sol";
import "../node_modules/@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC721, IERC165 } from "../node_modules/@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "../node_modules/@openzeppelin/contracts/utils/math/SafeMath.sol";
import "../node_modules/@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Counters } from "../node_modules/@openzeppelin/contracts/utils/Counters.sol";


contract NFTAuction is ReentrancyGuard, Pausable {

    using SafeERC20 for IERC20;
    using SafeMath for uint64;
    using SafeMath for uint96;
    using SafeMath for uint256;
    using SafeCast for uint256;
    using IterableOrderedOrderSet for IterableOrderedOrderSet.Data;
    using IterableOrderedOrderSet for bytes32;
    using Counters for Counters.Counter;

    bool private initialized;
    bool private initializing;
    uint16 private FEE_DENOMINATOR;

    bytes4 private interfaceId; // 721 interface id


    bytes32 private init_last_element; // first data in queue

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

    /**
    * @dev Modifier to use in the initializer function of a contract.
    */
    modifier initializer() {
        require(initializing || !initialized, "Contract instance has already been initialized");

        bool isTopLevelCall = !initializing;
        if (isTopLevelCall) {
            initializing = true;
            initialized = true;
        }

        _;

        if (isTopLevelCall) {
            initializing = false;
        }
    }


    event AuctionCreated(
        uint256 indexed auctionId,
        uint256 indexed tokenId,
        address indexed tokenContract,
        uint256 duration,
        bool    approved,
        uint256 reservePrice,
        address tokenOwner,
        uint256 minBidIncrementPerOrder
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
        address         cancelledBy
    );

    event AuctionApprovalUpdated(
        uint256 indexed auctionId,
        uint256 indexed tokenId,
        address indexed tokenContract,
        bool            approved
    );

    event AuctionCanceled(
        uint256 indexed auctionId,
        uint256 indexed tokenId,
        address indexed tokenContract,
        address         tokenOwner
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
        uint256 minBidIncrementPerOrder;
        // The address that should receive the funds once the NFT is sold.
        address tokenOwner;
    }

    struct BidStatus {
        mapping(address => bool) _status;
    }

    uint96 public feeNumerator;
    uint96 public feeDiscountNumerator;
    address public feeTo;
    uint256 public ticketFee;
    IERC20 public specifiedStakeToken;
    mapping(uint256 => Auction) public auctionData;
    mapping(uint256 => bool) public discounts;
    mapping(uint256 => IterableOrderedOrderSet.Data) internal sellOrders;
    mapping(uint256 => BidStatus) isBid;


    constructor() public Pausable() {}

    /**
     * @notice Call this function only 1 time to init value for variable
     * @dev initializer confirm this function can't invoke more than one time
     */
    function initialize()
    public
    initializer {
        interfaceId = 0x80ac58cd;
        FEE_DENOMINATOR = 1000;
        init_last_element = 0x0000000000000000000000000000000000000000000000000000000000000001;
    }

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
     * @dev can only call by owner
     */
    function setFeeParameters(uint96 _newFeeNumerator)
    public
    onlyOwner {
        require(
            _newFeeNumerator <= 15,
            "Fee is not allowed to be set higher than 1,5%"
        );

        feeNumerator = _newFeeNumerator;
    }

    /**
     * @notice Auction owner must pay some fee for this contract owner - fee when discount
     * @dev can only call by owner
     */
    function setFeeDiscountParameters(uint96 _newFeeNumerator)
    public
    onlyOwner {
        require(
            _newFeeNumerator <= 10,
            "Fee is not allowed to be set higher than 1%"
        );

        feeDiscountNumerator = _newFeeNumerator;
    }

    /**
     * @notice set ERC20 token user must pay when bid an auction
     * @dev can only call by owner
     */
    function setSpecifiedStakeToken(address _tokenAddress)
    public
    onlyOwner {

        specifiedStakeToken = IERC20(_tokenAddress);
    }

    /**
     * @notice set ERC20 token fee user must pay when bid an auction
     * @dev can only call by owner
     */
    function setSpecifiedStakeTokenFee(uint256 _fee)
    public
    onlyOwner {

        ticketFee = _fee;
    }

    /**
     * @notice Contract owner can set some Auction as Discount mean Auction owner only pay smaller than other
     * @dev can only call by owner
     */
    function addDiscount(uint256 _auctionId)
    external
    onlyOwner {
        discounts[_auctionId] = true;
    }

    /**
     * @notice Remove auction from auctions discount group
     * @dev can only call by owner
     */
    function removeDiscount(uint256 _auctionId)
    external
    onlyOwner {
        discounts[_auctionId] = false;
    }

    /**
     * @notice See an auctions is discount or not
     * @dev call from anyWhere with anyone
     */
    function getDiscountStatus(uint256 _auctionId)
    public
    view
    returns(bool) {
        return discounts[_auctionId];
    }

    /**
     * @notice Withdraw ticket fee
     * @dev call only by onwner
     */
    function withDrawTicketFee(uint256 _amount)
    public {

        IERC20(specifiedStakeToken).transfer(
            feeTo,
            _amount
        );
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
        uint256 minBidIncrementPerOrder
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
            tokenOwner
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

    /**
    * @notice Create a bid to an auction.
    * @param {auctionId, amount}
    * @dev Create bid to an exists Auction and must higer than last bid
    */

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

        (
            ,
            uint96 _amount
        ) = auctionData[auctionId].last_element.decodeOrder();

        require(
            amount >= _amount.add(auctionData[auctionId].minBidIncrementPerOrder),
            'Must send more than last bid by minBidIncrementPercentage amount'
        );

        if(!isBid[auctionId]._status[msg.sender]) {

            isBid[auctionId]._status[msg.sender] = true;

            specifiedStakeToken.transferFrom(
                msg.sender,
                address(this),
                ticketFee
            );
        }

        bytes32 _currentEncode = IterableOrderedOrderSet.encodeOrder(msg.sender, amount.toUint96());

        if(
            sellOrders[auctionId].insert(
                _currentEncode,
                auctionData[auctionId].last_element
            )
        )
        {

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
    nonReentrant
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
    nonReentrant
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
    nonReentrant
    auctionExists(auctionId)
    {
        require(
            auctionData[auctionId].tokenOwner == msg.sender ||
            (_tooLongAuction(auctionId) && isOwner()),
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

        uint96 _fee;
        uint96 _feeNumerator;
        IERC20 _rewardToken = auctionData[auctionId].ERC20Address;
        address _erc721Token = auctionData[auctionId].tokenContract;
        uint256 _erc721Id = auctionData[auctionId].tokenId;
        address _tokenOwner = auctionData[auctionId].tokenOwner;
        bytes32 _last_element = auctionData[auctionId].last_element;

        (
                address winner,
                uint96 winAmount

            ) = _last_element.decodeOrder();

        // fee depends on this auction is discont or not
        if(discounts[auctionId]) {
            _feeNumerator = feeNumerator;
        }
        else {
            _feeNumerator = feeDiscountNumerator;
        }

        // caculate fee
        if(feeTo != address(0)) {
            _fee = winAmount.mul(_feeNumerator)
                            .div(FEE_DENOMINATOR)
                            .toUint96();
        }

        // amount token will transfer for winner
        winAmount = winAmount.sub(_fee).toUint96();

        // remove winner from pay back list
        auctionData[auctionId].last_element = sellOrders[auctionId].prev(_last_element);

        // pay back list: return ERC20 for lost bidder list
        bool success = _forceCancelAllBid(auctionId);

        // delete auction informations
        delete auctionData[auctionId];
        delete sellOrders[auctionId];
        delete isBid[auctionId];

        _rewardToken.transfer(
                _tokenOwner,
                winAmount
            );

        IERC721(_erc721Token).safeTransferFrom(
                address(this),
                winner,
                _erc721Id
            );

        if(_fee != 0) {
            _rewardToken.transfer(
                feeTo,
                _fee
            );
        }

        if(!success) revert('Bid order to remove has wrong infomation');

        emit AuctionEnded(auctionId, winner, winAmount);
    }

    function _cancelAuction(uint256 auctionId)
    internal {

        address tokenOwner = auctionData[auctionId].tokenOwner;
        address tokenContract = auctionData[auctionId].tokenContract;
        uint256 tokenId = auctionData[auctionId].tokenId;

        delete sellOrders[auctionId];
        delete auctionData[auctionId];
        delete isBid[auctionId];

        IERC721(tokenContract).safeTransferFrom(address(this), tokenOwner, tokenId);

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

        bytes32 _last_element = auctionData[auctionId].last_element;
        bool success = sellOrders[auctionId].removeKeepHistory(_orderInfo);
        if(success) {
            (
                address _userAddress,
                uint96 _amount
            ) = _orderInfo.decodeOrder();

            require(_userAddress == msg.sender, 'Only the user can cancel their orders');

            if(_orderInfo == _last_element) {

                auctionData[auctionId].last_element = sellOrders[auctionId].prev(_last_element);
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