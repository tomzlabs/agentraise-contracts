// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LauncherFactoryBase} from "../launcher-beacon-v8.2/flap/LauncherFactoryBase.sol";
import {LauncherDataSchema, FieldDescriptor} from "../launcher-beacon-v8.2/flap/IVaultSchemas.sol";
import {ILauncherPortalV1} from "../launcher-beacon-v8/ILauncherPortalV1.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";


import {FlapSharedIndexerV1} from "../FlapSharedIndexerV1.sol";
import {AgentRaiseLauncherV82} from "../launcher-beacon-v8.2/AgentRaiseLauncherV82.sol";
import {IFlapPoolPortal} from "../interfaces/IFlapPoolPortal.sol";
import {IAgentIdRegistry} from "../interfaces/IAgentIdRegistry.sol";

interface ISaltReleased { function saltReleased() external view returns (bool); }

/// @notice Official Flap Pool Launch scam-word checker (separate from Portal). Immutable binding; no owner swap.
interface IScamWordChecker {
    function isScamWord(string calldata name, string calldata symbol) external view returns (bool nameScam, bool symbolScam);
}

/// @title AgentRaise Launcher Factory V8.2.2 (= V8.2.1 + D-04/D-05 fix: create rejects bps == 0 on any non-DIVIDEND active fee slot
///        (Portal InvalidFeeConfigBps at settle) and MARKETING configData that does not ABI-decode as a clean address) (V8.2.1 (= V8.2 + Z-01 fix: create rejects max(buyTaxBps, sellTaxBps) < 100 (incl. 0/0), which the
///        Portal launchTaxTokenV2 would reject with InvalidTaxBps at settle; launcher impl / distributor / rescue sources unchanged) (V8.2 = V8 + 3% fee math + launchers expose Flap description() JSON v1) (V8 = V7 logic; BeaconProxy launchers, Guardian-only upgrades) hardCap-only (create-time dynamic Portal floor: graduationFloorV2 × factory bps + LAUNCH_FLOOR_MARGIN_BPS; keeps V4 auto-settle + V3 namecheck) — factory itself nonupgradeable, Portal-only creation.
/// @notice SPACE ID registry and Portal are fixed. V8: each launcher is a CREATE2 BeaconProxy (salt = raiseId) of BEACON.
///         BEACON is owned by this factory, whose only upgrade entry is upgradeVaultImplementation (onlyGuardian = Flap Guardian
///         per LaunchVaultAddresses.guardian()). No owner, deployer or other role can upgrade or transfer the beacon.
/// LOCAL UNDEPLOYED HARDCAP-ONLY V8 — not the deployed V2/V3/V4 factories. Data = abi.encode(CreateConfig(...)); one dynamic tuple, not six flat arguments.
contract AgentRaiseLauncherFactoryV822 is LauncherFactoryBase, FlapSharedIndexerV1 {
    /// @notice V8: UpgradeableBeacon shared by every launcher of this factory (owner = this factory, never transferred).
    address public immutable BEACON;
    /// @dev keccak256(BeaconProxy creationCode ++ abi.encode(BEACON, "")) for CREATE2 address prediction.
    bytes32 private immutable PROXY_INITCODE_HASH;
    event VaultImplementationUpgraded(address indexed previousImplementation, address indexed newImplementation);
    address public constant AGENT_ID_REGISTRY = 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F;
    bytes32 constant NS_CREATOR_RAISED = "creatorRaised";
    bytes32 constant NS_POINTS = "points";
    uint256 public constant MIN_SHARE_PRICE = 0.001 ether;
    /// @notice V7: no fixed MIN_HARD_CAP. Create evaluates hardCap via poolFor → Portal.graduationFloorV2 (1× base;
    ///         NOT ForLauncher — launcher is unregistered at create) × launcherFactoryMultiplier(this) × (1 + margin).
    ///         Portal read failure reverts fail-closed. First contribution still re-checks the live launcher floor.
    uint256 public constant LAUNCH_FLOOR_MARGIN_BPS = 2_000; // 20% headroom above live create floor
    uint256 public constant MAX_SHARES = 100_000;
    uint256 public constant MAX_CREATOR_SHARE_BPS = 1000;
    uint256 public constant MAX_TAX_BPS = 1000;
    /// @notice V8.2.1 Z-01: Portal launchTaxTokenV2 requires max(buyTaxBps, sellTaxBps) >= 100 (1%); 0/0 etc. would revert at settle.
    uint256 public constant MIN_TAX_BPS = 100;
    uint256 public constant DEFAULT_SUPPLY = 1e9 ether;
    uint256 public constant MAX_DURATION = 90 days;
    address public constant PORTAL = 0x000042108465206185A077Edc3F3fd2b49060000;
    /// @notice Fixed official name/symbol checker. Creation fails closed if unavailable or either flag is true.
    address public constant SCAM_CHECKER = 0xfFb69d59f62454f3B8322Bc1a9FCE6E171a5264f;
    /// @custom:storage-location erc7201:agentraise.launcher.factory.v1
    struct Layout {
        address portal;          // DEPRECATED (v11, Flap SYS-FLAP-FIXED-ADDRESSES): unused, kept for layout; see PORTAL
        address agentIdRegistry;
        address beacon;
        uint256 _lock;
        uint256 raiseCount;
        mapping(uint256 => address) vaultOf;
        mapping(address => uint256) raiseOfVault;
        mapping(bytes32 => uint256) saltOwner;   // F12: salt → raiseId
        mapping(bytes32 => address) saltLocker;  // vault that locked the salt on the Portal (locks are per locker)
        mapping(address => uint256) creatorRaised;
        mapping(address => uint256) points;
    }
    // keccak256(abi.encode(uint256(keccak256("agentraise.launcher.factory.v1")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant LAYOUT_SLOT = 0xcfcadadc978cc11309965183d4a5aa366d946113b43f9ed25826f9d8a6638d00;
    function _l() private pure returns (Layout storage $) { bytes32 p = LAYOUT_SLOT; assembly { $.slot := p } }

    event VaultCreated(uint256 indexed raiseId, address indexed vault, address indexed creator);

    modifier nonReentrant() { Layout storage $ = _l(); require($._lock == 1, "AR: reentrant"); $._lock = 2; _; $._lock = 1; }
    modifier onlyVaultOf(uint256 raiseId) { require(!(msg.sender != _l().vaultOf[raiseId] || msg.sender == address(0)), "AR: not vault"); _; }

    /// @dev V8: the implementation is deployed FIRST (constructor arg = this factory's predicted CREATE address) because
    ///      embedding its initcode here would exceed EIP-3860 (49,152 B). The binding is enforced: a mismatched impl reverts.
    constructor(address impl) {
        require(impl.code.length != 0 && AgentRaiseLauncherV82(payable(impl)).DEPLOYING_FACTORY() == address(this)
            && AgentRaiseLauncherV82(payable(impl)).DISTRIBUTOR().FACTORY() == address(this), "AR: impl not bound to factory");
        BEACON = address(new UpgradeableBeacon(impl, address(this)));
        PROXY_INITCODE_HASH = keccak256(abi.encodePacked(type(BeaconProxy).creationCode, abi.encode(BEACON, bytes(""))));
        _l().agentIdRegistry = AGENT_ID_REGISTRY;
        _l()._lock = 1;
    }
    /// @notice Current launcher logic (what BEACON points to).
    function implementation() public view returns (address) { return UpgradeableBeacon(BEACON).implementation(); }
    /// @notice CREATE2 address of the launcher for `raiseId` (deterministic; independent of the implementation).
    function predictLauncher(uint256 raiseId) public view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(raiseId), PROXY_INITCODE_HASH)))));
    }
    /// @notice V8: Flap Guardian ONLY. Upgrades every existing and future launcher at once. The new implementation must be
    ///         bound to this factory (DEPLOYING_FACTORY) so new raises can still initialize; storage layout must be append-only.
    function upgradeVaultImplementation(address newImplementation) external override onlyGuardian {
        require(AgentRaiseLauncherV82(payable(newImplementation)).DEPLOYING_FACTORY() == address(this), "AR: impl not bound to factory");
        address prev = implementation();
        UpgradeableBeacon(BEACON).upgradeTo(newImplementation);
        emit VaultImplementationUpgraded(prev, newImplementation);
    }
    struct CreateConfig { string title; string metaCid; bytes shareData; uint64 deadline; address beneficiary; bytes launchData; }

    function _newLauncher(address creator, bytes calldata data) internal override nonReentrant returns (address launcher) {
        require(creator != address(0), "AR: bad params");
        CreateConfig memory input = abi.decode(data, (CreateConfig));
        require(keccak256(data) == keccak256(abi.encode(input)), "AR: noncanonical data");
        string memory title=input.title; string memory metaCid=input.metaCid;
        bytes memory shareData=input.shareData; uint64 deadline=input.deadline;
        address beneficiary=input.beneficiary; bytes memory launchData=input.launchData;
        AgentRaiseLauncherV82.ShareConfig memory cfg = abi.decode(shareData, (AgentRaiseLauncherV82.ShareConfig));
        AgentRaiseLauncherV82.LaunchConfig memory launch = abi.decode(launchData, (AgentRaiseLauncherV82.LaunchConfig));
        require(keccak256(shareData) == keccak256(abi.encode(cfg)) && keccak256(launchData) == keccak256(abi.encode(launch)), "AR: noncanonical data");
        _check(title, metaCid, cfg, deadline, beneficiary, launch);
        string memory agentId = IAgentIdRegistry(AGENT_ID_REGISTRY).handleOf(creator);
        require(bytes(agentId).length != 0, "AR: not agent");
        // Value is the salt-lock fee ONLY (V7: mandatory). It never buys shares for the creator or enters totalRaised.
        uint256 fee = ILauncherPortalV1(PORTAL).SALT_LOCK_FEE();
        require(fee != 0 && msg.value == fee, "AR: salt lock fee required");
        uint256 id = ++_l().raiseCount;
        launcher = predictLauncher(id);
        _l().vaultOf[id] = launcher; _l().raiseOfVault[launcher] = id;
        require(address(new BeaconProxy{salt: bytes32(id)}(BEACON, "")) == launcher, "AR: vault mismatch");
        AgentRaiseLauncherV82(payable(launcher)).initialize{value: msg.value}(id, creator, agentId, title, metaCid, cfg, deadline, beneficiary, launch);
        // Registration happens after return: never pretend this address already has a Portal record here.
        emit VaultCreated(id, launcher, creator);
    }
    function launcherDataSchema() external pure override returns (LauncherDataSchema memory schema) {
        schema.description = "Agent-ID-gated BNB whole shares; 3% fee (part reserved for Flap Trigger auto-distribution), buy/sell tax each 0-10% with at least one >= 1% (Portal rejects lower, incl. 0/0), 0-10% post-fee creator BNB, no creator tokens/first buy; permissionless settle and timed refunds; sale tokens custodied in Flap Token Dock (router) until pushed/claimed, rounding dust to beneficiary. Creation requires msg.value == Portal SALT_LOCK_FEE (salt always locked by the launcher) and official isScamWord(name,symbol)=(false,false). Nested bytes use exact AgentRaiseLauncherV82 structs.";
        schema.fields = new FieldDescriptor[](6);
        schema.fields[0] = FieldDescriptor("title", "string", "Raise title (1-120 bytes)", 0);
        schema.fields[1] = FieldDescriptor("metaCid", "string", "Raise metadata (up to 256 bytes)", 0);
        schema.fields[2] = FieldDescriptor("shareConfig", "bytes", "abi.encode(ShareConfig(uint256 sharePrice,uint32 maxShares,uint8 perWalletCap))", 0);
        schema.fields[3] = FieldDescriptor("deadline", "uint64", "Absolute Unix seconds, future and at most 90 days", 0);
        schema.fields[4] = FieldDescriptor("beneficiary", "address", "Nonzero beneficiary of creator BNB share and launcher marketing revenue", 0);
        schema.fields[5] = FieldDescriptor("launchConfig", "bytes", "abi.encode(AgentRaiseLauncherV82.LaunchConfig); see review notes for exact tuple", 0);
    }

    // ───────────── launch floors (Preparation-aware; shared by createRaise and every vault) ─────────────
    /// @notice F16 pool inputs for a total `R`: Q = R − 3% − creator BNB share, T = N·Q/(R+Q) (same math as the vault).
    /// @notice Pure disclosure math moved here solely to retain EIP-170 space; same rounding and checked arithmetic as V1.
    function economicsFor(uint256 R,uint256 creatorPaid,uint256 supply,uint256 sellTax,uint256 creatorBps) external pure returns(uint256 creatorMaxTakeBps,uint256 exitRecoveryBps,uint256 poolBps) {
        (uint256 X,uint256 T,uint256 N)=poolFor(R,creatorBps,supply);
        uint256 S=N-T; poolBps=T*10_000/N;
        if(R==0 || creatorPaid>=R) return(0,0,poolBps);
        uint256 cash=(R-R*300/10_000)*creatorBps/10_000; // V8.2: 3% fee
        uint256 keep=10_000-sellTax; uint256 others=R-creatorPaid;
        uint256 ct=(S*creatorPaid/R)*keep/10_000;
        uint256 got=ct==0?0:X*ct/(T+ct); uint256 take=cash+got;
        creatorMaxTakeBps=take>creatorPaid?(take-creatorPaid)*10_000/others:0;
        uint256 ot=(S*others/R)*keep/10_000;
        exitRecoveryBps=X*ot/(T+ot)*10_000/others;
    }
    function priceRatioFor(uint256 R,uint256 creatorBps,uint256 supply) external pure returns(uint256) {
        if(R==0) return 0;
        (uint256 q,uint256 t,uint256 n)=poolFor(R,creatorBps,supply);
        return q*(n-t)/t*10_000/R;
    }
    function poolFor(uint256 R, uint256 creatorShareBps, uint256 totalSupply) public pure returns (uint256 q, uint256 t, uint256 n) {
        n = totalSupply == 0 ? DEFAULT_SUPPLY : totalSupply;
        uint256 fee = R * 300 / 10_000; // V8.2: 3% (== launcher FEE_BPS 300; V8 was R/50 = 2%)
        q = R - fee - (R - fee) * creatorShareBps / 10_000;
        t = R == 0 ? 0 : n * q / (R + q);
    }

    /// @notice True iff `hardCap` pool economics clear live Portal create floor × factory bps × (1+LAUNCH_FLOOR_MARGIN_BPS).
    ///         Uses graduationFloorV2 only (no ForLauncher — create runs before Portal registration). Fail closed.
    function meetsLiveCreateFloor(uint256 hardCap, uint16 creatorShareBps, uint256 totalSupply) public view returns (bool) {
        require(creatorShareBps <= MAX_CREATOR_SHARE_BPS, "AR: bad launch config");
        ILauncherPortalV1 p = ILauncherPortalV1(PORTAL);
        (bool quoteEnabled, uint256 px) = p.launchQuoteConfig(0, address(0));
        require(quoteEnabled && px > 0, "AR: launch quote unavailable");
        (bool enabled, uint16 mbps) = p.launcherFactoryMultiplier(address(this));
        // Disabled / unknown factory: Portal treats launchers as 1×. Enabled mbps=0 → zero floors (Flap).
        uint256 m = enabled ? uint256(mbps) : 10_000;
        if (m == 0 || hardCap == 0) return m == 0; // mbps=0 → no floor; else hardCap 0 fails
        (uint256 q, uint256 t, uint256 n) = poolFor(hardCap, creatorShareBps, totalSupply);
        if (q == 0 || t == 0) return false;
        IFlapPoolPortal.GraduationFloorResultV2 memory g = p.graduationFloorV2(
            IFlapPoolPortal.GraduationFloorParams(address(0), px, q, t, n, address(0))
        );
        // need = createFloorUsdWad * m/10000 * (10000+MARGIN)/10000
        uint256 need = _ceilDiv(g.createFloorUsdWad * m * (10_000 + LAUNCH_FLOOR_MARGIN_BPS), 100_000_000);
        return g.quoteUsdWad >= need;
    }

    function _ceilDiv(uint256 a, uint256 b) private pure returns (uint256) {
        return (a + b - 1) / b;
    }

    /// @notice Live Portal lens only. No cached multiplier, inferred discount or stale fallback.
    function launchFloor(address launcher, uint256 px, uint256 poolQuote, uint256 poolTokens, uint256 supply)
        public view returns (IFlapPoolPortal.GraduationFloorResultV2 memory g)
    {
        ILauncherPortalV1 p = ILauncherPortalV1(PORTAL);
        (bool quoteEnabled, uint256 portalPx) = p.launchQuoteConfig(0, address(0));
        if (!quoteEnabled) return g;
        if (px == 0) px = portalPx;
        if (px == 0 || poolTokens == 0) return g;
        return p.graduationFloorV2ForLauncher(IFlapPoolPortal.GraduationFloorParams(address(0), px, poolQuote, poolTokens, supply, address(0)), launcher);
    }

    // ───────────── parameter checks (moved from the vault, EIP-170) ─────────────
    function _check(string memory title, string memory metaCid, AgentRaiseLauncherV82.ShareConfig memory cfg, uint64 deadline,
        address beneficiary, AgentRaiseLauncherV82.LaunchConfig memory c) internal view {
        require(!(bytes(title).length == 0 || bytes(title).length > 120 || bytes(metaCid).length > 256), "AR: bad params");
        require(!(beneficiary == address(0) || deadline <= block.timestamp || deadline > block.timestamp + MAX_DURATION), "AR: bad params");
        require(!(cfg.sharePrice < MIN_SHARE_PRICE || cfg.maxShares == 0 || cfg.maxShares > MAX_SHARES
            || cfg.sharePrice * cfg.maxShares > 1e27), "AR: bad share config");
        require(!(cfg.perWalletCap != 10 && cfg.perWalletCap != 20), "AR: wallet cap must be 10 or 20");
        require(!(bytes(c.tokenName).length == 0 || bytes(c.tokenName).length > 32 || bytes(c.tokenSymbol).length == 0
            || bytes(c.tokenSymbol).length > 12 || bytes(c.tokenMeta).length > 128 || c.salt == bytes32(0)), "AR: bad launch config");
        _assertNotScam(c.tokenName, c.tokenSymbol);
        uint256 supply = c.totalSupply == 0 ? DEFAULT_SUPPLY : c.totalSupply;
        require(!(supply < 100 ether || supply > 1e15 ether), "AR: bad launch config");
        require(!(c.buyTaxBps > MAX_TAX_BPS || c.sellTaxBps > MAX_TAX_BPS || c.creatorShareBps > MAX_CREATOR_SHARE_BPS), "AR: bad launch config");
        // V8.2.1 Z-01: the real Portal launchTaxTokenV2 reverts InvalidTaxBps(uint256) unless max(buy, sell) >= 1% (0/0, 1/0 bps, 50/50,
        // 99/99 all revert at settle; 100/0, 0/100, 100/1, 50/100 launch — BSC fork). Reject at create so principal is never stranded.
        require(!(c.buyTaxBps < MIN_TAX_BPS && c.sellTaxBps < MIN_TAX_BPS), "AR: buy or sell tax must be >= 1%");
        // Live create floor from hardCap pool BNB/tokens via graduationFloorV2 × factory bps + margin. Fail closed.
        require(meetsLiveCreateFloor(cfg.sharePrice * uint256(cfg.maxShares), c.creatorShareBps, supply), "AR: hard cap below launch floor");
        require(c.taxDuration >= c.antiFarmerDuration, "AR: tax duration < anti-farmer"); // FlapDirectTaxToken require
        _checkFeeConfigs(c.feeConfigs, supply);
    }



    /// @dev Creation-time only. Uses exact encoded name/symbol; no local denylist/normalization.
    ///      Fail closed on missing code, revert, wrong returndata size, or non-boolean words.
    ///      No settlement-time recheck: already-accepted principal must not be stranded by later word-list changes.
    function _assertNotScam(string memory name, string memory symbol) internal view {
        (bool ok, bytes memory ret) = SCAM_CHECKER.staticcall(
            abi.encodeWithSelector(IScamWordChecker.isScamWord.selector, name, symbol)
        );
        require(ok && ret.length == 64, "AR: name check unavailable");
        bytes32 nameWord;
        bytes32 symbolWord;
        assembly ("memory-safe") {
            nameWord := mload(add(ret, 32))
            symbolWord := mload(add(ret, 64))
        }
        require(
            (nameWord == bytes32(0) || nameWord == bytes32(uint256(1)))
                && (symbolWord == bytes32(0) || symbolWord == bytes32(uint256(1))),
            "AR: name check unavailable"
        );
        require(!(uint256(nameWord) == 1 || uint256(symbolWord) == 1), "AR: scam name or symbol");
    }

    /// @dev F14(a): replicate Flap Portal launchTaxTokenV2 fee-config validation so a raise that the Portal would reject can
    ///      never be created. ≤4 slots; each active type at most once (DuplicateFeeSlot); active bps sum = 10000
    ///      (InvalidTaxDistribution); MARKETING needs a non-zero address; VAULT is not supported here (so MARKETING ⊕ VAULT
    ///      holds trivially); DIVIDEND must pay the quote token (BNB) and its minimumShareBalance must lie in
    ///      [0.001%, 0.1%] of supply — checked even when its bps is 0 (Portal behaviour, verified on a BSC fork).
    function _checkFeeConfigs(IFlapPoolPortal.FeeConfig[] memory f, uint256 supply) internal pure {
        uint256 n = f.length;
        require(n <= 4, "AR: bad launch config");
        if (n == 0) return; // default: 100% DIVIDEND, min share 0.001% (valid by construction)
        uint256 seen; uint256 sum;
        for (uint256 i; i < n; ++i) {
            IFlapPoolPortal.FeeSlotType t = f[i].feeType;
            if (t == IFlapPoolPortal.FeeSlotType.NONE) continue;
            uint256 bit = 1 << uint8(t);
            require(!(seen & bit != 0), "AR: duplicate fee slot");
            seen |= bit; sum += f[i].bps;
            // V8.2.2 D-04: the real Portal rejects a zero-bps DEFLATION / LP_BPS / MARKETING slot (InvalidFeeConfigBps) at settle;
            //              DIVIDEND bps == 0 is Portal-accepted tracker-only mode.
            require(f[i].bps != 0 || t == IFlapPoolPortal.FeeSlotType.DIVIDEND, "AR: zero bps fee slot");
            require(t != IFlapPoolPortal.FeeSlotType.VAULT, "AR: vault fee slot unsupported");
            if (t == IFlapPoolPortal.FeeSlotType.MARKETING) {
                require(f[i].configData.length == 32, "AR: bad launch config");
                // V8.2.2 D-05: strict ABI decode (reverts on non-zero high 12 bytes) — the same decode feeConfigsOf() does at settle.
                abi.decode(f[i].configData, (address));
                // v10: marketingAddress == 0 → tax share is paid to THIS vault (claimTax → beneficiary)
            } else if (t == IFlapPoolPortal.FeeSlotType.DIVIDEND) {
                require(f[i].configData.length == 64, "AR: bad launch config");
                (address dt, uint256 minShare) = abi.decode(f[i].configData, (address, uint256));
                require(dt == address(0), "AR: dividend token must be BNB");
                require(!(minShare < supply * 10 / 1e6 || minShare > supply * 1000 / 1e6), "AR: min share out of range");
            } else require(f[i].configData.length == 0, "AR: bad launch config"); // DEFLATION / LP_BPS take no data
        }
        require(sum == 10_000, "AR: fee bps sum != 10000");
    }

    // ───────────── F12 salt registry (vault callbacks) ─────────────
    function claimSalt(uint256 raiseId, bytes32 salt) external onlyVaultOf(raiseId) returns (bool lockedByCaller) {
        Layout storage $ = _l();
        uint256 owner = $.saltOwner[salt];
        require(!(owner != 0 && owner != raiseId && !_released(owner)), "AR: salt taken");
        address locker = $.saltLocker[salt];
        require(!(locker != address(0) && locker != msg.sender), "AR: salt locked by other vault"); // Portal lock binds to one locker
        $.saltOwner[salt] = raiseId;
        return locker == msg.sender;
    }
    function markSaltLocked(uint256 raiseId, bytes32 salt) external onlyVaultOf(raiseId) {
        require(_l().saltOwner[salt] == raiseId, "AR: bad params");
        _l().saltLocker[salt] = msg.sender;
    }
    function releaseSalt(uint256 raiseId, bytes32 salt) external onlyVaultOf(raiseId) {
        if (_l().saltOwner[salt] == raiseId) delete _l().saltOwner[salt];
    }
    function _released(uint256 owner) internal view returns (bool) { return ISaltReleased(_l().vaultOf[owner]).saltReleased(); }

    // ───────────── global counters + FSI (vault callbacks) ─────────────
    function onContribution(uint256 raiseId, address creator, address who, uint256 amount, bool add) external onlyVaultOf(raiseId) {
        Layout storage $ = _l();
        if (add) { $.creatorRaised[creator] += amount; $.points[who] += amount; }
        else { $.creatorRaised[creator] -= amount; $.points[who] -= amount; }
        _fsiSetAddr(NS_CREATOR_RAISED, creator, $.creatorRaised[creator]);
        _fsiSetAddr(NS_POINTS, who, $.points[who]);
    }
    function fsiSetRound(uint256 raiseId, bytes32 ns, address account, uint256 value) external onlyVaultOf(raiseId) { _fsiSetRound(ns, raiseId, account, value); }
    function fsiAppend(uint256 raiseId, bytes32 ns, uint256 seq, address actor, address related, string calldata data) external onlyVaultOf(raiseId) { _fsiAppend(ns, raiseId, seq, actor, related, data); }
    function fsiLog(uint256 raiseId, bytes32 ns, address actor, address related, uint256 amount, uint256 extra) external onlyVaultOf(raiseId) { _fsiLog(ns, raiseId, actor, related, amount, extra); }

    // ───────────── views ─────────────
    function portal() external pure returns (address) { return PORTAL; }
    function agentIdRegistry() external view returns (address) { return _l().agentIdRegistry; }
    function raiseCount() external view returns (uint256) { return _l().raiseCount; }
    function vaultOf(uint256 raiseId) external view returns (address) { return _l().vaultOf[raiseId]; }
    function raiseOfVault(address vault) external view returns (uint256) { return _l().raiseOfVault[vault]; }
    function saltOwner(bytes32 salt) external view returns (uint256) { return _l().saltOwner[salt]; }
    function saltLocker(bytes32 salt) external view returns (address) { return _l().saltLocker[salt]; }
    function saltHolder(bytes32 salt) external view returns (uint256) { uint256 o = _l().saltOwner[salt]; return o != 0 && _released(o) ? 0 : o; }
    function creatorRaised(address a) external view returns (uint256) { return _l().creatorRaised[a]; }
    function launchAvailable() external view returns (bool) { (bool enabled,) = ILauncherPortalV1(PORTAL).launcherFactoryMultiplier(address(this)); return enabled || (ILauncherPortalV1(PORTAL).featureFlags() & 1) == 0; }
    function points(address a) external view returns (uint256) { return _l().points[a]; }
    function agentOf(address account) external view returns (string memory handle, uint256 tokenId) {
        handle = IAgentIdRegistry(_l().agentIdRegistry).handleOf(account);
        if (bytes(handle).length != 0) tokenId = uint256(keccak256(bytes(handle)));
    }
}
