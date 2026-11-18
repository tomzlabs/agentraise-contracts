// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
interface IERC20T { function balanceOf(address) external view returns (uint256); function transfer(address,uint256) external returns (bool); function transferFrom(address,address,uint256) external returns (bool); }
/// @notice Behavioral mock of Flap TokenDockRouter (ITokenDock surface only). Etched at 0x000048E8…0000 in unit tests.
contract MockTokenDockRouter {
    mapping(address => mapping(address => uint256)) public balanceOf;
    mapping(address => uint256) public totalReserved;
    bool public shortDeposit; bool public failWithdraw; bytes public reenterCall; bool public reenterOk; bool public reentered;
    event FlapTokenDockDeposited(address token, address owner, uint256 amount);
    event FlapTokenDockWithdrawn(address token, address owner, address to, uint256 amount);
    function setShortDeposit(bool v) external { shortDeposit = v; }
    function setFailWithdraw(bool v) external { failWithdraw = v; }
    function setReenter(bytes calldata c) external { reenterCall = c; }
    function isWhitelisted(address, address) external pure returns (bool) { return true; }
    function deposit(address token, uint256 amount) external {
        uint256 b0 = IERC20T(token).balanceOf(address(this));
        require(IERC20T(token).transferFrom(msg.sender, address(this), amount), "DOCK: pull");
        uint256 got = IERC20T(token).balanceOf(address(this)) - b0;
        require(got == amount, "DOCK: delta");
        uint256 credit = shortDeposit ? amount - 1 : amount;
        balanceOf[token][msg.sender] += credit; totalReserved[token] += credit;
        emit FlapTokenDockDeposited(token, msg.sender, credit);
    }
    function withdraw(address token, uint256 amount, address to) external {
        require(!failWithdraw, "DOCK: withdraw failed");
        balanceOf[token][msg.sender] -= amount; totalReserved[token] -= amount;
        if (reenterCall.length != 0) { (bool ok,) = msg.sender.call(reenterCall); reentered = true; reenterOk = ok; }
        require(IERC20T(token).transfer(to, amount), "DOCK: send");
        emit FlapTokenDockWithdrawn(token, msg.sender, to, amount);
    }
}
