// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol"; // For decimals()
import "../common/interfaces/IOracleRelayer.sol";
import "./interfaces/ICorePool.sol";
import "./uToken.sol"; // To cast uToken address and call exchangeRateStored
import "../synth/SynthFactory.sol"; // Optional, for sAsset oracleAssetId resolution
// SafeDecimalMath is not strictly needed here if we use Math.mulDiv correctly for all price scaling.

/**
 * @title LendRiskController
 * @author Unxversal Team
 * @notice Manages risk parameters and calculates account health for Unxversal Lend.
 */
contract LendRiskController is Ownable {
    struct MarketRiskConfig {
        bool isListed;
        bool canBeCollateral;
        uint256 collateralFactorBps;    // e.g., 7500 for 75%
        uint256 liquidationThresholdBps;// e.g., 8000 for 80%
        uint256 liquidationBonusBps;    // e.g., 500 for 5%
        address uTokenAddress;
        uint256 oracleAssetId;          // Resolved ID for the oracle
        uint8 underlyingDecimals;       // Decimals of the underlying asset
    }

    mapping(address => MarketRiskConfig) public marketRiskConfigs; // underlyingAssetAddress => Config
    address[] public listedAssets;

    ICorePool public corePool;
    IOracleRelayer public oracle;
    SynthFactory public synthFactory; // Optional

    uint256 public constant BPS_DENOMINATOR = 10000;
    uint256 public constant PRICE_PRECISION = 1e18; // Oracle prices and internal USD values are 1e18 scaled
    uint256 public constant HEALTH_FACTOR_PRECISION = 1e18;

    event MarketListed(address indexed underlyingAsset, address indexed uToken, uint256 cfBps, uint256 ltBps);
    event MarketConfigUpdated(address indexed underlyingAsset, uint256 cfBps, uint256 ltBps, uint256 lqBonusBps);
    event OracleAssetIdSet(address indexed underlyingAsset, uint256 oracleAssetId);
    event CorePoolSet(address indexed corePoolAddress);
    event OracleSet(address indexed oracleAddress);
    event SynthFactorySet(address indexed factoryAddress);

    constructor(
        address _corePoolAddress, address _oracleAddress,
        address _synthFactoryAddress, address _initialOwner
    ) Ownable(_initialOwner) {
        setCorePool(_corePoolAddress); // Emits event
        setOracle(_oracleAddress);   // Emits event
        if (_synthFactoryAddress != address(0)) {
            setSynthFactory(_synthFactoryAddress); // Emits event
        }
    }

    function setCorePool(address _corePoolAddress) public onlyOwner {
        require(_corePoolAddress != address(0), "LRC: Zero CorePool");
        corePool = ICorePool(_corePoolAddress);
        emit CorePoolSet(_corePoolAddress);
    }

    function setOracle(address _oracleAddress) public onlyOwner {
        require(_oracleAddress != address(0), "LRC: Zero oracle");
        oracle = IOracleRelayer(_oracleAddress);
        emit OracleSet(_oracleAddress);
    }

    function setSynthFactory(address _factoryAddress) public onlyOwner {
        synthFactory = SynthFactory(_factoryAddress); // Allow address(0) to disable
        emit SynthFactorySet(_factoryAddress);
    }

    function listMarket(
        address underlyingAsset, address _uTokenAddress, bool _canBeCollateral,
        uint256 _cfBps, uint256 _ltBps, uint256 _lqBonusBps, uint256 _oracleAssetId
    ) external onlyOwner {
        require(underlyingAsset != address(0), "LRC: Zero underlying");
        require(_uTokenAddress != address(0), "LRC: Zero uToken");
        require(_cfBps <= _ltBps, "LRC: CF > LT");
        require(_ltBps <= BPS_DENOMINATOR, "LRC: LT too high");
        require(_lqBonusBps <= BPS_DENOMINATOR / 4, "LRC: Bonus too high"); // Max 25% bonus example

        MarketRiskConfig storage config = marketRiskConfigs[underlyingAsset];
        uint256 resolvedOracleId = _oracleAssetId;
        uint8 underlyingDecs = IERC20Metadata(underlyingAsset).decimals(); // Fetch decimals

        if (resolvedOracleId == 0 && address(synthFactory) != address(0) && synthFactory.isSynthRegistered(underlyingAsset)) {
            SynthFactory.SynthConfig memory synthConf = synthFactory.getSynthConfig(underlyingAsset);
            resolvedOracleId = synthConf.assetId;
        }
        require(resolvedOracleId != 0, "LRC: Oracle ID not resolved");

        if (!config.isListed) {
            config.isListed = true;
            listedAssets.push(underlyingAsset);
            emit MarketListed(underlyingAsset, _uTokenAddress, _cfBps, _ltBps);
        }
        
        config.uTokenAddress = _uTokenAddress;
        config.canBeCollateral = _canBeCollateral;
        config.collateralFactorBps = _cfBps;
        config.liquidationThresholdBps = _ltBps;
        config.liquidationBonusBps = _lqBonusBps;
        config.oracleAssetId = resolvedOracleId;
        config.underlyingDecimals = underlyingDecs;

        emit MarketConfigUpdated(underlyingAsset, _cfBps, _ltBps, _lqBonusBps);
        if (_oracleAssetId != resolvedOracleId || config.oracleAssetId != resolvedOracleId) { // If it changed
             emit OracleAssetIdSet(underlyingAsset, resolvedOracleId);
        }
    }
    
    function setMarketOracleAssetId(address underlyingAsset, uint256 newOracleAssetId) external onlyOwner {
        MarketRiskConfig storage config = marketRiskConfigs[underlyingAsset];
        require(config.isListed, "LRC: Market not listed");
        require(newOracleAssetId != 0, "LRC: Zero oracle assetId");
        config.oracleAssetId = newOracleAssetId;
        emit OracleAssetIdSet(underlyingAsset, newOracleAssetId);
    }

    function getAccountLiquidityValues(address user)
        public view
        returns (uint256 totalCollateralValueUsd, uint256 totalBorrowValueUsd)
    {
        require(address(corePool) != address(0) && address(oracle) != address(0), "LRC: Not initialized");

        address[] memory suppliedAssets = corePool.getAssetsUserSupplied(user);
        address[] memory borrowedAssets = corePool.getAssetsUserBorrowed(user);

        for (uint i = 0; i < suppliedAssets.length; i++) {
            address underlying = suppliedAssets[i];
            MarketRiskConfig storage config = marketRiskConfigs[underlying];
            if (config.isListed && config.canBeCollateral) {
                (uint256 uTokenBalance, ) = corePool.getUserSupplyAndBorrowBalance(user, underlying);
                if (uTokenBalance > 0) {
                    uToken uTokenContract = uToken(payable(config.uTokenAddress));
                    uint256 underlyingSupplied = Math.mulDiv(uTokenBalance, uTokenContract.exchangeRateStored(), PRICE_PRECISION);
                    uint256 price = oracle.getPrice(config.oracleAssetId); // Assumes price is 1e18 scaled USD per WHOLE unit
                    
                    uint256 supplyUsd = Math.mulDiv(underlyingSupplied, price, (10**config.underlyingDecimals));
                    uint256 collateralContrib = Math.mulDiv(supplyUsd, config.collateralFactorBps, BPS_DENOMINATOR);
                    totalCollateralValueUsd += collateralContrib;
                }
            }
        }

        for (uint i = 0; i < borrowedAssets.length; i++) {
            address underlying = borrowedAssets[i];
            MarketRiskConfig storage config = marketRiskConfigs[underlying]; // Must be listed if borrowed
            if(config.isListed){ // Should always be true
                (, uint256 borrowBalance) = corePool.getUserSupplyAndBorrowBalance(user, underlying);
                if (borrowBalance > 0) {
                    uint256 price = oracle.getPrice(config.oracleAssetId);
                    uint256 borrowUsd = Math.mulDiv(borrowBalance, price, (10**config.underlyingDecimals));
                    totalBorrowValueUsd += borrowUsd;
                }
            }
        }
    }

    function getAccountLiquidity(address user) public view returns (int256 liquidityUsd) {
        (uint256 collUsd, uint256 borrUsd) = getAccountLiquidityValues(user);
        if (collUsd >= borrUsd) {
            return int256(collUsd - borrUsd);
        } else {
            return -int256(borrUsd - collUsd);
        }
    }

    function getHealthFactor(address user) public view returns (uint256 healthFactor) {
        (uint256 collUsd, uint256 borrUsd) = getAccountLiquidityValues(user);
        if (borrUsd == 0) return type(uint256).max; // Infinite health
        return Math.mulDiv(collUsd, HEALTH_FACTOR_PRECISION, borrUsd);
    }

    function isAccountLiquidatable(address user) public view returns (bool) {
        require(address(corePool) != address(0) && address(oracle) != address(0), "LRC: Not initialized");
        uint256 totalCollateralAtLTUsd = 0;
        uint256 totalBorrUsd = 0;

        address[] memory suppliedAssets = corePool.getAssetsUserSupplied(user);
        address[] memory borrowedAssets = corePool.getAssetsUserBorrowed(user);

        for (uint i = 0; i < suppliedAssets.length; i++) {
            address underlying = suppliedAssets[i];
            MarketRiskConfig storage config = marketRiskConfigs[underlying];
            if (config.isListed && config.canBeCollateral) {
                (uint256 uTokenBalance, ) = corePool.getUserSupplyAndBorrowBalance(user, underlying);
                if (uTokenBalance > 0) {
                    uToken uTokenContract = uToken(payable(config.uTokenAddress));
                    uint256 underlyingSupplied = Math.mulDiv(uTokenBalance, uTokenContract.exchangeRateStored(), PRICE_PRECISION);
                    uint256 price = oracle.getPrice(config.oracleAssetId);
                    uint256 supplyUsd = Math.mulDiv(underlyingSupplied, price, (10**config.underlyingDecimals));
                    uint256 collateralAtLT = Math.mulDiv(supplyUsd, config.liquidationThresholdBps, BPS_DENOMINATOR);
                    totalCollateralAtLTUsd += collateralAtLT;
                }
            }
        }

        for (uint i = 0; i < borrowedAssets.length; i++) {
            address underlying = borrowedAssets[i];
             MarketRiskConfig storage config = marketRiskConfigs[underlying];
            if(config.isListed){
                (, uint256 borrowBalance) = corePool.getUserSupplyAndBorrowBalance(user, underlying);
                if (borrowBalance > 0) {
                    uint256 price = oracle.getPrice(config.oracleAssetId);
                    uint256 borrowUsd = Math.mulDiv(borrowBalance, price, (10**config.underlyingDecimals));
                    totalBorrUsd += borrowUsd;
                }
            }
        }
        if (totalBorrUsd == 0) return false;
        return totalCollateralAtLTUsd < totalBorrUsd;
    }

    function preBorrowCheck(address user, address assetToBorrow, uint256 amountToBorrow) external view {
        MarketRiskConfig storage borrowCfg = marketRiskConfigs[assetToBorrow];
        require(borrowCfg.isListed, "LRC: Borrow asset not listed");
        
        (uint256 totalCollUsd, uint256 currentBorrUsd) = getAccountLiquidityValues(user);
        
        uint256 priceBorrowAsset = oracle.getPrice(borrowCfg.oracleAssetId);
        uint256 amountToBorrowUsd = Math.mulDiv(amountToBorrow, priceBorrowAsset, (10**borrowCfg.underlyingDecimals));
        uint256 newTotalBorrUsd = currentBorrUsd + amountToBorrowUsd;
        
        require(totalCollUsd >= newTotalBorrUsd, "LRC: Borrow exceeds collateral capacity");
    }

    function preWithdrawCheck(address user, address assetCollateral, uint256 amountCollateralToWithdraw) external view {
        MarketRiskConfig storage collCfg = marketRiskConfigs[assetCollateral];
        require(collCfg.isListed && collCfg.canBeCollateral, "LRC: Asset not valid collateral");

        (uint256 currentTotalCollUsd, uint256 totalBorrUsd) = getAccountLiquidityValues(user);
        if (totalBorrUsd == 0) return; // No borrows, can withdraw

        uint256 priceCollAsset = oracle.getPrice(collCfg.oracleAssetId);
        uint256 valueToWithdrawUsd = Math.mulDiv(amountCollateralToWithdraw, priceCollAsset, (10**collCfg.underlyingDecimals));
        
        // Calculate the reduction in borrowing power this withdrawal represents
        uint256 borrowingPowerReduction = Math.mulDiv(valueToWithdrawUsd, collCfg.collateralFactorBps, BPS_DENOMINATOR);

        require(currentTotalCollUsd > borrowingPowerReduction, "LRC: Not enough coll value to remove that much power");
        uint256 newTotalCollUsd = currentTotalCollUsd - borrowingPowerReduction;
        
        require(newTotalCollUsd >= totalBorrUsd, "LRC: Withdrawal makes position undercollateralized");
    }
    
    function getListedAssetsCount() external view returns (uint256) { return listedAssets.length; }
    function getListedAssetAtIndex(uint256 index) external view returns (address) { return listedAssets[index]; }
}