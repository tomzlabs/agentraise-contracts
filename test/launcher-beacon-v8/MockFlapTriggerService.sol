// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {ITriggerReceiver} from "../../contracts/launcher-beacon-v8/IFlapTriggerService.sol";

/// @notice Unit-test stand-in for FlapTriggerService (etched at the BSC address). execute() plays the backend.
contract MockFlapTriggerService {
    enum TriggerStatus { PENDING, EXECUTED, FAILED }
    struct TriggerRequest { address requester; uint64 executeAfter; TriggerStatus status; uint128 feePaid; }
    uint256 public fee; uint256 public maxGas; uint256 public count;
    mapping(uint256 => TriggerRequest) public reqs;
    event FlapTriggerRequested(uint256 requestId, address indexed requester, uint64 executeAfter, uint256 gasFeesPaid);
    event FlapTriggerExecuted(uint256 requestId, bool success, bytes data);
    function configure(uint256 f, uint256 g) external { fee = f; maxGas = g; }
    function getFee() external view returns (uint256) { return fee; }
    function getMaxCallbackGas() external view returns (uint256) { return maxGas; }
    function getRequestCount() external view returns (uint256) { return count; }
    function getRequest(uint256 id) external view returns (TriggerRequest memory) { return reqs[id]; }
    function requestTrigger(uint64 executeAfter) external payable returns (uint256 id) {
        require(msg.value >= fee, "InsufficientGasFee");
        id = count++; reqs[id] = TriggerRequest(msg.sender, executeAfter, TriggerStatus.PENDING, uint128(msg.value));
        emit FlapTriggerRequested(id, msg.sender, executeAfter, msg.value);
    }
    /// backend: bounded-gas callback; failure → FAILED (does not revert)
    function execute(uint256 id) public returns (bool ok) {
        TriggerRequest storage r = reqs[id]; require(r.requester != address(0) && r.status == TriggerStatus.PENDING, "InvalidRequestStatus");
        bytes memory data; (ok, data) = r.requester.call{gas: maxGas}(abi.encodeCall(ITriggerReceiver.trigger, (id)));
        r.status = ok ? TriggerStatus.EXECUTED : TriggerStatus.FAILED; emit FlapTriggerExecuted(id, ok, data);
    }
    function retryTrigger(uint256 id) external {
        TriggerRequest storage r = reqs[id]; require(r.status == TriggerStatus.FAILED, "InvalidRequestStatus");
        (bool ok, bytes memory data) = r.requester.call(abi.encodeCall(ITriggerReceiver.trigger, (id)));
        require(ok, "RetryFailed"); r.status = TriggerStatus.EXECUTED; emit FlapTriggerExecuted(id, ok, data);
    }
    /// backend loop: run every PENDING request in order (including ones created during callbacks)
    function drain() external returns (uint256 runs) { for (uint256 i; i < count; ++i) if (reqs[i].status == TriggerStatus.PENDING) { execute(i); ++runs; } }
}
