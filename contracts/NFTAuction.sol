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


  event AuctionCreated(
        uint256 indexed auctionId,
        uint256 indexed tokenId,
        address indexed tokenContract,
        uint256 duration,
        uint256 reservePrice,
        address tokenOwner,
        uint8 curatorFeePercentage
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
        // The minimum price of the first bid
        uint256 reservePrice;
        // The sale percentage to send to the curator
        uint8 curatorFeePercentage;
        // The address that should receive the funds once the NFT is sold.
        address tokenOwner;
        // The address of the current highest bid
        address bidder;
        //Amout of highest bid price
        uint96 amout;
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
        uint256 reservePrice,
        uint8 curatorFeePercentage
    ) public  whenNotPaused returns (uint256) {
        require(
            IERC165(tokenContract).supportsInterface(interfaceId),
            "tokenContract does not support ERC721 interface"
        );
        require(curatorFeePercentage < 100, "curatorFeePercentage must be less than 100");
        address tokenOwner = IERC721(tokenContract).ownerOf(tokenId);
        require(msg.sender == IERC721(tokenContract).getApproved(tokenId) || msg.sender == tokenOwner, "Caller must be approved or owner for token id");
        uint256 auctionId = _auctionIdTracker.current();

        sellOrders[auctionId].initializeEmptyList();

        auctionData[auctionId] = Auction (
          tokenId,
          biddingToken,
          tokenContract,
          duration,
          reservePrice,
          curatorFeePercentage,
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
            curatorFeePercentage
        );

        return auctionId;
    }
}