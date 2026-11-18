// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IAuditMathV8} from "../launcher-beacon-v8/IAuditMathV8.sol";
import {RescueStateV82, GuardianRescueV82, IGuardianRescueV82} from "./GuardianRescueV82.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IAgentRaiseFactory} from "../interfaces/IAgentRaiseFactory.sol";
import {IFlapPoolPortal, IERC20Min} from "../interfaces/IFlapPoolPortal.sol";
import {IStrategy as ILauncherStrategy} from "./flap/IStrategy.sol";
import {LaunchExtensionHelper} from "./flap/LaunchExtensionHelper.sol";
import {IAgentIdRegistry} from "../interfaces/IAgentIdRegistry.sol";
import {ITokenDock, IERC20Approve} from "../launcher-beacon-v8/ITokenDock.sol";
import {IAgentRaiseDistributorV8} from "../launcher-beacon-v8/IFlapTriggerService.sol";
import {ILauncherDescription} from "./flap/ILauncher.sol";

/// @title AgentRaise Launcher V8.2 = V8 logic + Flap Pool Launch description() (ILauncherDescription, JSON v1 rendered by the official
///        LauncherBase / LauncherHelper.toJson inside the fixed GuardianRescueV82 module) + 3% success fee (FEE_BPS 300).
///        V8 = V7 logic unchanged (Flap Token Dock custody, mandatory salt lock, hardCap-only live floor, auto-settle on fill)
///        deployed as one BeaconProxy per raise behind the factory's UpgradeableBeacon (upgrade authority: Flap Guardian only).
/// @notice Economic/state-machine logic copied from the local legacy vault, not an upgrade of it.
/// Factory is the only initializer; Portal provenance uses newLauncher, not Preparation.
/// No admin withdrawal. The ONLY upgrade path is factory.upgradeVaultImplementation (onlyGuardian = Flap Guardian) → beacon.upgradeTo.
/// Salt fees are separate from fundraising proceeds.
contract AgentRaiseLauncherV82 is Initializable, ILauncherStrategy, ILauncherDescription {
    // ───────────── types ─────────────
    enum State { LIVE, FILLED, SETTLEABLE, SETTLED, REFUNDING, EMERGENCY }

    /// @notice Share sale (the only mode in v8).
    struct ShareConfig {
        uint256 sharePrice;        // BNB (wei) per share, fixed at create (≥ MIN_SHARE_PRICE)
        uint32 maxShares;          // hard cap in shares (hardCap = sharePrice · maxShares); V7: the only cap
        uint8 perWalletCap;        // 10 or 20 shares per wallet / Agent ID (creator included)
    }

    /// @notice Flap Pool Launch parameters, fixed at createRaise (nothing is deployed until settle).
    struct LaunchConfig {
        string tokenName;          // 1..32 bytes
        string tokenSymbol;        // 1..12 bytes
        string tokenMeta;          // Flap meta IPFS CID ≤ 128 bytes
        uint256 totalSupply;       // [100 ether, 1e15 ether]; 0 → 1e9 ether
        bytes32 salt;              // CREATE2 salt → token address ends in 0x7777 (checked by the Portal)
        uint16 buyTaxBps;          // ≤ 1000 (UI default 100 = 1%)
        uint16 sellTaxBps;         // ≤ 1000 (UI default 100 = 1%)
        uint32 taxDuration;        // seconds, ≥ antiFarmerDuration
        uint32 antiFarmerDuration; // seconds
        uint16 creatorShareBps;    // ≤ 1000 of post-fee BNB → beneficiary (default 0)
        IFlapPoolPortal.FeeConfig[] feeConfigs; // empty → 100% DIVIDEND in BNB to holders, min share 0.001% of supply
    }

    struct Raise {
        address creator;
        address beneficiary;
        address token;             // set at settle
        address pool;              // set at settle
        uint64 deadline;
        bool closed;               // hardCap reached
        bool settled;
        bool failed;               // markFailed
        bool saltLocked;           // salt reserved on the Portal with this contract as locker (F7)
        uint256 hardCap;
        uint256 totalRaised;
        uint256 contributorCount;
        uint256 saleTokens;        // contributors' pro-rata pool
        uint256 poolTokens;
        uint256 beneficiaryOwed;   // F14(b): creator BNB share awaiting claimBeneficiary()
        uint64 closedAt;           // hardCap reached at (0 = not closed)
        uint64 settledAt;          // settle timestamp
        uint256 distCursor;        // next contributor index to push
        uint256 distributed;       // tokens delivered to contributors so far
        string title;
        string metaCid;
        string agentId;
    }

    // ───────────── constants / immutables ─────────────
    address public constant TREASURY = 0xE04c10D1160797c018630152e1ff8B13B50681d6;
    uint256 public constant FEE_BPS = 300; // V8.2: 3% success fee (was 2% in V8/V8.1; includes the Trigger auto-distribution reserve)
    uint256 public constant SETTLE_GRACE = 3 days;        // F14(c)
    // v11: parameter-limit constants live in AgentRaiseFactory (validation moved there, EIP-170)
    uint256 internal constant DEFAULT_SUPPLY = 1e9 ether;
    uint256 internal constant SETTLE_WINDOW = 30 days;
    uint256 public constant SETTLE_PUSH = 20; // V7: contributors pushed (dock withdrawals) inside settle(); rest via distribute(). 40→20 keeps the filling contribute ≈8-9M gas on a BSC fork (dock withdraw + dividend setShare ≈129k/push)
    /// @notice V4: gas that must remain when the filling contribution reaches auto-settle (covers the Portal launch; pushes
    ///         that still run short degrade to claim()). Below it the filling contribution reverts so estimators raise the limit.
    uint256 public constant AUTO_SETTLE_MIN_GAS = 8_000_000;
    uint256 internal constant PUSH_MIN_GAS = 340_000;
    /// @notice v11 (Flap audit SYS-FLAP-FIXED-ADDRESSES): canonical Flap Portal, hardcoded (same as factory.PORTAL).
    IFlapPoolPortal internal constant PORTAL = IFlapPoolPortal(0x000042108465206185A077Edc3F3fd2b49060000);
    /// @notice V7 (Flap SYS-FLAP-DISTRIBUTION-CUSTODY): sale tokens are custodied in Flap's shared Token Dock via its router
    ///         (routes Open/Verified dock internally; never cache the underlying dock). Payouts are dock withdrawals.
    ITokenDock public constant TOKEN_DOCK_ROUTER = ITokenDock(0x000048E888aBf09f690a952E1b386b2D031a0000);

    bytes32 constant NS_CREATOR_RAISED = "creatorRaised";
    bytes32 constant NS_RAISE_TOTAL = "raiseTotal";
    bytes32 constant NS_CONTRIB = "contrib";
    bytes32 constant NS_RAISE_META = "raiseMeta";
    bytes32 constant NS_CONTRIB_LOG = "contribLog";
    bytes32 constant NS_REFUND_LOG = "refundLog";
    bytes32 constant NS_SETTLE_LOG = "withdrawLog";
    bytes32 constant NS_POINTS = "points";

    /// @custom:storage-location erc7201:agentraise.launcher.v1
    struct Layout {
        IAgentRaiseFactory factory;
        IFlapPoolPortal portal;     // DEPRECATED (v11, Flap SYS-FLAP-FIXED-ADDRESSES): unused, kept for layout; see PORTAL
        IAgentIdRegistry registry;
        uint256 raiseId;            // the single raise this vault holds
        uint256 _lock;
        uint256 _launchingId;       // raise being launched (strategy callback guard)
        uint256 _expectDist;        // exact remainder amount expected from the Portal
        address _distToken;         // token delivered through initializeDistribution
        mapping(uint256 => Raise) _raises;
        mapping(uint256 => ShareConfig) _configs;
        mapping(uint256 => LaunchConfig) _launchCfg;
        mapping(uint256 => uint256) metaSeq;
        mapping(uint256 => address[]) _contributors;
        mapping(uint256 => mapping(address => uint256)) contributionOf;
        mapping(uint256 => mapping(address => bool)) tokensSent;
        mapping(uint256 => mapping(address => string)) contributorAgentId;
        mapping(uint256 => mapping(uint256 => address)) idUsedBy; // Agent ID tokenId => wallet (one ID, one wallet)
        mapping(uint256 => uint256) sharesSold;
        mapping(uint256 => mapping(address => uint256)) sharesOf;
        uint256 taxClaimed;         // v10: BNB tax forwarded to the beneficiary so far
        mapping(uint256 => uint256) paidCount; // V7: contributors whose sale tokens left the dock (dust sweep gate)
    }
    // keccak256(abi.encode(uint256(keccak256("agentraise.launcher.v1")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant LAYOUT_SLOT = 0xa7ac83b785d5e261f04a39ecccf3d3d4ba6bc81762518e7fff25b9a6d5225700;
    function _l() private pure returns (Layout storage $) { bytes32 p = LAYOUT_SLOT; assembly { $.slot := p } }

    // ───────────── events ─────────────
    event RaiseCreated(uint256 indexed raiseId, address indexed creator, address indexed beneficiary, string agentId, uint256 sharePrice, uint256 hardCap, uint64 deadline);
    event LaunchConfigured(uint256 indexed raiseId, bytes32 salt, bool saltLocked, uint256 totalSupply, uint256 poolTokens, uint256 saleTokens,
        uint16 buyTaxBps, uint16 sellTaxBps, uint16 creatorShareBps);
    event Contributed(uint256 indexed raiseId, address indexed contributor, uint256 amount, uint256 shares, string agentId);
    event RaiseClosed(uint256 indexed raiseId, uint256 totalRaised);
    event Settled(uint256 indexed raiseId, address indexed token, address pool, uint256 fee, uint256 creatorCash, uint256 poolQuote, uint256 poolTokens);
    event TokensSent(uint256 indexed raiseId, address indexed contributor, uint256 amount, bool claimed);
    event TokensPushFailed(uint256 indexed raiseId, address indexed contributor);
    event Failed(uint256 indexed raiseId, address by);
    event Refunded(uint256 indexed raiseId, address indexed contributor, uint256 amount);
    event BeneficiaryPaid(uint256 indexed raiseId, address indexed beneficiary, uint256 amount);
    event MetaUpdated(uint256 indexed raiseId, uint256 seq, string metaCid);
    event TaxClaimed(uint256 indexed raiseId, address indexed beneficiary, uint256 amount);
    /// @notice V4: the hardCap-filling contribution tried settle() and it reverted; the contribution stands, the raise stays
    ///         closed and settle() remains callable by anyone (same rules as V3). `reason` is the bubbled revert data.
    event AutoSettleFailed(uint256 indexed raiseId, bytes reason);


    modifier nonReentrant() { require(!RescueStateV82.state().halted, "AR: emergency recovery"); require(_l()._lock == 1, "AR: reentrant"); _l()._lock = 2; _; _l()._lock = 1; }

    /// @custom:oz-upgrades-unsafe-allow constructor
    address public immutable DEPLOYING_FACTORY;
    address public immutable RESCUE_MODULE;
    /// @notice V8: Trigger Service distribution add-on funded at settle from the fee.
    IAgentRaiseDistributorV8 public immutable DISTRIBUTOR;
    /// @dev V8: the factory is an explicit constructor argument (V7 used msg.sender) so a Guardian-deployed upgrade
    ///      implementation can bind to the SAME factory. Every proxy shares one beacon; initializers stay disabled here.
    constructor(address factory_, address distributor_) { require(factory_ != address(0) && distributor_ != address(0), "AR: bad params"); DEPLOYING_FACTORY = factory_; DISTRIBUTOR = IAgentRaiseDistributorV8(distributor_); RESCUE_MODULE=address(new GuardianRescueV82()); _disableInitializers(); }

    /// @notice Delegate module fixed per implementation (changes only with a Guardian beacon upgrade). Rescue selectors are in IGuardianRescueV82.
    fallback() external payable {
        require(msg.value == 0, "AR: no rescue value");
        require(msg.sig == GuardianRescueV82.emergencyWithdraw.selector || msg.sig == GuardianRescueV82.setReceiveForward.selector || msg.sig == GuardianRescueV82.rescueStatus.selector || msg.sig == GuardianRescueV82.economicsAt.selector || msg.sig == GuardianRescueV82.economics.selector || msg.sig == GuardianRescueV82.openPriceRatioBps.selector || msg.sig == GuardianRescueV82.status.selector || msg.sig == GuardianRescueV82.getLaunchConfig.selector || msg.sig == GuardianRescueV82.contributors.selector || msg.sig == GuardianRescueV82.sweepDust.selector || msg.sig == GuardianRescueV82.tokensInDock.selector || msg.sig == GuardianRescueV82.paidCount.selector || msg.sig == GuardianRescueV82.launcherDescription.selector, "AR: unknown method");
        if(msg.sig == GuardianRescueV82.emergencyWithdraw.selector || msg.sig == GuardianRescueV82.setReceiveForward.selector || msg.sig == GuardianRescueV82.sweepDust.selector) require(_l()._lock == 1, "AR: reentrant");
        _rescueDelegate();
    }
    function _rescueDelegate() private {
        address module=RESCUE_MODULE;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            calldatacopy(ptr,0,calldatasize())
            let ok := delegatecall(gas(),module,ptr,calldatasize(),0,0)
            returndatacopy(ptr,0,returndatasize())
            switch ok case 0 { revert(ptr,returndatasize()) } default { return(ptr,returndatasize()) }
        }
    }

    /// @notice BNB is accepted only from the Portal while a launch is in flight; stray BNB is rejected.
    ///         v10: after settle the vault also accepts BNB tax (MARKETING slot routed to this vault, see feeConfigsOf).
    receive() external payable {
        if (RescueStateV82.state().forwardEnabled) { _rescueDelegate(); }
        require(!RescueStateV82.state().halted, "AR: emergency recovery");
        Layout storage $ = _l();
        if ($._launchingId != 0) { require(msg.sender == address(PORTAL), "AR: BNB rejected"); return; }
        require($._raises[$.raiseId].settled, "AR: BNB rejected");
    }

    // ───────────── create (no token yet) ─────────────
    /// @dev V7: msg.value MUST be exactly PORTAL.SALT_LOCK_FEE(); `launch.salt` is always locked on the Portal with this
    ///      contract as locker (F7), so no third party can front-lock it and block settle (FlapSaltLockedByAnotherUser).
    function initialize(
        uint256 raiseId,
        address creator,
        string calldata agentId,
        string calldata title,
        string calldata metaCid,
        ShareConfig calldata cfg,
        uint64 deadline,
        address beneficiary,
        LaunchConfig calldata launch
    ) external payable initializer {
        require(msg.sender == DEPLOYING_FACTORY, "AR: not factory");
        Layout storage $ = _l();
        $.factory = IAgentRaiseFactory(msg.sender);
        $.registry = IAgentIdRegistry($.factory.agentIdRegistry());
        $.raiseId = raiseId; $._lock = 2; // locked during init; released at the end
        // v10: all pure parameter checks (title/meta/deadline/shares/wallet cap/launch strings/taxes/fee slots) run in
        // AgentRaiseFactory.createRaise BEFORE this vault is deployed (EIP-170 size). A BeaconProxy deployed by anyone else
        // cannot initialise: every factory callback below is onlyVault.
        uint256 hc = cfg.sharePrice * cfg.maxShares;

        Raise storage r = _l()._raises[raiseId];
        r.creator = creator; r.beneficiary = beneficiary; r.deadline = deadline; r.hardCap = hc;
        r.title = title; r.metaCid = metaCid; r.agentId = agentId;
        _l()._configs[raiseId] = cfg;
        _storeLaunch(raiseId, r, launch);
        _claimSalt(raiseId, r, launch.salt); // F12 registry + mandatory Portal salt lock (msg.value = SALT_LOCK_FEE)
        // Portal records Launcher provenance only after the factory callback returns.
        // The first contribution validates hardCap against the live launch floor; settle remains Portal-enforced.

        emit RaiseCreated(raiseId, creator, beneficiary, agentId, cfg.sharePrice, hc, deadline);
        emit LaunchConfigured(raiseId, launch.salt, r.saltLocked, _l()._launchCfg[raiseId].totalSupply, r.poolTokens, r.saleTokens,
            launch.buyTaxBps, launch.sellTaxBps, launch.creatorShareBps);
        $.factory.fsiSetRound(raiseId, NS_RAISE_TOTAL, address(0), 0);
        $.factory.fsiAppend(raiseId, NS_RAISE_META, 0, creator, beneficiary, metaCid);
        $._lock = 1;
    }

    function _storeLaunch(uint256 raiseId, Raise storage r, LaunchConfig calldata c) internal {
        uint256 supply = c.totalSupply == 0 ? DEFAULT_SUPPLY : c.totalSupply; // validated by the factory
        LaunchConfig storage s = _l()._launchCfg[raiseId];
        s.tokenName = c.tokenName; s.tokenSymbol = c.tokenSymbol; s.tokenMeta = c.tokenMeta; s.totalSupply = supply; s.salt = c.salt;
        s.buyTaxBps = c.buyTaxBps; s.sellTaxBps = c.sellTaxBps;
        s.taxDuration = c.taxDuration; s.antiFarmerDuration = c.antiFarmerDuration; s.creatorShareBps = c.creatorShareBps;
        for (uint256 i; i < c.feeConfigs.length; ++i) s.feeConfigs.push(c.feeConfigs[i]);
        (r.saleTokens, r.poolTokens) = _tokenSplit(raiseId, r.hardCap); // projection; recomputed for the actual total at settle
    }

    // V7 (Flap salt-lock finding): updateSalt removed — every raise locks its salt on the Portal at creation, so there is
    // no unlocked salt left to be squatted and nothing to replace (it could only ever revert "AR: salt locked").

    /// @dev F12: bind `salt` to `raiseId`. Reverts if another raise that can still settle (or already settled) owns it.
    ///      V7: the salt is ALWAYS locked on the Portal with this contract as locker: msg.value must equal SALT_LOCK_FEE().
    ///      The only exception is a salt this same contract already locked (factory registry says so): then msg.value must be 0.
    function _claimSalt(uint256 raiseId, Raise storage r, bytes32 salt) internal {
        // v10: the salt registry lives in the factory, so two vaults can never own the same salt (reverts SaltTaken)
        bool lockedHere = _l().factory.claimSalt(raiseId, salt);
        if (lockedHere) {
            require(msg.value == 0, "AR: bad amount");
            r.saltLocked = true;
        } else {
            require(msg.value == PORTAL.SALT_LOCK_FEE(), "AR: salt lock fee required");
            PORTAL.lockSalt{value: msg.value}(salt, 0); // 0 = DIRECT_V2_POOL_TAX; locker = this vault (reverts if already locked by anyone)
            _l().factory.markSaltLocked(raiseId, salt);
            r.saltLocked = true;
        }
    }
    /// @notice F12: the factory asks the owning vault whether its salt is free again (raise can never settle).
    function saltReleased() external view returns (bool) {
        uint256 id = _l().raiseId; Raise storage o = _l()._raises[id];
        return !o.settled && refundOpen(id);
    }
    /// @dev v9 / F16: sale vs pool tokens for a total `R` so that poolQuote/poolTokens == R/saleTokens (open price == presale).
    function _tokenSplit(uint256 raiseId, uint256 R) internal view returns (uint256 sale, uint256 pool) {
        uint256 N = _l()._launchCfg[raiseId].totalSupply;
        if (R == 0) return (N, 0);
        (,, uint256 Q) = _split(raiseId, R);
        pool = N * Q / (R + Q);
        sale = N - pool;
    }
    /// @notice v9: sale / pool tokens that settle would use for the current total (hardCap if nothing raised yet).
    function tokenSplit(uint256 raiseId) public view returns (uint256 saleTokens, uint256 poolTokens) {
        Raise storage r = _get(raiseId);
        return _tokenSplit(raiseId, r.totalRaised == 0 ? r.hardCap : r.totalRaised);
    }
    /// @dev F13: Portal floor for `amount` raised (after 3% fee and creator share), using THIS Launcher's live factory multiplier
    ///      (factory.launchFloor → Portal.graduationFloorV2ForLauncher(…, this)); px 0 = Portal's own BNB price.
    function _floor(uint256 raiseId, uint256 amount, uint256 px) internal view returns (IFlapPoolPortal.GraduationFloorResultV2 memory) {
        (,, uint256 poolQuote) = _split(raiseId, amount);
        (, uint256 poolTokens) = _tokenSplit(raiseId, amount);
        return _l().factory.launchFloor(address(this), px, poolQuote, poolTokens, _l()._launchCfg[raiseId].totalSupply);
    }
    function _meetsCreateFloor(uint256 raiseId, Raise storage, uint256 amount) internal view returns (bool) {
        return _floor(raiseId, amount, 0).meetsCreateFloor;
    }
    /// @notice F13: would the current total clear the Portal create floor at the Portal's current BNB price?
    function meetsLaunchFloor(uint256 raiseId) public view returns (bool) { Raise storage r = _get(raiseId); return _meetsCreateFloor(raiseId, r, r.totalRaised); }

    function updateMeta(uint256 raiseId, string calldata metaCid) external {
        require(!RescueStateV82.state().halted, "AR: emergency recovery");
        Raise storage r = _get(raiseId);
        require(msg.sender == r.creator, "AR: not creator");
        require(bytes(metaCid).length <= 256, "AR: bad params");
        r.metaCid = metaCid;
        uint256 seq = ++_l().metaSeq[raiseId];
        emit MetaUpdated(raiseId, seq, metaCid);
        _l().factory.fsiAppend(raiseId, NS_RAISE_META, seq, msg.sender, r.beneficiary, metaCid);
    }

    // ───────────── contribute (BNB escrow) ─────────────
    /// @notice Buy `qty` whole shares at the fixed share price. Caller must hold an Agent ID. Per-wallet cap: perWalletCap
    ///         (10 or 20) shares; the creator is bound by the same cap in their own raise, at the same price;
    ///         v9: the creator's tokens are delivered at settle like everyone's (no vesting).
    ///         V4 (Flap audit F011): the contribution that fills hardCap also settles in the same tx, like Flap's reference
    ///         MintLauncher. Fail-safe: settle runs in an external self-call; if it reverts (Portal paused, floor, salt …) its
    ///         effects roll back, AutoSettleFailed is emitted and the contribution still succeeds (manual settle() as before).
    ///         The filling call needs gasleft() >= AUTO_SETTLE_MIN_GAS at that point, and out-of-gas inside the self-call (or an
    ///         empty revert) reverts the whole tx instead, so a filler cannot skip settlement by under-funding gas.
    function contribute(uint256 raiseId, uint256 qty) external payable nonReentrant
    {
        Raise storage r = _get(raiseId);
        ShareConfig storage c = _l()._configs[raiseId];
        require(!(block.timestamp >= r.deadline || r.failed || r.settled), "AR: raise ended");
        require(!r.closed, "AR: raise closed");
        (uint256 agentTokenId, string memory agentId) = _agent();
        _bindAgent(raiseId, agentTokenId);
        // Portal provenance exists now. Creation already required hardCap >= live floor+20%; re-check live Flap create-floor vs hardCap here.
        if (r.totalRaised == 0) require(_meetsCreateFloor(raiseId, r, r.hardCap), "AR: below launch floor");
        uint256 amount = msg.value;
        require(!(qty == 0 || amount != c.sharePrice * qty), "AR: bad amount");
        require(_l().sharesSold[raiseId] + qty <= c.maxShares, "AR: sold out");
        uint256 myShares = _l().sharesOf[raiseId][msg.sender] + qty;
        require(myShares <= c.perWalletCap, "AR: over wallet cap");
        _l().sharesSold[raiseId] += qty; _l().sharesOf[raiseId][msg.sender] = myShares;
        uint256 logExtra = qty;

        uint256 prev = _l().contributionOf[raiseId][msg.sender];
        uint256 mine = prev + amount;

        if (prev == 0) { r.contributorCount += 1; _l()._contributors[raiseId].push(msg.sender); }
        _l().contributionOf[raiseId][msg.sender] = mine;
        r.totalRaised += amount;
        _l().contributorAgentId[raiseId][msg.sender] = agentId;
        if (r.totalRaised == r.hardCap) { r.closed = true; r.closedAt = uint64(block.timestamp); emit RaiseClosed(raiseId, r.totalRaised); }

        emit Contributed(raiseId, msg.sender, amount, qty, agentId);
        _l().factory.fsiSetRound(raiseId, NS_CONTRIB, msg.sender, mine);
        _l().factory.fsiSetRound(raiseId, NS_RAISE_TOTAL, address(0), r.totalRaised);
        _l().factory.onContribution(raiseId, r.creator, msg.sender, amount, true); // creatorRaised / points + FSI A
        _l().factory.fsiLog(raiseId, NS_CONTRIB_LOG, msg.sender, address(0), amount, logExtra);
        if (r.closed) _trySettle(raiseId);
    }

    /// @dev V4: attempt settle in an external self-call (lock must be held by the caller). Returns false only when the launch
    ///      genuinely reverted (AutoSettleFailed emitted, settle effects rolled back). Insufficient gas never counts as failure:
    ///      < AUTO_SETTLE_MIN_GAS reverts up front; OOG (top-level: < g/64 left; nested: empty revert data) reverts the whole tx.
    function _trySettle(uint256 raiseId) internal returns (bool) {
        uint256 g = gasleft();
        require(g >= AUTO_SETTLE_MIN_GAS, "AR: auto-settle needs more gas");
        try this.selfSettle(raiseId, msg.sender) { return true; } catch (bytes memory e) {
            require(e.length != 0 && gasleft() > g / 63, "AR: auto-settle out of gas");
            emit AutoSettleFailed(raiseId, e);
            return false;
        }
    }

    /// @notice One wallet per Agent ID per raise (F5). Agent IDs are soulbound and one-per-address, so this is
    ///         defence in depth against a registry change rather than a reachable path today.
    function _bindAgent(uint256 raiseId, uint256 tokenId) internal {
        address w = _l().idUsedBy[raiseId][tokenId];
        if (w == address(0)) _l().idUsedBy[raiseId][tokenId] = msg.sender;
        else require(w == msg.sender, "AR: agent id used by other addr");
    }

    // ───────────── settle: Flap Pool Launch + push tokens ─────────────
    function settle(uint256 raiseId) external nonReentrant { _settle(raiseId, msg.sender); }
    /// @notice V4: settle entry callable only by this contract, from the filling contribute() or a non-creator markFailed()
    ///         (lock held). `by` = original caller, recorded in the settle FSI log.
    function selfSettle(uint256 raiseId, address by) external {
        require(msg.sender == address(this) && _l()._lock == 2, "AR: only self");
        _settle(raiseId, by);
    }
    function _settle(uint256 raiseId, address by) internal {
        Raise storage r = _get(raiseId);
        require(canSettle(raiseId), "AR: not settleable");
        r.settled = true;

        (uint256 fee, uint256 cash, uint256 poolQuote) = settlementSplit(raiseId);
        (r.saleTokens, r.poolTokens) = _tokenSplit(raiseId, r.totalRaised); // F16: open price == presale price
        uint256 distAmount = r.saleTokens;
        _l()._launchingId = raiseId; _l()._expectDist = distAmount; _l()._distToken = address(0);

        // Portal errors (creationPaused / LaunchLiquidityTooLow / salt taken …) bubble unchanged
        (address token, address pool) = PORTAL.launchTaxTokenV2{value: poolQuote}(
            _params(raiseId, r, poolQuote),
            IFlapPoolPortal.Distribution(IFlapPoolPortal.DistributionTarget.EXPLICIT, address(this), uint128(distAmount), abi.encode(raiseId)),
            IFlapPoolPortal.CreatorBuyParams(0, "")
        );
        require(!(token == address(0) || token != _l()._distToken), "AR: bad distribution");
        _l()._launchingId = 0; _l()._expectDist = 0; _l()._distToken = address(0);
        r.token = token; r.pool = pool;

        r.settledAt = uint64(block.timestamp); // v9: no creator first-buy, no vesting
        r.beneficiaryOwed = cash;                                                              // F14(b): pull payment

        emit Settled(raiseId, token, pool, fee, cash, poolQuote, r.poolTokens);
        _l().factory.fsiLog(raiseId, NS_SETTLE_LOG, by, token, poolQuote, fee);
        _push(raiseId, r, SETTLE_PUSH);
        // V8: Trigger reserve for the contributors NOT pushed above comes out of the fee (capped at it); reserveFor never reverts.
        uint256 reserve = DISTRIBUTOR.reserveFor(r.contributorCount - r.distCursor);
        if (reserve > fee) reserve = fee;
        if (reserve != 0) DISTRIBUTOR.fund{value: reserve}(address(this));
        _send(TREASURY, fee - reserve); // immutable protocol treasury (EOA)
    }

    function _params(uint256 raiseId, Raise storage r, uint256 poolQuote) internal view returns (IFlapPoolPortal.CreateTaxTokenParams memory p) {
        LaunchConfig storage c = _l()._launchCfg[raiseId];
        p.name = c.tokenName; p.symbol = c.tokenSymbol; p.meta = c.tokenMeta;
        p.totalSupply = c.totalSupply; p.salt = c.salt;
        p.poolQuote = poolQuote; p.poolToken = r.poolTokens;
        p.buyTaxRate = c.buyTaxBps; p.sellTaxRate = c.sellTaxBps;
        p.taxDuration = c.taxDuration; p.antiFarmerDuration = c.antiFarmerDuration;
        p.feeConfigs = feeConfigsOf(raiseId);
        p.exemptAddrs = new address[](0);
        p.creatorBuyQuote = 0; // no creator first-buy
        (p.extensionID, p.extensionData) = LaunchExtensionHelper.encodeCreator(r.creator);
        p.commissionReceiver = address(0);
    }

    /// @notice Strategy callback: the Portal hands the remainder (sale tokens) to this contract during settle.
    function initializeDistribution(address token, uint256 amount, bytes calldata configData, bytes32) external {
        require(!RescueStateV82.state().halted, "AR: emergency recovery");
        require(!(msg.sender != address(PORTAL) || _l()._launchingId == 0 || _l()._distToken != address(0)), "AR: bad distribution");
        require(!(amount != _l()._expectDist || abi.decode(configData, (uint256)) != _l()._launchingId), "AR: bad distribution");
        _l()._distToken = token; // effect before external token transfer; blocks nested callbacks
        uint256 b0 = IERC20Min(token).balanceOf(address(this));
        require(IERC20Min(token).transferFrom(msg.sender, address(this), amount), "AR: transfer failed");
        require(IERC20Min(token).balanceOf(address(this)) - b0 == amount, "AR: bad distribution");
        // V7: custody the whole sale-token remainder in the Token Dock (router) inside this callback.
        uint256 d0 = TOKEN_DOCK_ROUTER.balanceOf(token, address(this));
        require(IERC20Approve(token).approve(address(TOKEN_DOCK_ROUTER), amount), "AR: dock deposit failed");
        TOKEN_DOCK_ROUTER.deposit(token, amount);
        require(TOKEN_DOCK_ROUTER.balanceOf(token, address(this)) - d0 == amount && IERC20Min(token).balanceOf(address(this)) == b0, "AR: dock deposit failed");
        _l()._distToken = token;
        emit FlapDistributionInitialized(token, amount);
    }

    /// @notice Permissionless: push tokens to the next `maxCount` contributors (backend runs it right after settle).
    function distribute(uint256 raiseId, uint256 maxCount) external nonReentrant returns (uint256 remaining) {
        Raise storage r = _get(raiseId);
        require(r.settled, "AR: not settled");
        _push(raiseId, r, maxCount);
        return _l()._contributors[raiseId].length - r.distCursor;
    }

    function _push(uint256 raiseId, Raise storage r, uint256 maxCount) internal {
        address[] storage list = _l()._contributors[raiseId];
        uint256 i = r.distCursor; uint256 end = i + maxCount; if (end > list.length) end = list.length;
        address token = r.token;
        for (; i < end; ++i) {
            if (gasleft() < PUSH_MIN_GAS) break; // V8: never start a push without its full 300k cap; the rest stays for the next batch
            address who = list[i];
            if (_l().tokensSent[raiseId][who]) continue;
            uint256 amt = tokensOwed(raiseId, who);
            _l().tokensSent[raiseId][who] = true;
            // V7: bounded-gas dock withdrawal straight to the contributor; a failure is left for claim() so one recipient can never block the batch
            (bool ok,) = address(TOKEN_DOCK_ROUTER).call{gas: 300_000}(abi.encodeCall(ITokenDock.withdraw, (token, amt, who)));
            if (ok) { r.distributed += amt; ++_l().paidCount[raiseId]; emit TokensSent(raiseId, who, amt, false); }
            else { _l().tokensSent[raiseId][who] = false; emit TokensPushFailed(raiseId, who); }
        }
        r.distCursor = i;
    }

    /// @notice Fallback: a contributor pulls their own tokens if the push has not reached / failed for them.
    function claim(uint256 raiseId) external nonReentrant {
        Raise storage r = _get(raiseId);
        require(r.settled, "AR: not settled");
        require(!(_l().tokensSent[raiseId][msg.sender] || _l().contributionOf[raiseId][msg.sender] == 0), "AR: nothing to claim");
        uint256 amt = tokensOwed(raiseId, msg.sender);
        _l().tokensSent[raiseId][msg.sender] = true;
        r.distributed += amt; ++_l().paidCount[raiseId];
        TOKEN_DOCK_ROUTER.withdraw(r.token, amt, msg.sender); // V7: paid out of the Token Dock
        emit TokensSent(raiseId, msg.sender, amt, true);
    }

    // V7 (EIP-170): sweepDust / tokensInDock / paidCount live in the fixed GuardianRescueV82 module (same ABI via fallback).

    /// @notice F14(b): pay the creator BNB share to the beneficiary (pull; anyone may trigger, funds only go to beneficiary).
    ///         A reverting beneficiary can therefore never block settle().
    function claimBeneficiary(uint256 raiseId) external nonReentrant {
        Raise storage r = _get(raiseId);
        uint256 amt = r.beneficiaryOwed;
        require(amt != 0, "AR: nothing to claim");
        r.beneficiaryOwed = 0;
        _send(r.beneficiary, amt);
        emit BeneficiaryPaid(raiseId, r.beneficiary, amt);
    }

    /// @notice v10: BNB tax that reached this vault (MARKETING slot routed to the vault) and is not yet forwarded.
    function taxAccrued() public view returns (uint256) {
        if (RescueStateV82.state().halted) return 0;
        Raise storage r = _l()._raises[_l().raiseId];
        if (!r.settled) return 0;
        return address(this).balance - r.beneficiaryOwed;
    }
    /// @notice v10: forward accrued tax to the beneficiary (permissionless trigger; funds only go to the beneficiary).
    ///         OPEN DECISION (docs/10): default recipient = beneficiary (creator side).
    function claimTax() external nonReentrant {
        uint256 id = _l().raiseId; Raise storage r = _l()._raises[id];
        uint256 amt = taxAccrued();
        require(amt != 0, "AR: nothing to claim");
        _l().taxClaimed += amt;
        _send(r.beneficiary, amt);
        emit TaxClaimed(id, r.beneficiary, amt);
    }

    // ───────────── failure / refund ─────────────
    /// @notice Opens refunds. Creator: any time before settle. V7: no soft cap — an unfilled raise after the deadline can only
    ///         be marked failed (anyone after deadline, no grace) then refunded; there is no settle-below-hardCap path.
    ///         Filled but unsettled (AutoSettleFailed): non-creator waits SETTLE_GRACE from settleableAt, then FIRST tries
    ///         settle() (V4 F011 self-call / gas guard). Launch success → SETTLED; genuine revert → AutoSettleFailed then Failed.
    ///         Creator cancellation before settle is unchanged (no settle attempt).
    function markFailed(uint256 raiseId) external nonReentrant {
        Raise storage r = _get(raiseId);
        require(!(r.settled || r.failed), "AR: cannot mark failed");
        if (msg.sender != r.creator) {
            if (r.closed) {
                require(block.timestamp >= settleableAt(raiseId) + SETTLE_GRACE, "AR: cannot mark failed");
                if (canSettle(raiseId) && _trySettle(raiseId)) return;
            } else {
                require(block.timestamp >= r.deadline, "AR: cannot mark failed");
            }
        }
        r.failed = true;
        emit Failed(raiseId, msg.sender);
    }

    function refund(uint256 raiseId) external nonReentrant {
        Raise storage r = _get(raiseId);
        require(refundOpen(raiseId), "AR: not refundable");
        uint256 amount = _l().contributionOf[raiseId][msg.sender];
        require(amount != 0, "AR: nothing to refund");
        _l().contributionOf[raiseId][msg.sender] = 0;
        r.totalRaised -= amount;
        _send(msg.sender, amount);
        emit Refunded(raiseId, msg.sender, amount);
        _l().factory.fsiSetRound(raiseId, NS_CONTRIB, msg.sender, 0);
        _l().factory.fsiSetRound(raiseId, NS_RAISE_TOTAL, address(0), r.totalRaised);
        _l().factory.onContribution(raiseId, r.creator, msg.sender, amount, false);
        _l().factory.fsiLog(raiseId, NS_REFUND_LOG, msg.sender, address(0), amount, 0);
    }

    // ───────────── agent gate (on-chain Agent ID) ─────────────
    function _agent() internal view returns (uint256 tokenId, string memory handle) {
        handle = _l().registry.handleOf(msg.sender);
        require(bytes(handle).length != 0, "AR: not agent");
        tokenId = uint256(keccak256(bytes(handle)));
    }


    // ───────────── V8.2: Flap Pool Launch display (Launcher description JSON v1) ─────────────
    /// @notice ILauncherDescription: Flap Launcher description JSON v1, read by the Portal inside newLauncher (after initialize).
    /// @dev EIP-170: rendered by the FIXED RESCUE_MODULE (official LauncherBase + LauncherHelper.toJson) reading this Launcher's
    ///      ERC-7201 layout in this context: STATICCALL to self → fallback (whitelisted view selector) → delegatecall. Display-only.
    ///      The module's ABI-encoded string is returned verbatim (no re-encode; saves EIP-170 bytes); a revert bubbles unchanged.
    function description() external view override returns (string memory) {
        bytes4 sel = IGuardianRescueV82.launcherDescription.selector;
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, sel)
            let ok := staticcall(gas(), address(), p, 4, 0, 0)
            returndatacopy(p, 0, returndatasize())
            if iszero(ok) { revert(p, returndatasize()) }
            return(p, returndatasize())
        }
    }

    // ───────────── views ─────────────
    function factory() external view returns (address) { return address(_l().factory); }
    /// @notice Preparation views (Flap audit): has this Preparation launched its (single) token, and where.
    function launched() external view returns (bool) { return _l()._raises[_l().raiseId].token != address(0); }
    function launchedToken() external view returns (address) { return _l()._raises[_l().raiseId].token; }
    function launchedPool() external view returns (address) { return _l()._raises[_l().raiseId].pool; }
    function portal() external pure returns (IFlapPoolPortal) { return PORTAL; }
    function vaultRaiseId() external view returns (uint256) { return _l().raiseId; }
    function taxClaimed() external view returns (uint256) { return _l().taxClaimed; }
    function metaSeq(uint256 id) external view returns (uint256) { return _l().metaSeq[id]; }
    function contributionOf(uint256 id, address a) external view returns (uint256) { return _l().contributionOf[id][a]; }
    function tokensSent(uint256 id, address a) external view returns (bool) { return _l().tokensSent[id][a]; }
    function contributorAgentId(uint256 id, address a) external view returns (string memory) { return _l().contributorAgentId[id][a]; }
    function idUsedBy(uint256 id, uint256 tokenId) external view returns (address) { return _l().idUsedBy[id][tokenId]; }
    function sharesSold(uint256 id) external view returns (uint256) { return _l().sharesSold[id]; }
    function sharesOf(uint256 id, address a) external view returns (uint256) { return _l().sharesOf[id][a]; }
    /// @notice V7: settle only when hardCap is fully filled (closed). No settle-below-hardCap.
    function canSettle(uint256 raiseId) public view returns (bool) {
        Raise storage r = _get(raiseId);
        return !RescueStateV82.state().halted && !r.settled && !refundOpen(raiseId) && r.closed;
    }
    /// @notice Time the raise stopped taking contributions: hardCap fill time, else the deadline.
    function settleableAt(uint256 raiseId) public view returns (uint256) {
        Raise storage r = _get(raiseId);
        return r.closed && r.closedAt < r.deadline ? r.closedAt : r.deadline;
    }
    /// @notice F14(c) / r3 F2: earliest time a non-creator may markFailed (the only non-creator path).
    function graceEndsAt(uint256 raiseId) external view returns (uint256) { return settleableAt(raiseId) + SETTLE_GRACE; }

    // Economics disclosure selectors are preserved by the FIXED delegate module (merged ABI).
    /// @notice F10: once true, settle() can never succeed.
    /// @notice V7: unfilled raises open refunds only after markFailed (or the 30-day absolute timeout).
    ///         Filled-but-unsettled opens after deadline + SETTLE_WINDOW (same escape hatch as V4).
    function refundOpen(uint256 raiseId) public view returns (bool) {
        Raise storage r = _get(raiseId);
        if (RescueStateV82.state().halted || r.settled) return false;
        if (r.failed) return true;
        if (block.timestamp < r.deadline) return false;
        return block.timestamp >= uint256(r.deadline) + SETTLE_WINDOW;
    }
    /// @notice BNB split at settle for the current total: fee + creatorCash + poolQuote == totalRaised.
    function settlementSplit(uint256 raiseId) public view returns (uint256 fee, uint256 creatorCash, uint256 poolQuote) {
        return _split(raiseId, _get(raiseId).totalRaised);
    }
    function _split(uint256 raiseId, uint256 R) internal view returns (uint256 fee, uint256 creatorCash, uint256 poolQuote) {
        LaunchConfig storage c = _l()._launchCfg[raiseId];
        fee = R * FEE_BPS / 10_000;
        creatorCash = (R - fee) * c.creatorShareBps / 10_000;
        poolQuote = R - fee - creatorCash;
    }
    /// @notice Contributor's pro-rata tokens: saleTokens · contribution / totalRaised (exact after settle; projected before).
    function tokensOwed(uint256 raiseId, address who) public view returns (uint256) {
        Raise storage r = _get(raiseId);
        if (r.totalRaised == 0) return 0;
        uint256 sale = r.settled ? r.saleTokens : _sale(raiseId, r.totalRaised);
        return sale * _l().contributionOf[raiseId][who] / r.totalRaised;
    }
    function _sale(uint256 raiseId, uint256 R) internal view returns (uint256 sale) { (sale,) = _tokenSplit(raiseId, R);
    }
    function feeConfigsOf(uint256 raiseId) public view returns (IFlapPoolPortal.FeeConfig[] memory f) {
        LaunchConfig storage c = _l()._launchCfg[raiseId];
        uint256 n = c.feeConfigs.length;
        if (n == 0) {
            f = new IFlapPoolPortal.FeeConfig[](1); // DEFAULT: 100% DIVIDEND in BNB (quote) to holders, min share 0.001%
            f[0] = IFlapPoolPortal.FeeConfig(IFlapPoolPortal.FeeSlotType.DIVIDEND, 10_000, abi.encode(address(0), c.totalSupply / 100_000));
        } else {
            f = new IFlapPoolPortal.FeeConfig[](n);
            for (uint256 i; i < n; ++i) {
                f[i] = c.feeConfigs[i];
                if (f[i].feeType == IFlapPoolPortal.FeeSlotType.MARKETING && abi.decode(f[i].configData, (address)) == address(0))
                    f[i].configData = abi.encode(address(this)); // v10: tax-to-vault
            }
        }
    }
    /// @notice F8: graduation / create-floor preview for the current total at `bnbUsdWad` (18-dec BNB price).
    function previewLaunch(uint256 raiseId, uint256 bnbUsdWad) external view returns (IFlapPoolPortal.GraduationFloorResultV2 memory) {
        return _floor(raiseId, _get(raiseId).totalRaised, bnbUsdWad); // v10.1: Preparation multiplier applied
    }
    function getRaise(uint256 raiseId) external view returns (Raise memory) { return _get(raiseId); }
    // V4 (EIP-170): getLaunchConfig(uint256) moved verbatim to the fixed GuardianRescueV82 module (same selector/ABI via fallback).
    function getConfig(uint256 raiseId) external view returns (ShareConfig memory) { _get(raiseId); return _l()._configs[raiseId]; }
    // V4 (EIP-170): contributors(uint256,uint256,uint256) moved verbatim to the fixed GuardianRescueV82 module.
    // V4 (EIP-170): status(uint256) moved verbatim to the fixed GuardianRescueV82 module; same selector/ABI via fallback().

    // ───────────── internal ─────────────
    function _get(uint256 raiseId) internal view returns (Raise storage r) {
        r = _l()._raises[raiseId];
        require(r.creator != address(0), "AR: raise not found");
    }
    function _send(address to, uint256 amount) internal {
        (bool ok,) = payable(to).call{value: amount}("");
        require(ok, "AR: transfer failed");
    }
}
