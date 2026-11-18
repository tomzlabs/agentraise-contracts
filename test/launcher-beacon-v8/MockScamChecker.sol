// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Test double etched over the official checker address. Not a production denylist.
contract MockScamChecker {
    bool public revertCall;
    bool public returnMalformed;
    bool public returnShort;
    bool public nameScam;
    bool public symbolScam;
    string public lastName;
    string public lastSymbol;
    function set(bool revertCall_, bool malformed_, bool short_, bool nameScam_, bool symbolScam_) external {
        revertCall = revertCall_; returnMalformed = malformed_; returnShort = short_; nameScam = nameScam_; symbolScam = symbolScam_;
    }
    function isScamWord(string calldata name, string calldata symbol) external view returns (bool, bool) {
        // view-compatible via staticcall; state writes impossible — capture via assembly-free return path only.
        require(!revertCall, "MOCK: checker revert");
        if (returnShort) { assembly ("memory-safe") { mstore(0x00, 1) return(0x00, 32) } }
        if (returnMalformed) { assembly ("memory-safe") { mstore(0x00, 2) mstore(0x20, 0) return(0x00, 64) } }
        return (nameScam, symbolScam);
    }
}

/// @dev Separate recorder used when tests need last args; MockScamChecker above stays view-pure for staticcall.
contract MockScamCheckerRecorder {
    bool public nameScam;
    bool public symbolScam;
    string public lastName;
    string public lastSymbol;
    function setFlags(bool n, bool s) external { nameScam=n; symbolScam=s; }
    function isScamWord(string calldata name, string calldata symbol) external returns (bool, bool) {
        lastName = name; lastSymbol = symbol; return (nameScam, symbolScam);
    }
}
