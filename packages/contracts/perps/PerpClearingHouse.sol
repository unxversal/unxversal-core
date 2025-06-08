// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import "../common/interfaces/IOracleRelayer.sol";
import "./libraries/FundingRateLib.sol";
import "./interfaces/IPerpsFeeCollector.sol";
import "./interfaces/ISpotPriceOracle.sol";
import "./interfaces/IPerpClearingHouse.sol";

/**
 * @title PerpClearingHouse
 * @author Unxversal Team
 * @notice Central clearinghouse for perpetual futures with cross-margin accounts, funding rates, and liquidations
 * @dev Simplified position accounting, proper risk controls, flash liquidation support, and USDC-denominated fees
 */
contract PerpClearingHouse is Ownable, ReentrancyGuard, Pausable, IPerpClearingHouse {
    using SafeERC20 for IERC20;
    using Strings for uint256;
    using EnumerableSet for EnumerableSet.Bytes32Set;

    // --- Constants ---
    uint256 public constant USDC_DECIMALS = 6;
    uint256 public constant PRICE_PRECISION = 1e18;
    uint256 public constant BPS_PRECISION = 10000;
    uint256 public constant MAX_LEVERAGE = 25; // 25x max leverage
    uint256 public constant MIN_MARGIN_RATIO = 400; // 4% minimum maintenance margin
    uint256 public constant MAX_POSITION_SIZE = 10_000_000 * 1e6; // $10M max position per market

    // --- Structs ---
    struct MarketConfig {
        bool isListed;
        bool isActive;
        uint256 oracleAssetId;
        ISpotPriceOracle spotOracle;
        uint256 maxLeverageBps;          // e.g., 2000 for 20x leverage
        uint256 maintenanceMarginBps;     // e.g., 500 for 5% maintenance margin
        uint256 liquidationFeeBps;        // e.g., 250 for 2.5% liquidation fee
        uint256 takerFeeBps;             // e.g., 10 for 0.1% taker fee
        int256 makerFeeBps;              // e.g., -5 for 0.05% maker rebate
        uint256 fundingIntervalSec;      // e.g., 3600 for 1 hour
        uint256 maxFundingRateBps;       // e.g., 75 for 0.75% max funding rate per interval
        uint256 fundingProtocolFeeBps;   // e.g., 1000 for 10% of funding fees to protocol
        uint256 minPositionSizeUsdc;     // Minimum position size in USDC
        uint256 maxPositionSizeUsdc;     // Maximum position size in USDC
    }

    struct MarketState {
        int256 cumulativeFundingIndex;   // Cumulative funding rate index (1e18 precision)
        uint256 lastFundingTime;         // Last funding settlement timestamp
        uint256 longOpenInterest;        // Total long open interest in USDC
        uint256 shortOpenInterest;       // Total short open interest in USDC
        uint256 nextFundingTime;         // Next scheduled funding time
    }

    struct Position {
        int256 sizeUsdc;                 // Position size in USDC (positive = long, negative = short)
        uint256 entryPrice;              // Average entry price (1e18 precision)
        int256 lastFundingIndex;         // Last funding index when position was updated
        uint256 lastUpdateTime;          // Last position update timestamp
        uint256 collateralUsdc;          // Allocated collateral for this position
    }

    struct Account {
        uint256 totalCollateralUsdc;     // Total USDC collateral balance
        mapping(bytes32 => Position) positions;
        EnumerableSet.Bytes32Set openMarkets;
    }

    // --- State Variables ---
    IERC20 public immutable usdcToken;
    IOracleRelayer public markPriceOracle;
    IPerpsFeeCollector public feeCollector;
    address public treasuryAddress;
    address public insuranceFundAddress;
    address public liquidationEngineAddress;

    mapping(bytes32 => MarketConfig) public markets;
    mapping(bytes32 => MarketState) public marketStates;
    mapping(address => Account) private accounts;

    bytes32[] public listedMarkets;
    mapping(bytes32 => uint256) public marketIndex; // marketId => index in listedMarkets

    // Treasury fee collection
    uint256 public collectedTreasuryFees;

    // --- Events ---
    event MarketListed(bytes32 indexed marketId, uint256 oracleAssetId, address spotOracle);
    event MarketConfigUpdated(bytes32 indexed marketId);
    event MarginDeposited(address indexed trader, uint256 amountUsdc);
    event MarginWithdrawn(address indexed trader, uint256 amountUsdc);
    event PositionChanged(
        address indexed trader,
        bytes32 indexed marketId,
        int256 newSizeUsdc,
        uint256 newEntryPrice,
        int256 realizedPnlUsdc,
        uint256 tradeFeeUsdc
    );
    event FundingRateCalculated(bytes32 indexed marketId, int256 fundingRate, uint256 timestamp);
    event FundingPaymentApplied(
        address indexed trader,
        bytes32 indexed marketId,
        int256 paymentUsdc,
        int256 positionSize
    );
    event PositionLiquidatedByEngine(
        address indexed trader,
        bytes32 indexed marketId,
        address indexed liquidator,
        int256 closedSizeUsdc,
        uint256 closePrice,
        uint256 liquidationFee,
        int256 realizedPnl
    );
    event TreasuryFeesCollected(uint256 amountUsdc);
    event ConfigurationUpdated(string indexed configType, address indexed newAddress);

    // --- Modifiers ---
    modifier onlyActiveMarket(bytes32 marketId) {
        require(markets[marketId].isListed && markets[marketId].isActive, "PCH: Market not active");
        _;
    }

    modifier onlyLiquidationEngine() {
        require(msg.sender == liquidationEngineAddress, "PCH: Not liquidation engine");
        _;
    }

    constructor(
        address _usdcToken,
        address _markPriceOracle,
        address _feeCollector,
        address _treasuryAddress,
        address _insuranceFundAddress,
        address _owner
    ) Ownable(_owner) {
        require(_usdcToken != address(0), "PCH: Zero USDC token");
        require(_markPriceOracle != address(0), "PCH: Zero oracle");
        require(_treasuryAddress != address(0), "PCH: Zero treasury");
        require(_insuranceFundAddress != address(0), "PCH: Zero insurance fund");

        usdcToken = IERC20(_usdcToken);
        markPriceOracle = IOracleRelayer(_markPriceOracle);
        feeCollector = IPerpsFeeCollector(_feeCollector);
        treasuryAddress = _treasuryAddress;
        insuranceFundAddress = _insuranceFundAddress;
    }

    // --- Admin Functions ---
    function setMarkPriceOracle(address _oracle) external onlyOwner {
        require(_oracle != address(0), "PCH: Zero oracle");
        markPriceOracle = IOracleRelayer(_oracle);
        emit ConfigurationUpdated("oracle", _oracle);
    }

    function setFeeCollector(address _feeCollector) external onlyOwner {
        feeCollector = IPerpsFeeCollector(_feeCollector);
        emit ConfigurationUpdated("feeCollector", _feeCollector);
    }

    function setTreasuryAddress(address _treasury) external onlyOwner {
        require(_treasury != address(0), "PCH: Zero treasury");
        treasuryAddress = _treasury;
        emit ConfigurationUpdated("treasury", _treasury);
    }

    function setInsuranceFundAddress(address _insuranceFund) external onlyOwner {
        require(_insuranceFund != address(0), "PCH: Zero insurance fund");
        insuranceFundAddress = _insuranceFund;
        emit ConfigurationUpdated("insuranceFund", _insuranceFund);
    }

    function setLiquidationEngineAddress(address _liquidationEngine) external onlyOwner {
        require(_liquidationEngine != address(0), "PCH: Zero liquidation engine");
        liquidationEngineAddress = _liquidationEngine;
        emit ConfigurationUpdated("liquidationEngine", _liquidationEngine);
    }

    function listMarket(
        bytes32 marketId,
        uint256 oracleAssetId,
        address spotOracle,
        uint256 maxLeverageBps,
        uint256 maintenanceMarginBps,
        uint256 liquidationFeeBps,
        uint256 takerFeeBps,
        int256 makerFeeBps,
        uint256 fundingIntervalSec,
        uint256 maxFundingRateBps,
        uint256 fundingProtocolFeeBps,
        uint256 minPositionSizeUsdc
    ) external onlyOwner {
        require(marketId != bytes32(0), "PCH: Zero market ID");
        require(!markets[marketId].isListed, "PCH: Market already listed");
        require(spotOracle != address(0), "PCH: Zero spot oracle");
        require(maxLeverageBps <= MAX_LEVERAGE * 100, "PCH: Leverage too high");
        require(maintenanceMarginBps >= MIN_MARGIN_RATIO, "PCH: Margin too low");
        require(liquidationFeeBps <= maintenanceMarginBps, "PCH: Liq fee too high");
        require(takerFeeBps <= 100, "PCH: Taker fee too high"); // Max 1%
        require(makerFeeBps >= -50 && makerFeeBps <= 100, "PCH: Invalid maker fee"); // Max 0.5% rebate, 1% fee
        require(fundingIntervalSec >= 3600, "PCH: Funding interval too short"); // Min 1 hour
        require(maxFundingRateBps <= 75, "PCH: Max funding rate too high"); // Max 0.75%
        require(fundingProtocolFeeBps <= 2500, "PCH: Protocol fee too high"); // Max 25%
        require(minPositionSizeUsdc >= 10 * 1e6, "PCH: Min position too small"); // Min $10

        markets[marketId] = MarketConfig({
            isListed: true,
            isActive: true,
            oracleAssetId: oracleAssetId,
            spotOracle: ISpotPriceOracle(spotOracle),
            maxLeverageBps: maxLeverageBps,
            maintenanceMarginBps: maintenanceMarginBps,
            liquidationFeeBps: liquidationFeeBps,
            takerFeeBps: takerFeeBps,
            makerFeeBps: makerFeeBps,
            fundingIntervalSec: fundingIntervalSec,
            maxFundingRateBps: maxFundingRateBps,
            fundingProtocolFeeBps: fundingProtocolFeeBps,
            minPositionSizeUsdc: minPositionSizeUsdc,
            maxPositionSizeUsdc: MAX_POSITION_SIZE
        });

        marketStates[marketId] = MarketState({
            cumulativeFundingIndex: 0,
            lastFundingTime: block.timestamp,
            longOpenInterest: 0,
            shortOpenInterest: 0,
            nextFundingTime: block.timestamp + fundingIntervalSec
        });

        marketIndex[marketId] = listedMarkets.length;
        listedMarkets.push(marketId);

        emit MarketListed(marketId, oracleAssetId, spotOracle);
    }

    function setMarketActive(bytes32 marketId, bool active) external onlyOwner {
        require(markets[marketId].isListed, "PCH: Market not listed");
        markets[marketId].isActive = active;
        emit MarketConfigUpdated(marketId);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // --- User Functions ---
    function depositMargin(uint256 amountUsdc) external nonReentrant whenNotPaused {
        require(amountUsdc > 0, "PCH: Zero deposit");
        
        usdcToken.safeTransferFrom(msg.sender, address(this), amountUsdc);
        accounts[msg.sender].totalCollateralUsdc += amountUsdc;
        
        emit MarginDeposited(msg.sender, amountUsdc);
    }

    function withdrawMargin(uint256 amountUsdc) external nonReentrant whenNotPaused {
        require(amountUsdc > 0, "PCH: Zero withdrawal");
        
        Account storage account = accounts[msg.sender];
        require(account.totalCollateralUsdc >= amountUsdc, "PCH: Insufficient balance");

        // Check that withdrawal won't violate maintenance margin requirements
        uint256 totalMarginRequired = _calculateTotalMaintenanceMargin(msg.sender);
        int256 totalUnrealizedPnl = _calculateTotalUnrealizedPnl(msg.sender);
        
        int256 marginAfterWithdrawal = int256(account.totalCollateralUsdc - amountUsdc) + totalUnrealizedPnl;
        require(marginAfterWithdrawal >= int256(totalMarginRequired), "PCH: Withdrawal violates margin");

        account.totalCollateralUsdc -= amountUsdc;
        usdcToken.safeTransfer(msg.sender, amountUsdc);
        
        emit MarginWithdrawn(msg.sender, amountUsdc);
    }

    function fillMatchedOrder(MatchedOrderFillData calldata fill) 
        external 
        nonReentrant 
        whenNotPaused 
        onlyActiveMarket(fill.marketId) 
    {
        require(fill.maker != msg.sender && fill.maker != address(0), "PCH: Invalid maker");
        require(fill.sizeNotionalUsd != 0, "PCH: Zero size");
        require(fill.price1e18 > 0, "PCH: Zero price");

        MarketConfig storage market = markets[fill.marketId];
        uint256 absSize = uint256(fill.sizeNotionalUsd > 0 ? fill.sizeNotionalUsd : -fill.sizeNotionalUsd);
        require(absSize >= market.minPositionSizeUsdc, "PCH: Position too small");

        // Check margin requirements for both parties
        _checkMarginRequirements(msg.sender, fill.marketId, fill.sizeNotionalUsd);
        _checkMarginRequirements(fill.maker, fill.marketId, -fill.sizeNotionalUsd);

        // Settle funding for both traders
        _settleFunding(msg.sender, fill.marketId);
        _settleFunding(fill.maker, fill.marketId);

        // Execute trades
        (int256 takerPnl, uint256 takerFee) = _updatePosition(
            msg.sender, fill.marketId, fill.sizeNotionalUsd, fill.price1e18, true, false
        );
        (int256 makerPnl, uint256 makerFee) = _updatePosition(
            fill.maker, fill.marketId, -fill.sizeNotionalUsd, fill.price1e18, false, false
        );

        // Apply PnL and collect fees
        _applyPnl(msg.sender, takerPnl);
        _applyPnl(fill.maker, makerPnl);
        
        if (takerFee > 0) _collectTradeFee(msg.sender, takerFee, true);
        if (makerFee > 0) _collectTradeFee(fill.maker, makerFee, false);

        // Update market open interest
        _updateOpenInterest(fill.marketId, fill.sizeNotionalUsd);
    }

    function settleMarketFunding(bytes32 marketId) external nonReentrant onlyActiveMarket(marketId) {
        MarketState storage state = marketStates[marketId];
        require(block.timestamp >= state.nextFundingTime, "PCH: Funding not due");

        MarketConfig storage market = markets[marketId];
        
        // Get mark and index prices
        uint256 markPrice = markPriceOracle.getPrice(market.oracleAssetId);
        uint256 indexPrice = market.spotOracle.getPrice();
        
        // Calculate funding rate
        FundingRateLib.FundingParams memory params = FundingRateLib.FundingParams({
            fundingIntervalSeconds: market.fundingIntervalSec,
            maxFundingRateAbsValue: (market.maxFundingRateBps * PRICE_PRECISION) / BPS_PRECISION
        });
        
        int256 fundingRate = FundingRateLib.calculateNextFundingRate(markPrice, indexPrice, params);
        
        // Update cumulative funding index
        state.cumulativeFundingIndex += fundingRate;
        state.lastFundingTime = block.timestamp;
        state.nextFundingTime = block.timestamp + market.fundingIntervalSec;
        
        emit FundingRateCalculated(marketId, fundingRate, block.timestamp);
    }

    // --- Liquidation Hook ---
    function processLiquidation(
        address trader,
        bytes32 marketId,
        int256 sizeToCloseNotionalUsd,
        uint256 closePrice1e18,
        uint256 totalLiquidationFeeUsdc
    ) external nonReentrant onlyLiquidationEngine returns (int256 realizedPnlOnCloseUsdc) {
        require(markets[marketId].isListed, "PCH: Market not listed");
        
        // Settle funding before liquidation
        _settleFunding(trader, marketId);
        
        // Execute liquidation trade
        (realizedPnlOnCloseUsdc,) = _updatePosition(
            trader, marketId, sizeToCloseNotionalUsd, closePrice1e18, true, true
        );
        
        // Apply PnL
        _applyPnl(trader, realizedPnlOnCloseUsdc);
        
        // Deduct liquidation fee
        Account storage account = accounts[trader];
        require(account.totalCollateralUsdc >= totalLiquidationFeeUsdc, "PCH: Insufficient margin");
        account.totalCollateralUsdc -= totalLiquidationFeeUsdc;
        
        // Send fee to fee collector for distribution
        if (totalLiquidationFeeUsdc > 0 && address(feeCollector) != address(0)) {
            usdcToken.safeTransfer(address(feeCollector), totalLiquidationFeeUsdc);
        }
        
        // Update open interest
        _updateOpenInterest(marketId, sizeToCloseNotionalUsd);
        
        emit PositionLiquidatedByEngine(
            trader, marketId, msg.sender, sizeToCloseNotionalUsd, 
            closePrice1e18, totalLiquidationFeeUsdc, realizedPnlOnCloseUsdc
        );
        
        return realizedPnlOnCloseUsdc;
    }

    // --- Internal Functions ---
    function _checkMarginRequirements(address trader, bytes32 marketId, int256 tradeSize) internal view {
        Account storage account = accounts[trader];
        uint256 currentMarginReq = _calculateTotalMaintenanceMargin(trader);
        uint256 additionalMarginReq = _calculateAdditionalMarginRequirement(marketId, tradeSize);
        
        int256 totalUnrealizedPnl = _calculateTotalUnrealizedPnl(trader);
        int256 availableMargin = int256(account.totalCollateralUsdc) + totalUnrealizedPnl;
        
        require(availableMargin >= int256(currentMarginReq + additionalMarginReq), "PCH: Insufficient margin");
    }

    function _calculateAdditionalMarginRequirement(bytes32 marketId, int256 tradeSize) internal view returns (uint256) {
        if (tradeSize == 0) return 0;
        
        MarketConfig storage market = markets[marketId];
        uint256 absTradeSize = uint256(tradeSize > 0 ? tradeSize : -tradeSize);
        
        // Calculate margin requirement based on leverage
        return Math.mulDiv(absTradeSize, BPS_PRECISION, market.maxLeverageBps);
    }

    function _settleFunding(address trader, bytes32 marketId) internal {
        Account storage account = accounts[trader];
        Position storage position = account.positions[marketId];
        
        if (position.sizeUsdc == 0) return;
        
        MarketState storage state = marketStates[marketId];
        int256 fundingDelta = state.cumulativeFundingIndex - position.lastFundingIndex;
        
        if (fundingDelta != 0) {
            int256 fundingPayment = (position.sizeUsdc * fundingDelta) / int256(PRICE_PRECISION);
            
            if (fundingPayment > 0) {
                // Trader pays funding
                uint256 payment = uint256(fundingPayment);
                if (account.totalCollateralUsdc >= payment) {
                    account.totalCollateralUsdc -= payment;
                } else {
                    account.totalCollateralUsdc = 0;
                }
            } else if (fundingPayment < 0) {
                // Trader receives funding
                account.totalCollateralUsdc += uint256(-fundingPayment);
            }
            
            position.lastFundingIndex = state.cumulativeFundingIndex;
            
            emit FundingPaymentApplied(trader, marketId, fundingPayment, position.sizeUsdc);
        }
    }

    function _updatePosition(
        address trader,
        bytes32 marketId,
        int256 tradeSize,
        uint256 price,
        bool isTaker,
        bool isLiquidation
    ) internal returns (int256 realizedPnl, uint256 tradeFee) {
        Account storage account = accounts[trader];
        Position storage position = account.positions[marketId];
        MarketConfig storage market = markets[marketId];
        
        int256 oldSize = position.sizeUsdc;
        int256 newSize = oldSize + tradeSize;
        uint256 absTradeSize = uint256(tradeSize > 0 ? tradeSize : -tradeSize);
        
        // Calculate trade fee
        if (!isLiquidation) {
            if (isTaker) {
                tradeFee = Math.mulDiv(absTradeSize, market.takerFeeBps, BPS_PRECISION);
            } else if (market.makerFeeBps > 0) {
                tradeFee = Math.mulDiv(absTradeSize, uint256(market.makerFeeBps), BPS_PRECISION);
            }
            // Note: negative maker fees (rebates) are handled as negative realized PnL
        }
        
        // Calculate realized PnL for position changes
        if (oldSize != 0 && (oldSize > 0) != (tradeSize > 0)) {
            // Position is being reduced or flipped
            uint256 reduceSize = Math.min(absTradeSize, uint256(oldSize > 0 ? oldSize : -oldSize));
            realizedPnl = _calculateRealizedPnl(oldSize, reduceSize, position.entryPrice, price);
        }
        
        // Update position
        if (newSize == 0) {
            // Position closed
            position.sizeUsdc = 0;
            position.entryPrice = 0;
            position.collateralUsdc = 0;
            account.openMarkets.remove(marketId);
        } else {
            // Position opened or modified
            if (oldSize == 0 || (oldSize > 0) != (newSize > 0)) {
                // New position or flipped position
                position.entryPrice = price;
                if (!account.openMarkets.contains(marketId)) {
                    account.openMarkets.add(marketId);
                }
            } else if ((oldSize > 0) == (newSize > 0) && absTradeSize > uint256(oldSize > 0 ? oldSize : -oldSize)) {
                // Position increased in same direction - update weighted average entry price
                uint256 oldAbsSize = uint256(oldSize > 0 ? oldSize : -oldSize);
                uint256 addedSize = absTradeSize - oldAbsSize;
                position.entryPrice = ((position.entryPrice * oldAbsSize) + (price * addedSize)) / uint256(newSize > 0 ? newSize : -newSize);
            }
            
            position.sizeUsdc = newSize;
        }
        
        position.lastUpdateTime = block.timestamp;
        position.lastFundingIndex = marketStates[marketId].cumulativeFundingIndex;
        
        // Handle maker rebates as negative fees (positive PnL)
        if (!isLiquidation && !isTaker && market.makerFeeBps < 0) {
            uint256 rebate = Math.mulDiv(absTradeSize, uint256(-market.makerFeeBps), BPS_PRECISION);
            realizedPnl += int256(rebate);
        }
        
        emit PositionChanged(trader, marketId, newSize, position.entryPrice, realizedPnl, tradeFee);
    }

    function _calculateRealizedPnl(
        int256 positionSize,
        uint256 reduceSize,
        uint256 entryPrice,
        uint256 exitPrice
    ) internal pure returns (int256) {
        if (positionSize == 0 || reduceSize == 0 || entryPrice == 0) return 0;
        
        int256 priceDiff = int256(exitPrice) - int256(entryPrice);
        int256 realizedAmount = positionSize > 0 ? int256(reduceSize) : -int256(reduceSize);
        
        return (realizedAmount * priceDiff) / int256(PRICE_PRECISION);
    }

    function _applyPnl(address trader, int256 pnl) internal {
        Account storage account = accounts[trader];
        
        if (pnl > 0) {
            account.totalCollateralUsdc += uint256(pnl);
        } else if (pnl < 0) {
            uint256 loss = uint256(-pnl);
            if (account.totalCollateralUsdc >= loss) {
                account.totalCollateralUsdc -= loss;
            } else {
                account.totalCollateralUsdc = 0;
            }
        }
    }

    function _collectTradeFee(address trader, uint256 feeAmount, bool /*isTaker*/) internal {
        Account storage account = accounts[trader];
        require(account.totalCollateralUsdc >= feeAmount, "PCH: Insufficient balance for fee");
        
        account.totalCollateralUsdc -= feeAmount;
        
        // 80% to treasury, 20% to insurance fund
        uint256 treasuryFee = Math.mulDiv(feeAmount, 8000, BPS_PRECISION);
        uint256 insuranceFee = feeAmount - treasuryFee;
        
        collectedTreasuryFees += treasuryFee;
        
        if (insuranceFee > 0) {
            usdcToken.safeTransfer(insuranceFundAddress, insuranceFee);
        }
    }

    function _updateOpenInterest(bytes32 marketId, int256 tradeSize) internal {
        MarketState storage state = marketStates[marketId];
        
        if (tradeSize > 0) {
            state.longOpenInterest += uint256(tradeSize);
        } else {
            state.shortOpenInterest += uint256(-tradeSize);
        }
    }

    function _calculateTotalMaintenanceMargin(address trader) internal view returns (uint256 totalMargin) {
        Account storage account = accounts[trader];
        
        for (uint256 i = 0; i < account.openMarkets.length(); i++) {
            bytes32 marketId = account.openMarkets.at(i);
            Position storage position = account.positions[marketId];
            MarketConfig storage market = markets[marketId];
            
            if (position.sizeUsdc != 0) {
                uint256 positionValue = uint256(position.sizeUsdc > 0 ? position.sizeUsdc : -position.sizeUsdc);
                totalMargin += Math.mulDiv(positionValue, market.maintenanceMarginBps, BPS_PRECISION);
            }
        }
    }

    function _calculateTotalUnrealizedPnl(address trader) internal view returns (int256 totalPnl) {
        Account storage account = accounts[trader];
        
        for (uint256 i = 0; i < account.openMarkets.length(); i++) {
            bytes32 marketId = account.openMarkets.at(i);
            Position storage position = account.positions[marketId];
            
            if (position.sizeUsdc != 0) {
                MarketConfig storage market = markets[marketId];
                uint256 markPrice = markPriceOracle.getPrice(market.oracleAssetId);
                
                int256 priceDiff = int256(markPrice) - int256(position.entryPrice);
                totalPnl += (position.sizeUsdc * priceDiff) / int256(PRICE_PRECISION);
            }
        }
    }

    // --- View Functions ---
    function getTraderCollateralBalance(address trader) external view returns (uint256) {
        return accounts[trader].totalCollateralUsdc;
    }

    function getAccountSummary(address trader) external view returns (
        uint256 usdcCollateral,
        int256 totalUnrealizedPnlUsdc,
        uint256 totalMarginBalanceUsdc,
        uint256 totalMaintenanceMarginReqUsdc,
        uint256 totalInitialMarginReqUsdc,
        bool isCurrentlyLiquidatable
    ) {
        Account storage account = accounts[trader];
        usdcCollateral = account.totalCollateralUsdc;
        totalUnrealizedPnlUsdc = _calculateTotalUnrealizedPnl(trader);
        totalMaintenanceMarginReqUsdc = _calculateTotalMaintenanceMargin(trader);
        
        int256 marginBalance = int256(usdcCollateral) + totalUnrealizedPnlUsdc;
        totalMarginBalanceUsdc = marginBalance > 0 ? uint256(marginBalance) : 0;
        
        // Calculate initial margin requirement (based on leverage)
        for (uint256 i = 0; i < account.openMarkets.length(); i++) {
            bytes32 marketId = account.openMarkets.at(i);
            Position storage position = account.positions[marketId];
            MarketConfig storage market = markets[marketId];
            
            if (position.sizeUsdc != 0) {
                uint256 positionValue = uint256(position.sizeUsdc > 0 ? position.sizeUsdc : -position.sizeUsdc);
                totalInitialMarginReqUsdc += Math.mulDiv(positionValue, BPS_PRECISION, market.maxLeverageBps);
            }
        }
        
        isCurrentlyLiquidatable = totalMarginBalanceUsdc < totalMaintenanceMarginReqUsdc && totalMaintenanceMarginReqUsdc > 0;
    }

    function getListedMarketIds() external view returns (bytes32[] memory) {
        return listedMarkets;
    }

    function isMarketActuallyListed(bytes32 marketId) external view returns (bool) {
        return markets[marketId].isListed;
    }

    function getTraderPosition(address trader, bytes32 marketId) external view returns (
        int256 sizeUsdc,
        uint256 entryPrice,
        int256 unrealizedPnl,
        uint256 marginRequired
    ) {
        Position storage position = accounts[trader].positions[marketId];
        sizeUsdc = position.sizeUsdc;
        entryPrice = position.entryPrice;
        
        if (sizeUsdc != 0) {
            MarketConfig storage market = markets[marketId];
            uint256 markPrice = markPriceOracle.getPrice(market.oracleAssetId);
            
            int256 priceDiff = int256(markPrice) - int256(entryPrice);
            unrealizedPnl = (sizeUsdc * priceDiff) / int256(PRICE_PRECISION);
            
            uint256 positionValue = uint256(sizeUsdc > 0 ? sizeUsdc : -sizeUsdc);
            marginRequired = Math.mulDiv(positionValue, market.maintenanceMarginBps, BPS_PRECISION);
        }
    }

    // --- Treasury Functions ---
    function collectTreasuryFees() external nonReentrant {
        require(collectedTreasuryFees > 0, "PCH: No fees to collect");
        
        uint256 amount = collectedTreasuryFees;
        collectedTreasuryFees = 0;
        
        usdcToken.safeTransfer(treasuryAddress, amount);
        emit TreasuryFeesCollected(amount);
    }
}