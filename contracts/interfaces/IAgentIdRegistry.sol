// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice SPACE ID Agent ID registry (HandleRegistry, "SPACE ID Agent ID"/"AI") on BSC mainnet
///         0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F. Soulbound ERC-721, one handle per address,
///         tokenId = uint256(keccak256(bytes(handle))). Minted by SPACE ID's signer to Binance Agentic Wallets.
interface IAgentIdRegistry {
    function handleOf(address owner) external view returns (string memory);
    function ownerOfHandle(string calldata handle) external view returns (address);
    function balanceOf(address owner) external view returns (uint256);
    function ownerOf(uint256 tokenId) external view returns (address);
}
