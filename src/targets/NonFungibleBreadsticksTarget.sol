// SPDX-License-Identifier: MIT or Apache-2.0
pragma solidity ^0.8.30;

interface INonFungibleBreadsticks {
    function approve(address to, uint256 tokenId) external;
    function balanceOf(address owner) external view returns (uint256);
    function breadsticksToReserve() external view returns (uint256);
    function getApproved(uint256 tokenId) external view returns (address);
    function imageURI() external view returns (string memory);
    function imageURI2() external view returns (string memory);
    function isApprovedForAll(address owner, address operator) external view returns (bool);
    function mintBreadstick() external;
    function name() external view returns (string memory);
    function owner() external view returns (address);
    function ownerOf(uint256 tokenId) external view returns (address);
    function pause() external;
    function paused() external view returns (bool);
    function renounceOwnership() external;
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
    function safeTransferFrom(address from, address to, uint256 tokenId, bytes calldata _data) external;
    function setApprovalForAll(address operator, bool approved) external;
    function setImageURI(string calldata uri) external;
    function setImageURI2(string calldata uri) external;
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
    function symbol() external view returns (string calldata);
    function tokenURI(uint256 tokenId) external view returns (string calldata);
    function totalSupply() external view returns (uint256);
    function transferFrom(address from, address to, uint256 tokenId) external;
    function transferOwnership(address newOwner) external;
    function unpause() external;
}

error Paused();
error PassedTargetIndex(uint256 id);
error TooEarly(uint256 id);

contract NonFungibleBreadsticksTarget {
    // TODO: i was having an issue earlier with immutables. what was it?
    INonFungibleBreadsticks immutable NFB;

    constructor(INonFungibleBreadsticks nfb) {
        NFB = nfb;
    }

    // // note: FlashAccount already has onERC721Received. we don't need it here. this would just bloat deploy costs
    // // note: commenting this out also keeps people from calling gorge directly on this contract
    // function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
    //     return this.onERC721Received.selector;
    // }

    function gorge(uint256 max_order_size, uint256 target_index) external {
        if (NFB.paused()) {
            revert Paused();
        }

        uint256 current_index = NFB.totalSupply();

        if (current_index > target_index) {
            revert PassedTargetIndex(current_index);
        }

        if (current_index + max_order_size < target_index) {
            revert TooEarly(current_index);
        }

        while (current_index <= target_index) {
            NFB.mintBreadstick();
            current_index += 1;
        }
    }
}
