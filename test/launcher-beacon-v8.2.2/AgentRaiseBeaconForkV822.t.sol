// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Test} from "forge-std/Test.sol";
import {AgentRaiseLauncherFactoryV822 as Factory} from "../../contracts/launcher-beacon-v8.2.2/AgentRaiseLauncherFactoryV822.sol";
import {AgentRaiseLauncherV82 as Launcher} from "../../contracts/launcher-beacon-v8.2/AgentRaiseLauncherV82.sol";
import {AgentRaiseTriggerDistributorV82 as Distributor} from "../../contracts/launcher-beacon-v8.2/AgentRaiseTriggerDistributorV82.sol";
import {IFlapPoolPortal} from "../../contracts/interfaces/IFlapPoolPortal.sol";
import {IAgentIdRegistry} from "../../contracts/interfaces/IAgentIdRegistry.sol";

interface IPortalAdminD04 {
    function MANAGE_ROLE() external view returns (bytes32);
    function setLauncherFactoryMultiplier(address factory, uint16 multiplierBps, bool enabled) external;
    function newLauncher(address factory, bytes calldata data) external payable returns (address);
    function SALT_LOCK_FEE() external view returns (uint256);
}

/// @notice V8.2.2 D-04 / D-05 small fork test against the REAL BSC Portal (factory enabled only inside the fork).
/// Bad layouts (zero-bps DEFLATION / LP_BPS / MARKETING, dirty MARKETING address) are rejected at create — no salt lock, no principal.
/// Good layouts (DIVIDEND bps 0, one-sided tax, clean MARKETING, all four slots, default) fill and auto-settle through Portal.launchTaxTokenV2.
/// Run: BSC_RPC_URL=https://bsc-rpc.publicnode.com forge test --match-path 'test/launcher-beacon-v8.2.2/AgentRaiseBeaconForkV822.t.sol' -vv
contract AgentRaiseBeaconForkV822Test is Test {
    address constant PORTAL = 0x000042108465206185A077Edc3F3fd2b49060000;
    bytes32 constant SALT = 0x7673bf55f9fa36870b72878dab03320e246babf9e94557d9ce91bb95f6733d43; // vanity …7777 (from V8.2 fork suite)
    uint256 constant SUPPLY = 1e9 ether;
    address creator = address(0xA11CE); address bene = address(0xBEEF);
    Factory factory; address reg; bool forked;
    modifier onlyFork() { if (!forked) vm.skip(true); _; }

    function setUp() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) { vm.skip(true); return; }
        vm.createSelectFork(rpc); forked = true;
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        Distributor dist = new Distributor(predicted);
        Launcher impl = new Launcher(predicted, address(dist));
        factory = new Factory(address(impl));
        assertEq(address(factory), predicted);
        reg = factory.agentIdRegistry();
        bytes32 role = IPortalAdminD04(PORTAL).MANAGE_ROLE();
        vm.store(PORTAL, keccak256(abi.encode(address(this), keccak256(abi.encode(role, uint256(101))))), bytes32(uint256(1)));
        IPortalAdminD04(PORTAL).setLauncherFactoryMultiplier(address(factory), 10000, true);
    }
    function _agent(address who, uint256 i) internal {
        vm.mockCall(reg, abi.encodeWithSelector(IAgentIdRegistry.handleOf.selector, who), abi.encode(string.concat("d04-agent-", vm.toString(i))));
        vm.deal(who, 10 ether);
    }
    function _fc(IFlapPoolPortal.FeeSlotType t, uint16 bps, bytes memory d) internal pure returns (IFlapPoolPortal.FeeConfig memory) { return IFlapPoolPortal.FeeConfig(t, bps, d); }
    function _div(uint16 bps) internal pure returns (IFlapPoolPortal.FeeConfig memory) { return _fc(IFlapPoolPortal.FeeSlotType.DIVIDEND, bps, abi.encode(address(0), SUPPLY / 100_000)); }
    function _arr(IFlapPoolPortal.FeeConfig memory a) internal pure returns (IFlapPoolPortal.FeeConfig[] memory f) { f = new IFlapPoolPortal.FeeConfig[](1); f[0] = a; }
    function _arr(IFlapPoolPortal.FeeConfig memory a, IFlapPoolPortal.FeeConfig memory b) internal pure returns (IFlapPoolPortal.FeeConfig[] memory f) { f = new IFlapPoolPortal.FeeConfig[](2); f[0] = a; f[1] = b; }
    function _data(IFlapPoolPortal.FeeConfig[] memory f, uint16 buy, uint16 sell) internal view returns (bytes memory) {
        Launcher.LaunchConfig memory c;
        c.tokenName = "Dock Fork Test"; c.tokenSymbol = "DOCKT"; c.tokenMeta = "bafk-fork"; c.totalSupply = SUPPLY; c.salt = SALT;
        c.buyTaxBps = buy; c.sellTaxBps = sell; c.taxDuration = 7 days; c.feeConfigs = f;
        return abi.encode(Factory.CreateConfig("D04 fork raise", "bafk-raise", abi.encode(Launcher.ShareConfig(0.1 ether, 50, 10)),
            uint64(block.timestamp + 1 days), bene, abi.encode(c)));
    }
    function _reject(IFlapPoolPortal.FeeConfig[] memory f, bytes memory reason) internal {
        _agent(creator, 0); uint256 fee = IPortalAdminD04(PORTAL).SALT_LOCK_FEE(); bytes memory d = _data(f, 100, 100);
        vm.prank(creator); vm.expectRevert(reason);
        IPortalAdminD04(PORTAL).newLauncher{value: fee}(address(factory), d);
        assertEq(factory.raiseCount(), 0); assertEq(factory.saltOwner(SALT), 0);
    }
    function _launch(IFlapPoolPortal.FeeConfig[] memory f, uint16 buy, uint16 sell) internal {
        uint256 snap = vm.snapshotState();
        _agent(creator, 0); uint256 fee = IPortalAdminD04(PORTAL).SALT_LOCK_FEE(); bytes memory d = _data(f, buy, sell);
        vm.prank(creator); Launcher l = Launcher(payable(IPortalAdminD04(PORTAL).newLauncher{value: fee}(address(factory), d)));
        uint256 id = factory.raiseCount(); assertEq(id, 1);
        for (uint256 i = 1; i <= 5; ++i) { address w = address(uint160(0xD0C0000 + i)); _agent(w, i); vm.prank(w, w); l.contribute{value: 1 ether}(id, 10); }
        Launcher.Raise memory r = l.getRaise(id);
        assertTrue(r.closed && r.settled, "auto-settled via real Portal.launchTaxTokenV2");
        l.feeConfigsOf(id); // readable
        vm.revertToState(snap);
    }
    function test_fork_v822_d04_zeroBpsSlotsRejectedAtCreate() public onlyFork {
        bytes memory zb = bytes("AR: zero bps fee slot");
        _reject(_arr(_fc(IFlapPoolPortal.FeeSlotType.DEFLATION, 0, ""), _fc(IFlapPoolPortal.FeeSlotType.LP_BPS, 10000, "")), zb);
        _reject(_arr(_fc(IFlapPoolPortal.FeeSlotType.LP_BPS, 0, ""), _fc(IFlapPoolPortal.FeeSlotType.DEFLATION, 10000, "")), zb);
        _reject(_arr(_fc(IFlapPoolPortal.FeeSlotType.MARKETING, 0, abi.encode(address(0))), _fc(IFlapPoolPortal.FeeSlotType.DEFLATION, 10000, "")), zb);
    }
    function test_fork_v822_d05_dirtyMarketingRejectedAtCreate() public onlyFork {
        _reject(_arr(_fc(IFlapPoolPortal.FeeSlotType.MARKETING, 10000, abi.encode((uint256(1) << 160) | uint256(uint160(address(0xBEEF)))))), "");
    }
    function test_fork_v822_dividendZeroBpsLaunches() public onlyFork {
        _launch(_arr(_fc(IFlapPoolPortal.FeeSlotType.DEFLATION, 10000, ""), _div(0)), 100, 100);
    }
    function test_fork_v822_oneSidedTaxCleanMarketingLaunches() public onlyFork {
        _launch(_arr(_fc(IFlapPoolPortal.FeeSlotType.MARKETING, 10000, abi.encode(address(0xBEEF)))), 0, 100);
        _launch(_arr(_fc(IFlapPoolPortal.FeeSlotType.MARKETING, 10000, abi.encode(address(0)))), 100, 0);
    }
    function test_fork_v822_fourSlotsAndDefaultLaunch() public onlyFork {
        IFlapPoolPortal.FeeConfig[] memory f4 = new IFlapPoolPortal.FeeConfig[](4);
        f4[0] = _fc(IFlapPoolPortal.FeeSlotType.DEFLATION, 1000, ""); f4[1] = _fc(IFlapPoolPortal.FeeSlotType.LP_BPS, 2000, "");
        f4[2] = _fc(IFlapPoolPortal.FeeSlotType.MARKETING, 3000, abi.encode(address(0xBEEF))); f4[3] = _div(4000);
        _launch(f4, 100, 100);
        _launch(new IFlapPoolPortal.FeeConfig[](0), 100, 100);
    }
}
