// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IFlapPoolPortal} from "./IFlapPoolPortal.sol";

/// @notice Callbacks the AgentRaiseFactory exposes to its own vaults (onlyVault) + shared views.
interface IAgentRaiseFactory {
    function portal() external view returns (address);
    function agentIdRegistry() external view returns (address);
    function creatorRaised(address) external view returns (uint256);
    function points(address) external view returns (uint256);
    function saltHolder(bytes32 salt) external view returns (uint256);
    function claimSalt(uint256 raiseId, bytes32 salt) external returns (bool lockedByCaller);
    function markSaltLocked(uint256 raiseId, bytes32 salt) external;
    function releaseSalt(uint256 raiseId, bytes32 salt) external;
    function onContribution(uint256 raiseId, address creator, address who, uint256 amount, bool add) external;
    function fsiSetRound(uint256 raiseId, bytes32 ns, address account, uint256 value) external;
    function fsiAppend(uint256 raiseId, bytes32 ns, uint256 seq, address actor, address related, string calldata data) external;
    function launchFloor(address prep, uint256 px, uint256 poolQuote, uint256 poolTokens, uint256 supply) external view returns (IFlapPoolPortal.GraduationFloorResultV2 memory);
    function fsiLog(uint256 raiseId, bytes32 ns, address actor, address related, uint256 amount, uint256 extra) external;
}
