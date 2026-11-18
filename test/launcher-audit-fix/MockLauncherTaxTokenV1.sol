// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
// Isolated unchanged token mock for the standalone Launcher audit suite.
contract MockTaxToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;
    bool public rejectTo; address public blocked;
    constructor(uint256 s, address to) { totalSupply = s; balanceOf[to] = s; }
    function setBlocked(address b) external { blocked = b; }
    function portalMove(address f, address to, uint256 v) external { _mv(f, to, v); } // mock only
    function approve(address s, uint256 v) external returns (bool) { allowance[msg.sender][s] = v; return true; }
    function transfer(address to, uint256 v) external returns (bool) { _mv(msg.sender, to, v); return true; }
    function transferFrom(address f, address to, uint256 v) external returns (bool) { allowance[f][msg.sender] -= v; _mv(f, to, v); return true; }
    function _mv(address f, address to, uint256 v) internal { require(to != blocked, "blocked"); balanceOf[f] -= v; balanceOf[to] += v; }
}
