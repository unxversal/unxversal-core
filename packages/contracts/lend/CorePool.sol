// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "./interfaces/ICorePool.sol";
import "./interfaces/IFlashLoanReceiver.sol";
import "./interfaces/ILendRiskController.sol";
import "./interestModels/IInterestRateModel.sol";

// Forward declaration to avoid circular imports
interface IUToken {
    function underlying() external view returns (address);
    function mintTokens(address to, uint256 amount) external;
    function burnTokens(address from, uint256 amount) external;
    function transferUnderlyingTo(address to, uint256 amount) external returns (bool);
    function exchangeRateStored() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
}

/**
 * @title CorePool
 * @author Unxversal Team
 * @notice Central contract for Unxversal Lend - manages markets, user balances, and interest accrual
 * @dev Production-ready lending pool with flash loans, proper interest calculation, and fee collection
 */
contract CorePool is Ownable, ReentrancyGuard, Pausable, ICorePool {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    // --- Structs ---
    struct Market {
        bool isListed;
        address uTokenAddress;
        address interestRateModel;
        uint256 totalBorrowsPrincipal;
        uint256 totalReserves;
        uint256 borrowIndex;
        uint256 reserveFactorMantissa;
        uint256 lastAccrualBlock;
        uint8 underlyingDecimals;
    }

    struct UserBorrowData {
        uint256 principal;
        uint256 interestIndex;
    }

    // --- Market State ---
    mapping(address => Market) public markets;
    EnumerableSet.AddressSet private _listedMarketUnderlyings;

    // --- User State ---
    mapping(address => mapping(address => UserBorrowData)) public userBorrowData;
    mapping(address => EnumerableSet.AddressSet) private _userSuppliedAssets;
    mapping(address => EnumerableSet.AddressSet) private _userBorrowedAssets;

    // --- Dependencies ---
    ILendRiskController public riskController;
    address public liquidationEngineAddress;
    address public treasuryAddress;

    // --- Fee Configuration ---
    uint256 public override flashFeeBps = 8; // 0.08% flash loan fee
    uint256 public reserveFeeBps = 1200; // 12% of interest goes to reserves
    uint256 public insuranceFeeBps = 200; // 2% of interest goes to insurance fund
    uint256 public treasuryFeeBps = 800; // 8% of flash loan fees go to treasury

    // --- Constants ---
    uint256 public constant BORROW_INDEX_PRECISION = 1e18;
    uint256 public constant BPS_DENOMINATOR = 10000;
    uint256 public constant MAX_FLASH_FEE = 1000; // Max 10% flash loan fee

    constructor(address _riskControllerAddress, address _treasuryAddress, address _initialOwner) 
        Ownable(_initialOwner) 
    {
        require(_riskControllerAddress != address(0), "CorePool: Zero RiskController");
        require(_treasuryAddress != address(0), "CorePool: Zero Treasury");
        
        riskController = ILendRiskController(_riskControllerAddress);
        treasuryAddress = _treasuryAddress;
        
        emit RiskControllerSet(_riskControllerAddress);
    }

    // --- Admin Functions ---
    
    function setRiskController(address _newRiskControllerAddress) external override onlyOwner {
        require(_newRiskControllerAddress != address(0), "CorePool: Zero RiskController");
        riskController = ILendRiskController(_newRiskControllerAddress);
        emit RiskControllerSet(_newRiskControllerAddress);
    }

    function setLiquidationEngine(address _newEngineAddress) external override onlyOwner {
        require(_newEngineAddress != address(0), "CorePool: Zero LiquidationEngine");
        liquidationEngineAddress = _newEngineAddress;
        emit LiquidationEngineSet(_newEngineAddress);
    }

    function setTreasuryAddress(address _newTreasuryAddress) external onlyOwner {
        require(_newTreasuryAddress != address(0), "CorePool: Zero Treasury");
        treasuryAddress = _newTreasuryAddress;
    }

    function setFlashFeeBps(uint256 _newFlashFeeBps) external onlyOwner {
        require(_newFlashFeeBps <= MAX_FLASH_FEE, "CorePool: Flash fee too high");
        flashFeeBps = _newFlashFeeBps;
    }

    function listMarket(address underlyingAsset, address _uTokenAddress, address _irmAddress) 
        external override onlyOwner 
    {
        require(underlyingAsset != address(0) && _uTokenAddress != address(0) && _irmAddress != address(0), 
            "CorePool: Zero address");
        
        Market storage market = markets[underlyingAsset];
        require(!market.isListed, "CorePool: Market already listed");

        // Validate uToken
        require(IUToken(_uTokenAddress).underlying() == underlyingAsset, "CorePool: uToken mismatch");

        market.isListed = true;
        market.uTokenAddress = _uTokenAddress;
        market.interestRateModel = _irmAddress;
        market.borrowIndex = BORROW_INDEX_PRECISION;
        market.lastAccrualBlock = block.number;
        market.underlyingDecimals = IERC20Metadata(underlyingAsset).decimals();
        market.reserveFactorMantissa = reserveFeeBps * 1e14; // Convert BPS to 1e18 scale
        
        _listedMarketUnderlyings.add(underlyingAsset);

        emit MarketListed(underlyingAsset, _uTokenAddress, _irmAddress);
    }

    function setReserveFactor(address underlyingAsset, uint256 newReserveFactorMantissa) 
        external override onlyOwner 
    {
        Market storage market = markets[underlyingAsset];
        require(market.isListed, "CorePool: Market not listed");
        require(newReserveFactorMantissa <= BORROW_INDEX_PRECISION, "CorePool: Reserve factor too high");
        
        accrueInterest(underlyingAsset);
        market.reserveFactorMantissa = newReserveFactorMantissa;
        emit ReserveFactorSet(underlyingAsset, newReserveFactorMantissa);
    }
    
    function setInterestRateModel(address underlyingAsset, address newIrmAddress) 
        external override onlyOwner 
    {
        Market storage market = markets[underlyingAsset];
        require(market.isListed, "CorePool: Market not listed");
        require(newIrmAddress != address(0), "CorePool: Zero IRM");
        
        accrueInterest(underlyingAsset);
        market.interestRateModel = newIrmAddress;
        emit NewInterestRateModel(underlyingAsset, newIrmAddress);
    }

    function withdrawReserves(address underlyingAsset, uint256 amountToWithdraw, address recipient) 
        external override onlyOwner nonReentrant 
    {
        Market storage market = markets[underlyingAsset];
        require(market.isListed, "CorePool: Market not listed");
        require(recipient != address(0) && amountToWithdraw > 0, "CorePool: Invalid params");
        
        accrueInterest(underlyingAsset);
        require(market.totalReserves >= amountToWithdraw, "CorePool: Insufficient reserves");
        
        market.totalReserves -= amountToWithdraw;
        IUToken(market.uTokenAddress).transferUnderlyingTo(recipient, amountToWithdraw);
        emit ReservesWithdrawn(underlyingAsset, recipient, amountToWithdraw);
    }

    function pause() external override onlyOwner { 
        _pause(); 
    }
    
    function unpause() external override onlyOwner { 
        _unpause(); 
    }

    // --- Interest Accrual ---
    
    function accrueInterest(address underlyingAsset) public override returns (uint256 newBorrowIndex) {
        Market storage market = markets[underlyingAsset];
        if (!market.isListed || market.lastAccrualBlock == block.number) {
            return market.borrowIndex;
        }

        uint256 currentBorrowIndex = market.borrowIndex;
        uint256 blockDelta = block.number - market.lastAccrualBlock;
        
        newBorrowIndex = currentBorrowIndex;

        if (market.totalBorrowsPrincipal > 0 && blockDelta > 0) {
            // Get current market state
            uint256 cashInUToken = IERC20(underlyingAsset).balanceOf(market.uTokenAddress);
            uint256 totalBorrowsWithInterest = Math.mulDiv(
                market.totalBorrowsPrincipal, 
                currentBorrowIndex, 
                BORROW_INDEX_PRECISION
            );

            // Get borrow rate from IRM
            IInterestRateModel irm = IInterestRateModel(market.interestRateModel);
            uint256 borrowRatePerBlock = irm.getBorrowRate(
                cashInUToken, 
                totalBorrowsWithInterest, 
                market.totalReserves
            );

            // Calculate new borrow index
            uint256 interestFactor = 1e18 + (borrowRatePerBlock * blockDelta);
            newBorrowIndex = Math.mulDiv(currentBorrowIndex, interestFactor, BORROW_INDEX_PRECISION);
            
            // Calculate interest accrued
            uint256 newTotalBorrowsWithInterest = Math.mulDiv(
                market.totalBorrowsPrincipal,
                newBorrowIndex,
                BORROW_INDEX_PRECISION
            );
            uint256 interestAccumulated = newTotalBorrowsWithInterest - totalBorrowsWithInterest;
            
            // Allocate interest to reserves and insurance
            uint256 reservesAdded = Math.mulDiv(interestAccumulated, market.reserveFactorMantissa, BORROW_INDEX_PRECISION);
            uint256 insuranceFeeAdded = Math.mulDiv(interestAccumulated, insuranceFeeBps * 1e14, BORROW_INDEX_PRECISION);
            
            market.totalReserves += reservesAdded;
            market.borrowIndex = newBorrowIndex;
            
            // Collect insurance fee to treasury
            if (insuranceFeeAdded > 0) {
                IUToken(market.uTokenAddress).transferUnderlyingTo(treasuryAddress, insuranceFeeAdded);
                emit InsuranceFundFeeCollected(underlyingAsset, insuranceFeeAdded);
            }
        }

        market.lastAccrualBlock = block.number;
        emit MarketInterestAccrued(underlyingAsset, newBorrowIndex, market.totalBorrowsPrincipal, market.totalReserves);
        
        return newBorrowIndex;
    }

    // --- User Operations ---
    
    function supply(address underlyingAsset, uint256 amount) external override nonReentrant whenNotPaused {
        Market storage market = markets[underlyingAsset];
        require(market.isListed, "CorePool: Market not listed");
        require(amount > 0, "CorePool: Zero supply");
        
        accrueInterest(underlyingAsset);

        IUToken uTokenContract = IUToken(payable(market.uTokenAddress));
        uint256 exchangeRate = uTokenContract.exchangeRateStored();
        require(exchangeRate > 0, "CorePool: Invalid exchange rate");

        // Transfer tokens from user to uToken
        IERC20(underlyingAsset).safeTransferFrom(msg.sender, address(uTokenContract), amount);

        // Mint uTokens to user
        uint256 uTokensToMint = Math.mulDiv(amount, BORROW_INDEX_PRECISION, exchangeRate);
        uTokenContract.mintTokens(msg.sender, uTokensToMint);
        
        _userSuppliedAssets[msg.sender].add(underlyingAsset);
        emit Supply(msg.sender, underlyingAsset, amount, uTokensToMint);
    }

    function withdraw(address underlyingAsset, uint256 uTokensToRedeem) 
        external override nonReentrant whenNotPaused 
    {
        Market storage market = markets[underlyingAsset];
        require(market.isListed, "CorePool: Market not listed");
        require(uTokensToRedeem > 0, "CorePool: Zero redeem");
        
        accrueInterest(underlyingAsset);

        IUToken uTokenContract = IUToken(payable(market.uTokenAddress));
        uint256 exchangeRate = uTokenContract.exchangeRateStored();
        require(exchangeRate > 0, "CorePool: Invalid exchange rate");
        
        uint256 underlyingToWithdraw = Math.mulDiv(uTokensToRedeem, exchangeRate, BORROW_INDEX_PRECISION);

        // Check withdrawal limits via risk controller
        riskController.preWithdrawCheck(msg.sender, underlyingAsset, underlyingToWithdraw);

        // Burn uTokens and transfer underlying
        uTokenContract.burnTokens(msg.sender, uTokensToRedeem);
        uTokenContract.transferUnderlyingTo(msg.sender, underlyingToWithdraw);

        // Remove from user's supplied assets if balance is zero
        if (uTokenContract.balanceOf(msg.sender) == 0) {
            _userSuppliedAssets[msg.sender].remove(underlyingAsset);
        }
        
        emit Withdraw(msg.sender, underlyingAsset, underlyingToWithdraw, uTokensToRedeem);
    }

    function borrow(address underlyingAsset, uint256 amountToBorrow) 
        external override nonReentrant whenNotPaused 
    {
        Market storage market = markets[underlyingAsset];
        require(market.isListed, "CorePool: Market not listed");
        require(amountToBorrow > 0, "CorePool: Zero borrow");
        
        uint256 currentBorrowIndex = accrueInterest(underlyingAsset);

        // Check borrow limits via risk controller
        riskController.preBorrowCheck(msg.sender, underlyingAsset, amountToBorrow);

        // Check liquidity
        IUToken uTokenContract = IUToken(payable(market.uTokenAddress));
        uint256 cashInUToken = IERC20(underlyingAsset).balanceOf(market.uTokenAddress);
        require(cashInUToken >= amountToBorrow, "CorePool: Insufficient liquidity");

        // Update user's borrow data
        UserBorrowData storage borrowData = userBorrowData[msg.sender][underlyingAsset];
        uint256 accountBorrowsPrior = _getBorrowBalanceWithInterest(borrowData, currentBorrowIndex);
        uint256 newBorrowBalance = accountBorrowsPrior + amountToBorrow;
        
        // Convert to principal amount
        uint256 newBorrowPrincipal = Math.mulDiv(newBorrowBalance, BORROW_INDEX_PRECISION, currentBorrowIndex);
        
        borrowData.principal = newBorrowPrincipal;
        borrowData.interestIndex = currentBorrowIndex;
        market.totalBorrowsPrincipal += Math.mulDiv(amountToBorrow, BORROW_INDEX_PRECISION, currentBorrowIndex);

        // Transfer tokens to borrower
        uTokenContract.transferUnderlyingTo(msg.sender, amountToBorrow);
        _userBorrowedAssets[msg.sender].add(underlyingAsset);
        
        emit Borrow(msg.sender, underlyingAsset, amountToBorrow);
    }

    function repayBorrow(address underlyingAsset, uint256 amountToRepay) 
        external override nonReentrant whenNotPaused 
    {
        _repayBorrowInternal(msg.sender, msg.sender, underlyingAsset, amountToRepay);
    }

    function repayBorrowBehalf(address borrower, address underlyingAsset, uint256 amountToRepay) 
        external override nonReentrant whenNotPaused 
    {
        _repayBorrowInternal(msg.sender, borrower, underlyingAsset, amountToRepay);
    }

    function _repayBorrowInternal(address payer, address borrower, address underlyingAsset, uint256 amountToRepayInput) 
        internal 
    {
        Market storage market = markets[underlyingAsset];
        require(market.isListed, "CorePool: Market not listed");
        require(amountToRepayInput > 0, "CorePool: Zero repay");
        
        uint256 currentBorrowIndex = accrueInterest(underlyingAsset);

        UserBorrowData storage borrowData = userBorrowData[borrower][underlyingAsset];
        uint256 accountBorrowsPrior = _getBorrowBalanceWithInterest(borrowData, currentBorrowIndex);
        require(accountBorrowsPrior > 0, "CorePool: No outstanding borrow");

        // Determine actual repay amount
        uint256 actualRepayAmount;
        if (amountToRepayInput == type(uint256).max || amountToRepayInput >= accountBorrowsPrior) {
            actualRepayAmount = accountBorrowsPrior;
            borrowData.principal = 0;
            borrowData.interestIndex = 0;
            _userBorrowedAssets[borrower].remove(underlyingAsset);
        } else {
            actualRepayAmount = amountToRepayInput;
            uint256 newBorrowBalance = accountBorrowsPrior - actualRepayAmount;
            borrowData.principal = Math.mulDiv(newBorrowBalance, BORROW_INDEX_PRECISION, currentBorrowIndex);
            borrowData.interestIndex = currentBorrowIndex;
        }

        // Update market state
        uint256 principalReduced = Math.mulDiv(actualRepayAmount, BORROW_INDEX_PRECISION, currentBorrowIndex);
        market.totalBorrowsPrincipal -= principalReduced;

        // Transfer repayment from payer to uToken
        IUToken uTokenContract = IUToken(payable(market.uTokenAddress));
        IERC20(underlyingAsset).safeTransferFrom(payer, address(uTokenContract), actualRepayAmount);

        emit RepayBorrow(payer, borrower, underlyingAsset, actualRepayAmount, borrowData.principal);
    }

    // --- Flash Loans ---
    
    function flashLoan(address receiver, address underlyingAsset, uint256 amount, bytes calldata data) 
        external override nonReentrant whenNotPaused 
    {
        Market storage market = markets[underlyingAsset];
        require(market.isListed, "CorePool: Market not listed");
        require(amount > 0, "CorePool: Zero flash loan amount");
        
        accrueInterest(underlyingAsset);
        
        IUToken uTokenContract = IUToken(payable(market.uTokenAddress));
        uint256 cashBefore = IERC20(underlyingAsset).balanceOf(address(uTokenContract));
        require(cashBefore >= amount, "CorePool: Insufficient liquidity for flash loan");

        // Calculate fee
        uint256 fee = Math.mulDiv(amount, flashFeeBps, BPS_DENOMINATOR);
        
        // Transfer flash loan amount to receiver
        uTokenContract.transferUnderlyingTo(receiver, amount);
        
        // Call receiver's executeOperation
        require(
            IFlashLoanReceiver(receiver).executeOperation(underlyingAsset, amount, fee, msg.sender, data),
            "CorePool: Flash loan execution failed"
        );
        
        // Verify repayment
        uint256 cashAfter = IERC20(underlyingAsset).balanceOf(address(uTokenContract));
        require(cashAfter >= cashBefore + fee, "CorePool: Flash loan not repaid with fee");
        
        // Collect treasury fee
        if (fee > 0) {
            uint256 treasuryFee = Math.mulDiv(fee, treasuryFeeBps, BPS_DENOMINATOR);
            if (treasuryFee > 0) {
                uTokenContract.transferUnderlyingTo(treasuryAddress, treasuryFee);
            }
            
            // Rest goes to lenders (stays in uToken)
        }
        
        emit FlashLoan(receiver, underlyingAsset, amount, fee);
    }

    // --- Helper Functions ---
    
    function _getBorrowBalanceWithInterest(UserBorrowData storage borrowData, uint256 currentBorrowIndex) 
        internal view returns (uint256) 
    {
        if (borrowData.principal == 0) return 0;
        return Math.mulDiv(borrowData.principal, currentBorrowIndex, borrowData.interestIndex);
    }

    // --- Liquidation Hooks ---
    
    modifier onlyLiquidationEngine() {
        require(msg.sender == liquidationEngineAddress, "CorePool: Caller not LiquidationEngine");
        _;
    }

    function reduceBorrowBalanceForLiquidation(
        address borrower, 
        address underlyingAsset, 
        uint256 amountRepaidByLiquidator
    ) external override nonReentrant onlyLiquidationEngine {
        Market storage market = markets[underlyingAsset];
        require(market.isListed, "CorePool: Market not listed");
        
        uint256 currentBorrowIndex = accrueInterest(underlyingAsset);

        UserBorrowData storage borrowData = userBorrowData[borrower][underlyingAsset];
        uint256 accountBorrowsPrior = _getBorrowBalanceWithInterest(borrowData, currentBorrowIndex);
        require(accountBorrowsPrior >= amountRepaidByLiquidator, "CorePool: Liquidation repay > borrow balance");

        uint256 newBorrowBalance = accountBorrowsPrior - amountRepaidByLiquidator;
        if (newBorrowBalance == 0) {
            borrowData.principal = 0;
            borrowData.interestIndex = 0;
            _userBorrowedAssets[borrower].remove(underlyingAsset);
        } else {
            borrowData.principal = Math.mulDiv(newBorrowBalance, BORROW_INDEX_PRECISION, currentBorrowIndex);
            borrowData.interestIndex = currentBorrowIndex;
        }
        
        uint256 principalReduced = Math.mulDiv(amountRepaidByLiquidator, BORROW_INDEX_PRECISION, currentBorrowIndex);
        market.totalBorrowsPrincipal -= principalReduced;
        
        emit RepayBorrow(liquidationEngineAddress, borrower, underlyingAsset, amountRepaidByLiquidator, borrowData.principal);
    }

    function repayBorrowBehalfByEngine(
        address liquidator,
        address borrower,
        address underlyingAsset,
        uint256 amountToRepay
    ) external override nonReentrant onlyLiquidationEngine {
        _repayBorrowInternal(liquidator, borrower, underlyingAsset, amountToRepay);
    }

    function seizeAndTransferCollateral(
        address borrower,
        address liquidator,
        address underlyingCollateralAsset,
        uint256 amountUnderlyingToSeize
    ) external override nonReentrant onlyLiquidationEngine {
        Market storage market = markets[underlyingCollateralAsset];
        require(market.isListed, "CorePool: Collateral market not listed");
        require(amountUnderlyingToSeize > 0, "CorePool: Zero seize amount");
        
        accrueInterest(underlyingCollateralAsset);

        IUToken uTokenCollateral = IUToken(payable(market.uTokenAddress));
        uint256 exchangeRate = uTokenCollateral.exchangeRateStored();
        require(exchangeRate > 0, "CorePool: Invalid collateral exchange rate");

        uint256 uTokensToSeize = Math.mulDiv(amountUnderlyingToSeize, BORROW_INDEX_PRECISION, exchangeRate);
        require(uTokenCollateral.balanceOf(borrower) >= uTokensToSeize, "CorePool: Insufficient uTokens to seize");

        // Burn borrower's uTokens and transfer underlying to liquidator
        uTokenCollateral.burnTokens(borrower, uTokensToSeize);
        uTokenCollateral.transferUnderlyingTo(liquidator, amountUnderlyingToSeize);

        if (uTokenCollateral.balanceOf(borrower) == 0) {
            _userSuppliedAssets[borrower].remove(underlyingCollateralAsset);
        }
        
        emit CollateralSeized(borrower, liquidator, underlyingCollateralAsset, amountUnderlyingToSeize);
    }

    // --- View Functions ---
    
    function getUserSupplyAndBorrowBalance(address user, address underlyingAsset)
        external view override
        returns (uint256 uTokenSupplyBalance, uint256 underlyingBorrowBalanceWithInterest)
    {
        Market storage market = markets[underlyingAsset];
        if (!market.isListed) return (0, 0);
        
        uTokenSupplyBalance = IUToken(market.uTokenAddress).balanceOf(user);
        
        uint256 marketBorrowIndex = _getUpdatedBorrowIndex(underlyingAsset);
        underlyingBorrowBalanceWithInterest = _getBorrowBalanceWithInterest(
            userBorrowData[user][underlyingAsset], 
            marketBorrowIndex
        );
    }

    function getAssetsUserSupplied(address user) external view override returns (address[] memory) {
        return _userSuppliedAssets[user].values();
    }

    function getAssetsUserBorrowed(address user) external view override returns (address[] memory) {
        return _userBorrowedAssets[user].values();
    }

    function getUTokenForUnderlying(address underlyingAsset) external view override returns (address) {
        return markets[underlyingAsset].uTokenAddress;
    }

    function getInterestRateModelForUnderlying(address underlyingAsset) external view override returns (address) {
        return markets[underlyingAsset].interestRateModel;
    }

    function totalBorrowsCurrent(address underlyingAsset) external view override returns (uint256) {
        Market storage market = markets[underlyingAsset];
        if (!market.isListed || market.totalBorrowsPrincipal == 0) return 0;
        
        uint256 updatedBorrowIndex = _getUpdatedBorrowIndex(underlyingAsset);
        return Math.mulDiv(market.totalBorrowsPrincipal, updatedBorrowIndex, BORROW_INDEX_PRECISION);
    }

    function totalReserves(address underlyingAsset) external view override returns (uint256) {
        Market storage market = markets[underlyingAsset];
        return market.totalReserves;
    }

    function getMarketBorrowIndex(address underlyingAsset) external view override returns (uint256) {
        return _getUpdatedBorrowIndex(underlyingAsset);
    }

    function getMarketState(address underlyingAsset) 
        external view override 
        returns (
            uint256 totalBorrows, 
            uint256 _totalReserves, 
            uint256 borrowIndex,
            uint256 lastAccrualBlock, 
            uint256 reserveFactorMantissa, 
            uint8 underlyingDecimals
        ) 
    {
        Market storage market = markets[underlyingAsset];
        require(market.isListed, "CorePool: Market not listed");
        
        borrowIndex = _getUpdatedBorrowIndex(underlyingAsset);
        totalBorrows = Math.mulDiv(market.totalBorrowsPrincipal, borrowIndex, BORROW_INDEX_PRECISION);
        _totalReserves = market.totalReserves;
        lastAccrualBlock = market.lastAccrualBlock;
        reserveFactorMantissa = market.reserveFactorMantissa;
        underlyingDecimals = market.underlyingDecimals;
    }

    function _getUpdatedBorrowIndex(address underlyingAsset) internal view returns (uint256) {
        Market storage market = markets[underlyingAsset];
        if (!market.isListed || market.lastAccrualBlock == block.number || market.totalBorrowsPrincipal == 0) {
            return market.borrowIndex;
        }
        
        uint256 blockDelta = block.number - market.lastAccrualBlock;
        uint256 cashInUToken = IERC20(underlyingAsset).balanceOf(market.uTokenAddress);
        uint256 totalBorrowsWithInterest = Math.mulDiv(
            market.totalBorrowsPrincipal,
            market.borrowIndex,
            BORROW_INDEX_PRECISION
        );
        
        IInterestRateModel irm = IInterestRateModel(market.interestRateModel);
        uint256 borrowRatePerBlock = irm.getBorrowRate(cashInUToken, totalBorrowsWithInterest, market.totalReserves);
        
        uint256 interestFactor = 1e18 + (borrowRatePerBlock * blockDelta);
        return Math.mulDiv(market.borrowIndex, interestFactor, BORROW_INDEX_PRECISION);
    }
}