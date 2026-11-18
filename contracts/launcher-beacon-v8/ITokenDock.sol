// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Flap Token Dock interface as published in the Pool Launch guide ("Reserve options: AllocationStrategy or Token Dock",
///         https://docs.flap.sh/en/flap/drafts/pool-launch). TokenDockRouter, OpenTokenDock and VerifiedTokenDock all expose it.
interface ITokenDock {
    /// @notice Credit `amount` of `token` to msg.sender's balance. Pulls via transferFrom and checks the balance delta.
    function deposit(address token, uint256 amount) external;
    /// @notice Debit msg.sender's balance and send to `to`. Never gated.
    function withdraw(address token, uint256 amount, address to) external;
    function balanceOf(address token, address owner) external view returns (uint256);
    function totalReserved(address token) external view returns (uint256);
    function isWhitelisted(address vault, address token) external view returns (bool);
    event FlapTokenDockDeposited(address token, address owner, uint256 amount);
    event FlapTokenDockWithdrawn(address token, address owner, address to, uint256 amount);
}

interface IERC20Approve {
    function approve(address spender, uint256 amount) external returns (bool);
}
