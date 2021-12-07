// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;


import "../node_modules/@openzeppelin/contracts/token/ERC721/ERC721.sol";

contract MyERC721 is ERC721 {
    constructor () public
        ERC721("Evry ERC721", "E721")
    {
    }

    /**
    * Custom accessor to create a unique token
    */
    function mintUniqueTokenTo(
        address _to,
        uint256 _tokenId
    ) public
    {
        super._mint(_to, _tokenId);
    }
}