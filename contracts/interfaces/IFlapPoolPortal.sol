// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Minimal ABI of the Flap Pool Launch Portal (BSC mainnet/testnet proxy 0x000042108465206185A077Edc3F3fd2b49060000),
///         transcribed from https://docs.utter.cash/zh/docs/pool-launch. launchTaxTokenV2 selector 0x67e258b6,
///         creationPaused() 0xbd12dd64, graduationFloorV2 0x53b045aa and lockSalt 0xbabf8fea were confirmed present in the
///         live implementation bytecode (0x90722c19…bb8b) on 2026-11-02.
interface IFlapPoolPortal {
    enum FeeSlotType { NONE, DEFLATION, LP_BPS, MARKETING, VAULT, DIVIDEND }
    enum DistributionTarget { NONE, EXPLICIT, VAULT }

    struct FeeConfig { FeeSlotType feeType; uint16 bps; bytes configData; }

    struct CreateTaxTokenParams {
        string name;
        string symbol;
        string meta;
        uint256 totalSupply;        // [100 ether, 1e15 ether]
        bytes32 salt;               // token address must end in 0x7777
        address quoteToken;         // 0 = native BNB
        uint8 dexId;                // 0
        uint256 poolQuote;
        uint256 poolToken;
        uint16 buyTaxRate;          // bps ≤ 1000
        uint16 sellTaxRate;
        uint32 taxDuration;
        uint32 antiFarmerDuration;
        FeeConfig[] feeConfigs;     // ≤ 4, active bps sum = 10000
        uint8 antiSniperMode;       // must be 0
        uint32 exemptWindow;        // must be 0
        address[] exemptAddrs;      // must be empty
        uint256 creatorBuyQuote;
        bytes32 extensionID;        // must be 0
        bytes extensionData;        // must be empty
        address commissionReceiver; // 0 = off
    }

    struct Distribution { DistributionTarget target; address strategy; uint128 amount; bytes configData; }
    struct CreatorBuyParams { uint256 minOutputAmount; bytes permitData; }

    struct GraduationFloorParams { address quoteToken; uint256 quotePriceUsd; uint256 poolQuote; uint256 poolToken; uint256 totalSupply; address vaultFactory; }
    struct GraduationFloorResultV2 { bool meetsFloor; uint256 floorUsdWad; uint256 quoteUsdWad; uint16 multiplierBps; bool meetsCreateFloor; uint256 createFloorUsdWad; }

    function launchTaxTokenV2(CreateTaxTokenParams calldata p, Distribution calldata distribution, CreatorBuyParams calldata creatorBuy)
        external payable returns (address token, address pool);
    function creationPaused() external view returns (bool);
    function launchQuoteConfig(uint8 kind, address quoteToken) external view returns (bool enabled, uint256 quotePriceUsd);
    function graduationFloorV2(GraduationFloorParams calldata params) external view returns (GraduationFloorResultV2 memory);
    function lockSalt(bytes32 salt, uint8 kind) external payable;
    function SALT_LOCK_FEE() external view returns (uint256);

    // ── Preparation (Pool Launch "面向 Mini App 开发者"; docs.utter.cash/zh/docs/pool-launch) ──
    /// @dev Record the Portal stores per Preparation (docs). multiplierBps ∈ [1, 10000] scales create + graduation floors.
    struct PreparationRecord { address preFactory; uint16 multiplierBps; }
    /// @dev docs: Portal forwards msg.value to `preFactory.newPreparation(data)`, checks the returned address has code and
    ///      bps ∈ [1,10000], then stores {preFactory, multiplierBps}. Reverts UntrustedPreparationFactory unless Flap called
    ///      setTrustedPreparationFactory(preFactory, true).
    function newPreparation(address preFactory, bytes calldata data) external payable returns (address preparation, uint16 multiplierBps);
    function getPreparation(address preparation) external view returns (PreparationRecord memory);
    /// @dev Named by the Flap audit bot (live DLP impl 0x5bc8…b3e0); NOT in the public docs. Callers wrap it in try/catch and
    ///      fall back to graduationFloorV2 × getPreparation().multiplierBps. Verify with the fork test before relying on it.
    function graduationFloorV2ForPreparation(GraduationFloorParams calldata params, address preparation) external view returns (GraduationFloorResultV2 memory);
}

/// @notice Flap Pool Launch Preparation factory (docs: Portal only calls newPreparation + factorySpecVersion).
interface IPreparationFactory {
    function newPreparation(bytes calldata data) external payable returns (address preparation, uint16 multiplierBps);
    function factorySpecVersion() external pure returns (string memory); // must be "plp-v1"
}

/// @notice Flap Pool Launch distribution strategy interface (Portal approves `amount`, strategy pulls it).
interface IStrategy {
    function initializeDistribution(address token, uint256 amount, bytes calldata configData, bytes32 salt) external;
}

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}
