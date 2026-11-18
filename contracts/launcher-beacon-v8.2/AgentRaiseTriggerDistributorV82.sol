// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IFlapTriggerService, ITriggerReceiver} from "../launcher-beacon-v8/IFlapTriggerService.sol";
import {AgentRaiseLauncherV82} from "./AgentRaiseLauncherV82.sol";

interface IAgentRaiseFactoryV81Min { function raiseOfVault(address vault) external view returns (uint256); }

/// @title AgentRaise V8.2 Trigger Distributor (= V8.1 logic unchanged; bound to the V8.2 factory/launcher types): distribution starts automatically AT SETTLE and continues via Flap Trigger.
/// @notice Non-upgradeable add-on, no owner. Drop-in for the audited V8 launcher (AgentRaiseLauncherV82 source unchanged): the
///         launcher already calls `fund{value: reserve}(address(this))` inside settle, after its 20 pushes and only when
///         contributors remain. V8.1 makes that call also register the FIRST Trigger request in the same transaction, so no
///         user transaction is needed after settle. Each callback pushes BATCH contributors and pays the next request from the
///         launcher's budget (reserved out of the 3% fee) until everyone is pushed.
///         Fail-safe (settle liveness): an auto-schedule failure NEVER reverts settle. It is reported with AutoScheduleFailed /
///         OutOfBudget (budget kept), and recovery is a permissionless schedule() / fund() by anyone once the Trigger Service works
///         again. Not enough gas for the auto-schedule step reverts with EMPTY data, which the launcher treats as out-of-gas and
///         reverts the whole transaction, so a caller cannot make settle "succeed without scheduling" by under-funding gas.
contract AgentRaiseTriggerDistributorV82 is ITriggerReceiver {
    IFlapTriggerService public constant TRIGGER = IFlapTriggerService(0xcf4EE25035CF883895110f367F5BA8172416a7F9);
    address public constant TREASURY = 0xE04c10D1160797c018630152e1ff8B13B50681d6;
    /// @notice Pushes per callback (≈109.5k gas each on a BSC fork → 14 ≈ 1.54M < 2M callback cap). Unchanged from V8.
    uint256 public constant BATCH = 14;
    /// @notice A callback with less gas than this reverts (request → FAILED, anyone retries via TRIGGER.retryTrigger). Unchanged.
    uint256 public constant MIN_CALLBACK_GAS = 600_000;
    /// @notice Reserve basis when getFee() is unavailable/nonsensical at settle (current mainnet fee), so a budget still exists
    ///         for the later permissionless restart. The launcher caps the reserve at the 3% fee; unused budget is swept to TREASURY.
    uint256 public constant FALLBACK_FEE = 0.0002 ether;
    /// @notice Gas forwarded to getFee() / requestTrigger() on the auto-schedule path (fixed caps: a caller cannot shrink them).
    uint256 public constant FEE_READ_GAS = 50_000;
    uint256 public constant REQUEST_GAS = 300_000;
    /// @notice Minimum gasleft() before each auto-schedule external call; below it the call reverts with empty data (= OOG).
    uint256 public constant AUTO_MIN_GAS = 420_000;
    address public immutable FACTORY;

    mapping(address => uint256) public budgetOf;          // launcher → prepaid BNB for trigger fees
    mapping(uint256 => address) public launcherOfRequest; // requestId → launcher (deleted on use: anti-replay)
    mapping(address => uint256) internal _pending;        // launcher → requestId + 1 (0 = none)
    uint256 private _lock = 1;

    event Funded(address indexed launcher, address indexed from, uint256 amount);
    event Scheduled(address indexed launcher, uint256 indexed requestId, uint256 fee, uint256 budgetLeft);
    event BatchDistributed(address indexed launcher, uint256 indexed requestId, uint256 remaining);
    event OutOfBudget(address indexed launcher, uint256 budget, uint256 fee);
    event BudgetSwept(address indexed launcher, uint256 amount);
    /// @notice V8.1: the automatic first (or resumed) request could not be registered; nothing is pending, budget kept.
    ///         `reason` = raw revert data from the Trigger Service (empty for a gas-capped failure or missing code).
    event AutoScheduleFailed(address indexed launcher, uint256 budget, bytes reason);

    modifier nonReentrant() { require(_lock == 1, "AR: reentrant"); _lock = 2; _; _lock = 1; }

    constructor(address factory_) { require(factory_ != address(0), "AR: bad params"); FACTORY = factory_; }

    /// @notice Trigger budget for `remaining` contributors left after the settle push: (ceil(remaining / 14) + 1 spare) × fee.
    ///         Never reverts. V8.1: an unavailable / zero / > 1 BNB getFee() uses FALLBACK_FEE instead of 0, so the outage is
    ///         reported by fund() (AutoScheduleFailed) instead of silently skipping the distributor.
    function reserveFor(uint256 remaining) public view returns (uint256) {
        if (remaining == 0) return 0;
        (bool ok, uint256 fee) = _readFee();
        if (!ok || fee == 0 || fee > 1 ether) fee = FALLBACK_FEE;
        return ((remaining + BATCH - 1) / BATCH + 1) * fee;
    }

    /// @notice Credit BNB to a launcher's trigger budget. Called by the launcher inside settle (V8 launcher code, unchanged)
    ///         and by anyone as a top-up. If the raise is settled, contributors remain and nothing is pending, it also
    ///         registers the next Trigger request automatically (first request at settle; resume after OutOfBudget/outage).
    function fund(address launcher) external payable nonReentrant {
        uint256 id = _raiseId(launcher);
        require(id != 0, "AR: unknown launcher");
        budgetOf[launcher] += msg.value;
        emit Funded(launcher, msg.sender, msg.value);
        if (_pending[launcher] != 0) return; // never double-schedule
        AgentRaiseLauncherV82.Raise memory r = AgentRaiseLauncherV82(payable(launcher)).getRaise(id);
        if (r.settled && r.distCursor < r.contributorCount) _autoSchedule(launcher);
    }

    /// @notice Exceptional, permissionless fallback (normal flow needs no call): restart after AutoScheduleFailed or OutOfBudget.
    function schedule(address launcher) external nonReentrant returns (uint256 requestId) {
        uint256 id = _raiseId(launcher);
        require(id != 0, "AR: unknown launcher");
        require(_pending[launcher] == 0, "AR: already scheduled");
        AgentRaiseLauncherV82.Raise memory r = AgentRaiseLauncherV82(payable(launcher)).getRaise(id);
        require(r.settled && r.distCursor < r.contributorCount, "AR: nothing to distribute");
        bool ok; (ok, requestId) = _schedule(launcher);
        require(ok, "AR: out of budget");
    }

    /// @notice Trigger Service callback: push the next BATCH contributors, then schedule the next batch if any remain. Unchanged.
    function trigger(uint256 requestId) external override nonReentrant {
        require(msg.sender == address(TRIGGER), "AR: only trigger service");
        require(gasleft() >= MIN_CALLBACK_GAS, "AR: callback gas too low");
        address launcher = launcherOfRequest[requestId];
        require(launcher != address(0), "AR: unknown request");
        delete launcherOfRequest[requestId];
        delete _pending[launcher];
        uint256 remaining = AgentRaiseLauncherV82(payable(launcher)).distribute(_raiseId(launcher), BATCH);
        emit BatchDistributed(launcher, requestId, remaining);
        if (remaining != 0) _schedule(launcher);
    }

    /// @notice After every contributor was pushed (cursor at the end) and nothing is pending, unused budget → treasury. Unchanged.
    function sweepBudget(address launcher) external nonReentrant {
        uint256 id = _raiseId(launcher);
        require(id != 0 && _pending[launcher] == 0, "AR: pending");
        AgentRaiseLauncherV82.Raise memory r = AgentRaiseLauncherV82(payable(launcher)).getRaise(id);
        require(r.settled && r.distCursor == r.contributorCount, "AR: not finished");
        uint256 amt = budgetOf[launcher];
        budgetOf[launcher] = 0;
        (bool ok,) = payable(TREASURY).call{value: amt}("");
        require(ok, "AR: transfer failed");
        emit BudgetSwept(launcher, amt);
    }

    function pendingRequestOf(address launcher) external view returns (bool pending, uint256 requestId) {
        uint256 p = _pending[launcher];
        return (p != 0, p == 0 ? 0 : p - 1);
    }

    /// @dev Reverting variant (explicit schedule() and the in-callback next batch → FAILED request, retryable). Unchanged.
    function _schedule(address launcher) internal returns (bool, uint256 requestId) {
        uint256 fee = TRIGGER.getFee();
        uint256 b = budgetOf[launcher];
        if (b < fee) { emit OutOfBudget(launcher, b, fee); return (false, 0); }
        budgetOf[launcher] = b - fee;
        requestId = TRIGGER.requestTrigger{value: fee}(0);
        launcherOfRequest[requestId] = launcher;
        _pending[launcher] = requestId + 1;
        emit Scheduled(launcher, requestId, fee, b - fee);
        return (true, requestId);
    }

    /// @dev Non-reverting variant used from fund() (i.e. inside settle). Every failure emits an event; gas shortage reverts empty.
    function _autoSchedule(address launcher) internal {
        _needGas();
        uint256 b = budgetOf[launcher];
        (bool ok, uint256 fee) = _readFee();
        if (!ok) { emit AutoScheduleFailed(launcher, b, ""); return; }
        if (b < fee) { emit OutOfBudget(launcher, b, fee); return; }
        budgetOf[launcher] = b - fee; // effects first; restored if the request is not registered
        _needGas();
        bytes memory ret;
        (ok, ret) = address(TRIGGER).call{value: fee, gas: REQUEST_GAS}(abi.encodeCall(IFlapTriggerService.requestTrigger, (uint64(0))));
        if (!ok) { budgetOf[launcher] = b; emit AutoScheduleFailed(launcher, b, ret); return; }
        if (ret.length < 32) { emit AutoScheduleFailed(launcher, b - fee, ret); return; } // fee taken, no id: report, no pending
        uint256 requestId = abi.decode(ret, (uint256));
        launcherOfRequest[requestId] = launcher;
        _pending[launcher] = requestId + 1;
        emit Scheduled(launcher, requestId, fee, b - fee);
    }

    function _readFee() internal view returns (bool, uint256) {
        (bool ok, bytes memory ret) = address(TRIGGER).staticcall{gas: FEE_READ_GAS}(abi.encodeCall(IFlapTriggerService.getFee, ()));
        if (!ok || ret.length < 32) return (false, 0);
        return (true, abi.decode(ret, (uint256)));
    }

    /// @dev Empty revert = out-of-gas for the launcher's auto-settle guard (whole tx reverts; never a silent skip).
    function _needGas() internal view { if (gasleft() < AUTO_MIN_GAS) assembly { revert(0, 0) } }

    function _raiseId(address launcher) internal view returns (uint256) { return IAgentRaiseFactoryV81Min(FACTORY).raiseOfVault(launcher); }
}
