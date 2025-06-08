// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ICorePool
 * @author Unxversal Team  
 * @notice Interface for the CorePool contract - central lending/borrowing hub
 */
interface ICorePool {

    // --- Events ---
    event MarketListed(address indexed underlying, address indexed uToken, address indexed irm);
    event MarketInterestAccrued(address indexed underlying, uint256 newBorrowIndex, uint256 newTotalBorrows, uint256 newTotalReserves);
    event Supply(address indexed user, address indexed underlying, uint256 amountUnderlying, uint256 amountUTokensMinted);
    event Withdraw(address indexed user, address indexed underlying, uint256 amountUnderlying, uint256 amountUTokensBurned);
    event Borrow(address indexed user, address indexed underlying, uint256 amountBorrowed);
    event RepayBorrow(address indexed payer, address indexed borrower, address indexed underlying, uint256 amountRepaid, uint256 newBorrowPrincipal);
    event FlashLoan(address indexed receiver, address indexed underlying, uint256 amount, uint256 fee);
    event ReserveFactorSet(address indexed underlying, uint256 newReserveFactorMantissa);
    event NewInterestRateModel(address indexed underlying, address indexed newIrm);
    event RiskControllerSet(address indexed newRiskController);
    event LiquidationEngineSet(address indexed newEngine);
    event ReservesWithdrawn(address indexed underlying, address indexed recipient, uint256 amountWithdrawn);
    event CollateralSeized(address indexed borrower, address indexed liquidator, address indexed collateralAsset, uint256 amountUnderlyingSeized);
    event InsuranceFundFeeCollected(address indexed underlying, uint256 feeAmount);

    // --- Admin Functions ---
    function listMarket(address underlyingAsset, address uTokenAddress, address irmAddress) external;
    function setReserveFactor(address underlyingAsset, uint256 newReserveFactorMantissa) external;
    function setInterestRateModel(address underlyingAsset, address newIrmAddress) external;
    function withdrawReserves(address underlyingAsset, uint256 amountToWithdraw, address recipient) external;
    function setRiskController(address newRiskControllerAddress) external;
    function setLiquidationEngine(address newEngineAddress) external;
    function pause() external;
    function unpause() external;

    // --- Interest Accrual ---
    function accrueInterest(address underlyingAsset) external returns (uint256 newBorrowIndex);

    // --- User Operations ---
    function supply(address underlyingAsset, uint256 amount) external;
    function withdraw(address underlyingAsset, uint256 uTokensToRedeem) external;
    function borrow(address underlyingAsset, uint256 amountToBorrow) external;
    function repayBorrow(address underlyingAsset, uint256 amountToRepay) external;
    function repayBorrowBehalf(address borrower, address underlyingAsset, uint256 amountToRepay) external;

    // --- Flash Loans ---
    function flashLoan(address receiver, address underlyingAsset, uint256 amount, bytes calldata data) external;
    function flashFeeBps() external view returns (uint256);

    // --- Liquidation Hooks ---
    function reduceBorrowBalanceForLiquidation(address borrower, address underlyingAsset, uint256 amountRepaidByLiquidator) external;
    function repayBorrowBehalfByEngine(address liquidator, address borrower, address underlyingAsset, uint256 amountToRepay) external;
    function seizeAndTransferCollateral(address borrower, address liquidator, address underlyingCollateralAsset, uint256 amountUnderlyingToSeize) external;

    // --- View Functions ---
    function getUserSupplyAndBorrowBalance(address user, address underlyingAsset) external view returns (uint256 uTokenSupplyBalance, uint256 underlyingBorrowBalanceWithInterest);
    function getAssetsUserSupplied(address user) external view returns (address[] memory);
    function getAssetsUserBorrowed(address user) external view returns (address[] memory);
    function getUTokenForUnderlying(address underlyingAsset) external view returns (address);
    function getInterestRateModelForUnderlying(address underlyingAsset) external view returns (address);
    function totalBorrowsCurrent(address underlyingAsset) external view returns (uint256);
    function totalReserves(address underlyingAsset) external view returns (uint256);
    function getMarketBorrowIndex(address underlyingAsset) external view returns (uint256);
    function getMarketState(address underlyingAsset) external view returns (uint256 totalBorrows, uint256 totalReserves, uint256 borrowIndex, uint256 lastAccrualBlock, uint256 reserveFactorMantissa, uint8 underlyingDecimals);
} 