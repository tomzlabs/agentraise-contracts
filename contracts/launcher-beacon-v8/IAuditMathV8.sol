// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
interface IAuditMathV8 {
 function economicsFor(uint256 raised,uint256 creatorPaid,uint256 supply,uint256 sellTax,uint256 creatorBps) external pure returns(uint256,uint256,uint256);
 function priceRatioFor(uint256 raised,uint256 creatorBps,uint256 supply) external pure returns(uint256);
}
