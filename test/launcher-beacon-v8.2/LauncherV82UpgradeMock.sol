// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {AgentRaiseLauncherV82} from "../../contracts/launcher-beacon-v8.2/AgentRaiseLauncherV82.sol";

/// @notice Test-only "next" implementation: identical V8.2 logic + one new view, same ERC-7201 layout (append-only).
contract LauncherV82UpgradeMock is AgentRaiseLauncherV82 {
    constructor(address factory_, address distributor_) AgentRaiseLauncherV82(factory_, distributor_) {}
    function upgradeMarker() external pure returns (uint256) { return 8_001; }
}
