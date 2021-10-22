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

    Counters.Counter private _auctionIdTracker;

    modifier auctionExists(uint256 auctionId) {
    require(_exists(auctionId), "Auction doesn't exist");
        _;
    }


    event AuctionCreated(
        uint256 indexed auctionId,
        uint256 indexed tokenId,
        address indexed tokenContract,
        uint256 duration,
        uint256 reservePrice,
        address tokenOwner,
        uint8 minBidIncrementPerOrder
    );

    event NewSellOrder(
        uint256 indexed auctionId,
        uint64 indexed userId,
        uint96 buyAmount,
        uint96 sellAmount
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

    mapping(uint256 => IterableOrderedOrderSet.Data) internal sellOrders;
    mapping(uint256 => Auction) public auctionData;

        /**
     * @notice Create an auction.
     * @dev Store the auction details in the auctions mapping and emit an AuctionCreated event.
     * If there is no curator, or if the curator is the auction creator, automatically approve the auction.
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
        require(msg.sender == IERC721(tokenContract).getApproved(tokenId) || msg.sender == tokenOwner, "Caller must be approved or owner for token id");
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
    returns(bool) {
        require(msg.sender != auctionData[auctionId].tokenOwner , "A user can not bid their own Auction");
        require(auctionData[auctionId].approved, 'Auction must be approved by owner');
        require(block.timestamp <
                auctionData[auctionId].start_time.add(auctionData[auctionId].duration),
                'Auction expired'
        );

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

            return true;
        }

        return false;
    }

    function _exists(uint256 auctionId) internal view returns(bool) {
        return auctionData[auctionId].tokenOwner != address(0);
    }
}