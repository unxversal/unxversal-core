// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IPerpsFeeCollector
 * @author Unxversal Team
 * @notice Interface for a contract that receives and processes/distributes fees and other protocol revenues
 *         from the Unxversal Perpetual Futures protocol.
 * @dev PerpClearingHouse will interact with an implementation of this interface.
 *      All amounts are typically in the margin asset (e.g., USDC).
 */
interface IPerpsFeeCollector {

    // --- Events ---

    /**
     * @notice Emitted when trading fees are processed by the collector.
     * @param payer The address of the trader who paid the fee.
     * @param marketId The market ID where the trade occurred.
     * @param feeToken The address of the token in which the fee was paid (e.g., USDC).
     * @param amount The amount of the fee received by the collector.
     * @param isTakerFee True if the fee originated from a taker order.
     */
    event TradingFeeProcessed(
        address indexed payer,
        bytes32 indexed marketId,
        address indexed feeToken,
        uint256 amount,
        bool isTakerFee
    );

    /**
     * @notice Emitted when a liquidation fee is processed and distributed.
     * @param liquidatedTrader The address of the trader whose position was liquidated.
     * @param liquidator The address of the entity that performed the liquidation.
     * @param marketId The market ID of the liquidated position.
     * @param feeToken The address of the token in which the fee was paid.
     * @param totalLiquidationFee The total fee amount received from the trader's margin.
     * @param amountToLiquidator The portion of the fee paid to the liquidator.
     * @param amountToInsuranceFund The portion of the fee paid to the insurance fund.
     */
    event LiquidationFeeDistributed(
        address indexed liquidatedTrader,
        address indexed liquidator,
        bytes32 indexed marketId,
        address feeToken,
        uint256 totalLiquidationFee,
        uint256 amountToLiquidator,
        uint256 amountToInsuranceFund
    );

    /**
     * @notice Emitted when the protocol's share of funding payments is processed.
     * @param marketId The market ID where funding occurred.
     * @param feeToken The address of the token in which the fee was paid.
     * @param protocolShareAmount The amount of funding fee retained by the protocol.
     */
    event ProtocolFundingShareProcessed(
        bytes32 indexed marketId,
        address indexed feeToken,
        uint256 protocolShareAmount
    );


    // --- Core Fee Handling Functions ---

    /**
     * @notice Called by PerpClearingHouse to deposit trading fees.
     * @dev PerpClearingHouse will have already transferred the `amount` of `feeToken` to this contract.
     *      This function is primarily for accounting and further routing by the collector.
     * @param payer The address of the trader who paid the fee.
     * @param marketId The market ID where the trade occurred.
     * @param feeToken The address of the token in which the fee is paid.
     * @param amount The amount of the fee.
     * @param isTakerFee True if it's a taker fee.
     */
    function processTradingFee(
        address payer,
        bytes32 marketId,
        address feeToken,
        uint256 amount,
        bool isTakerFee
    ) external;

    /**
     * @notice Called by PerpClearingHouse after a liquidation.
     * @dev PerpClearingHouse will have already transferred the `totalLiquidationFee` of `feeToken` to this contract.
     *      This function is responsible for splitting the `totalLiquidationFee` and paying the `liquidator`
     *      their share, and sending the remainder to the insurance fund.
     * @param liquidatedTrader The address of the trader whose position was liquidated.
     * @param liquidator The address of the entity performing the liquidation (to receive their reward).
     * @param marketId The market ID of the liquidated position.
     * @param feeToken The address of the token in which the fee is paid.
     * @param totalLiquidationFee The total fee amount collected from the liquidated trader's margin.
     * @param liquidatorShareBps The share of the fee (in BPS) that goes to the liquidator.
     * @param insuranceFundAddress The address of the insurance fund to receive its share.
     */
    function processLiquidationFee(
        address liquidatedTrader,
        address liquidator,
        bytes32 marketId,
        address feeToken,
        uint256 totalLiquidationFee,
        uint256 liquidatorShareBps, // e.g., 5000 for 50%
        address insuranceFundAddress
    ) external;

    /**
     * @notice Called by PerpClearingHouse to deposit the protocol's share of funding payments.
     * @dev PerpClearingHouse will have already transferred the `protocolShareAmount` of `feeToken` to this contract.
     *      This function is for accounting and further routing of the protocol's funding revenue.
     * @param marketId The market ID where funding occurred.
     * @param feeToken The address of the token in which the fee is paid.
     * @param protocolShareAmount The amount of the funding fee retained by the protocol.
     */
    function processProtocolFundingShare(
        bytes32 marketId,
        address feeToken,
        uint256 protocolShareAmount
    ) external;

    /**
     * @notice Called by PerpClearingHouse when it needs to pay funding to a trader.
     * @dev This function signifies that the FeeCollector (acting as a funding pool manager)
     *      should transfer `netPaymentToTrader` of `payoutToken` to the `trader`.
     *      The FeeCollector must have sufficient balance of `payoutToken`.
     * @param trader The address of the trader receiving funding.
     * @param marketId The market ID related to the funding.
     * @param payoutToken The token in which the funding is paid (e.g., USDC).
     * @param netPaymentToTrader The net amount to be paid to the trader.
     */
    function payoutFundingToTrader(
        address trader,
        bytes32 marketId,
        address payoutToken,
        uint256 netPaymentToTrader
    ) external;


    // Optional: Admin functions for the FeeCollector itself
    function setTreasuryAddress(address _treasury) external; // If it routes funds
    function setInsuranceFundAddress(address _insuranceFund) external; // If it routes funds
    function withdrawCollectedFees(address token, address to, uint256 amount) external; // If it accumulates
}