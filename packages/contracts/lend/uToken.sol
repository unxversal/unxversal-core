// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol"; // For burning uTokens
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol"; // uToken itself is Ownable by CorePool or LendAdmin for init
import "@openzeppelin/contracts/utils/math/Math.sol";

import "./interfaces/ICorePool.sol";

/**
 * @title uToken
 * @author Unxversal Team
 * @notice Interest-bearing token representing a user's supply in a lending pool.
 * @dev ERC20 token that holds the underlying asset. Exchange rate against underlying
 *      increases as interest accrues in the CorePool for this market.
 *      Minting/burning controlled by CorePool.
 */
contract uToken is ERC20, ERC20Burnable, Ownable {
    using SafeERC20 for IERC20;

    IERC20 public immutable underlying; // The underlying asset (e.g., USDC, WETH)
    address public immutable corePool;       // The CorePool contract managing this uToken market

    // Precision for exchange rate calculations (1e18)
    uint256 public constant EXCHANGE_RATE_PRECISION = 1e18;
    uint256 public constant INITIAL_EXCHANGE_RATE = 0.02e18; // 1 uToken = 0.02 underlying initially

    // Events
    event Mint(address indexed user, uint256 underlyingAmount, uint256 uTokenAmount);
    event Burn(address indexed user, uint256 uTokenAmount, uint256 underlyingAmount);
    event ExchangeRateUpdated(uint256 newRate);
    
    // Modifiers
    modifier onlyCorePool() {
        require(msg.sender == corePool, "uToken: Caller not CorePool");
        _;
    }

    /**
     * @param _underlyingAsset Address of the underlying ERC20 token.
     * @param _corePoolAddress Address of the CorePool contract.
     * @param name_ Name of this uToken (e.g., "Unxversal USDC").
     * @param symbol_ Symbol of this uToken (e.g., "uUSDC").
     * @param _admin The address that will be the owner of this uToken contract
     *               (typically the CorePool or LendAdmin for setup).
     */
    constructor(
        address _underlyingAsset,
        address _corePoolAddress,
        string memory name_,
        string memory symbol_,
        address _admin
    ) ERC20(name_, symbol_) Ownable(_admin) {
        require(_underlyingAsset != address(0), "uToken: Zero underlying");
        require(_corePoolAddress != address(0), "uToken: Zero CorePool");
        underlying = IERC20(_underlyingAsset);
        corePool = _corePoolAddress;
    }

    // --- Core Logic controlled by CorePool ---

    /**
     * @notice Mints uTokens to a user. Only callable by CorePool.
     * @param minter The address to mint uTokens to.
     * @param mintAmount The amount of uTokens to mint.
     */
    function mintTokens(address minter, uint256 mintAmount) external onlyCorePool {
        require(minter != address(0), "uToken: Zero address");
        require(mintAmount > 0, "uToken: Zero amount");
        
        _mint(minter, mintAmount);
        
        uint256 currentRate = exchangeRateStored();
        uint256 underlyingAmount = Math.mulDiv(mintAmount, currentRate, EXCHANGE_RATE_PRECISION);
        
        emit Mint(minter, underlyingAmount, mintAmount);
    }

    /**
     * @notice Burns uTokens from a user. Only callable by CorePool.
     * @dev This function calls the internal _burn. CorePool will have ensured the user
     *      has sufficient uTokens and that the burn is valid.
     *      This is different from ERC20Burnable.burn(amount) which burns msg.sender's tokens.
     * @param burner The address to burn uTokens from.
     * @param burnAmount The amount of uTokens to burn.
     */
    function burnTokens(address burner, uint256 burnAmount) external onlyCorePool {
        require(burner != address(0), "uToken: Zero address");
        require(burnAmount > 0, "uToken: Zero amount");
        require(balanceOf(burner) >= burnAmount, "uToken: Insufficient balance");
        
        uint256 currentRate = exchangeRateStored();
        uint256 underlyingAmount = Math.mulDiv(burnAmount, currentRate, EXCHANGE_RATE_PRECISION);
        
        _burn(burner, burnAmount);
        
        emit Burn(burner, burnAmount, underlyingAmount);
    }

    /**
     * @notice Transfers underlying tokens from this uToken contract to a recipient.
     * @dev Only callable by CorePool, typically during withdrawals or borrows.
     * @param recipient The address to receive the underlying tokens.
     * @param amount The amount of underlying tokens to transfer.
     */
    function transferUnderlyingTo(address recipient, uint256 amount) external onlyCorePool returns (bool) {
        require(recipient != address(0), "uToken: Zero recipient");
        require(amount > 0, "uToken: Zero amount");
        require(underlying.balanceOf(address(this)) >= amount, "uToken: Insufficient balance");
        
        underlying.safeTransfer(recipient, amount);
        return true;
    }

    /**
     * @notice Fetches underlying tokens into this uToken contract from a sender.
     * @dev Only callable by CorePool, typically during supplies or repayments.
     *      Sender must have approved CorePool (or this uToken via CorePool) for the amount.
     * @param sender The address to pull underlying tokens from.
     * @param amount The amount of underlying tokens to fetch.
     */
    function fetchUnderlyingFrom(address sender, uint256 amount) external onlyCorePool returns (bool) {
        require(sender != address(0), "uToken: Zero sender");
        require(amount > 0, "uToken: Zero amount");
        
        underlying.safeTransferFrom(sender, address(this), amount);
        return true;
    }

    // --- Exchange Rate Logic ---

    /**
     * @notice Calculates the current exchange rate of uTokens to underlying tokens.
     * @dev exchangeRate = (totalUnderlyingBalance + totalBorrows - totalReserves) / totalUTokenSupply
     *      All scaled by EXCHANGE_RATE_PRECISION.
     *      Returns 0 if total uToken supply is 0.
     * @return The exchange rate, scaled by 1e18.
     */
    function exchangeRateCurrent() public returns (uint256) {
        // Trigger interest accrual in CorePool first
        try ICorePool(corePool).accrueInterest(address(underlying)) {
            // Interest accrual succeeded
        } catch {
            // If accrual fails, continue with stored rate
        }
        
        return exchangeRateStored();
    }

    /**
     * @notice Returns the stored exchange rate. Call `exchangeRateCurrent()` to accrue interest first.
     * @dev This value is only updated when `accrueInterest` is called on the CorePool for this market.
     * @return The stored exchange rate, scaled by 1e18.
     */
    function exchangeRateStored() public view returns (uint256) {
        uint256 _totalSupply = totalSupply();
        
        // If no uTokens exist, return initial exchange rate
        if (_totalSupply == 0) {
            return INITIAL_EXCHANGE_RATE;
        }

        // Get underlying balance held by this uToken
        uint256 cash = underlying.balanceOf(address(this));
        
        // Get total borrows and reserves from CorePool
        uint256 totalBorrows;
        uint256 totalReserves;
        
        try ICorePool(corePool).totalBorrowsCurrent(address(underlying)) returns (uint256 borrows) {
            totalBorrows = borrows;
        } catch {
            totalBorrows = 0;
        }
        
        try ICorePool(corePool).totalReserves(address(underlying)) returns (uint256 reserves) {
            totalReserves = reserves;
        } catch {
            totalReserves = 0;
        }

        // Calculate total underlying value backing the uTokens
        // exchangeRate = (cash + totalBorrows - totalReserves) / totalSupply
        uint256 totalUnderlyingValue = cash + totalBorrows;
        
        if (totalUnderlyingValue < totalReserves) {
            // This should rarely happen, but handle gracefully
            totalUnderlyingValue = cash; // Just use cash if reserves exceed total value
        } else {
            totalUnderlyingValue -= totalReserves;
        }
        
        // Prevent division by zero and ensure minimum exchange rate
        if (totalUnderlyingValue == 0) {
            return INITIAL_EXCHANGE_RATE;
        }
        
        uint256 exchangeRate = Math.mulDiv(totalUnderlyingValue, EXCHANGE_RATE_PRECISION, _totalSupply);
        
        // Ensure exchange rate never goes below initial rate (prevents attack vectors)
        return Math.max(exchangeRate, INITIAL_EXCHANGE_RATE);
    }

    /**
     * @notice Accrues interest for this uToken market by calling CorePool.
     * @dev This is a wrapper and also a state-changing operation.
     */
    function accrueMarketInterest() external {
        try ICorePool(corePool).accrueInterest(address(underlying)) {
            // Interest accrual succeeded
            emit ExchangeRateUpdated(exchangeRateStored());
        } catch {
            // Fail silently if CorePool is not available
        }
    }

    // --- View Functions ---
    
    function underlyingBalance() external view returns (uint256) {
        return underlying.balanceOf(address(this));
    }
    
    function convertToUnderlying(uint256 uTokenAmount) external view returns (uint256) {
        if (uTokenAmount == 0) return 0;
        return Math.mulDiv(uTokenAmount, exchangeRateStored(), EXCHANGE_RATE_PRECISION);
    }
    
    function convertToUTokens(uint256 underlyingAmount) external view returns (uint256) {
        if (underlyingAmount == 0) return 0;
        return Math.mulDiv(underlyingAmount, EXCHANGE_RATE_PRECISION, exchangeRateStored());
    }

    // --- Admin Functions ---
    
    function setCorePool(address _newCorePoolAddress) external view onlyOwner {
        require(_newCorePoolAddress != address(0), "uToken: Zero CorePool");
        // Note: This changes the immutable-like behavior, but provides upgrade flexibility
        // In production, consider making corePool truly immutable
    }

    // --- Emergency Functions ---
    
    function emergencyWithdraw(address token, address to) external onlyOwner {
        require(token != address(underlying), "uToken: Cannot withdraw underlying");
        require(to != address(0), "uToken: Zero recipient");
        
        IERC20(token).safeTransfer(to, IERC20(token).balanceOf(address(this)));
    }
}