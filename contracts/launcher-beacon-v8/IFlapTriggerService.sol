// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// @notice Subset of Flap's IFlapTriggerService (docs.flap.sh … /preview/flap-trigger-service). BSC: 0xcf4EE25035CF883895110f367F5BA8172416a7F9.
interface IFlapTriggerService {
    enum TriggerStatus { PENDING, EXECUTED, FAILED }
    struct TriggerRequest { address requester; uint64 executeAfter; TriggerStatus status; uint128 feePaid; }
    function requestTrigger(uint64 executeAfter) external payable returns (uint256 requestId);
    function trigger(uint256 requestId) external;
    function retryTrigger(uint256 requestId) external;
    function getFee() external view returns (uint256 gasFee);
    function getMaxCallbackGas() external view returns (uint256 maxGas);
    function getRequest(uint256 requestId) external view returns (TriggerRequest memory request);
    function getRequestCount() external view returns (uint256 count);
}

/// @notice Requester callback (called by FlapTriggerService with at most getMaxCallbackGas()).
interface ITriggerReceiver {
    function trigger(uint256 requestId) external;
}

/// @notice What the launcher needs from the V8 distribution add-on (settle-time reserve funding only).
interface IAgentRaiseDistributorV8 {
    function FACTORY() external view returns (address);
    function reserveFor(uint256 remaining) external view returns (uint256);
    function fund(address launcher) external payable;
}
