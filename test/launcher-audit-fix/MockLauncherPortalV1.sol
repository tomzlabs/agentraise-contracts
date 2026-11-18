// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {IPortalTypes} from "../../contracts/launcher-audit-fix/flap/IPortal.sol";
import {ILauncherFactory, LauncherRecord} from "../../contracts/launcher-audit-fix/flap/ILauncher.sol";
import {Distribution, DistributionTarget} from "../../contracts/launcher-audit-fix/flap/Distribution.sol";
import {IStrategy} from "../../contracts/launcher-audit-fix/flap/IStrategy.sol";
import {LaunchExtensionHelper} from "../../contracts/launcher-audit-fix/flap/LaunchExtensionHelper.sol";
import {IFlapPoolPortal} from "../../contracts/interfaces/IFlapPoolPortal.sol";
import {MockTaxToken} from "./MockLauncherTaxTokenV1.sol";
/// @notice Behavioral mock, NOT Portal implementation, deployment or audit evidence.
contract MockLauncherPortalV1 {
    uint256 public constant SALT_LOCK_FEE = 0.01 ether;
    uint256 public featureFlags;
    uint256 public price;
    bool public quoteEnabled;
    bool public noLens;
    bool public badDistribution;
    bool public skipDistribution;
    bool public reenter;
    bool public reentryRejected;
    bool public duplicateCallbackRejected;
    struct FactoryConfig { bool enabled; uint16 multiplierBps; }
    mapping(address => FactoryConfig) public launcherFactoryMultiplier;
    mapping(address => FactoryConfig) public vaultFactoryMultiplier;
    mapping(address => LauncherRecord) private records;
    mapping(address => bool) public launched;
    mapping(bytes32 => address) public lockerOf;
    mapping(bytes32 => bool) public saltUsed;
    address public blockedRecipient;
    function setBlockedRecipient(address a) external { blockedRecipient = a; }
    address public lastCaller;
    address public lastCreator;
    uint256 public lastValue;
    IPortalTypes.CreateTaxTokenParams private lastParams;
    event FlapNewLauncherCreated(address launcher, address launcherFactory, address creator);
    function configure(uint256 price_, bool quoteEnabled_) external { price = price_; quoteEnabled = quoteEnabled_; }
    function setFactory(address f, bool enabled, uint16 bps) external { require(bps <= 10000); launcherFactoryMultiplier[f] = FactoryConfig(enabled,bps); }
    function setVaultFactory(address f, bool enabled, uint16 bps) external { vaultFactoryMultiplier[f] = FactoryConfig(enabled,bps); }
    function setFlags(uint256 flags) external { featureFlags = flags; }
    function setBehavior(bool noLens_, bool bad_, bool skip_, bool reenter_) external { noLens=noLens_;badDistribution=bad_;skipDistribution=skip_;reenter=reenter_; }
    function newLauncher(address factory, bytes calldata data) external payable returns (address launcher) {
        require(launcherFactoryMultiplier[factory].enabled, "MOCK: disabled");
        launcher = ILauncherFactory(factory).newLauncher{value:msg.value}(msg.sender,data);
        require(launcher.code.length>0 && records[launcher].launcherFactory==address(0), "MOCK: invalid launcher");
        records[launcher] = LauncherRecord(factory);
        emit FlapNewLauncherCreated(launcher,factory,msg.sender);
    }
    function getLauncher(address a) external view returns (LauncherRecord memory) { return records[a]; }
    function lockSalt(bytes32 salt,uint8 kind) external payable { require(kind==0 && msg.value==SALT_LOCK_FEE,"MOCK: fee"); require(lockerOf[salt]==address(0) && !saltUsed[salt],"MOCK: salt");lockerOf[salt]=msg.sender; }
    function launchQuoteConfig(uint8,address) external view returns(bool,uint256){return(quoteEnabled,price);}
    function _bps(address launcher,address vf) internal view returns(uint16) {
        if(vaultFactoryMultiplier[vf].enabled)return vaultFactoryMultiplier[vf].multiplierBps;
        FactoryConfig memory c=launcherFactoryMultiplier[records[launcher].launcherFactory];
        return c.enabled?c.multiplierBps:10000;
    }
    function graduationFloorV2(IFlapPoolPortal.GraduationFloorParams calldata p) external view returns(IFlapPoolPortal.GraduationFloorResultV2 memory){require(!noLens,"MOCK: missing lens");return _floor(p,10000);}
    function graduationFloorV2ForLauncher(IFlapPoolPortal.GraduationFloorParams calldata p,address launcher) external view returns(IFlapPoolPortal.GraduationFloorResultV2 memory){require(!noLens,"MOCK: missing lens");return _floor(p,_bps(launcher,p.vaultFactory));}
    function _floor(IFlapPoolPortal.GraduationFloorParams memory p,uint16 bps) internal pure returns(IFlapPoolPortal.GraduationFloorResultV2 memory g){
        g.quoteUsdWad=p.poolQuote*p.quotePriceUsd/1 ether;
        uint256 denominator=uint256(p.poolToken)*10000;
        g.floorUsdWad=(1500 ether*uint256(bps)*p.totalSupply+denominator-1)/denominator;
        g.createFloorUsdWad=(750 ether*uint256(bps)*p.totalSupply+denominator-1)/denominator;
        g.meetsFloor=g.quoteUsdWad>=g.floorUsdWad;g.meetsCreateFloor=g.quoteUsdWad>=g.createFloorUsdWad;g.multiplierBps=bps;
    }
    function launchTaxTokenV2(IPortalTypes.CreateTaxTokenParams calldata p,Distribution calldata d,IPortalTypes.CreatorBuyParams calldata cb) external payable returns(address token,address pool){
        address factory=records[msg.sender].launcherFactory;
        require(factory!=address(0),"MOCK: unregistered");require(!launched[msg.sender],"MOCK: launched");
        require(featureFlags&1==0 || launcherFactoryMultiplier[factory].enabled,"MOCK: paused");
        require(quoteEnabled,"MOCK: quote disabled");
        require(_floor(IFlapPoolPortal.GraduationFloorParams(address(0),price,p.poolQuote,p.poolToken,p.totalSupply,address(0)),_bps(msg.sender,address(0))).meetsCreateFloor,"MOCK: floor");
        require(p.creatorBuyQuote==0 && cb.minOutputAmount==0 && cb.permitData.length==0,"MOCK: first buy");
        require(p.commissionReceiver==address(0) && p.quoteToken==address(0) && p.dexId==0 && p.antiSniperMode==0 && p.exemptWindow==0 && p.exemptAddrs.length==0,"MOCK: shape");
        require(d.target==DistributionTarget.EXPLICIT && d.strategy==msg.sender && p.poolToken+d.amount==p.totalSupply,"MOCK: allocation");
        require(msg.value==p.poolQuote && !saltUsed[p.salt] && (lockerOf[p.salt]==address(0)||lockerOf[p.salt]==msg.sender),"MOCK: value/salt");
        (bool found,address creator)=LaunchExtensionHelper.decodeCreator(p.extensionID,p.extensionData);require(found && creator!=address(0),"MOCK: creator");
        launched[msg.sender]=true;saltUsed[p.salt]=true;
        if(reenter){(bool ok,)=msg.sender.call(abi.encodeWithSignature("settle(uint256)",abi.decode(d.configData,(uint256))));reentryRejected=!ok;require(!ok,"MOCK: reentered");}
        MockTaxToken t=new MockTaxToken(p.totalSupply,address(this));if(blockedRecipient!=address(0))t.setBlocked(blockedRecipient);token=address(t);pool=address(uint160(uint256(keccak256(abi.encode(token)))));t.transfer(pool,p.poolToken);
        if(!skipDistribution){uint256 amount=badDistribution?d.amount-1:d.amount;t.approve(d.strategy,amount);IStrategy(d.strategy).initializeDistribution(token,amount,d.configData,bytes32(0));require(t.allowance(address(this),d.strategy)==0,"MOCK: unspent approval");(bool ok,)=d.strategy.call(abi.encodeCall(IStrategy.initializeDistribution,(token,amount,d.configData,bytes32(0))));duplicateCallbackRejected=!ok;require(!ok,"MOCK: duplicate callback");}
        lastParams=p;lastValue=msg.value;lastCaller=msg.sender;lastCreator=creator;
    }
    function last() external view returns(IPortalTypes.CreateTaxTokenParams memory){return lastParams;}
}
contract LauncherRegistryV1 {
    mapping(address=>string) private handles;
    function set(address a,string calldata h) external {handles[a]=h;}
    function handleOf(address a) external view returns(string memory){return handles[a];}
}
