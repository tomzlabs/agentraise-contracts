// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {IPortal} from "../launcher-audit-fix/flap/IPortal.sol";
import {IFlapPoolPortal} from "../interfaces/IFlapPoolPortal.sol";
/// @notice Additional lens signatures transcribed from the current Pool Launch guide.
/// Uses existing ABI-identical lens structs only; NOT a fabricated official base.
interface ILauncherPortalV1 is IPortal {
    function launchQuoteConfig(uint8 kind, address quoteToken) external view returns (bool enabled, uint256 quotePriceUsd);
    function graduationFloorV2(IFlapPoolPortal.GraduationFloorParams calldata params)
        external view returns (IFlapPoolPortal.GraduationFloorResultV2 memory);
    function graduationFloorV2ForLauncher(IFlapPoolPortal.GraduationFloorParams calldata params, address launcher)
        external view returns (IFlapPoolPortal.GraduationFloorResultV2 memory);
}
