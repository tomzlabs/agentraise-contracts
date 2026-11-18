// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {LauncherV82UpgradeMock} from "../launcher-beacon-v8.2/LauncherV82UpgradeMock.sol";
import {MockFlapTriggerService} from "../launcher-beacon-v8/MockFlapTriggerService.sol";
import {MockReentrantTrigger} from "../launcher-beacon-v8.2/MockReentrantTrigger.sol";
import {AgentRaiseTriggerDistributorV82 as Distributor} from "../../contracts/launcher-beacon-v8.2/AgentRaiseTriggerDistributorV82.sol";
import {Test, Vm} from "forge-std/Test.sol";
import {AgentRaiseLauncherFactoryV822 as Factory} from "../../contracts/launcher-beacon-v8.2.2/AgentRaiseLauncherFactoryV822.sol";
import {AgentRaiseLauncherV82 as Launcher} from "../../contracts/launcher-beacon-v8.2/AgentRaiseLauncherV82.sol";
import {LauncherFactoryBase} from "../../contracts/launcher-beacon-v8.2/flap/LauncherFactoryBase.sol";
import {ILauncherFactory,LauncherRecord} from "../../contracts/launcher-beacon-v8.2/flap/ILauncher.sol";
import {IPortal,IPortalTypes} from "../../contracts/launcher-audit-fix/flap/IPortal.sol";
import {LauncherDataSchema} from "../../contracts/launcher-beacon-v8.2/flap/IVaultSchemas.sol";
import {IFlapPoolPortal, IERC20Min} from "../../contracts/interfaces/IFlapPoolPortal.sol";
import {Distribution} from "../../contracts/launcher-audit-fix/flap/Distribution.sol";
import {MockLauncherPortalV1,LauncherRegistryV1} from "../launcher-audit-fix/MockLauncherPortalV1.sol";
import {MockTaxToken} from "../launcher-audit-fix/MockLauncherTaxTokenV1.sol";
import {MockScamChecker} from "../launcher-beacon-v8/MockScamChecker.sol";
import {GuardianRescueV82,IGuardianRescueV82} from "../../contracts/launcher-beacon-v8.2/GuardianRescueV82.sol";
import {ILauncherDescription} from "../../contracts/launcher-beacon-v8.2/flap/ILauncher.sol";
import {MockTokenDockRouter} from "../launcher-beacon-v8/MockTokenDockRouter.sol";

/// @notice V8.2 suite = the V8.1 suite ported to AgentRaiseLauncherV82 / FactoryV82 / TriggerDistributorV82 (fee assertions 2% -> 3%)
///         plus the V8.2 Flap Launcher description() tests at the end. Logic otherwise identical to V8.1.
contract AgentRaiseLauncherV822Test is Test {
    address constant HUB=0x000042108465206185A077Edc3F3fd2b49060000;
    address constant REG=0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F;
    address constant GUARDIAN=0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b;
    address constant TREASURY=0xE04c10D1160797c018630152e1ff8B13B50681d6;
    address creator=address(0xA11CE);address alice=address(0xB0B);address bob=address(0xCAFE);address bene=address(0xBEEF);
    Factory factory;MockLauncherPortalV1 portal;LauncherRegistryV1 registry;
    address constant CHECKER=0xfFb69d59f62454f3B8322Bc1a9FCE6E171a5264f;
    MockScamChecker checker;
    address constant TRIG=0xcf4EE25035CF883895110f367F5BA8172416a7F9;MockFlapTriggerService trig;Distributor dist;
    address constant DOCK=0x000048E888aBf09f690a952E1b386b2D031a0000;MockTokenDockRouter dock;
    function setUp() public {
        vm.chainId(56);vm.warp(1000000);
        MockLauncherPortalV1 p=new MockLauncherPortalV1();vm.etch(HUB,address(p).code);portal=MockLauncherPortalV1(HUB);portal.configure(1e30,true);
        LauncherRegistryV1 r=new LauncherRegistryV1();vm.etch(REG,address(r).code);registry=LauncherRegistryV1(REG);
        MockScamChecker c=new MockScamChecker();vm.etch(CHECKER,address(c).code);checker=MockScamChecker(CHECKER);checker.set(false,false,false,false,false);
        MockTokenDockRouter dk=new MockTokenDockRouter();vm.etch(DOCK,address(dk).code);dock=MockTokenDockRouter(DOCK);
        MockFlapTriggerService tg=new MockFlapTriggerService();vm.etch(TRIG,address(tg).code);trig=MockFlapTriggerService(TRIG);trig.configure(0.0002 ether,2_000_000);
        factory=_deployFactory();portal.setFactory(address(factory),true,10000);
        _agent(creator,"creator");_agent(alice,"alice");_agent(bob,"bob");vm.deal(address(this),1000 ether);
    }

    /// @dev Test-only binary search over factory.meetsLiveCreateFloor (not deployed on factory — EIP-170).
    function _minHardCapWei(uint16 creatorShareBps, uint256 totalSupply) internal view returns (uint256) {
        if (factory.meetsLiveCreateFloor(0, creatorShareBps, totalSupply)) return 0;
        uint256 lo = 1;
        uint256 hi = 1_000_000 ether;
        require(factory.meetsLiveCreateFloor(hi, creatorShareBps, totalSupply), "test: no upper bound");
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (factory.meetsLiveCreateFloor(mid, creatorShareBps, totalSupply)) hi = mid;
            else lo = mid + 1;
        }
        return lo;
    }

    /// @dev V8 deployment order (same as the mainnet script): impl bound to the predicted factory CREATE address, then factory.
    function _deployFactory() internal returns(Factory f){address predicted=vm.computeCreateAddress(address(this),vm.getNonce(address(this))+2);dist=new Distributor(predicted);Launcher impl=new Launcher(predicted,address(dist));f=new Factory(address(impl));assertEq(address(f),predicted);}
    function _agent(address who,string memory h) internal {registry.set(who,h);vm.deal(who,1000 ether);}
    function _cfg() internal pure returns(Launcher.ShareConfig memory){return Launcher.ShareConfig(0.1 ether,100,20);}
    function _launch(bytes32 salt) internal pure returns(Launcher.LaunchConfig memory c){c.tokenName="Agent Launch";c.tokenSymbol="AGENT";c.tokenMeta="bafk-test";c.totalSupply=1e9 ether;c.salt=salt;c.buyTaxBps=100;c.sellTaxBps=100;c.taxDuration=7 days;c.creatorShareBps=1000;c.feeConfigs=new IFlapPoolPortal.FeeConfig[](0);}
    function _data(Launcher.ShareConfig memory cfg,uint64 deadline,Launcher.LaunchConfig memory launch,address beneficiary) internal pure returns(bytes memory){return abi.encode(Factory.CreateConfig("Agent raise","bafk-raise",abi.encode(cfg),deadline,beneficiary,abi.encode(launch)));}
    function _create(bytes32 salt) internal returns(Launcher l,uint256 id){return _createFee(salt,portal.SALT_LOCK_FEE());}
    function _createFee(bytes32 salt,uint256 fee) internal returns(Launcher l,uint256 id){bytes memory data=_data(_cfg(),uint64(block.timestamp+1 days),_launch(salt),bene);vm.prank(creator);l=Launcher(payable(portal.newLauncher{value:fee}(address(factory),data)));id=factory.raiseCount();}
    function _buy(Launcher l,uint256 id,address who,uint256 qty) internal {vm.prank(who);l.contribute{value:qty*0.1 ether}(id,qty);}
    function _fillToHard(Launcher l,uint256 id) internal returns(address a,address b){a=address(0x111);b=address(0x222);_agent(a,"four");_agent(b,"five");_buy(l,id,alice,20);_buy(l,id,bob,20);_buy(l,id,creator,20);_buy(l,id,a,20);_buy(l,id,b,20);}
    /// @dev Close hardCap with Portal launch forced to revert so auto-settle fails; restores Portal. Leaves canSettle=true.
    function _ready(Launcher l,uint256 id) internal {portal.setBehavior(false,true,false,false);_fillToHard(l,id);portal.setBehavior(false,false,false,false);assertTrue(l.getRaise(id).closed);assertFalse(l.getRaise(id).settled);assertTrue(l.canSettle(id));}
    function test_officialAbiAndSchema() public view {
        assertEq(IPortal.launchTaxTokenV2.selector,IFlapPoolPortal.launchTaxTokenV2.selector);
        assertEq(IPortal.newLauncher.selector,bytes4(keccak256("newLauncher(address,bytes)")));
        assertEq(factory.factorySpecVersion(),"lf-v1");assertEq(factory.flapSharedIndexerSpecVersion(),"fsi-v1");
        LauncherDataSchema memory schema=factory.launcherDataSchema();assertEq(schema.fields.length,6);assertEq(schema.fields[2].fieldType,"bytes");assertFalse(schema.isArray);
        assertEq(factory.agentIdRegistry(),REG);assertEq(factory.PORTAL(),HUB);
    }
    function test_onlyHubCannotSpoofCreator() public {vm.expectRevert(abi.encodeWithSelector(LauncherFactoryBase.NotHub.selector,address(this)));factory.newLauncher(creator,_data(_cfg(),uint64(block.timestamp+1 days),_launch(bytes32(uint256(1))),bene));}
    function test_creatorIsOriginalPortalCaller() public {(Launcher l,uint256 id)=_create(bytes32(uint256(1)));assertEq(l.getRaise(id).creator,creator);assertEq(l.getRaise(id).agentId,"creator");assertEq(portal.getLauncher(address(l)).launcherFactory,address(factory));assertEq(factory.vaultOf(id),address(l));assertEq(factory.raiseOfVault(address(l)),id);}
    function test_absentAgentCreateRevertsAtomically() public {registry.set(creator,"");vm.prank(creator);vm.expectRevert("AR: not agent");portal.newLauncher{value:0.01 ether}(address(factory),_data(_cfg(),uint64(block.timestamp+1 days),_launch(bytes32(uint256(2))),bene));assertEq(factory.raiseCount(),0);}
    function test_absentAgentContribute() public {(Launcher l,uint256 id)=_create(bytes32(uint256(1)));registry.set(alice,"");vm.prank(alice);vm.expectRevert("AR: not agent");l.contribute{value:0.1 ether}(id,1);assertEq(l.sharesSold(id),0);}
    function test_oneAgentIdOneWallet() public {(Launcher l,uint256 id)=_create(bytes32(uint256(1)));_buy(l,id,alice,1);registry.set(bob,"alice");vm.prank(bob);vm.expectRevert("AR: agent id used by other addr");l.contribute{value:0.1 ether}(id,1);}
    function test_creatorSameCap() public {(Launcher l,uint256 id)=_create(bytes32(uint256(1)));_buy(l,id,creator,20);vm.prank(creator);vm.expectRevert("AR: over wallet cap");l.contribute{value:0.1 ether}(id,1);}
    function test_badCapAndShareConfig() public {Launcher.ShareConfig memory cfg=_cfg();cfg.perWalletCap=30;vm.prank(creator);vm.expectRevert("AR: wallet cap must be 10 or 20");portal.newLauncher{value:0.01 ether}(address(factory),_data(cfg,uint64(block.timestamp+1 days),_launch(bytes32(uint256(2))),bene));}
    function test_zeroQuantityAndIncorrectAmount() public {(Launcher l,uint256 id)=_create(bytes32(uint256(1)));vm.startPrank(alice);vm.expectRevert("AR: bad amount");l.contribute(id,0);vm.expectRevert("AR: bad amount");l.contribute{value:0.09 ether}(id,1);vm.stopPrank();}
    function test_deadlineBoundary() public {(Launcher l,uint256 id)=_create(bytes32(uint256(1)));vm.warp(l.getRaise(id).deadline-1);_buy(l,id,alice,1);vm.warp(block.timestamp+1);vm.prank(bob);vm.expectRevert("AR: raise ended");l.contribute{value:0.1 ether}(id,1);}
    function test_deadlineLimits() public {vm.prank(creator);vm.expectRevert("AR: bad params");portal.newLauncher{value:0.01 ether}(address(factory),_data(_cfg(),uint64(block.timestamp+90 days+1),_launch(bytes32(uint256(2))),bene));}
    function test_feeSeparateSaltOwnedByLauncher() public {(Launcher l,uint256 id)=_createFee(bytes32(uint256(1)),portal.SALT_LOCK_FEE());assertEq(address(l).balance,0);assertEq(l.getRaise(id).totalRaised,0);assertEq(portal.lockerOf(bytes32(uint256(1))),address(l));assertEq(factory.saltLocker(bytes32(uint256(1))),address(l));assertTrue(l.getRaise(id).saltLocked);}
    function test_excessFeeRejectedAndNoPartialCreation() public {uint256 badFee=portal.SALT_LOCK_FEE()+1;vm.prank(creator);vm.expectRevert("AR: salt lock fee required");portal.newLauncher{value:badFee}(address(factory),_data(_cfg(),uint64(block.timestamp+1 days),_launch(bytes32(uint256(2))),bene));assertEq(factory.raiseCount(),0);assertEq(factory.vaultOf(1),address(0));}
    function test_factoryOnlyInitializerAndImplementationDisabled() public {(Launcher l,)=_create(bytes32(uint256(1)));vm.expectRevert();l.initialize(2,creator,"fake","x","",_cfg(),uint64(block.timestamp+1 days),bene,_launch(bytes32(uint256(2))));Launcher implementation=Launcher(payable(factory.implementation()));vm.expectRevert();implementation.initialize(2,creator,"fake","x","",_cfg(),uint64(block.timestamp+1 days),bene,_launch(bytes32(uint256(2))));}
    function test_noncanonicalDataRejected() public {bytes memory d=bytes.concat(_data(_cfg(),uint64(block.timestamp+1 days),_launch(bytes32(uint256(1))),bene),hex"00");vm.prank(creator);vm.expectRevert("AR: noncanonical data");portal.newLauncher{value:0.01 ether}(address(factory),d);}
    function test_disabledFactoryCannotCreate() public {portal.setFactory(address(factory),false,3000);vm.prank(creator);vm.expectRevert("MOCK: disabled");portal.newLauncher{value:0.01 ether}(address(factory),_data(_cfg(),uint64(block.timestamp+1 days),_launch(bytes32(uint256(2))),bene));}
    function test_settlePermissionlessNoAgentAndSingleLaunch() public {(Launcher l,uint256 id)=_createFee(bytes32(uint256(1)),portal.SALT_LOCK_FEE());_ready(l,id);address keeper=address(0xF00);assertEq(registry.handleOf(keeper),"");vm.prank(keeper);l.settle(id);assertTrue(l.getRaise(id).settled);assertEq(portal.lastCaller(),address(l));assertEq(portal.lastCreator(),creator);assertTrue(portal.launched(address(l)));assertTrue(portal.duplicateCallbackRejected());vm.expectRevert("AR: not settleable");l.settle(id);}
    function test_accountingDistributionAndBeneficiaryConserved() public {(Launcher l,uint256 id)=_create(bytes32(uint256(1)));_ready(l,id);uint256 beforeTreasury=TREASURY.balance;l.settle(id);Launcher.Raise memory r=l.getRaise(id);IPortalTypes.CreateTaxTokenParams memory p=portal.last();assertEq(p.creatorBuyQuote,0);assertEq(p.commissionReceiver,address(0));assertEq(p.totalSupply,r.poolTokens+r.saleTokens);assertEq(p.poolQuote+TREASURY.balance-beforeTreasury+r.beneficiaryOwed,10 ether);assertEq(portal.lastValue(),p.poolQuote);assertEq(IERC20Min(r.token).balanceOf(alice),r.saleTokens*20/100);assertEq(IERC20Min(r.token).balanceOf(bob),r.saleTokens*20/100);assertEq(IERC20Min(r.token).balanceOf(creator),r.saleTokens*20/100);assertApproxEqAbs(p.poolQuote*1e18/p.poolToken,10 ether*1e18/r.saleTokens,1);uint256 owed=r.beneficiaryOwed;uint256 beforeBene=bene.balance;l.claimBeneficiary(id);assertEq(bene.balance-beforeBene,owed);assertEq(address(l).balance,0);}
    function test_dynamicMultiplierZeroAndDisabledFallback() public {(Launcher l,uint256 id)=_create(bytes32(uint256(1)));_buy(l,id,alice,10);portal.configure(1000 ether,true);IFlapPoolPortal.GraduationFloorResultV2 memory full=l.previewLaunch(id,1000 ether);portal.setFactory(address(factory),true,5000);IFlapPoolPortal.GraduationFloorResultV2 memory half=l.previewLaunch(id,1000 ether);assertEq(half.multiplierBps,5000);assertLt(half.createFloorUsdWad,full.createFloorUsdWad);assertTrue(half.meetsCreateFloor);portal.setFactory(address(factory),true,0);assertEq(l.previewLaunch(id,1000 ether).createFloorUsdWad,0);portal.setFactory(address(factory),false,0);assertEq(l.previewLaunch(id,1000 ether).multiplierBps,10000);assertFalse(l.previewLaunch(id,1000 ether).meetsCreateFloor);}
    function test_missingLensFailsClosedNoStaleDiscount() public {(Launcher l,uint256 id)=_create(bytes32(uint256(1)));_buy(l,id,alice,1);portal.setBehavior(true,false,false,false);vm.expectRevert("MOCK: missing lens");l.previewLaunch(id,1000 ether);}
    function test_disabledExistingFactoryStillLaunchesAtOneX() public {(Launcher l,uint256 id)=_create(bytes32(uint256(1)));_ready(l,id);portal.setFactory(address(factory),false,0);l.settle(id);assertTrue(l.getRaise(id).settled);}
    function test_enabledFactoryPauseBypassAndDisabledPauseRefund() public {(Launcher l,uint256 id)=_create(bytes32(uint256(1)));_ready(l,id);portal.setFlags(1);l.settle(id);(Launcher l2,uint256 id2)=_create(bytes32(uint256(2)));_ready(l2,id2);portal.setFactory(address(factory),false,5000);vm.expectRevert("MOCK: paused");l2.settle(id2);vm.warp(uint256(l2.getRaise(id2).deadline)+3 days);l2.markFailed(id2);vm.prank(alice);l2.refund(id2);assertEq(l2.contributionOf(id2,alice),0);}
    function test_v6_unfilledAtDeadlineNeedsMarkFailedThenRefunds() public {(Launcher l,uint256 id)=_create(bytes32(uint256(1)));_buy(l,id,alice,1);vm.warp(l.getRaise(id).deadline);assertFalse(l.refundOpen(id));assertFalse(l.canSettle(id));vm.prank(address(0xBAD1));l.markFailed(id);assertTrue(l.refundOpen(id));uint256 b=alice.balance;vm.prank(alice);l.refund(id);assertEq(alice.balance-b,0.1 ether);assertEq(factory.creatorRaised(creator),0);assertEq(factory.points(alice),0);}
    function test_creatorCancelAnyTime() public {(Launcher l,uint256 id)=_create(bytes32(uint256(1)));_buy(l,id,alice,10);vm.prank(creator);l.markFailed(id);assertTrue(l.refundOpen(id));vm.prank(alice);l.refund(id);assertEq(address(l).balance,0);}
    function test_nonCreatorGraceAndExactThirtyDayTimeout() public {
        // Filled-unsettled: non-creator blocked until grace; 30-day timeout opens refunds without markFailed.
        (Launcher l,uint256 id)=_create(bytes32(uint256(1)));_ready(l,id);
        vm.prank(address(0xBAD1));vm.expectRevert("AR: cannot mark failed");l.markFailed(id);assertFalse(l.refundOpen(id));
        vm.warp(uint256(l.getRaise(id).deadline)+30 days-1);assertFalse(l.refundOpen(id));
        vm.warp(block.timestamp+1);assertTrue(l.refundOpen(id));assertFalse(l.canSettle(id));
        vm.prank(alice);l.refund(id);assertEq(l.contributionOf(id,alice),0);
        // Unfilled: anyone may markFailed right after deadline (no grace); no auto-refund without it.
        (Launcher l2,uint256 id2)=_create(bytes32(uint256(2)));_buy(l2,id2,alice,1);
        vm.warp(l2.getRaise(id2).deadline);assertFalse(l2.refundOpen(id2));
        vm.prank(address(0xBAD1));l2.markFailed(id2);assertTrue(l2.refundOpen(id2));
    }    function test_launchFailureRollsBackAndCanRefundAfterGrace() public {(Launcher l,uint256 id)=_create(bytes32(uint256(1)));_ready(l,id);portal.setBehavior(false,true,false,false);vm.expectRevert("AR: bad distribution");l.settle(id);assertFalse(l.getRaise(id).settled);assertFalse(portal.launched(address(l)));assertEq(address(l).balance,10 ether);vm.warp(uint256(l.getRaise(id).deadline)+3 days);l.markFailed(id);vm.prank(alice);l.refund(id);assertEq(l.contributionOf(id,alice),0);assertEq(address(l).balance,8 ether);}
    function test_missingDistributionRejected() public {(Launcher l,uint256 id)=_create(bytes32(uint256(1)));_ready(l,id);portal.setBehavior(false,false,true,false);vm.expectRevert("AR: bad distribution");l.settle(id);assertFalse(l.getRaise(id).settled);}
    function test_portalCannotReenterSettleAndCannotCallbackTwice() public {(Launcher l,uint256 id)=_create(bytes32(uint256(1)));_ready(l,id);portal.setBehavior(false,false,false,true);l.settle(id);assertTrue(portal.reentryRejected());assertTrue(portal.duplicateCallbackRejected());}
    function test_unauthorizedDistribution() public {(Launcher l,uint256 id)=_create(bytes32(uint256(1)));vm.expectRevert("AR: bad distribution");l.initializeDistribution(address(1),1,abi.encode(id),bytes32(0));}
    function test_guardianOnlyUpgradeAndNoOtherAuthority() public {vm.expectRevert(abi.encodeWithSelector(LauncherFactoryBase.NotGuardian.selector,address(this)));factory.upgradeVaultImplementation(address(1));vm.prank(GUARDIAN);vm.expectRevert();factory.upgradeVaultImplementation(address(1));}
    function test_saltRegistryAndCancelledUnlockedRelease() public {(Launcher l,uint256 id)=_create(bytes32(uint256(1)));vm.prank(creator);vm.expectRevert("AR: salt taken");portal.newLauncher{value:0.01 ether}(address(factory),_data(_cfg(),uint64(block.timestamp+1 days),_launch(bytes32(uint256(1))),bene));vm.prank(creator);l.markFailed(id);(Launcher l2,)=_create(bytes32(uint256(2)));assertTrue(address(l2)!=address(l)); /* V7: salt 1 stays Portal-locked by l (see test_lockedSaltCannotMigrateToAnotherLauncher) */}
    function test_lockedSaltCannotMigrateToAnotherLauncher() public {(Launcher l,uint256 id)=_createFee(bytes32(uint256(1)),portal.SALT_LOCK_FEE());vm.prank(creator);l.markFailed(id);vm.prank(creator);vm.expectRevert("AR: salt locked by other vault");portal.newLauncher{value:0.01 ether}(address(factory),_data(_cfg(),uint64(block.timestamp+1 days),_launch(bytes32(uint256(1))),bene));}
    function test_defaultDividendAndInvalidTaxSplit() public {(Launcher l,uint256 id)=_create(bytes32(uint256(1)));IFlapPoolPortal.FeeConfig[] memory fees=l.feeConfigsOf(id);assertEq(fees.length,1);assertEq(uint8(fees[0].feeType),5);assertEq(fees[0].bps,10000);(address dt,uint256 min)=abi.decode(fees[0].configData,(address,uint256));assertEq(dt,address(0));assertEq(min,1e9 ether/100000);Launcher.LaunchConfig memory c=_launch(bytes32(uint256(2)));c.feeConfigs=new IFlapPoolPortal.FeeConfig[](1);c.feeConfigs[0]=IFlapPoolPortal.FeeConfig(IFlapPoolPortal.FeeSlotType.DEFLATION,9999,"");vm.prank(creator);vm.expectRevert("AR: fee bps sum != 10000");portal.newLauncher{value:0.01 ether}(address(factory),_data(_cfg(),uint64(block.timestamp+1 days),c,bene));}
    function test_marketingToLauncherClaimTaxBoundToBeneficiary() public {Launcher.LaunchConfig memory c=_launch(bytes32(uint256(1)));c.feeConfigs=new IFlapPoolPortal.FeeConfig[](4);c.feeConfigs[0]=IFlapPoolPortal.FeeConfig(IFlapPoolPortal.FeeSlotType.DEFLATION,1000,"");c.feeConfigs[1]=IFlapPoolPortal.FeeConfig(IFlapPoolPortal.FeeSlotType.LP_BPS,2000,"");c.feeConfigs[2]=IFlapPoolPortal.FeeConfig(IFlapPoolPortal.FeeSlotType.MARKETING,3000,abi.encode(address(0)));c.feeConfigs[3]=IFlapPoolPortal.FeeConfig(IFlapPoolPortal.FeeSlotType.DIVIDEND,4000,abi.encode(address(0),1e9 ether/100000));vm.prank(creator);Launcher l=Launcher(payable(portal.newLauncher{value:0.01 ether}(address(factory),_data(_cfg(),uint64(block.timestamp+1 days),c,bene))));uint256 id=factory.raiseCount();assertEq(abi.decode(l.feeConfigsOf(id)[2].configData,(address)),address(l));_ready(l,id);l.settle(id);(bool ok,)=address(l).call{value:0.3 ether}("");assertTrue(ok);assertEq(l.taxAccrued(),0.3 ether);uint256 before=bene.balance;l.claimTax();assertEq(bene.balance-before,0.3 ether);}
    function test_quoteDisabledDoesNotTrapEscrow() public {(Launcher l,uint256 id)=_create(bytes32(uint256(1)));_ready(l,id);portal.configure(1e30,false);assertFalse(l.meetsLaunchFloor(id));vm.expectRevert("MOCK: quote disabled");l.settle(id);vm.warp(uint256(l.getRaise(id).deadline)+3 days);l.markFailed(id);vm.prank(alice);l.refund(id);assertEq(l.contributionOf(id,alice),0);assertEq(address(l).balance,8 ether);}
    function test_immutableBytecodeSizeLimits() public view {assertLt(address(factory).code.length,24576);assertLt(factory.implementation().code.length,24576);}
    function testFuzz_poolAccountingConserves(uint96 raw,uint16 share) public view {uint256 raised=bound(raw,0.001 ether,1e27);uint256 bps=bound(share,0,1000);(uint256 q,uint256 tokens,uint256 n)=factory.poolFor(raised,bps,1e9 ether);uint256 fee=raised*300/10000;uint256 cash=(raised-fee)*bps/10000;assertEq(q+fee+cash,raised);assertEq(tokens,n*q/(raised+q));assertGt(tokens,0);assertLt(tokens,n);}
    function testFuzz_exactContributionsAndRefund(uint8 raw) public {uint256 qty=bound(raw,1,9);(Launcher l,uint256 id)=_create(bytes32(uint256(1)));_buy(l,id,alice,qty);assertEq(l.contributionOf(id,alice),qty*0.1 ether);assertEq(l.sharesOf(id,alice),qty);vm.warp(l.getRaise(id).deadline);vm.prank(creator);l.markFailed(id);uint256 before=alice.balance;vm.prank(alice);l.refund(id);assertEq(alice.balance-before,qty*0.1 ether);}

    function test_hardCapFloorCheckedBeforeFirstPrincipalAfterRegistration() public {
        // Create at high BNB USD so hardCap 10 clears create-time floor+margin; then crash price so first contribute fails.
        portal.configure(700 ether, true);
        (Launcher l, uint256 id) = _create(bytes32(uint256(1)));
        assertEq(portal.getLauncher(address(l)).launcherFactory, address(factory));
        portal.configure(100 ether, true); // BNB USD crash → live forLauncher floor rises in BNB terms
        vm.prank(alice); vm.expectRevert("AR: below launch floor"); l.contribute{value:0.1 ether}(id, 1);
        assertEq(address(l).balance, 0); assertEq(l.sharesSold(id), 0); assertEq(factory.points(alice), 0);
        portal.setFactory(address(factory), true, 5000); // 0.5× factory bps → contribute ok
        _buy(l, id, alice, 1); assertEq(l.getRaise(id).totalRaised, 0.1 ether);
    }
    function test_uninitializedForeignCloneCannotSpoofFactory() public {
        Launcher foreign=Launcher(payable(address(new BeaconProxy(factory.BEACON(),""))));
        vm.expectRevert("AR: not factory");foreign.initialize(9,creator,"creator","x","",_cfg(),uint64(block.timestamp+1 days),bene,_launch(bytes32(uint256(9))));
    }
    function test_spoofRegistryCannotAuthorizeCreator() public {
        LauncherRegistryV1 fake=new LauncherRegistryV1();address attacker=address(0xBAD);fake.set(attacker,"fake");vm.deal(attacker,1 ether);
        vm.prank(attacker);vm.expectRevert("AR: not agent");portal.newLauncher{value:0.01 ether}(address(factory),_data(_cfg(),uint64(block.timestamp+1 days),_launch(bytes32(uint256(3))),bene));
        assertEq(factory.agentIdRegistry(),REG);assertEq(factory.raiseCount(),0);
    }
    function test_registryFailureDoesNotGatePermissionlessSettle() public {
        (Launcher l,uint256 id)=_create(bytes32(uint256(1)));_ready(l,id);vm.etch(REG,hex"60006000fd");l.settle(id);assertTrue(l.getRaise(id).settled);
    }
    function test_fillEarlyAndGraceAnchoredToClose() public {
        (Launcher l,uint256 id)=_create(bytes32(uint256(1)));
        address a=address(0x111);address b=address(0x222);_agent(a,"four");_agent(b,"five");
        _buy(l,id,alice,20);_buy(l,id,bob,20);_buy(l,id,creator,20);_buy(l,id,a,20);_buy(l,id,b,20);
        assertTrue(l.getRaise(id).closed);assertEq(l.graceEndsAt(id),block.timestamp+3 days);assertTrue(l.getRaise(id).settled);assertFalse(l.canSettle(id));vm.expectRevert("AR: not settleable");l.settle(id); // V4: auto-settled by the filling contribution
    }
    function test_failedPushCanBeClaimedWithoutAgentIdentity() public {
        (Launcher l,uint256 id)=_create(bytes32(uint256(1)));_ready(l,id);portal.setBlockedRecipient(alice);l.settle(id);
        Launcher.Raise memory r=l.getRaise(id);assertFalse(l.tokensSent(id,alice));assertEq(IERC20Min(r.token).balanceOf(alice),0);
        MockTaxToken(r.token).setBlocked(address(0));registry.set(alice,"");vm.prank(alice);l.claim(id);assertEq(IERC20Min(r.token).balanceOf(alice),r.saleTokens*20/100);assertTrue(l.tokensSent(id,alice));
        vm.prank(alice);vm.expectRevert("AR: nothing to claim");l.claim(id);
    }
    function test_pushBatchBeyondFortyAndNoDoublePayment() public {
        (Launcher l,uint256 id)=_create(bytes32(uint256(1)));
        for(uint256 i=1;i<=50;++i){address who=address(uint160(0x10000+i));_agent(who,vm.toString(i));_buy(l,id,who,2);}
        assertTrue(l.getRaise(id).settled); /* V4: 50th buy filled hardCap and auto-settled */ Launcher.Raise memory r=l.getRaise(id);assertEq(r.distCursor,20);assertFalse(l.tokensSent(id,address(uint160(0x10000+50))));
        l.distribute(id,50);r=l.getRaise(id);assertEq(r.distCursor,50);assertEq(IERC20Min(r.token).balanceOf(address(l)),0);uint256 dust=_m(l).tokensInDock();assertEq(r.distributed+dust,r.saleTokens);assertLt(dust,50);
        l.distribute(id,50);assertEq(l.getRaise(id).distributed,r.distributed);
    }
    function test_rejectingBeneficiaryDoesNotBlockLaunch() public {
        RejectingLauncherBeneficiaryV81 reject=new RejectingLauncherBeneficiaryV81();
        vm.prank(creator);Launcher l=Launcher(payable(portal.newLauncher{value:0.01 ether}(address(factory),_data(_cfg(),uint64(block.timestamp+1 days),_launch(bytes32(uint256(1))),address(reject)))));
        uint256 id=factory.raiseCount();_ready(l,id);l.settle(id);uint256 owed=l.getRaise(id).beneficiaryOwed;assertGt(owed,0);
        vm.expectRevert("AR: transfer failed");l.claimBeneficiary(id);assertEq(l.getRaise(id).beneficiaryOwed,owed);
    }
    function test_claimsBeforeSettleAndRepeatedRefundRejected() public {
        (Launcher l,uint256 id)=_create(bytes32(uint256(1)));_buy(l,id,alice,1);vm.prank(alice);vm.expectRevert("AR: not settled");l.claim(id);
        vm.prank(alice);vm.expectRevert("AR: not refundable");l.refund(id);vm.warp(l.getRaise(id).deadline);vm.prank(creator);l.markFailed(id);vm.prank(alice);l.refund(id);vm.prank(alice);vm.expectRevert("AR: nothing to refund");l.refund(id);
    }
    function test_protocolAndCreatorFeeBounds() public {
        Launcher.LaunchConfig memory c=_launch(bytes32(uint256(3)));c.creatorShareBps=1001;vm.prank(creator);vm.expectRevert("AR: bad launch config");portal.newLauncher{value:0.01 ether}(address(factory),_data(_cfg(),uint64(block.timestamp+1 days),c,bene));
    }
    function test_unregisteredLauncherCannotUseCreatorExtension() public {
        IPortalTypes.CreateTaxTokenParams memory p;Distribution memory d;IPortalTypes.CreatorBuyParams memory cb;
        vm.expectRevert("MOCK: unregistered");portal.launchTaxTokenV2(p,d,cb);
    }
    function test_callbackAndGlobalCountersCannotBeSpoofed() public {
        (Launcher l,uint256 id)=_create(bytes32(uint256(1)));vm.expectRevert("AR: not vault");factory.onContribution(id,creator,alice,1 ether,true);
        vm.expectRevert("AR: not vault");factory.claimSalt(id,bytes32(uint256(9)));assertEq(factory.creatorRaised(creator),0);assertEq(l.sharesSold(id),0);
    }
    // ───────────── V4 auto-settle ─────────────
    event AutoSettleFailed(uint256 indexed raiseId, bytes reason);
    function _fill4(Launcher l,uint256 id) internal returns(address a,address b){a=address(0x111);b=address(0x222);_agent(a,"four");_agent(b,"five");_buy(l,id,alice,20);_buy(l,id,bob,20);_buy(l,id,creator,20);_buy(l,id,a,20);}
    function test_v4_autoSettleOnFillSuccess() public {
        (Launcher l,uint256 id)=_create(bytes32(uint256(1)));(,address b)=_fill4(l,id);
        assertFalse(l.getRaise(id).settled);uint256 tb=TREASURY.balance;
        vm.prank(b);l.contribute{value:2 ether}(id,20);
        Launcher.Raise memory r=l.getRaise(id);
        assertTrue(r.closed);assertTrue(r.settled);assertTrue(r.token!=address(0));assertEq(r.settledAt,block.timestamp);assertEq(r.distCursor,5);
        assertEq(TREASURY.balance-tb,0.3 ether);assertEq(l.sharesSold(id),100);assertEq(l.contributionOf(id,b),2 ether);
        assertEq(IERC20Min(r.token).balanceOf(b),r.saleTokens/5);assertEq(IERC20Min(r.token).balanceOf(alice),r.saleTokens/5);
        assertEq(address(l).balance,r.beneficiaryOwed);
        assertEq(uint8(GuardianRescueV82(payable(address(l))).status(id)),3); // SETTLED via module
    }
    function test_v4_markFailedUnreachableOnceAutoSettled() public {
        (Launcher l,uint256 id)=_create(bytes32(uint256(1)));(,address b)=_fill4(l,id);_buy(l,id,b,20);assertTrue(l.getRaise(id).settled);
        vm.prank(creator);vm.expectRevert("AR: cannot mark failed");l.markFailed(id);
        vm.warp(block.timestamp+3 days+1);vm.prank(alice);vm.expectRevert("AR: cannot mark failed");l.markFailed(id);
        vm.warp(uint256(l.getRaise(id).deadline)+31 days);vm.expectRevert("AR: cannot mark failed");l.markFailed(id);
        assertFalse(l.refundOpen(id));vm.prank(alice);vm.expectRevert("AR: not refundable");l.refund(id);
    }
    function test_v4_autoSettleFailureKeepsContributionAndManualSettleWorks() public {
        (Launcher l,uint256 id)=_create(bytes32(uint256(1)));(,address b)=_fill4(l,id);
        portal.setBehavior(false,true,false,false); // Portal launch will revert "AR: bad distribution"
        vm.expectEmit(true,false,false,true,address(l));emit AutoSettleFailed(id,abi.encodeWithSignature("Error(string)","AR: bad distribution"));
        vm.prank(b);l.contribute{value:2 ether}(id,20);
        Launcher.Raise memory r=l.getRaise(id);
        assertTrue(r.closed);assertFalse(r.settled);assertEq(r.token,address(0));assertEq(r.totalRaised,10 ether);assertEq(l.sharesSold(id),100);
        assertEq(l.contributionOf(id,b),2 ether);assertEq(address(l).balance,10 ether);assertFalse(portal.launched(address(l)));assertTrue(l.canSettle(id));
        assertEq(uint8(GuardianRescueV82(payable(address(l))).status(id)),1); // FILLED
        vm.prank(b);vm.expectRevert("AR: raise closed");l.contribute{value:0.1 ether}(id,1);
        portal.setBehavior(false,false,false,false);
        address anyone=address(0xD00D);vm.prank(anyone);l.settle(id);assertTrue(l.getRaise(id).settled);assertEq(l.getRaise(id).distCursor,5);
    }
    function test_v4_autoSettleFailurePausedPortalThenGraceRulesUnchanged() public {
        (Launcher l,uint256 id)=_create(bytes32(uint256(1)));(,address b)=_fill4(l,id);
        portal.setFactory(address(factory),false,10000);portal.setFlags(1); // disabled factory + creation pause => "MOCK: paused"
        vm.expectEmit(true,false,false,true,address(l));emit AutoSettleFailed(id,abi.encodeWithSignature("Error(string)","MOCK: paused"));
        vm.prank(b);l.contribute{value:2 ether}(id,20);assertFalse(l.getRaise(id).settled);
        vm.prank(alice);vm.expectRevert("AR: cannot mark failed");l.markFailed(id); // in grace: non-creator still blocked
        vm.warp(block.timestamp+3 days);vm.prank(alice);l.markFailed(id);             // post-grace: retries settle, still paused => refunds
        assertTrue(l.getRaise(id).failed);
        vm.prank(b);l.refund(id);assertEq(l.contributionOf(id,b),0);
    }
    function test_v4_lowGasFillingContributionRevertsWhole() public {
        (Launcher l,uint256 id)=_create(bytes32(uint256(1)));(,address b)=_fill4(l,id);
        vm.prank(b);(bool ok,)=address(l).call{value:2 ether,gas:7_000_000}(abi.encodeCall(Launcher.contribute,(id,20)));
        assertFalse(ok);assertEq(l.sharesSold(id),80);assertFalse(l.getRaise(id).closed);assertEq(l.contributionOf(id,b),0);
        vm.prank(b);l.contribute{value:2 ether}(id,20);assertTrue(l.getRaise(id).settled); // enough gas => fills + settles
    }
    function test_v4_lowGasRevertReasonAndNonFillingUnaffected() public {
        (Launcher l,uint256 id)=_create(bytes32(uint256(1)));(,address b)=_fill4(l,id);
        vm.prank(b);vm.expectRevert("AR: auto-settle needs more gas");l.contribute{value:2 ether,gas:7_000_000}(id,20);
        vm.prank(b);l.contribute{value:1.9 ether,gas:500_000}(id,19);assertFalse(l.getRaise(id).closed); // non-filling buys need no extra gas
        assertEq(l.AUTO_SETTLE_MIN_GAS(),8_000_000);
    }
    function test_v4_emptyRevertTreatedAsOutOfGas() public {
        (Launcher l,uint256 id)=_create(bytes32(uint256(1)));(,address b)=_fill4(l,id);
        vm.mockCallRevert(HUB,abi.encodeWithSelector(IFlapPoolPortal.launchTaxTokenV2.selector),"");
        vm.prank(b);vm.expectRevert("AR: auto-settle out of gas");l.contribute{value:2 ether}(id,20);
        assertEq(l.sharesSold(id),80);
    }
    function test_v4_nestedOutOfGasCannotSkipSettle(uint24 raw) public {
        (Launcher l,uint256 id)=_create(bytes32(uint256(1)));(,address b)=_fill4(l,id);
        uint256 gl=bound(raw,8_000_000,9_000_000);
        vm.prank(b);(bool ok,)=address(l).call{value:2 ether,gas:gl}(abi.encodeCall(Launcher.contribute,(id,20)));
        // invariant: either the raise is unchanged or it filled AND settled; never filled-but-unsettled due to gas
        if(ok) assertTrue(l.getRaise(id).settled); else assertEq(l.sharesSold(id),80);
    }
    function test_v4_selfSettleOnlySelfDuringContribute() public {
        (Launcher l,uint256 id)=_create(bytes32(uint256(1)));_fill4(l,id);
        vm.expectRevert("AR: only self");l.selfSettle(id,alice);
        vm.prank(address(l));vm.expectRevert("AR: only self");l.selfSettle(id,alice); // self but lock not held
    }
    function test_v4_portalReentryDuringAutoSettleRejected() public {
        (Launcher l,uint256 id)=_create(bytes32(uint256(1)));(,address b)=_fill4(l,id);
        portal.setBehavior(false,false,false,true); // Portal calls settle() back on the Launcher during launchTaxTokenV2
        vm.prank(b);l.contribute{value:2 ether}(id,20);
        assertTrue(portal.reentryRejected());assertTrue(portal.duplicateCallbackRejected());assertTrue(l.getRaise(id).settled);
    }
    function test_v6_partialCannotSettle_unfilledMarkFailedRefunds() public {
        (Launcher l,uint256 id)=_create(bytes32(uint256(1)));_buy(l,id,alice,20);_buy(l,id,bob,10); // 3 BNB < hardCap 10
        assertFalse(l.getRaise(id).closed);assertFalse(l.getRaise(id).settled);assertFalse(l.canSettle(id));
        vm.warp(l.getRaise(id).deadline);assertFalse(l.canSettle(id));assertFalse(l.refundOpen(id));
        vm.expectRevert("AR: not settleable");l.settle(id);
        vm.prank(address(0xBAD1));l.markFailed(id);assertTrue(l.getRaise(id).failed);assertTrue(l.refundOpen(id));
        uint256 b=alice.balance;vm.prank(alice);l.refund(id);assertEq(alice.balance-b,2 ether);
    }
    function test_v4_movedViewsThroughModule() public {
        (Launcher l,uint256 id)=_create(bytes32(uint256(1)));_buy(l,id,alice,1);_buy(l,id,bob,1);
        GuardianRescueV82 m=GuardianRescueV82(payable(address(l)));
        address[] memory c=m.contributors(id,0,10);assertEq(c.length,2);assertEq(c[0],alice);assertEq(c[1],bob);
        assertEq(m.contributors(id,1,1)[0],bob);assertEq(m.contributors(id,5,1).length,0);
        Launcher.LaunchConfig memory lc=m.getLaunchConfig(id);assertEq(lc.tokenSymbol,"AGENT");assertEq(lc.totalSupply,1e9 ether);assertEq(lc.creatorShareBps,1000);
        assertEq(uint8(m.status(id)),0);
        vm.expectRevert("AR: raise not found");m.getLaunchConfig(id+1);vm.expectRevert("AR: raise not found");m.status(id+1);
        m.economics(id); // economics still resolves getLaunchConfig internally
    }
    function _gasFill(uint32 n,bytes32 salt) internal returns(uint256 nonFill,uint256 fill,uint256 cursor){
        vm.prank(creator);Launcher l=Launcher(payable(portal.newLauncher{value:0.01 ether}(address(factory),_data(Launcher.ShareConfig(2.55 ether,n,10),uint64(block.timestamp+1 days),_launch(salt),bene))));uint256 id=factory.raiseCount();
        for(uint256 i=1;i<=n;++i){address w=address(uint160(uint256(salt)*0x1000+0x40000+i));_agent(w,string.concat(vm.toString(uint256(salt)),"-",vm.toString(i)));
            uint256 g=gasleft();vm.prank(w);l.contribute{value:2.55 ether}(id,1);uint256 used=g-gasleft();if(i==n-1)nonFill=used;if(i==n)fill=used;}
        assertTrue(l.getRaise(id).settled);cursor=l.getRaise(id).distCursor;
    }
    function test_v4_gasFillingContributionMock() public {
        uint32[4] memory ns=[uint32(2),20,40,60];
        for(uint256 k;k<4;++k){(uint256 a,uint256 f,uint256 c)=_gasFill(ns[k],bytes32(uint256(100+k)));
            emit log_named_uint(string.concat("N=",vm.toString(ns[k])," nonFillingContribute"),a);
            emit log_named_uint(string.concat("N=",vm.toString(ns[k])," fillingContribute(auto-settle)"),f);
            emit log_named_uint(string.concat("N=",vm.toString(ns[k])," pushedInSettle"),c);}
    }
    // ───────────── V4 F011: non-creator markFailed tries settle first ─────────────
    event Failed(uint256 indexed raiseId, address by);
    function _filledUnsettledPastGrace() internal returns(Launcher l,uint256 id){(l,id)=_create(bytes32(uint256(7)));_ready(l,id);vm.warp(uint256(l.getRaise(id).closedAt)+3 days);}
    function test_v4_f011_postGraceMarkFailedLaunchesSettleableRaise() public {
        (Launcher l,uint256 id)=_filledUnsettledPastGrace();assertTrue(l.canSettle(id));
        address griefer=address(0xBAD1);vm.recordLogs();vm.prank(griefer);l.markFailed(id);
        Launcher.Raise memory r=l.getRaise(id);
        assertTrue(r.settled);assertFalse(r.failed);assertTrue(r.token!=address(0));assertFalse(l.refundOpen(id));
        assertEq(IERC20Min(r.token).balanceOf(alice),r.saleTokens*20/100);
        bytes32 failedSig=keccak256("Failed(uint256,address)");Vm.Log[] memory logs=vm.getRecordedLogs();
        for(uint256 i;i<logs.length;++i) assertTrue(logs[i].topics.length==0 || logs[i].topics[0]!=failedSig);
        vm.prank(griefer);vm.expectRevert("AR: cannot mark failed");l.markFailed(id);
    }
    function test_v4_f011_postGraceGenuineLaunchFailureOpensRefunds() public {
        (Launcher l,uint256 id)=_filledUnsettledPastGrace();portal.setBehavior(false,true,false,false);
        vm.expectEmit(true,false,false,true,address(l));emit AutoSettleFailed(id,abi.encodeWithSignature("Error(string)","AR: bad distribution"));
        vm.expectEmit(true,false,false,true,address(l));emit Failed(id,address(0xBAD1));
        vm.prank(address(0xBAD1));l.markFailed(id);
        assertTrue(l.getRaise(id).failed);assertFalse(l.getRaise(id).settled);assertTrue(l.refundOpen(id));assertFalse(portal.launched(address(l)));
        uint256 b=alice.balance;vm.prank(alice);l.refund(id);assertEq(alice.balance-b,2 ether);
    }
    function test_v4_f011_lowGasMarkFailedRevertsNoFailure() public {
        (Launcher l,uint256 id)=_filledUnsettledPastGrace();
        vm.prank(address(0xBAD1));vm.expectRevert("AR: auto-settle needs more gas");l.markFailed{gas:7_000_000}(id);
        assertFalse(l.getRaise(id).failed);assertTrue(l.canSettle(id));
        vm.prank(address(0xBAD1));(bool ok,)=address(l).call{gas:300_000}(abi.encodeCall(Launcher.markFailed,(id)));assertFalse(ok);assertFalse(l.getRaise(id).failed);
    }
    function test_v4_f011_emptyRevertInMarkFailedTreatedAsOutOfGas() public {
        (Launcher l,uint256 id)=_filledUnsettledPastGrace();
        vm.mockCallRevert(HUB,abi.encodeWithSelector(IFlapPoolPortal.launchTaxTokenV2.selector),"");
        vm.prank(address(0xBAD1));vm.expectRevert("AR: auto-settle out of gas");l.markFailed(id);
        assertFalse(l.getRaise(id).failed);
    }
    function test_v4_f011_nestedOutOfGasCannotForceFailure(uint24 raw) public {
        (Launcher l,uint256 id)=_filledUnsettledPastGrace();uint256 gl=bound(raw,8_000_000,9_000_000);
        vm.prank(address(0xBAD1));(bool ok,)=address(l).call{gas:gl}(abi.encodeCall(Launcher.markFailed,(id)));
        assertFalse(l.getRaise(id).failed); if(ok) assertTrue(l.getRaise(id).settled); // never failed by under-paying gas
    }
    function test_v4_f011_hardCapAutoSettleFailedThenMarkFailedRetriesSettle() public {
        (Launcher l,uint256 id)=_create(bytes32(uint256(1)));(,address b)=_fill4(l,id);
        portal.setBehavior(false,true,false,false);vm.prank(b);l.contribute{value:2 ether}(id,20);
        assertTrue(l.getRaise(id).closed);assertFalse(l.getRaise(id).settled);
        portal.setBehavior(false,false,false,false); // cause cleared, but nobody called settle() during grace
        vm.warp(block.timestamp+3 days);vm.prank(address(0xBAD1));l.markFailed(id);
        assertTrue(l.getRaise(id).settled);assertFalse(l.getRaise(id).failed);assertEq(l.getRaise(id).distCursor,5);
    }
    function test_v6_unfilledMarkFailedNoSettleAttemptNoGasGuard() public {
        (Launcher l,uint256 id)=_create(bytes32(uint256(1)));_buy(l,id,alice,5); // below hardCap
        vm.warp(l.getRaise(id).deadline);assertFalse(l.canSettle(id)); // no grace needed for unfilled
        vm.prank(address(0xBAD1));l.markFailed{gas:500_000}(id);assertTrue(l.getRaise(id).failed);
    }
    function test_v4_f011_creatorCancelUnchangedNoSettleAttempt() public {
        (Launcher l,uint256 id)=_filledUnsettledPastGrace();assertTrue(l.canSettle(id));
        vm.prank(creator);l.markFailed{gas:500_000}(id); // creator path: no settle attempt, no gas guard
        assertTrue(l.getRaise(id).failed);assertFalse(l.getRaise(id).settled);assertFalse(portal.launched(address(l)));
    }

    // ───────────── V7 hardCap-only / dynamic Portal floor + LAUNCH_FLOOR_MARGIN_BPS ─────────────
    function test_v6_marginConstantIs20Percent() public view {
        assertEq(factory.LAUNCH_FLOOR_MARGIN_BPS(), 2000);
    }
    function test_v6_minHardCapBoundaryJustAboveAndBelow() public {
        portal.configure(700 ether, true);
        portal.setFactory(address(factory), true, 10000);
        uint256 min10 = _minHardCapWei(1000, 1e9 ether);
        assertGt(min10, 0);
        assertTrue(factory.meetsLiveCreateFloor(min10, 1000, 1e9 ether));
        if (min10 > 1) assertFalse(factory.meetsLiveCreateFloor(min10 - 1, 1000, 1e9 ether));
        // Encode hardCap via sharePrice/maxShares (sharePrice >= MIN_SHARE_PRICE)
        uint256 sp = min10 >= factory.MIN_SHARE_PRICE() ? min10 : factory.MIN_SHARE_PRICE();
        uint32 n = uint32((min10 + sp - 1) / sp); // ceil
        if (sp * n < min10) n += 1;
        vm.prank(creator);
        portal.newLauncher{value:0.01 ether}(address(factory), _data(Launcher.ShareConfig(sp, n, 10), uint64(block.timestamp+1 days), _launch(bytes32(uint256(50))), bene));
        // Just below: hardCap = min10-1 via sharePrice=min10-1 if legal, else maxShares encoding
        uint256 below = min10 - 1;
        uint256 spB = below >= factory.MIN_SHARE_PRICE() ? below : factory.MIN_SHARE_PRICE();
        uint32 nB = below >= factory.MIN_SHARE_PRICE() ? 1 : uint32(below / spB); // may be 0 if below < MIN
        if (nB == 0) {
            // below < MIN_SHARE_PRICE: creation fails share config first; use meetsLiveCreateFloor directly
            assertFalse(factory.meetsLiveCreateFloor(below, 1000, 1e9 ether));
        } else {
            vm.prank(creator); vm.expectRevert("AR: hard cap below launch floor");
            portal.newLauncher{value:0.01 ether}(address(factory), _data(Launcher.ShareConfig(spB, nB == 1 && spB == below ? 1 : nB, 10), uint64(block.timestamp+1 days), _launch(bytes32(uint256(51))), bene));
        }
        assertEq(factory.raiseCount(), 1);
    }
    function test_v6_minHardCapScalesWithBpsAndCreatorShare() public {
        portal.configure(700 ether, true);
        portal.setFactory(address(factory), true, 10000);
        uint256 a = _minHardCapWei(0, 1e9 ether);
        uint256 b5 = _minHardCapWei(500, 1e9 ether);
        uint256 b = _minHardCapWei(1000, 1e9 ether);
        assertGt(b5, a);
        assertGt(b, b5);
        portal.setFactory(address(factory), true, 5000);
        uint256 half = _minHardCapWei(1000, 1e9 ether);
        assertLt(half, b);
        assertGt(half, 0);
        portal.setFactory(address(factory), true, 1000);
        assertLt(_minHardCapWei(1000, 1e9 ether), half);
        portal.setFactory(address(factory), true, 1);
        assertGt(_minHardCapWei(1000, 1e9 ether), 0);
        portal.setFactory(address(factory), true, 0);
        assertEq(_minHardCapWei(1000, 1e9 ether), 0);
        // disabled factory → treated as 1×
        portal.setFactory(address(factory), false, 10000);
        assertEq(_minHardCapWei(1000, 1e9 ether), b);
    }
    function test_v6_minHardCapFailClosedOnQuoteOrLens() public {
        portal.configure(700 ether, false);
        vm.expectRevert("AR: launch quote unavailable");
        factory.meetsLiveCreateFloor(10 ether, 0, 1e9 ether);
        portal.configure(0, true);
        vm.expectRevert("AR: launch quote unavailable");
        factory.meetsLiveCreateFloor(10 ether, 0, 1e9 ether);
        portal.configure(700 ether, true);
        portal.setBehavior(true, false, false, false);
        vm.expectRevert("MOCK: missing lens");
        factory.meetsLiveCreateFloor(10 ether, 0, 1e9 ether);
        portal.setBehavior(false, false, false, false);
        portal.configure(700 ether, false);
        vm.prank(creator); vm.expectRevert("AR: launch quote unavailable");
        portal.newLauncher{value:0.01 ether}(address(factory), _data(Launcher.ShareConfig(10 ether, 1, 10), uint64(block.timestamp+1 days), _launch(bytes32(uint256(70))), bene));
    }
    function test_v6_minHardCapMatrixPriceBpsShare() public {
        uint256[3] memory prices = [uint256(650 ether), 700 ether, 750 ether];
        uint16[5] memory bpss = [uint16(0), 1, 1000, 5000, 10000];
        uint16[3] memory shares = [uint16(0), 500, 1000];
        for (uint256 i; i < prices.length; ++i) {
            portal.configure(prices[i], true);
            for (uint256 j; j < bpss.length; ++j) {
                portal.setFactory(address(factory), true, bpss[j]);
                for (uint256 k; k < shares.length; ++k) {
                    uint256 minH = _minHardCapWei(shares[k], 1e9 ether);
                    if (bpss[j] == 0) { assertEq(minH, 0); continue; }
                    if (k > 0) assertGe(minH, _minHardCapWei(shares[k-1], 1e9 ether));
                    assertTrue(factory.meetsLiveCreateFloor(minH, shares[k], 1e9 ether));
                    if (minH > 1) assertFalse(factory.meetsLiveCreateFloor(minH - 1, shares[k], 1e9 ether));
                    if (i > 0) {
                        portal.configure(prices[i-1], true);
                        uint256 prev = _minHardCapWei(shares[k], 1e9 ether);
                        portal.configure(prices[i], true);
                        assertLe(minH, prev);
                    }
                }
            }
        }
    }
    function test_v6_fillAutoSettles_partialCannotSettle() public {
        (Launcher l,uint256 id)=_create(bytes32(uint256(1)));_buy(l,id,alice,20);
        assertFalse(l.canSettle(id));vm.expectRevert("AR: not settleable");l.settle(id);
        _buy(l,id,bob,20);_buy(l,id,creator,20);address a=address(0x111);address b=address(0x222);_agent(a,"four");_agent(b,"five");
        _buy(l,id,a,20);_buy(l,id,b,20);
        assertTrue(l.getRaise(id).settled);assertTrue(l.getRaise(id).closed);assertFalse(l.canSettle(id));
    }


    // ───────────── V7: Token Dock custody ─────────────
    function _m(Launcher l) internal pure returns(GuardianRescueV82){return GuardianRescueV82(payable(address(l)));}
    function test_v7_settleDepositsWholeRemainderIntoDock() public {
        (Launcher l,uint256 id)=_create(bytes32(uint256(1)));_ready(l,id);
        assertEq(_m(l).tokensInDock(),0);
        portal.setBehavior(false,false,false,false);
        // block pushes so the whole remainder stays custodied after settle
        dock.setFailWithdraw(true);l.settle(id);dock.setFailWithdraw(false);
        Launcher.Raise memory r=l.getRaise(id);
        assertEq(IERC20Min(r.token).balanceOf(address(l)),0,"launcher holds no sale tokens");
        assertEq(dock.balanceOf(r.token,address(l)),r.saleTokens);assertEq(_m(l).tokensInDock(),r.saleTokens);
        assertEq(IERC20Min(r.token).balanceOf(DOCK),r.saleTokens);assertEq(r.distributed,0);
        assertEq(address(l.TOKEN_DOCK_ROUTER()),DOCK);
    }
    function test_v7_shortDockCreditRevertsLaunch() public {
        (Launcher l,uint256 id)=_create(bytes32(uint256(1)));_ready(l,id);dock.setShortDeposit(true);
        vm.expectRevert("AR: dock deposit failed");l.settle(id);assertFalse(l.getRaise(id).settled);
    }
    function test_v7_pushAndClaimComeFromDock() public {
        (Launcher l,uint256 id)=_create(bytes32(uint256(1)));_ready(l,id);l.settle(id);
        Launcher.Raise memory r=l.getRaise(id);
        assertEq(IERC20Min(r.token).balanceOf(alice),r.saleTokens*20/100);assertEq(_m(l).paidCount(id),5);
        assertEq(_m(l).tokensInDock(),r.saleTokens-r.distributed);assertEq(IERC20Min(r.token).balanceOf(address(l)),0);
    }
    function test_v7_failedPushThenClaimFromDockNoDoubleClaim() public {
        (Launcher l,uint256 id)=_create(bytes32(uint256(1)));_ready(l,id);dock.setFailWithdraw(true);l.settle(id);dock.setFailWithdraw(false);
        Launcher.Raise memory r=l.getRaise(id);assertEq(_m(l).paidCount(id),0);assertFalse(l.tokensSent(id,alice));
        vm.prank(alice);l.claim(id);assertEq(IERC20Min(r.token).balanceOf(alice),r.saleTokens*20/100);
        vm.prank(alice);vm.expectRevert("AR: nothing to claim");l.claim(id);
        l.distribute(id,10);assertEq(_m(l).paidCount(id),1); /* cursor already passed failed pushes → claim() */ vm.prank(bob);l.claim(id);vm.prank(creator);l.claim(id);vm.prank(address(0x111));l.claim(id);vm.prank(address(0x222));l.claim(id);assertEq(_m(l).paidCount(id),5);
        vm.prank(address(0xD00D));vm.expectRevert("AR: nothing to claim");l.claim(id);
    }
    function test_v7_dustSweepOnlyAfterAllPaidToBeneficiary() public {
        (Launcher l,uint256 id)=_create(bytes32(uint256(1)));
        address[3] memory w=[alice,bob,creator];uint256[3] memory q=[uint256(33),33,34];
        // uneven shares → rounding dust; 3 wallets with cap 20 can't fill 100 shares, so add more
        for(uint256 i=1;i<=7;++i){address who=address(uint160(0x20000+i));_agent(who,string.concat("d",vm.toString(i)));_buy(l,id,who,13);}
        _buy(l,id,alice,9);
        Launcher.Raise memory r=l.getRaise(id);assertTrue(r.settled);w;q;assertEq(_m(l).paidCount(id),8);emit log_named_uint("dust wei",_m(l).tokensInDock());
        uint256 dust=_m(l).tokensInDock();
        if(dust==0){vm.expectRevert("AR: nothing to claim");_m(l).sweepDust(id);return;}
        uint256 b0=IERC20Min(r.token).balanceOf(bene);vm.prank(address(0xD00D));_m(l).sweepDust(id);
        assertEq(IERC20Min(r.token).balanceOf(bene)-b0,dust);assertEq(_m(l).tokensInDock(),0);
        vm.expectRevert("AR: nothing to claim");_m(l).sweepDust(id);
    }
    function test_v7_dustSweepBlockedWhileSomeoneUnpaid() public {
        (Launcher l,uint256 id)=_create(bytes32(uint256(1)));_ready(l,id);portal.setBlockedRecipient(alice);l.settle(id);
        assertEq(_m(l).paidCount(id),4);vm.expectRevert("AR: not all paid");_m(l).sweepDust(id);
        Launcher.Raise memory r=l.getRaise(id);MockTaxToken(r.token).setBlocked(address(0));vm.prank(alice);l.claim(id);
        assertEq(_m(l).paidCount(id),5);
        if(_m(l).tokensInDock()!=0) _m(l).sweepDust(id); else {vm.expectRevert("AR: nothing to claim");_m(l).sweepDust(id);}
        assertEq(_m(l).tokensInDock(),0);
    }
    function test_v7_sweepBeforeSettleReverts() public {
        (Launcher l,uint256 id)=_create(bytes32(uint256(1)));_buy(l,id,alice,1);vm.expectRevert("AR: not all paid");_m(l).sweepDust(id);
    }
    function test_v7_guardianRescueWithdrawsFromDock() public {
        (Launcher l,uint256 id)=_create(bytes32(uint256(1)));_ready(l,id);dock.setFailWithdraw(true);l.settle(id);dock.setFailWithdraw(false);
        Launcher.Raise memory r=l.getRaise(id);address safe=address(0x5AFE);
        vm.expectRevert("AR: only Guardian");GuardianRescueV82(payable(address(l))).emergencyWithdraw(r.token,payable(safe));
        vm.prank(GUARDIAN);GuardianRescueV82(payable(address(l))).emergencyWithdraw(r.token,payable(safe));
        assertEq(IERC20Min(r.token).balanceOf(safe),r.saleTokens);assertEq(_m(l).tokensInDock(),0);
        vm.prank(alice);vm.expectRevert("AR: emergency recovery");l.claim(id);
    }
    function test_v7_guardianRescueNoBalanceReverts() public {
        (Launcher l,uint256 id)=_create(bytes32(uint256(1)));_ready(l,id);l.settle(id);l.distribute(id,10);
        Launcher.Raise memory r=l.getRaise(id);
        if(_m(l).tokensInDock()!=0){_m(l).sweepDust(id);}
        vm.prank(GUARDIAN);vm.expectRevert("AR: no recovery balance");GuardianRescueV82(payable(address(l))).emergencyWithdraw(r.token,payable(address(0x5AFE)));
    }
    function test_v7_initializeDistributionOnlyPortalAndSingleUse() public {
        (Launcher l,uint256 id)=_create(bytes32(uint256(1)));_ready(l,id);
        vm.prank(address(0xBAD));vm.expectRevert("AR: bad distribution");l.initializeDistribution(address(1),1,abi.encode(id),bytes32(0));
        vm.prank(HUB);vm.expectRevert("AR: bad distribution");l.initializeDistribution(address(1),1,abi.encode(id),bytes32(0)); // not launching
        portal.setBehavior(false,false,false,true);l.settle(id);assertTrue(portal.duplicateCallbackRejected());
        Launcher.Raise memory r=l.getRaise(id);vm.prank(HUB);vm.expectRevert("AR: bad distribution");l.initializeDistribution(r.token,1,abi.encode(id),bytes32(0));
    }
    function test_v7_dockReentryIntoClaimRejected() public {
        (Launcher l,uint256 id)=_create(bytes32(uint256(1)));_ready(l,id);dock.setFailWithdraw(true);l.settle(id);dock.setFailWithdraw(false);
        dock.setReenter(abi.encodeCall(Launcher.claim,(id)));
        vm.prank(alice);l.claim(id);assertTrue(dock.reentered());assertFalse(dock.reenterOk());
        dock.setReenter(abi.encodeCall(Launcher.distribute,(id,10)));
        vm.prank(bob);l.claim(id);assertFalse(dock.reenterOk());
        dock.setReenter(abi.encodeCall(GuardianRescueV82.sweepDust,(id)));
        vm.prank(creator);l.claim(id);assertFalse(dock.reenterOk());
        Launcher.Raise memory r=l.getRaise(id);assertEq(IERC20Min(r.token).balanceOf(alice),r.saleTokens*20/100);
    }
    // ───────────── V7: mandatory salt lock (Flap finding: unlocked salt front-lock griefing) ─────────────
    function test_v7_saltLock_createWithoutFeeReverts() public {
        vm.prank(creator);vm.expectRevert("AR: salt lock fee required");
        portal.newLauncher(address(factory),_data(_cfg(),uint64(block.timestamp+1 days),_launch(bytes32(uint256(9))),bene));
        assertEq(factory.raiseCount(),0);assertEq(portal.lockerOf(bytes32(uint256(9))),address(0));
    }
    function test_v7_saltLock_createWithFeeAlwaysLocksByLauncher() public {
        uint256 p0=address(portal).balance;(Launcher l,uint256 id)=_create(bytes32(uint256(9)));
        assertTrue(l.getRaise(id).saltLocked);assertEq(portal.lockerOf(bytes32(uint256(9))),address(l));assertEq(factory.saltLocker(bytes32(uint256(9))),address(l));
        assertEq(address(portal).balance-p0,portal.SALT_LOCK_FEE());assertEq(address(l).balance,0);assertEq(l.getRaise(id).totalRaised,0);
    }
    function test_v7_saltLock_thirdPartyPreLockBlocksCreation() public {
        address griefer=address(0x6E1F);vm.deal(griefer,1 ether);
        vm.prank(griefer);portal.lockSalt{value:0.01 ether}(bytes32(uint256(9)),0);
        vm.prank(creator);vm.expectRevert("MOCK: salt"); // real Portal: SaltAlreadyLockedByAnotherUser (see fork test)
        portal.newLauncher{value:0.01 ether}(address(factory),_data(_cfg(),uint64(block.timestamp+1 days),_launch(bytes32(uint256(9))),bene));
        assertEq(factory.raiseCount(),0);assertEq(factory.saltOwner(bytes32(uint256(9))),0);
        (Launcher l,uint256 id)=_create(bytes32(uint256(10)));assertTrue(l.getRaise(id).saltLocked); // creator just picks another salt
    }
    function test_v7_saltLock_thirdPartyCannotFrontLockAfterCreationAndSettleSucceeds() public {
        (Launcher l,uint256 id)=_create(bytes32(uint256(9)));address griefer=address(0x6E1F);vm.deal(griefer,1 ether);
        vm.prank(griefer);vm.expectRevert("MOCK: salt");portal.lockSalt{value:0.01 ether}(bytes32(uint256(9)),0);
        _ready(l,id);l.settle(id);assertTrue(l.getRaise(id).settled);
    }
    function test_v7_saltLock_updateSaltRemoved() public {
        (Launcher l,uint256 id)=_create(bytes32(uint256(9)));vm.prank(creator);
        (bool ok,bytes memory ret)=address(l).call(abi.encodeWithSignature("updateSalt(uint256,bytes32)",id,bytes32(uint256(10))));
        assertFalse(ok);assertEq(keccak256(ret),keccak256(abi.encodeWithSignature("Error(string)","AR: unknown method")));
    }
    function test_v7_refundPathUntouchedByDock() public {
        (Launcher l,uint256 id)=_create(bytes32(uint256(1)));_buy(l,id,alice,3);vm.prank(creator);l.markFailed(id);
        uint256 b=alice.balance;vm.prank(alice);l.refund(id);assertEq(alice.balance-b,0.3 ether);assertEq(_m(l).tokensInDock(),0);
    }
    // ───────────── V8: BeaconProxy + Guardian-only upgrades ─────────────
    bytes32 constant BEACON_SLOT=0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50; // ERC1967 beacon slot
    function _bound() internal returns(LauncherV82UpgradeMock){return new LauncherV82UpgradeMock(address(factory),address(dist));}
    function test_v8_launcherIsBeaconProxyAtPredictedAddress() public {
        UpgradeableBeacon b=UpgradeableBeacon(factory.BEACON());
        assertEq(b.owner(),address(factory),"beacon owned by factory");assertEq(b.implementation(),factory.implementation());
        assertEq(Launcher(payable(factory.implementation())).DEPLOYING_FACTORY(),address(factory));
        address predicted=factory.predictLauncher(1);
        (Launcher l,uint256 id)=_create(bytes32(uint256(1)));
        assertEq(id,1);assertEq(address(l),predicted);
        assertEq(address(uint160(uint256(vm.load(address(l),BEACON_SLOT)))),address(b),"ERC1967 beacon slot");
        assertLt(address(l).code.length,400,"proxy, not a full copy");
        (Launcher l2,uint256 id2)=_create(bytes32(uint256(2)));assertEq(address(l2),factory.predictLauncher(id2));
    }
    function test_v8_onlyGuardianCanUpgrade() public {
        LauncherV82UpgradeMock next=_bound();
        address[5] memory who=[address(this),TREASURY,creator,address(0xD00D),HUB]; // test contract = factory deployer
        for(uint256 i;i<who.length;++i){vm.prank(who[i]);vm.expectRevert(abi.encodeWithSelector(LauncherFactoryBase.NotGuardian.selector,who[i]));factory.upgradeVaultImplementation(address(next));}
        UpgradeableBeacon b=UpgradeableBeacon(factory.BEACON());
        address[3] memory direct=[address(this),GUARDIAN,TREASURY];
        for(uint256 i;i<direct.length;++i){
            vm.startPrank(direct[i]);
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector,direct[i]));b.upgradeTo(address(next));
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector,direct[i]));b.transferOwnership(direct[i]);
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector,direct[i]));b.renounceOwnership();
            vm.stopPrank();
        }
        assertEq(b.implementation()!=address(next),true);assertEq(b.owner(),address(factory));
        address prevImpl=b.implementation();vm.expectEmit(true,true,false,false,address(factory));emit VaultImplementationUpgraded(prevImpl,address(next));
        vm.prank(GUARDIAN);factory.upgradeVaultImplementation(address(next));
        assertEq(factory.implementation(),address(next));assertEq(b.owner(),address(factory));
    }
    event VaultImplementationUpgraded(address indexed previousImplementation, address indexed newImplementation);
    function test_v8_upgradeRejectsUnboundOrCodelessImplementation() public {
        address before=factory.implementation();
        LauncherV82UpgradeMock foreign=new LauncherV82UpgradeMock(address(0xF00),address(dist));
        vm.startPrank(GUARDIAN);
        vm.expectRevert("AR: impl not bound to factory");factory.upgradeVaultImplementation(address(foreign));
        vm.expectRevert();factory.upgradeVaultImplementation(address(0xC0DE));
        vm.stopPrank();
        assertEq(factory.implementation(),before);
    }
    function test_v8_factoryConstructorRejectsUnboundImpl() public {
        Launcher wrong=new Launcher(address(0xF00),address(dist));
        vm.expectRevert("AR: impl not bound to factory");new Factory(address(wrong));
        vm.expectRevert();new Factory(address(0xC0DE));
        vm.expectRevert("AR: bad params");new Launcher(address(0),address(dist));vm.expectRevert("AR: bad params");new Launcher(address(factory),address(0));
        Distributor otherDist=new Distributor(address(0xF00));Launcher wrongDist=new Launcher(vm.computeCreateAddress(address(this),vm.getNonce(address(this))+1),address(otherDist));vm.expectRevert("AR: impl not bound to factory");new Factory(address(wrongDist));
    }
    function test_v8_upgradeChangesLogicForExistingRaisesAndPreservesStorage() public {
        (Launcher l,uint256 id)=_create(bytes32(uint256(1)));
        _buy(l,id,alice,20);_buy(l,id,bob,15);_buy(l,id,creator,5);
        Launcher.Raise memory r0=l.getRaise(id);
        uint256 sAlice=l.sharesOf(id,alice);uint256 sold=l.sharesSold(id);uint256 bal=address(l).balance;
        (bool ok,)=address(l).call(abi.encodeWithSignature("upgradeMarker()"));assertFalse(ok,"old logic has no marker");
        LauncherV82UpgradeMock next=_bound();
        vm.prank(GUARDIAN);factory.upgradeVaultImplementation(address(next));
        assertEq(LauncherV82UpgradeMock(payable(address(l))).upgradeMarker(),8_001,"existing raise runs new logic");
        Launcher.Raise memory r1=l.getRaise(id);
        assertEq(r1.creator,r0.creator);assertEq(r1.beneficiary,r0.beneficiary);assertEq(r1.totalRaised,r0.totalRaised);
        assertEq(r1.contributorCount,r0.contributorCount);assertEq(r1.hardCap,r0.hardCap);assertEq(r1.deadline,r0.deadline);
        assertEq(r1.agentId,r0.agentId);assertEq(r1.title,r0.title);assertEq(r1.saltLocked,r0.saltLocked);
        assertEq(l.sharesOf(id,alice),sAlice);assertEq(l.sharesSold(id),sold);assertEq(address(l).balance,bal);
        assertEq(factory.vaultOf(id),address(l));assertEq(portal.lockerOf(bytes32(uint256(1))),address(l));
        // the upgraded raise keeps working end-to-end: fill → auto-settle → push/distribute from the dock
        address a=address(0x111);address b2=address(0x222);_agent(a,"four");_agent(b2,"five");
        _buy(l,id,bob,5);_buy(l,id,creator,15);_buy(l,id,a,20);_buy(l,id,b2,20);
        Launcher.Raise memory r2=l.getRaise(id);assertTrue(r2.settled,"auto-settled after upgrade");
        if(r2.distCursor<r2.contributorCount) l.distribute(id,100);
        assertEq(l.getRaise(id).distCursor,l.getRaise(id).contributorCount);
        assertGt(IERC20Min(r2.token).balanceOf(alice),0);
        // and NEW raises after the upgrade are created on the new logic and initialize normally
        (Launcher l2,uint256 id2)=_create(bytes32(uint256(2)));
        assertEq(LauncherV82UpgradeMock(payable(address(l2))).upgradeMarker(),8_001);assertEq(l2.getRaise(id2).creator,creator);
    }
    function test_v8_implementationCannotBeInitializedDirectly() public {
        Launcher impl=Launcher(payable(factory.implementation()));
        vm.prank(address(factory));vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(9,creator,"creator","x","",_cfg(),uint64(block.timestamp+1 days),bene,_launch(bytes32(uint256(9))));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(9,creator,"creator","x","",_cfg(),uint64(block.timestamp+1 days),bene,_launch(bytes32(uint256(9))));
        LauncherV82UpgradeMock next=_bound();
        vm.prank(address(factory));vm.expectRevert(Initializable.InvalidInitialization.selector);
        next.initialize(9,creator,"creator","x","",_cfg(),uint64(block.timestamp+1 days),bene,_launch(bytes32(uint256(9))));
    }
    function test_v8_proxyCannotReinitialize() public {
        (Launcher l,uint256 id)=_create(bytes32(uint256(1)));
        vm.prank(address(factory));vm.expectRevert(Initializable.InvalidInitialization.selector);
        l.initialize(id,alice,"alice","hijack","",_cfg(),uint64(block.timestamp+1 days),alice,_launch(bytes32(uint256(5))));
        address nx=address(_bound());vm.prank(GUARDIAN);factory.upgradeVaultImplementation(nx);
        vm.prank(address(factory));vm.expectRevert(Initializable.InvalidInitialization.selector);
        l.initialize(id,alice,"alice","hijack","",_cfg(),uint64(block.timestamp+1 days),alice,_launch(bytes32(uint256(5))));
        assertEq(l.getRaise(id).creator,creator);assertEq(l.getRaise(id).beneficiary,bene);
    }
    function test_v8_foreignBeaconProxyOnOurBeaconCannotInitOrUseFactory() public {
        Launcher foreign=Launcher(payable(address(new BeaconProxy(factory.BEACON(),""))));
        vm.prank(creator);vm.expectRevert("AR: not factory");
        foreign.initialize(1,creator,"creator","x","",_cfg(),uint64(block.timestamp+1 days),bene,_launch(bytes32(uint256(1))));
        vm.prank(address(foreign));vm.expectRevert("AR: not vault");factory.onContribution(1,creator,creator,1 ether,true);
    }
    function test_v8_createGasWithSaltLock() public {
        bytes memory data=_data(_cfg(),uint64(block.timestamp+1 days),_launch(bytes32(uint256(42))),bene);uint256 fee=portal.SALT_LOCK_FEE();
        vm.prank(creator);uint256 g=gasleft();portal.newLauncher{value:fee}(address(factory),data);g-=gasleft();
        emit log_named_uint("V8 create (mock Portal, salt lock fee) gas",g);
        assertLt(g,3_000_000);
    }

    // ───────────── V8.2: 3% fee (V8.1: 2%) + Flap Trigger distribution that STARTS AT SETTLE (no user schedule tx) ─────────────
    event OutOfBudget(address indexed launcher, uint256 budget, uint256 fee);
    event TokensPushFailed(uint256 indexed raiseId, address indexed contributor);
    event Scheduled(address indexed launcher, uint256 indexed requestId, uint256 fee, uint256 budgetLeft);
    event AutoScheduleFailed(address indexed launcher, uint256 budget, bytes reason);
    event Settled(uint256 indexed raiseId, address indexed token, address pool, uint256 fee, uint256 creatorCash, uint256 poolQuote, uint256 poolTokens);
    /// _fill50 makes several calls (agent setup + contribute), so match the AutoScheduleFailed log from the recorded logs.
    function _assertAutoFailed(address l,uint256 budget,bytes memory reason) internal {
        Vm.Log[] memory logs=vm.getRecordedLogs();uint256 hits;
        for(uint256 i;i<logs.length;++i){
            if(logs[i].emitter==address(dist)&&logs[i].topics.length==2&&logs[i].topics[0]==AutoScheduleFailed.selector){
                assertEq(logs[i].topics[1],bytes32(uint256(uint160(l))));assertEq(logs[i].data,abi.encode(budget,reason));++hits;}
        }
        assertEq(hits,1,"exactly one AutoScheduleFailed in the settle tx");
    }
    uint256 constant F=0.0002 ether; uint256 constant RES=(3+1)*F; // 30 remaining → ceil(30/14)=3 batches + 1 spare
    /// 10 BNB hard cap (0.1 × 100 shares) split 2 shares each over 50 wallets; the 50th contribution fills and auto-settles.
    function _create49(bytes32 salt,uint256 base) internal returns(Launcher l,uint256 id){
        (l,id)=_create(salt);
        for(uint256 i=1;i<=49;++i){address w=address(uint160(base+i));_agent(w,string.concat(vm.toString(base),"-",vm.toString(i)));_buy(l,id,w,2);}
        assertFalse(l.getRaise(id).closed);
    }
    function _fill50(Launcher l,uint256 id,uint256 base) internal {address w=address(uint160(base+50));_agent(w,string.concat(vm.toString(base),"-50"));_buy(l,id,w,2);}
    function _create50() internal returns(Launcher l,uint256 id){(l,id)=_create49(bytes32(uint256(77)),0xE0000);_fill50(l,id,0xE0000);assertTrue(l.getRaise(id).settled);}
    function _w(uint256 i) internal pure returns(address){return address(uint160(0xE0000+i));}
    function _pending(Launcher l) internal view returns(bool p,uint256 rid){return dist.pendingRequestOf(address(l));}
    function _done(Launcher l,uint256 id) internal view {Launcher.Raise memory r=l.getRaise(id);assertEq(r.distCursor,50);assertEq(_m(l).paidCount(id),50);for(uint256 i=1;i<=50;++i) assertEq(IERC20Min(r.token).balanceOf(_w(i)),r.saleTokens/50);}

    function test_v82_feeIsThreePercent() public view {
        assertEq(Launcher(payable(factory.implementation())).FEE_BPS(),300);
        (uint256 q,,)=factory.poolFor(10 ether,0,1e9 ether);assertEq(q,9.7 ether);
        (uint256 q2,,)=factory.poolFor(10 ether,1000,1e9 ether);assertEq(q2,9.7 ether-0.97 ether,"3% fee, then 10% creator share of the rest");
        assertEq(dist.BATCH(),14);assertEq(address(Launcher(payable(factory.implementation())).DISTRIBUTOR()),address(dist));
    }
    function test_v81_smallRaiseWholeFeeToTreasuryNoReserveNoRequest() public {
        (Launcher l,uint256 id)=_create(bytes32(uint256(1)));uint256 tb=TREASURY.balance;_fillToHard(l,id);
        Launcher.Raise memory r=l.getRaise(id);assertTrue(r.settled);assertEq(r.distCursor,r.contributorCount);
        assertEq(TREASURY.balance-tb,0.3 ether);assertEq(dist.budgetOf(address(l)),0);assertEq(trig.count(),0);
        (bool p,)=_pending(l);assertFalse(p);
        vm.expectRevert("AR: nothing to distribute");dist.schedule(address(l));
    }
    /// Core: the filling contribution settles AND registers the first Trigger request in the same tx. Nobody calls schedule().
    function test_v81_fillingContributionRegistersFirstRequestInSameTx() public {
        uint256 tb=TREASURY.balance;(Launcher l,uint256 id)=_create49(bytes32(uint256(77)),0xE0000);
        assertEq(trig.count(),0);
        vm.recordLogs();_fill50(l,id,0xE0000);Vm.Log[] memory logs=vm.getRecordedLogs();
        bool settledLog;bool scheduledLog;
        for(uint256 i;i<logs.length;++i){
            if(logs[i].emitter==address(l)&&logs[i].topics[0]==Settled.selector){settledLog=true;assertFalse(scheduledLog,"scheduled after settle");}
            if(logs[i].emitter==address(dist)&&logs[i].topics[0]==Scheduled.selector){scheduledLog=true;assertEq(address(uint160(uint256(logs[i].topics[1]))),address(l));}
            assertTrue(logs[i].topics[0]!=AutoScheduleFailed.selector);
        }
        assertTrue(settledLog&&scheduledLog,"Settled + Scheduled in the filling tx");
        Launcher.Raise memory r=l.getRaise(id);assertTrue(r.settled);assertEq(r.distCursor,20);
        (bool p,uint256 rid)=_pending(l);assertTrue(p,"first request already pending");assertEq(rid,0);assertEq(trig.count(),1);
        assertEq(trig.getRequest(rid).requester,address(dist));assertEq(uint8(trig.getRequest(rid).status),0);assertEq(trig.getRequest(rid).feePaid,F);
        assertEq(dist.reserveFor(30),RES);assertEq(dist.budgetOf(address(l)),RES-F);assertEq(TREASURY.balance-tb,0.3 ether-RES,"3% fee - reserve; nothing extra from creator/contributors");
        vm.expectRevert("AR: already scheduled");dist.schedule(address(l));
        assertEq(trig.drain(),3,"Flap backend executes 3 batches; each schedules the next");
        _done(l,id);(p,)=_pending(l);assertFalse(p);assertEq(dist.budgetOf(address(l)),F,"spare unused");
        uint256 t2=TREASURY.balance;dist.sweepBudget(address(l));assertEq(TREASURY.balance-t2,F);assertEq(dist.budgetOf(address(l)),0);
    }
    function test_v81_manualSettleAfterAutoSettleFailedAlsoSchedules() public {
        (Launcher l,uint256 id)=_create49(bytes32(uint256(77)),0xE0000);portal.setBehavior(false,true,false,false);
        _fill50(l,id,0xE0000);assertFalse(l.getRaise(id).settled);assertEq(trig.count(),0);
        portal.setBehavior(false,false,false,false);vm.prank(address(0xD00D));l.settle(id);
        (bool p,)=_pending(l);assertTrue(p);trig.drain();_done(l,id);
    }
    function test_v81_postGraceMarkFailedSettleAlsoSchedules() public {
        (Launcher l,uint256 id)=_create49(bytes32(uint256(77)),0xE0000);portal.setBehavior(false,true,false,false);
        _fill50(l,id,0xE0000);portal.setBehavior(false,false,false,false);
        vm.warp(uint256(l.getRaise(id).closedAt)+3 days);vm.prank(alice);l.markFailed(id);
        assertTrue(l.getRaise(id).settled);(bool p,)=_pending(l);assertTrue(p);trig.drain();_done(l,id);
    }
    /// Trigger Service down at settle: settle still succeeds, the outage is an event (not silent), budget kept from the fee
    /// (fallback fee basis); after recovery ANY address restarts with one permissionless call (exceptional, not the normal flow).
    function test_v81_triggerOutageAtSettleEmitsEventAndPermissionlessRestart() public {
        (Launcher l,uint256 id)=_create49(bytes32(uint256(77)),0xE0000);bytes memory code=address(trig).code;
        vm.etch(TRIG,hex"fe");uint256 tb=TREASURY.balance;
        vm.recordLogs();
        _fill50(l,id,0xE0000);_assertAutoFailed(address(l),RES,"");
        assertTrue(l.getRaise(id).settled,"settle liveness");(bool p,)=_pending(l);assertFalse(p);
        assertEq(dist.reserveFor(30),RES,"fallback fee basis");assertEq(dist.budgetOf(address(l)),RES);assertEq(TREASURY.balance-tb,0.3 ether-RES);
        vm.etch(TRIG,code); // service restored (storage kept)
        vm.prank(address(0x5EED));dist.fund(address(l)); // 0-value poke by anyone (schedule() works too)
        (p,)=_pending(l);assertTrue(p);trig.drain();_done(l,id);
    }
    function test_v81_requestTriggerRevertsAtSettleBudgetKeptEventThenScheduleFallback() public {
        (Launcher l,uint256 id)=_create49(bytes32(uint256(77)),0xE0000);
        vm.mockCallRevert(TRIG,abi.encodeWithSelector(MockFlapTriggerService.requestTrigger.selector),abi.encodeWithSignature("Error(string)","paused"));
        vm.recordLogs();
        _fill50(l,id,0xE0000);_assertAutoFailed(address(l),RES,abi.encodeWithSignature("Error(string)","paused"));
        assertTrue(l.getRaise(id).settled);(bool p,)=_pending(l);assertFalse(p);assertEq(dist.budgetOf(address(l)),RES);assertEq(address(dist).balance,RES);
        vm.clearMockedCalls();vm.prank(bob);dist.schedule(address(l));trig.drain();_done(l,id);
    }
    function test_v81_outOfBudgetThenTopUpResumesAutomatically() public {
        (Launcher l,uint256 id)=_create50();(,uint256 rid)=_pending(l); // budget 0.0008 → 0.0006 after first request
        trig.configure(0.0004 ether,2_000_000);trig.execute(rid);assertEq(dist.budgetOf(address(l)),0.0002 ether);
        vm.expectEmit(true,false,false,true,address(dist));emit OutOfBudget(address(l),0.0002 ether,0.0004 ether);
        trig.execute(rid+1);(bool p,)=_pending(l);assertFalse(p);assertEq(l.getRaise(id).distCursor,48);
        vm.expectRevert("AR: unknown launcher");dist.fund{value:1}(address(0xDEAD));
        vm.prank(alice);dist.fund{value:0.0002 ether}(address(l)); // top-up alone resumes (no schedule call)
        (p,)=_pending(l);assertTrue(p);trig.drain();_done(l,id);
    }
    function test_v81_noDoubleScheduling() public {
        (Launcher l,)=_create50();(,uint256 rid)=_pending(l);uint256 b=dist.budgetOf(address(l));
        vm.prank(bob);dist.fund{value:1}(address(l));assertEq(trig.count(),1,"no second request while pending");assertEq(dist.budgetOf(address(l)),b+1);
        vm.expectRevert("AR: already scheduled");dist.schedule(address(l));
        trig.execute(rid);assertEq(trig.count(),2,"callback schedules exactly the next one");(,uint256 r2)=_pending(l);assertEq(r2,rid+1);
    }
    function test_v81_triggerOnlyServiceAndNoReplay() public {
        (Launcher l,)=_create50();(,uint256 rid)=_pending(l);
        vm.expectRevert("AR: only trigger service");dist.trigger(rid);
        vm.prank(GUARDIAN);vm.expectRevert("AR: only trigger service");dist.trigger(rid);
        vm.prank(address(l));vm.expectRevert("AR: only trigger service");dist.trigger(rid);
        trig.execute(rid);
        vm.prank(TRIG);vm.expectRevert("AR: unknown request");dist.trigger(rid); // used id deleted
        vm.prank(TRIG);vm.expectRevert("AR: unknown request");dist.trigger(9999);
    }
    function test_v81_failedCallbackRetriedByAnyone() public {
        (Launcher l,uint256 id)=_create50();(,uint256 rid)=_pending(l);trig.configure(F,150_000); // backend gas too low → FAILED
        assertFalse(trig.execute(rid));assertEq(l.getRaise(id).distCursor,20);assertEq(uint8(trig.getRequest(rid).status),2);
        (bool p,)=_pending(l);assertTrue(p,"still pending after revert");
        vm.prank(bob);trig.retryTrigger(rid);assertEq(l.getRaise(id).distCursor,34);
        trig.configure(F,2_000_000);trig.drain();_done(l,id);
    }
    function test_v81_reentrantTriggerCannotDoubleScheduleOrBlockSettle() public {
        for(uint256 m=1;m<=2;++m){
            uint256 snap=vm.snapshotState();
            (Launcher l,uint256 id)=_create49(bytes32(uint256(77)),0xE0000);
            MockReentrantTrigger h=new MockReentrantTrigger();vm.etch(TRIG,address(h).code);MockReentrantTrigger(TRIG).set(address(l),m);
            vm.recordLogs();
            _fill50(l,id,0xE0000);_assertAutoFailed(address(l),RES,abi.encodeWithSignature("Error(string)","AR: reentrant"));
            assertTrue(l.getRaise(id).settled);(bool p,)=_pending(l);assertFalse(p);assertEq(dist.budgetOf(address(l)),RES);assertEq(dist.launcherOfRequest(7),address(0));
            vm.revertToState(snap);
        }
    }
    /// Gas griefing: for any gas, a settle either reverts entirely or ends with the first request pending (Trigger healthy).
    function testFuzz_v81_lowGasCannotSettleWithoutScheduling(uint24 raw) public {
        (Launcher l,uint256 id)=_create49(bytes32(uint256(77)),0xE0000);portal.setBehavior(false,true,false,false);
        _fill50(l,id,0xE0000);portal.setBehavior(false,false,false,false);
        uint256 gl=bound(raw,300_000,6_000_000);
        (bool ok,)=address(l).call{gas:gl}(abi.encodeCall(Launcher.settle,(id)));
        (bool p,)=_pending(l);
        if(ok){assertTrue(l.getRaise(id).settled);assertTrue(p,"settled => first request pending");}
        else {assertFalse(l.getRaise(id).settled);assertFalse(p);}
    }
    function testFuzz_v81_lowGasRestartPokeIsAllOrNothing(uint24 raw) public {
        (Launcher l,uint256 id)=_create49(bytes32(uint256(77)),0xE0000);bytes memory code=address(trig).code;
        vm.etch(TRIG,hex"fe");_fill50(l,id,0xE0000);vm.etch(TRIG,code);
        uint256 gl=bound(raw,30_000,1_500_000);
        (bool ok,)=address(dist).call{gas:gl}(abi.encodeCall(Distributor.fund,(address(l))));
        (bool p,)=_pending(l);if(ok) assertTrue(p,"poke ok => pending"); else assertFalse(p);
        assertEq(dist.budgetOf(address(l)),p?RES-F:RES);
    }
    function test_v81_reserveCappedAtFeeStillSchedules() public {
        trig.configure(0.1 ether,2_000_000); // 4 × 0.1 > 0.3 fee (3% of 10) → capped at the fee
        uint256 tb=TREASURY.balance;(Launcher l,)=_create50();
        assertEq(TREASURY.balance-tb,0);(bool p,)=_pending(l);assertTrue(p);assertEq(dist.budgetOf(address(l)),0.2 ether,"reserve = whole 0.3 fee, first request paid 0.1");
    }
    function test_v81_reserveForFallbackNeverZeroWhenRemaining() public {
        assertEq(dist.reserveFor(0),0);assertEq(dist.reserveFor(1),2*F);assertEq(dist.reserveFor(14),2*F);assertEq(dist.reserveFor(15),3*F);
        trig.configure(0,2_000_000);assertEq(dist.reserveFor(30),RES);
        trig.configure(2 ether,2_000_000);assertEq(dist.reserveFor(30),RES);
        vm.etch(TRIG,hex"fe");assertEq(dist.reserveFor(30),RES);
        vm.etch(TRIG,"");assertEq(dist.reserveFor(30),RES);
    }
    function test_v81_fundBeforeSettleOnlyCredits() public {
        (Launcher l,)=_create49(bytes32(uint256(77)),0xE0000);
        vm.prank(bob);dist.fund{value:1 ether}(address(l));assertEq(dist.budgetOf(address(l)),1 ether);assertEq(trig.count(),0);
    }
    function test_v81_sweepBudgetOnlyWhenFinished() public {
        (Launcher l,uint256 id)=_create50();
        vm.expectRevert("AR: pending");dist.sweepBudget(address(l));
        trig.drain();_done(l,id);dist.sweepBudget(address(l));assertEq(dist.budgetOf(address(l)),0);
    }
    function test_v81_pushStopsOnLowGasInsteadOfSkipping() public {
        (Launcher l,uint256 id)=_create50();
        vm.recordLogs();l.distribute{gas:900_000}(id,30);Vm.Log[] memory logs=vm.getRecordedLogs();
        for(uint256 i;i<logs.length;++i) assertTrue(logs[i].topics[0]!=TokensPushFailed.selector,"no low-gas skip");
        Launcher.Raise memory r=l.getRaise(id);assertGt(r.distCursor,20);assertLt(r.distCursor,50);assertEq(_m(l).paidCount(id),r.distCursor);
        trig.drain();_done(l,id); // the pending Trigger request continues from the moved cursor
    }
    function test_v81_skippedRecipientInTriggerBatchCanClaim() public {
        (Launcher l,uint256 id)=_create50();Launcher.Raise memory r=l.getRaise(id);
        MockTaxToken(r.token).setBlocked(_w(25));trig.drain();
        r=l.getRaise(id);assertEq(r.distCursor,50);assertEq(_m(l).paidCount(id),49);assertFalse(l.tokensSent(id,_w(25)));
        MockTaxToken(r.token).setBlocked(address(0));vm.prank(_w(25));l.claim(id);
        assertEq(IERC20Min(r.token).balanceOf(_w(25)),r.saleTokens/50);assertEq(_m(l).paidCount(id),50);
    }
    function test_v81_sizesAndAuditedLauncherUnchanged() public {
        assertLt(address(dist).code.length,24576);assertLt(factory.implementation().code.length,24576);assertLt(address(factory).code.length,24576);
        emit log_named_uint("TriggerDistributorV81 runtime",address(dist).code.length);
        emit log_named_uint("LauncherV8 impl runtime (V8.1 set)",factory.implementation().code.length);
        emit log_named_uint("FactoryV8 runtime (V8.1 set)",address(factory).code.length);
        assertEq(keccak256(bytes(factory.factorySpecVersion())),keccak256("lf-v1"));
    }
    function test_v81_gasFillingContributionMock() public {
        (Launcher l,uint256 id)=_create49(bytes32(uint256(77)),0xE0000);address w=address(uint160(0xE0000+50));_agent(w,"g50");
        vm.prank(w);uint256 g=gasleft();l.contribute{value:0.2 ether}(id,2);g-=gasleft();
        emit log_named_uint("V8.1 filling contribute (mock: settle + 20 pushes + reserve + first request)",g);assertLt(g,11_000_000);
    }

    // ───────────── V8.2: Flap Pool Launch Launcher description (JSON v1) ─────────────
    string constant D_TZH=unicode"AI 智能体募集发射";
    string constant D_TEN="AI agent raise launch";
    string constant D_SZH=unicode"持有 Agent ID 的智能体用 BNB 认购份额，直到硬顶。认满即自动结算并在 Flap 发射，代币分批自动发给认购者。募集失败可退款。";
    string constant D_SEN="Agents with an Agent ID buy shares with BNB until the hard cap. Filling it settles and launches on Flap automatically; contributors receive tokens automatically in batches. If the raise fails, contributions are refunded.";
    function _createNamed(bytes32 salt,string memory name,string memory symbol) internal returns(Launcher l,uint256 id){
        Launcher.LaunchConfig memory c=_launch(salt);c.tokenName=name;c.tokenSymbol=symbol;
        uint256 fee=portal.SALT_LOCK_FEE();vm.prank(creator);l=Launcher(payable(portal.newLauncher{value:fee}(address(factory),_data(_cfg(),uint64(block.timestamp+1 days),c,bene))));id=factory.raiseCount();
    }
    /// @dev Independent re-implementation of the spec's v1 format (keys, order, string types) for exact-match checks.
    function _expectedJson(string memory nameEsc,string memory symbolEsc,uint256 target,uint256 ratio) internal pure returns(string memory){
        return string.concat('{"v":1,"name":"',nameEsc,'","symbol":"',symbolEsc,'","quoteToken":"0x0000000000000000000000000000000000000000","targetRaise":"',
            vm.toString(target),'","poolTokenRatio":"',vm.toString(ratio),'","titleZh":"',D_TZH,'","titleEn":"',D_TEN,'","summaryZh":"',D_SZH,'","summaryEn":"',D_SEN,'"}');
    }
    function _ratio(Launcher l,uint256 id) internal view returns(uint256){Launcher.Raise memory r=l.getRaise(id);return r.poolTokens*1e18/1e9 ether;}
    /// @dev The Portal's best-effort read: STATICCALL description() with at most 200k gas, accept <= 4096 bytes.
    function _portalRead(address l) internal view returns(string memory json,uint256 gasUsed){
        uint256 g=gasleft();(bool ok,bytes memory ret)=l.staticcall{gas:200_000}(abi.encodeWithSignature("description()"));gasUsed=g-gasleft();
        require(ok,"description() reverted under the Portal gas cap");json=abi.decode(ret,(string));
    }
    function test_v82_descriptionExactJsonAtCreation() public {
        (Launcher l,uint256 id)=_create(bytes32(uint256(1)));
        Launcher.Raise memory r=l.getRaise(id);assertEq(r.hardCap,10 ether);
        // hardCap 10, 3% fee, 10% creator share: Q = 8.73; poolTokens = N*Q/(R+Q)
        uint256 pool=uint256(1e9 ether)*8.73 ether/(10 ether+8.73 ether);assertEq(r.poolTokens,pool);
        string memory want=_expectedJson("Agent Launch","AGENT",10 ether,pool*1e18/1e9 ether);
        assertEq(l.description(),want);
        assertEq(ILauncherDescription(address(l)).description(),want,"official ILauncherDescription selector");
        emit log_string(l.description());
    }
    function test_v82_descriptionParsesAsSpecV1() public {
        (Launcher l,uint256 id)=_create(bytes32(uint256(1)));string memory j=l.description();
        assertEq(vm.parseJsonUint(j,".v"),1);
        assertEq(vm.parseJsonString(j,".name"),"Agent Launch");assertEq(vm.parseJsonString(j,".symbol"),"AGENT");
        assertEq(vm.parseJsonString(j,".quoteToken"),"0x0000000000000000000000000000000000000000");
        assertEq(vm.parseJsonString(j,".targetRaise"),vm.toString(l.getRaise(id).hardCap));
        assertEq(vm.parseJsonString(j,".poolTokenRatio"),vm.toString(_ratio(l,id)));
        assertEq(vm.parseJsonString(j,".titleZh"),D_TZH);assertEq(vm.parseJsonString(j,".titleEn"),D_TEN);
        assertEq(vm.parseJsonString(j,".summaryZh"),D_SZH);assertEq(vm.parseJsonString(j,".summaryEn"),D_SEN);
        string[] memory keys=vm.parseJsonKeys(j,"$");assertEq(keys.length,10,"exactly the 10 v1 keys");
    }
    function test_v82_descriptionEscapesUserNameAndSymbol() public {
        string memory name='Ag"ent\\Raise\n</x>';string memory sym='A"B\\';
        (Launcher l,uint256 id)=_createNamed(bytes32(uint256(9)),name,sym);string memory j=l.description();
        assertEq(j,_expectedJson('Ag\\"ent\\\\Raise\\n</x>','A\\"B\\\\',10 ether,_ratio(l,id)),"only name/symbol escaped (LibString.escapeJSON)");
        assertEq(vm.parseJsonString(j,".name"),name,"round trip");assertEq(vm.parseJsonString(j,".symbol"),sym,"round trip");
        assertEq(vm.parseJsonUint(j,".v"),1);
    }
    function test_v82_descriptionConstantsNeedNoEscaping() public pure {
        string[4] memory c=[D_TZH,D_TEN,D_SZH,D_SEN];
        for(uint256 k;k<4;++k){bytes memory b=bytes(c[k]);for(uint256 i;i<b.length;++i){assertTrue(b[i]!='"'&&b[i]!='\\'&&uint8(b[i])>=0x20,"constant needs escaping");}}
        assertTrue(bytes(D_SEN).length>0&&bytes(D_SZH).length>0);
    }
    function test_v82_descriptionUnderPortalGasAndSizeLimits() public {
        (Launcher l,)=_create(bytes32(uint256(1)));(string memory j,uint256 g)=_portalRead(address(l));
        assertEq(j,l.description());assertLt(g,200_000);assertLe(bytes(j).length,4096);
        emit log_named_uint("description() gas (default)",g);emit log_named_uint("description() bytes (default)",bytes(j).length);
        // worst case: 32-byte name and 12-byte symbol made only of characters that escape to 6 bytes each (\u00XX)
        string memory n32=string(abi.encodePacked(bytes32(0x0101010101010101010101010101010101010101010101010101010101010101)));
        string memory s12=string(abi.encodePacked(bytes12(0x010101010101010101010101)));
        (Launcher w,)=_createNamed(bytes32(uint256(10)),n32,s12);(string memory jw,uint256 gw)=_portalRead(address(w));
        assertEq(vm.parseJsonString(jw,".name"),n32);assertLt(gw,200_000);assertLe(bytes(jw).length,4096);
        emit log_named_uint("description() gas (worst-case name/symbol)",gw);emit log_named_uint("description() bytes (worst case)",bytes(jw).length);
    }
    function test_v82_descriptionStableThroughSettleAndOnImplReverts() public {
        (Launcher l,uint256 id)=_create(bytes32(uint256(1)));string memory before=l.description();
        _fillToHard(l,id);assertTrue(l.getRaise(id).settled);assertEq(l.description(),before,"hardCap-only: settle split == creation projection");
        Launcher impl=Launcher(payable(factory.implementation()));vm.expectRevert("AR: raise not found");impl.description();
        // also reachable via the module's own selector through the fallback (view, no lock)
        assertEq(IGuardianRescueV82(address(l)).launcherDescription(),before);
    }
    function test_v82_descriptionAfterMarkFailed() public {
        (Launcher l,uint256 id)=_create(bytes32(uint256(1)));string memory before=l.description();vm.prank(creator);l.markFailed(id);assertEq(l.description(),before);
    }

    // ───────────── V8.2.1 Z-01: Portal needs max(buy, sell) >= 1%; 0/0 (and any pair both < 1%) must be rejected at create ─────────────
    function _taxData(bytes32 salt,uint16 buy,uint16 sell) internal view returns(bytes memory){Launcher.LaunchConfig memory c=_launch(salt);c.buyTaxBps=buy;c.sellTaxBps=sell;return _data(_cfg(),uint64(block.timestamp+1 days),c,bene);}
    function _createTax(bytes32 salt,uint16 buy,uint16 sell) internal returns(Launcher l){bytes memory d=_taxData(salt,buy,sell);uint256 fee=portal.SALT_LOCK_FEE();vm.prank(creator);l=Launcher(payable(portal.newLauncher{value:fee}(address(factory),d)));}
    function _expectTaxReject(uint16 buy,uint16 sell) internal {bytes memory d=_taxData(bytes32(uint256(9)),buy,sell);uint256 fee=portal.SALT_LOCK_FEE();vm.prank(creator);vm.expectRevert(bytes("AR: buy or sell tax must be >= 1%"));portal.newLauncher{value:fee}(address(factory),d);}
    function test_v821_z01_zeroBuyAndSellTaxRevertsAtCreate() public {
        _expectTaxReject(0,0);
        assertEq(factory.raiseCount(),0);assertEq(factory.saltOwner(bytes32(uint256(9))),0);
        // independent of taxDuration and fee-slot layout
        Launcher.LaunchConfig memory c=_launch(bytes32(uint256(9)));c.buyTaxBps=0;c.sellTaxBps=0;c.taxDuration=0;
        c.feeConfigs=new IFlapPoolPortal.FeeConfig[](1);c.feeConfigs[0]=IFlapPoolPortal.FeeConfig(IFlapPoolPortal.FeeSlotType.MARKETING,10000,abi.encode(address(0)));
        bytes memory d=_data(_cfg(),uint64(block.timestamp+1 days),c,bene);uint256 fee=portal.SALT_LOCK_FEE();
        vm.prank(creator);vm.expectRevert(bytes("AR: buy or sell tax must be >= 1%"));portal.newLauncher{value:fee}(address(factory),d);
        assertEq(factory.raiseCount(),0);
    }
    function test_v821_z01_subOnePercentPairsRevertAtCreate() public {
        _expectTaxReject(1,0);_expectTaxReject(0,1);_expectTaxReject(1,1);_expectTaxReject(50,50);_expectTaxReject(99,99);_expectTaxReject(99,0);_expectTaxReject(0,99);
        assertEq(factory.raiseCount(),0);
    }
    function test_v821_z01_buyOnlyTaxCreatesAndSettles() public {Launcher l=_createTax(bytes32(uint256(1)),100,0);uint256 id=factory.raiseCount();assertEq(id,1);Launcher.LaunchConfig memory g=_m(l).getLaunchConfig(id);assertEq(g.buyTaxBps,100);assertEq(g.sellTaxBps,0);_ready(l,id);l.settle(id);assertTrue(l.getRaise(id).settled);}
    function test_v821_z01_sellOnlyTaxCreatesAndSettles() public {Launcher l=_createTax(bytes32(uint256(1)),0,100);uint256 id=factory.raiseCount();assertEq(id,1);Launcher.LaunchConfig memory g=_m(l).getLaunchConfig(id);assertEq(g.buyTaxBps,0);assertEq(g.sellTaxBps,100);_ready(l,id);l.settle(id);assertTrue(l.getRaise(id).settled);}
    function test_v821_z01_mixedPairsAboveMinCreate() public {_createTax(bytes32(uint256(1)),100,1);_createTax(bytes32(uint256(2)),50,100);_createTax(bytes32(uint256(3)),1000,1000);assertEq(factory.raiseCount(),3);assertEq(factory.MIN_TAX_BPS(),100);}
    function test_v821_z01_maxTaxBoundUnchanged() public {bytes memory d=_taxData(bytes32(uint256(2)),1001,0);vm.prank(creator);vm.expectRevert(bytes("AR: bad launch config"));portal.newLauncher{value:0.01 ether}(address(factory),d);}
    function test_v821_z01_schemaMentionsTaxRule() public view {LauncherDataSchema memory sc=factory.launcherDataSchema();assertTrue(_contains(sc.description,"at least one >= 1%"));}
    function _contains(string memory h,string memory n) internal pure returns(bool){bytes memory a=bytes(h);bytes memory b=bytes(n);if(b.length>a.length)return false;for(uint256 i;i<=a.length-b.length;++i){bool ok=true;for(uint256 j;j<b.length;++j){if(a[i+j]!=b[j]){ok=false;break;}}if(ok)return true;}return false;}

    // ───────────── V8.2.2 D-04 / D-05: fee slots the real Portal rejects at settle must be rejected at create ─────────────
    function _fc(IFlapPoolPortal.FeeSlotType t,uint16 bps,bytes memory d) internal pure returns(IFlapPoolPortal.FeeConfig memory){return IFlapPoolPortal.FeeConfig(t,bps,d);}
    function _feeData(bytes32 salt,IFlapPoolPortal.FeeConfig[] memory f) internal view returns(bytes memory){Launcher.LaunchConfig memory c=_launch(salt);c.feeConfigs=f;return _data(_cfg(),uint64(block.timestamp+1 days),c,bene);}
    function _two(IFlapPoolPortal.FeeConfig memory a,IFlapPoolPortal.FeeConfig memory b) internal pure returns(IFlapPoolPortal.FeeConfig[] memory f){f=new IFlapPoolPortal.FeeConfig[](2);f[0]=a;f[1]=b;}
    function _one(IFlapPoolPortal.FeeConfig memory a) internal pure returns(IFlapPoolPortal.FeeConfig[] memory f){f=new IFlapPoolPortal.FeeConfig[](1);f[0]=a;}
    function _feeReject(IFlapPoolPortal.FeeConfig[] memory f,bytes memory reason) internal {bytes memory d=_feeData(bytes32(uint256(9)),f);uint256 fee=portal.SALT_LOCK_FEE();vm.prank(creator);vm.expectRevert(reason);portal.newLauncher{value:fee}(address(factory),d);assertEq(factory.raiseCount(),0);assertEq(factory.saltOwner(bytes32(uint256(9))),0);}
    function _feeCreateSettle(bytes32 salt,IFlapPoolPortal.FeeConfig[] memory f) internal returns(Launcher l,uint256 id){bytes memory d=_feeData(salt,f);uint256 fee=portal.SALT_LOCK_FEE();vm.prank(creator);l=Launcher(payable(portal.newLauncher{value:fee}(address(factory),d)));id=factory.raiseCount();_ready(l,id);l.settle(id);assertTrue(l.getRaise(id).settled);}
    function _div(uint16 bps) internal pure returns(IFlapPoolPortal.FeeConfig memory){return _fc(IFlapPoolPortal.FeeSlotType.DIVIDEND,bps,abi.encode(address(0),uint256(1e9 ether/100000)));}
    bytes constant ZB="AR: zero bps fee slot";
    function test_v822_d04_zeroBpsDeflationRejected() public {_feeReject(_two(_fc(IFlapPoolPortal.FeeSlotType.DEFLATION,0,""),_fc(IFlapPoolPortal.FeeSlotType.LP_BPS,10000,"")),ZB);}
    function test_v822_d04_zeroBpsLpRejected() public {_feeReject(_two(_fc(IFlapPoolPortal.FeeSlotType.LP_BPS,0,""),_fc(IFlapPoolPortal.FeeSlotType.DEFLATION,10000,"")),ZB);}
    function test_v822_d04_zeroBpsMarketingRejected() public {
        _feeReject(_two(_fc(IFlapPoolPortal.FeeSlotType.MARKETING,0,abi.encode(address(0))),_fc(IFlapPoolPortal.FeeSlotType.DEFLATION,10000,"")),ZB);
        _feeReject(_two(_div(10000),_fc(IFlapPoolPortal.FeeSlotType.MARKETING,0,abi.encode(address(0xBEEF)))),ZB);
    }
    function test_v822_d04_zeroBpsCheckedBeforeOrderAndSum() public {
        // zero slot last / with DIVIDEND as the 10000 slot / single zero slot (sum also wrong) → zero-bps reason first
        _feeReject(_two(_div(10000),_fc(IFlapPoolPortal.FeeSlotType.DEFLATION,0,"")),ZB);
        _feeReject(_one(_fc(IFlapPoolPortal.FeeSlotType.LP_BPS,0,"")),ZB);
    }
    function test_v822_d04_dividendZeroBpsAccepted() public {
        (Launcher l,uint256 id)=_feeCreateSettle(bytes32(uint256(1)),_two(_fc(IFlapPoolPortal.FeeSlotType.DEFLATION,10000,""),_div(0)));
        IFlapPoolPortal.FeeConfig[] memory g=l.feeConfigsOf(id);assertEq(g.length,2);assertEq(uint8(g[1].feeType),5);assertEq(g[1].bps,0);
    }
    function test_v822_d04_noneSlotStillIgnored() public {
        // NONE slots are not counted (Portal: "configData ignored"); bps 0 there is not a D-04 slot
        IFlapPoolPortal.FeeConfig[] memory f=new IFlapPoolPortal.FeeConfig[](2);f[0]=_fc(IFlapPoolPortal.FeeSlotType.NONE,0,"");f[1]=_fc(IFlapPoolPortal.FeeSlotType.DEFLATION,10000,"");
        _feeCreateSettle(bytes32(uint256(1)),f);
    }
    function test_v822_d04_allPositiveFourSlotsStillAccepted() public {
        IFlapPoolPortal.FeeConfig[] memory f=new IFlapPoolPortal.FeeConfig[](4);
        f[0]=_fc(IFlapPoolPortal.FeeSlotType.DEFLATION,1,"");f[1]=_fc(IFlapPoolPortal.FeeSlotType.LP_BPS,1,"");f[2]=_fc(IFlapPoolPortal.FeeSlotType.MARKETING,1,abi.encode(address(0xBEEF)));f[3]=_div(9997);
        _feeCreateSettle(bytes32(uint256(1)),f);
    }
    function test_v822_d05_dirtyMarketingAddressRejected() public {
        // non-zero high 12 bytes (length still 32): strict abi.decode reverts with empty data, before any salt lock / state
        _feeReject(_one(_fc(IFlapPoolPortal.FeeSlotType.MARKETING,10000,abi.encode((uint256(1)<<160)|uint256(uint160(address(0xBEEF)))))),"");
        _feeReject(_one(_fc(IFlapPoolPortal.FeeSlotType.MARKETING,10000,abi.encode(uint256(0xff)<<248))),"");           // dirty top byte, zero low address
        _feeReject(_one(_fc(IFlapPoolPortal.FeeSlotType.MARKETING,10000,abi.encode(type(uint256).max))),"");
        _feeReject(_two(_div(5000),_fc(IFlapPoolPortal.FeeSlotType.MARKETING,5000,abi.encode(uint256(1)<<255))),"");
    }
    function test_v822_d05_cleanMarketingAddressAccepted() public {
        (Launcher l,uint256 id)=_feeCreateSettle(bytes32(uint256(1)),_one(_fc(IFlapPoolPortal.FeeSlotType.MARKETING,10000,abi.encode(address(0xBEEF)))));
        assertEq(abi.decode(l.feeConfigsOf(id)[0].configData,(address)),address(0xBEEF));
        (Launcher l2,uint256 id2)=_feeCreateSettle(bytes32(uint256(2)),_one(_fc(IFlapPoolPortal.FeeSlotType.MARKETING,10000,abi.encode(address(type(uint160).max)))));
        assertEq(abi.decode(l2.feeConfigsOf(id2)[0].configData,(address)),address(type(uint160).max));
        // address(0) keeps v10 tax-to-vault routing
        (Launcher l3,uint256 id3)=_feeCreateSettle(bytes32(uint256(3)),_one(_fc(IFlapPoolPortal.FeeSlotType.MARKETING,10000,abi.encode(address(0)))));
        assertEq(abi.decode(l3.feeConfigsOf(id3)[0].configData,(address)),address(l3));
    }
    function test_v822_d05_marketingLengthStillExact() public {
        _feeReject(_one(_fc(IFlapPoolPortal.FeeSlotType.MARKETING,10000,abi.encodePacked(address(0xBEEF)))),bytes("AR: bad launch config"));
        _feeReject(_one(_fc(IFlapPoolPortal.FeeSlotType.MARKETING,10000,abi.encode(address(0xBEEF),uint256(0)))),bytes("AR: bad launch config"));
    }
    function test_v822_scan_dirtyDividendTokenAlreadyRejected() public {
        // pre-existing V8.2.1 behaviour (abi.decode (address,uint256)) — same class as D-05, already safe
        _feeReject(_one(_fc(IFlapPoolPortal.FeeSlotType.DIVIDEND,10000,abi.encode((uint256(1)<<160),uint256(1e9 ether/100000)))),"");
    }
    function test_v822_z01_taxFloorKept() public view {assertEq(factory.MIN_TAX_BPS(),100);}

}

contract RejectingLauncherBeneficiaryV81 { receive() external payable { revert("reject"); } }
