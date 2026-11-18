// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {AgentRaiseLauncherV82} from "./AgentRaiseLauncherV82.sol";
import {IAuditMathV8} from "../launcher-beacon-v8/IAuditMathV8.sol";
import {LaunchVaultAddresses} from "./flap/LaunchVaultAddresses.sol";
import {ITokenDock} from "../launcher-beacon-v8/ITokenDock.sol";
import {LauncherDescription, LauncherHelper} from "./flap/LauncherHelper.sol";
import {LauncherBase} from "./flap/LauncherBase.sol";

/// @notice Independent storage, never overlapping Initializable or the raise state.
library RescueStateV82 {
    struct State { bool halted; bool forwardEnabled; bool busy; address destination; }
    // Dedicated namespace: keccak256("agentraise.launcher.auditfix.rescue.v2").
    bytes32 internal constant SLOT=keccak256("agentraise.launcher.auditfix.rescue.v2");
    function state() internal pure returns(State storage s) { bytes32 slot=SLOT; assembly { s.slot := slot } }
}

/// @notice ABI for the fixed delegate module exposed by each V2 Launcher fallback.
/// No selector is claimed to be a published Flap standard. Reviewer approval remains required.
interface IGuardianRescueV82 {
    function emergencyWithdraw(address token,address payable recipient) external;
    function setReceiveForward(address payable destination,bool enabled) external;
    function rescueStatus() external view returns(bool permanentlyHalted,bool forwardEnabled,address destination);
    /// @notice V8.2: Flap Launcher description JSON v1 of the calling Launcher (served through its fallback).
    function launcherDescription() external view returns(string memory);
}

/// @notice FIXED, non-upgradeable emergency code. Executes in clone context, not factory custody.
/// Guardian may extract ALL native/ERC20 balances, INCLUDING contributor principal and sale tokens.
/// A successful rescue or enabling forwarding permanently quarantines that clone. Original debts
/// remain historical records, NOT funded ordinary refund/claim promises. Guardian handles recovery.
contract GuardianRescueV82 is IGuardianRescueV82, LauncherBase {
    ITokenDock private constant DOCK = ITokenDock(0x000048E888aBf09f690a952E1b386b2D031a0000); // == Launcher TOKEN_DOCK_ROUTER
    /// @notice Original read-only economics ABI retained here for EIP-170 space; no custody writes.
    function economicsAt(uint256 id,uint256 raised,uint256 creatorPaid) public view returns(uint256,uint256,uint256) {
        AgentRaiseLauncherV82 l=AgentRaiseLauncherV82(payable(address(this)));
        AgentRaiseLauncherV82.LaunchConfig memory c=getLaunchConfig(id);
        return IAuditMathV8(l.factory()).economicsFor(raised,creatorPaid,c.totalSupply,c.sellTaxBps,c.creatorShareBps);
    }
    function economics(uint256 id) external view returns(uint256,uint256,uint256) {
        AgentRaiseLauncherV82 l=AgentRaiseLauncherV82(payable(address(this)));
        AgentRaiseLauncherV82.Raise memory r=l.getRaise(id);
        return economicsAt(id,r.totalRaised==0?r.hardCap:r.totalRaised,r.totalRaised==0?0:l.contributionOf(id,r.creator));
    }
    function openPriceRatioBps(uint256 id,uint256 raised) external view returns(uint256) {
        AgentRaiseLauncherV82 l=AgentRaiseLauncherV82(payable(address(this)));
        AgentRaiseLauncherV82.LaunchConfig memory c=getLaunchConfig(id);
        return IAuditMathV8(l.factory()).priceRatioFor(raised,c.creatorShareBps,c.totalSupply);
    }
    // ───────────── V8.2: Flap Pool Launch description (official LauncherBase / LauncherHelper.toJson) ─────────────
    // Developer constants: no quotes, backslashes or control characters (LauncherHelper escapes only name/symbol).
    string internal constant TITLE_ZH = unicode"AI 智能体募集发射";
    string internal constant TITLE_EN = "AI agent raise launch";
    string internal constant SUMMARY_ZH = unicode"持有 Agent ID 的智能体用 BNB 认购份额，直到硬顶。认满即自动结算并在 Flap 发射，代币分批自动发给认购者。募集失败可退款。";
    string internal constant SUMMARY_EN = "Agents with an Agent ID buy shares with BNB until the hard cap. Filling it settles and launches on Flap automatically; contributors receive tokens automatically in batches. If the raise fails, contributions are refunded.";

    /// @notice Delegate-context render of the Launcher's description (= LauncherBase.description() of the Launcher).
    function launcherDescription() external view returns (string memory) { return LauncherHelper.toJson(_description()); }

    /// @dev Display-only; never used for gating or accounting. Every field is written by Launcher.initialize(), i.e. before the
    ///      Portal reads description() inside newLauncher. targetRaise = hardCap (hardCap-only: settle requires it filled, so it is
    ///      the exact raise); poolTokenRatio = poolTokens / totalSupply at hardCap (the split settle reuses since R == hardCap).
    ///      quoteToken = address(0): native BNB, as the Launcher's launch params. Reverts "raise not found" before initialize.
    function _description() internal view override returns (LauncherDescription memory d) {
        uint256 id = _l().raiseId;
        AgentRaiseLauncherV82.Raise storage r = _l()._raises[id];
        require(r.creator != address(0), "AR: raise not found");
        AgentRaiseLauncherV82.LaunchConfig storage c = _l()._launchCfg[id];
        d.name = c.tokenName;
        d.symbol = c.tokenSymbol;
        d.targetRaise = r.hardCap;
        d.poolTokenRatio = r.poolTokens * 1e18 / c.totalSupply;
        d.titleZh = TITLE_ZH;
        d.titleEn = TITLE_EN;
        d.summaryZh = SUMMARY_ZH;
        d.summaryEn = SUMMARY_EN;
    }
    /// @dev LauncherBase hook; the module never launches (Launcher._settle calls the Portal itself).
    function _getHub() internal view override returns (address) { return LaunchVaultAddresses.hub(); }

    /// @dev V4: read-only views moved from the Launcher (EIP-170). They read the Launcher's ERC-7201 layout directly in clone context.
    bytes32 private constant LAYOUT_SLOT = 0xa7ac83b785d5e261f04a39ecccf3d3d4ba6bc81762518e7fff25b9a6d5225700; // == AgentRaiseLauncherV82.LAYOUT_SLOT
    function _l() private pure returns (AgentRaiseLauncherV82.Layout storage $) { bytes32 p = LAYOUT_SLOT; assembly { $.slot := p } }
    function getLaunchConfig(uint256 raiseId) public view returns (AgentRaiseLauncherV82.LaunchConfig memory) {
        require(_l()._raises[raiseId].creator != address(0), "AR: raise not found");
        return _l()._launchCfg[raiseId];
    }
    function contributors(uint256 raiseId, uint256 from, uint256 count) external view returns (address[] memory out) {
        address[] storage l = _l()._contributors[raiseId];
        uint256 end = from + count > l.length ? l.length : from + count;
        out = new address[](end > from ? end - from : 0);
        for (uint256 i = from; i < end; ++i) out[i - from] = l[i];
    }
    /// @notice V4: lifecycle status, moved here from the Launcher for EIP-170 headroom. Same logic/order as V3 Launcher.status().
    function status(uint256 id) external view returns(AgentRaiseLauncherV82.State) {
        if(RescueStateV82.state().halted) return AgentRaiseLauncherV82.State.EMERGENCY;
        AgentRaiseLauncherV82 l=AgentRaiseLauncherV82(payable(address(this)));
        AgentRaiseLauncherV82.Raise memory r=l.getRaise(id); // reverts "AR: raise not found" like _get
        if(r.settled) return AgentRaiseLauncherV82.State.SETTLED;
        if(l.refundOpen(id)) return AgentRaiseLauncherV82.State.REFUNDING;
        if(l.canSettle(id)) return block.timestamp<r.deadline?AgentRaiseLauncherV82.State.FILLED:AgentRaiseLauncherV82.State.SETTLEABLE;
        return AgentRaiseLauncherV82.State.LIVE;
    }
    /// @notice V7: rounding dust left in the Token Dock after every contributor was paid, sent to the beneficiary.
    event DustSwept(uint256 indexed raiseId, address indexed beneficiary, uint256 amount);
    /// @notice V7: permissionless. Once every contributor has been paid, send the pro-rata rounding dust still in the
    ///         Token Dock to the beneficiary (funds can only go to the beneficiary). Uses the Launcher's own reentrancy lock.
    function sweepDust(uint256 raiseId) external {
        require(!RescueStateV82.state().halted, "AR: emergency recovery");
        AgentRaiseLauncherV82.Layout storage $ = _l();
        require($._lock == 1, "AR: reentrant"); $._lock = 2;
        AgentRaiseLauncherV82.Raise storage r = $._raises[raiseId];
        require(r.creator != address(0), "AR: raise not found");
        require(r.settled && $.paidCount[raiseId] == $._contributors[raiseId].length, "AR: not all paid");
        uint256 amt = DOCK.balanceOf(r.token, address(this));
        require(amt != 0, "AR: nothing to claim");
        DOCK.withdraw(r.token, amt, r.beneficiary);
        emit DustSwept(raiseId, r.beneficiary, amt);
        $._lock = 1;
    }
    /// @notice V7: sale tokens of this launcher still custodied in the Token Dock (0 before settle).
    function tokensInDock() external view returns (uint256) {
        address t = _l()._raises[_l().raiseId].token;
        return t == address(0) ? 0 : DOCK.balanceOf(t, address(this));
    }
    /// @notice V7: contributors whose sale tokens already left the dock (push or claim).
    function paidCount(uint256 id) external view returns (uint256) { return _l().paidCount[id]; }
    event EmergencyWithdraw(address indexed token,address indexed recipient,uint256 amount);
    event ReceiveForwardSet(address indexed destination,bool enabled);
    event NativeForwarded(address indexed sender,address indexed destination,uint256 amount);
    modifier guardian() { require(msg.sender==LaunchVaultAddresses.guardian(),"AR: only Guardian"); _; }
    modifier lock() { RescueStateV82.State storage s=RescueStateV82.state(); require(!s.busy,"AR: rescue reentrant"); s.busy=true; _; s.busy=false; }
    function rescueStatus() external view returns(bool,bool,address) { RescueStateV82.State storage s=RescueStateV82.state(); return(s.halted,s.forwardEnabled,s.destination); }
    function setReceiveForward(address payable destination,bool enabled) external guardian lock {
        require(destination!=address(0) && destination!=address(this),"AR: bad recovery recipient");
        RescueStateV82.State storage s=RescueStateV82.state();
        s.destination=destination; s.forwardEnabled=enabled;
        if(enabled) s.halted=true; // No resuming an insolvent lifecycle after diverted funds.
        emit ReceiveForwardSet(destination,enabled);
    }
    function emergencyWithdraw(address token,address payable recipient) external guardian lock {
        require(recipient!=address(0) && recipient!=address(this),"AR: bad recovery recipient");
        RescueStateV82.state().halted=true;
        uint256 amount;
        if(token==address(0)) {
            amount=address(this).balance; require(amount!=0,"AR: no recovery balance");
            (bool ok,)=recipient.call{value:amount}(""); require(ok,"AR: recovery BNB failed");
        } else {
            require(token.code.length!=0,"AR: recovery token has no code");
            // V7: sale tokens live in the Token Dock under this launcher; withdraw them straight to the recipient first.
            uint256 docked=DOCK.balanceOf(token,address(this));
            if(docked!=0) DOCK.withdraw(token,docked,recipient);
            (bool readOk,bytes memory balance)=token.staticcall(abi.encodeWithSignature("balanceOf(address)",address(this)));
            require(readOk && balance.length==32,"AR: recovery balance failed");
            amount=abi.decode(balance,(uint256)); require(amount+docked!=0,"AR: no recovery balance");
            if(amount!=0) {
                (bool ok,bytes memory result)=token.call(abi.encodeWithSignature("transfer(address,uint256)",recipient,amount));
                require(ok && (result.length==0 || (result.length==32 && abi.decode(result,(uint256))==1)),"AR: recovery token failed");
            }
            amount+=docked;
        }
        emit EmergencyWithdraw(token,recipient,amount);
    }
    receive() external payable lock {
        RescueStateV82.State storage s=RescueStateV82.state();
        require(s.halted && s.forwardEnabled,"AR: forwarding disabled");
        if(msg.value==0) return;
        (bool ok,)=payable(s.destination).call{value:msg.value}("");
        require(ok,"AR: forward failed");
        emit NativeForwarded(msg.sender,s.destination,msg.value);
    }
}
