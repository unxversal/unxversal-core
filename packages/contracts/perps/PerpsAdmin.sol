// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../common/access/ProtocolAdminAccess.sol"; // Inherits Ownable
import "./PerpClearingHouse.sol";
import "./PerpLiquidationEngine.sol";
import "../common/interfaces/IOracleRelayer.sol";
// import "./PerpsFeeSwitch.sol"; // Assuming no separate fee switch for now; CH handles.

/**
 * @title PerpsAdmin
 * @author Unxversal Team
 * @notice Administrative module for the Unxversal Perpetual Futures protocol.
 * @dev Manages parameters for PerpClearingHouse, individual PerpMarkets within it,
 *      and the PerpLiquidationEngine. Owned by a multisig or DAO Timelock.
 *      This contract becomes the owner of PerpClearingHouse and PerpLiquidationEngine.
 */
contract PerpsAdmin is ProtocolAdminAccess {
    PerpClearingHouse public perpClearingHouse;
    PerpLiquidationEngine public perpLiquidationEngine;
    IOracleRelayer public oracleRelayer; // Reference to the oracle for configuring CH

    // --- Events ---
    event PerpClearingHouseSet(address indexed clearingHouseAddress);
    event PerpLiquidationEngineSet(address indexed engineAddress);
    event OracleRelayerSetForPerps(address indexed newOracleAddress);
    // Market and specific parameter configuration events are emitted by PerpClearingHouse/PerpLiquidationEngine.

    constructor(
        address _initialOwner,
        address _perpClearingHouseAddress,
        address _perpLiquidationEngineAddress,
        address _oracleRelayerAddress
    ) ProtocolAdminAccess(_initialOwner) {
        // It's crucial that after these contracts are deployed, their ownership
        // is transferred to this PerpsAdmin contract.
        // These setters just store the addresses for this admin contract to use.
        setPerpClearingHouse(_perpClearingHouseAddress); // Emits event
        setPerpLiquidationEngine(_perpLiquidationEngineAddress); // Emits event
        setOracleRelayerForPerps(_oracleRelayerAddress); // Emits event
    }

    // --- Target Contract Address Management (by PerpsAdmin Owner) ---
    function setPerpClearingHouse(address _newAddress) public onlyOwner {
        require(_newAddress != address(0), "PerpsAdmin: Zero ClearingHouse");
        perpClearingHouse = PerpClearingHouse(_newAddress);
        emit PerpClearingHouseSet(_newAddress);
    }

    function setPerpLiquidationEngine(address _newAddress) public onlyOwner {
        require(_newAddress != address(0), "PerpsAdmin: Zero LiquidationEngine");
        perpLiquidationEngine = PerpLiquidationEngine(_newAddress);
        emit PerpLiquidationEngineSet(_newAddress);
    }

    function setOracleRelayerForPerps(address _newAddress) public onlyOwner {
        require(_newAddress != address(0), "PerpsAdmin: Zero OracleRelayer");
        oracleRelayer = IOracleRelayer(_newAddress);
        // Ensure PerpClearingHouse is updated if it's already set
        if (address(perpClearingHouse) != address(0)) {
            // PerpClearingHouse must have `setOracle(address)` and be owned by this admin contract
            perpClearingHouse.setMarkPriceOracle(_newAddress);
        }
        emit OracleRelayerSetForPerps(_newAddress);
    }

    // --- PerpClearingHouse Market Configuration (Delegated Calls) ---
    // Assumes PerpClearingHouse has these functions and is owned by this PerpsAdmin.
    
    /**
     * @notice Lists a new market or updates parameters of an existing one in PerpClearingHouse.
     * @param marketId Unique identifier for the market (e.g., keccak256("BTC-PERP")).
     * @param underlyingAssetIdOracle Asset ID for fetching mark price from IOracleRelayer.
     * @param spotIndexOracleAddress Address of the oracle for fetching spot price.
     * @param maxLeverage Max leverage allowed, e.g., 2000 for 20x (scaled by 100).
     * @param imrBps Initial Margin Ratio in BPS (e.g., 500 for 5%).
     * @param liqFeeBps Liquidation Fee (penalty on remaining margin) in BPS.
     * @param takerTradeFeeBps Taker trade fee in BPS.
     * @param makerTradeFeeBps Maker trade fee in BPS (can be negative for rebate).
     */
    function configureMarketDetails(
        bytes32 marketId, // Using bytes32 for marketId
        uint256 underlyingAssetIdOracle,
        address spotIndexOracleAddress,
        uint256 maxLeverage,
        uint256 imrBps,
        uint256 /* mmrBps */,
        uint256 liqFeeBps,
        int256 takerTradeFeeBps,
        int256 makerTradeFeeBps,
        bool /* isActive */
    ) external onlyOwner {
        require(address(perpClearingHouse) != address(0), "PerpsAdmin: ClearingHouse not set");
        perpClearingHouse.listMarket(
            marketId,
            underlyingAssetIdOracle,
            spotIndexOracleAddress,
            maxLeverage,
            imrBps, // maintenanceMarginBps
            liqFeeBps, // liquidationFeeBps
            uint256(takerTradeFeeBps), // takerFeeBps
            int256(makerTradeFeeBps), // makerFeeBps
            3600, // fundingIntervalSec (1 hour default)
            75, // maxFundingRateBps (0.75% default)
            1000, // fundingProtocolFeeBps (10% default)
            10 * 1e6 // minPositionSizeUsdc ($10 minimum)
        );
    }

    /**
     * @notice Sets funding parameters for a specific market in PerpClearingHouse.
     * @dev TODO: Implement funding parameter updates in PerpClearingHouse.
     */
    function setMarketFundingParams(
        bytes32 /* marketId */,
        uint256 /* fundingIntervalSeconds */,
        uint256 /* maxFundingRateAbsValue */, // 1e18 scaled, e.g., 0.001e18 for 0.1%
        uint256 /* fundingFeeBps */ // Protocol's cut of funding
    ) external view onlyOwner {
        require(address(perpClearingHouse) != address(0), "PerpsAdmin: ClearingHouse not set");
        // TODO: Implement funding parameter updates in PerpClearingHouse
        // perpClearingHouse.setMarketFundingParameters(
        //     marketId, fundingIntervalSeconds, maxFundingRateAbsValue, fundingFeeBps
        // );
    }

    function setMarketSpotIndexOracle(bytes32 /* marketId */, address /* spotIndexOracleAddress */) external view onlyOwner {
        require(address(perpClearingHouse) != address(0), "PerpsAdmin: ClearingHouse not set");
        // TODO: Implement spot index oracle updates in PerpClearingHouse
        // PerpClearingHouse needs: setSpotIndexOracle(bytes32 marketId, address spotOracle)
        // The spotOracle could be a TWAP from Unxversal DEX or another source.
        // perpClearingHouse.setMarketSpotIndexOracle(marketId, spotIndexOracleAddress);
    }

    // --- PerpLiquidationEngine Configuration (Delegated Calls) ---
    // Assumes PerpLiquidationEngine has these functions and is owned by this PerpsAdmin.

    /**
     * @notice Configures parameters for the PerpLiquidationEngine.
     * @param _insuranceFund Address of the insurance fund.
     * @dev Other parameters are currently unused:
     *      - _liquidatorShareOfLiqFeeBps: Liquidator share is passed per liquidation in processLiquidationFee
     *      - _maxOpenInterestToLiquidateBps: Not implemented yet
     */
    function configurePerpLiquidationEngine(
        address _insuranceFund,
        uint256 /* _liquidatorShareOfLiqFeeBps */,
        uint256 /* _maxOpenInterestToLiquidateBps */ // Example additional param
    ) external onlyOwner {
        require(address(perpClearingHouse) != address(0), "PerpsAdmin: ClearingHouse not set");
        require(address(perpLiquidationEngine) != address(0), "PerpsAdmin: Perp LE not set");
        
        // Set insurance fund in ClearingHouse
        perpClearingHouse.setInsuranceFundAddress(_insuranceFund);
        
        // Note: Liquidator share is passed per liquidation in processLiquidationFee
        // Note: maxOpenInterestToLiquidateBps is not implemented yet
        // perpLiquidationEngine.setMaxOpenInterestToLiquidateBps(_maxOpenInterestToLiquidateBps);
    }

    // --- Global Pause/Unpause for Perps Protocol ---
    // Assumes target contracts implement OZ Pausable and are owned by this PerpsAdmin.
    function pausePerpsProtocol() external onlyOwner {
        if (address(perpClearingHouse) != address(0) && !perpClearingHouse.paused()) {
            perpClearingHouse.pause();
        }
        if (address(perpLiquidationEngine) != address(0) && !perpLiquidationEngine.paused()) {
            perpLiquidationEngine.pauseEngine();
        }
    }

    function unpausePerpsProtocol() external onlyOwner {
        if (address(perpClearingHouse) != address(0) && perpClearingHouse.paused()) {
            perpClearingHouse.unpause();
        }
        if (address(perpLiquidationEngine) != address(0) && perpLiquidationEngine.paused()) {
            perpLiquidationEngine.unpauseEngine();
        }
    }

    // --- Ownership Transfers of Core Perps Contracts ---
    // Allows this PerpsAdmin (owned by DAO Timelock) to transfer ownership
    // of the underlying protocol contracts to a new admin (e.g., a new PerpsAdmin version or DAO).
    function transferClearingHouseOwnership(address newOwner) external onlyOwner {
        require(address(perpClearingHouse) != address(0), "PerpsAdmin: ClearingHouse not set");
        require(newOwner != address(0), "PerpsAdmin: New owner is zero address");
        perpClearingHouse.transferOwnership(newOwner);
    }

    function transferLiquidationEngineOwnership(address newOwner) external onlyOwner {
        require(address(perpLiquidationEngine) != address(0), "PerpsAdmin: Perp LE not set");
        require(newOwner != address(0), "PerpsAdmin: New owner is zero address");
        perpLiquidationEngine.transferOwnership(newOwner);
    }

    // --- Admin functions for core dependencies (if not set at target contract deployment) ---
    // These are for cases where target contracts (CH, LE) need their dependencies set by their owner (this contract)
    
    function setClearingHouseOracle(address _oracle) external onlyOwner {
        require(address(perpClearingHouse) != address(0), "PerpsAdmin: ClearingHouse not set");
        perpClearingHouse.setMarkPriceOracle(_oracle);
    }

    // Note: Fee recipient is managed through the PerpsFeeCollector contract
    // function setClearingHouseFeeRecipient(address _recipient) external onlyOwner {
    //     require(address(perpClearingHouse) != address(0), "PerpsAdmin: ClearingHouse not set");
    //     perpClearingHouse.setFeeRecipient(_recipient);
    // }

    function setClearingHouseLiquidationEngine(address _engine) external onlyOwner {
        require(address(perpClearingHouse) != address(0), "PerpsAdmin: ClearingHouse not set");
        // PerpClearingHouse needs setLiquidationEngine(address)
        perpClearingHouse.setLiquidationEngineAddress(_engine);
    }

    /**
     * @notice Sets core dependencies for the PerpLiquidationEngine
     * @param _ch Address of the PerpClearingHouse
     * @dev Other parameters are unused since dependencies are obtained through clearing house:
     *      - _oracle: Oracle is accessed through clearing house
     *      - _usdc: USDC token is accessed through clearing house
     */
    function setLiquidationEngineCoreDependencies(address _ch, address /* _oracle */, address /* _usdc */) external onlyOwner {
        require(address(perpLiquidationEngine) != address(0), "PerpsAdmin: Perp LE not set");
        // Note: Liquidation engine gets all dependencies through clearing house
        perpLiquidationEngine.setPerpClearingHouse(_ch);
    }
}