// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IDistReenter { function schedule(address launcher) external returns (uint256); function fund(address launcher) external payable; }

/// @notice Test-only hostile Trigger Service (etched at the BSC address): requestTrigger re-enters the distributor.
contract MockReentrantTrigger {
    address public target; uint256 public mode; // 1 = re-enter schedule, 2 = re-enter fund
    function set(address t, uint256 m) external { target = t; mode = m; }
    function getFee() external pure returns (uint256) { return 0.0002 ether; }
    function requestTrigger(uint64) external payable returns (uint256) {
        if (mode == 1) IDistReenter(msg.sender).schedule(target);
        else IDistReenter(msg.sender).fund(target);
        return 7;
    }
}
