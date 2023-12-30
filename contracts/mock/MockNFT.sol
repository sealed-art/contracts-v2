//SPDX-License-Identifier: None
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";

contract MockNFT is ERC721Enumerable {
    constructor() ERC721("Test NFT", "TEST") {}
    uint public last;

    function mint(address receiver) external {
        _mint(receiver, last++);
    }

    function mintId(address receiver, uint id) external {
        _mint(receiver, id);
    }

    function mintToCaller() external {
        _mint(msg.sender, last++);
    }

    function _baseURI() internal pure override returns (string memory) {
        return "ipfs://QmZcH4YvBVVRJtdn4RdbaqgspFU8gH6P9vomDpBVpAL3u4/";
    }
}
