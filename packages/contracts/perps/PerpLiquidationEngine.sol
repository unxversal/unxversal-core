// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "./interfaces/IPerpClearingHouse.sol";
// IOracleRelayer is used via PerpClearingHouse for mark price
// IPerpsFeeCollector is used by PerpClearingHouse to send fees

/**
 * @title PerpLiquidationEngine
 * @author Unxversal Team
 * @notice Engine for triggering and processing liquidations of undercollateralized perpetual futures positions.
 * @dev Keepers call `liquidateTraderPosition`. This engine verifies liquidation eligibility and
 *      instructs PerpClearingHouse to close the position and assess fees.
 */
contract PerpLiquidationEngine is Ownable, ReentrancyGuard, Pausable {
    IPerpClearingHouse public perpClearingHouse;

    // Default max percentage of a position's notional size to close in a single liquidation event.
    // Can be overridden by more sophisticated logic if needed.
    uint256 public defaultLiquidationCloseFactorBps; // e.g., 5000 for 50% (0-10000 BPS)

    // --- Events ---
    event PerpClearingHouseSet(address indexed clearingHouseAddress);
    event DefaultLiquidationCloseFactorSet(uint256 newCloseFactorBps);
    // Actual LiquidationEvent with details is emitted by PerpClearingHouse.
    // This engine might emit a simpler "LiquidationTriggered" event if desired.
    event LiquidationTriggered(
        address indexed liquidator,
        address indexed trader,
        bytes32 indexed marketId,
        int256 sizeClosedNotionalUsd,
        uint256 atPrice1e18
    );


    constructor(
        address _perpClearingHouseAddress,
        address _initialOwner
    ) Ownable(_initialOwner) {
        setPerpClearingHouse(_perpClearingHouseAddress); // Emits event
        // defaultLiquidationCloseFactorBps should be set by owner post-deployment.
        // Example: setDefaultLiquidationCloseFactor(5000); // 50%
    }

    // --- Admin Functions ---
    /**
     * @notice Sets the address of the PerpClearingHouse contract.
     * @param _newClearingHouseAddress The new address.
     */
    function setPerpClearingHouse(address _newClearingHouseAddress) public onlyOwner {
        require(_newClearingHouseAddress != address(0), "PLE: Zero ClearingHouse");
        perpClearingHouse = IPerpClearingHouse(_newClearingHouseAddress);
        emit PerpClearingHouseSet(_newClearingHouseAddress);
    }

    /**
     * @notice Sets the default close factor for liquidations.
     * @param _newCloseFactorBps New close factor in BPS (e.g., 5000 for 50%). Must be > 0 and <= 10000.
     */
    function setDefaultLiquidationCloseFactor(uint256 _newCloseFactorBps) external onlyOwner {
        require(_newCloseFactorBps > 0 && _newCloseFactorBps <= 10000,
            "PLE: Invalid close factor");
        defaultLiquidationCloseFactorBps = _newCloseFactorBps;
        emit DefaultLiquidationCloseFactorSet(_newCloseFactorBps);
    }

    /** @notice Pauses the ability to trigger new liquidations through this engine. */
    function pauseEngine() external onlyOwner { _pause(); }

    /** @notice Unpauses the ability to trigger new liquidations. */
    function unpauseEngine() external onlyOwner { _unpause(); }


    // --- Liquidation Function ---
    /**
     * @notice Allows anyone (a liquidator/keeper) to liquidate an unhealthy trader's position in a specific market.
     * @dev Checks if the trader is liquidatable, calculates the portion to close,
     *      and calls PerpClearingHouse to execute the liquidation.
     * @param trader The address of the account to liquidate.
     * @param marketId The market ID of the position to liquidate.
     * @param sizeToAttemptCloseNotionalUsd The notional USD amount the liquidator *wishes* to close.
     *                                      The actual amount closed will be capped by the position size
     *                                      and `defaultLiquidationCloseFactorBps`.
     *                                      Sign should be opposite to the trader's position
     *                                      (e.g., if trader is long, this should be negative).
     */
    function liquidateTraderPosition(
        address trader,
        bytes32 marketId,
        int256 sizeToAttemptCloseNotionalUsd // e.g. -1000e6 to close $1000 of a long position
    ) external nonReentrant whenNotPaused {
        require(address(perpClearingHouse) != address(0), "PLE: ClearingHouse not set");
        require(defaultLiquidationCloseFactorBps > 0, "PLE: Close factor not set");
        require(trader != address(0), "PLE: Zero trader address");
        require(marketId != bytes32(0), "PLE: Zero marketId");
        require(sizeToAttemptCloseNotionalUsd != 0, "PLE: Zero close size attempt");

        // 1. Check trader's overall account health from PerpClearingHouse
        // getAccountSummary returns: collateral, uPnl, marginBalance, mmr, imr, isLiquidatable
        (,,,, , bool accountIsLiquidatable) = perpClearingHouse.getAccountSummary(trader);
        require(accountIsLiquidatable, "PLE: Trader not liquidatable");

        // 2. Get trader's current position in the specified market
        (int256 positionSize,,,) = perpClearingHouse.getTraderPosition(trader, marketId);
        require(positionSize != 0, "PLE: Trader no position in market");

        // 3. Ensure attempted close size has the opposite sign of the position
        require((positionSize > 0 && sizeToAttemptCloseNotionalUsd < 0) ||
                (positionSize < 0 && sizeToAttemptCloseNotionalUsd > 0),
                "PLE: Close size must oppose position");

        // 4. Determine actual size to close
        uint256 absPositionSize = uint256(positionSize > 0 ? positionSize : -positionSize);
        uint256 maxCloseableByFactor = Math.mulDiv(absPositionSize, defaultLiquidationCloseFactorBps, 10000);
        
        uint256 absAttemptedCloseSize = uint256(sizeToAttemptCloseNotionalUsd > 0 ? sizeToAttemptCloseNotionalUsd : -sizeToAttemptCloseNotionalUsd);
        uint256 actualAbsSizeToClose = Math.min(absAttemptedCloseSize, maxCloseableByFactor);
        actualAbsSizeToClose = Math.min(actualAbsSizeToClose, absPositionSize); // Cannot close more than the position

        require(actualAbsSizeToClose > 0, "PLE: Calculated close size is zero");

        // Re-apply the sign based on the position's sign (we are closing it)
        int256 actualSignedSizeToClose = positionSize > 0 ? -int256(actualAbsSizeToClose) : int256(actualAbsSizeToClose);

        // 5. Use a reasonable liquidation price (will be validated by clearing house)
        uint256 closePrice1e18 = 1e18; // Placeholder - clearing house will use actual mark price

        // 6. Calculate total liquidation fee to be deducted by ClearingHouse
        // Use standard 2.5% liquidation fee (clearing house will use actual market config)
        uint256 liquidationFeeUsdc = Math.mulDiv(actualAbsSizeToClose, 250, 10000); // 2.5%

        // 7. Call PerpClearingHouse to process the liquidation
        // PerpClearingHouse.processLiquidation will:
        // - Update trader's position by `actualSignedSizeToClose` at `closePrice1e18`.
        // - Calculate and apply realized PnL to trader's margin.
        // - Deduct `liquidationFeeUsdc` from trader's margin.
        // - Send `liquidationFeeUsdc` to the IPerpsFeeCollector.
        // - Emit its own PositionLiquidatedByEngine event with PnL details.
        perpClearingHouse.processLiquidation(
            trader,
            marketId,
            actualSignedSizeToClose,
            closePrice1e18,
            liquidationFeeUsdc
        );

        // This engine's role is to trigger. The FeeCollector handles splitting the fee
        // between this liquidator (_msgSender()) and the insurance fund.
        emit LiquidationTriggered(
            _msgSender(), // The liquidator
            trader,
            marketId,
            actualSignedSizeToClose,
            closePrice1e18
        );
    }

    // --- View Functions ---
    /**
     * @notice Public view to check if a trader is liquidatable according to PerpClearingHouse.
     * @param trader The address of the trader.
     * @return True if liquidatable, false otherwise.
     */
    function isTraderLiquidatable(address trader) external view returns (bool) {
        if (address(perpClearingHouse) == address(0)) return false;
        (,,,, , bool liquidatable) = perpClearingHouse.getAccountSummary(trader);
        return liquidatable;
    }
}