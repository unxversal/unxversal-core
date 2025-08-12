module unxversal::common {
    use sui::tx_context::TxContext;
    use std::string::String;

    /// Standard error codes for common operations
    const E_INSUFFICIENT_UNXV_BALANCE: u64 = 1;
    const E_INVALID_FEE_ASSET: u64 = 2;

    /// Calculates fee breakdown when offering a discount via UNXV token payment.
    /// - `base_fee`: the original fee amount before discount
    /// - `discount_pct`: percentage discount (e.g., 20 for 20%)
    /// - `payment_asset`: asset the user chooses to pay with ("UNXV" or others)
    /// - `unxv_balance`: user's current UNXV balance
    public fun calculate_fee_with_discount(
        base_fee: u64,
        discount_pct: u64,
        payment_asset: String,
        unxv_balance: u64
    ): FeeCalculation {
        let mut discount = 0;
        // Only apply discount if paying with UNXV and having sufficient balance
        if (payment_asset == "UNXV".to_string() && unxv_balance >= (base_fee * discount_pct) / 100) {
            discount = (base_fee * discount_pct) / 100;
        }
        let final_fee = base_fee - discount;
        FeeCalculation { base_fee, unxv_discount: discount, final_fee, payment_asset }
    }

    /// Represents the result of a fee calculation, including any UNXV discount.
    public struct FeeCalculation has drop {
        /// Original fee before discount
        base_fee: u64,
        /// Discount amount (in fee units) applied when paying with UNXV
        unxv_discount: u64,
        /// Final fee after discount
        final_fee: u64,
        /// Asset used for payment (e.g., "UNXV" or collateral symbol)
        payment_asset: String,
    }

    /// Event emitted whenever a fee is collected by the protocol.
    /// Clients should index this to track revenue and discounts.
    public struct FeeCollected has copy, drop {
        /// Type of fee (e.g., "mint", "burn", "stability", "liquidation")
        fee_type: String,
        /// Amount of fee collected (in smallest units of the fee asset)
        amount: u64,
        /// Asset used to pay the fee (e.g., collateral, "UNXV", or other)
        asset_type: String,
        /// Address of the user who paid the fee
        user: address,
        /// Whether a UNXV discount was applied
        unxv_discount_applied: bool,
        /// Timestamp when the fee was collected
        timestamp: u64,
    }

    /// Event emitted when UNXV tokens are burned as part of fee discounts or other deflationary actions.
    public struct UnxvBurned has copy, drop {
        /// Amount of UNXV tokens burned
        amount_burned: u64,
        /// Source of fees that triggered this burn (e.g., "minting", "trading")
        fee_source: String,
        /// Timestamp when the burn occurred
        timestamp: u64,
    }

    /// Processes fee payment, including optionally auto-swapping to UNXV and distributing split to bots.
    /// This is a stub: specific modules should invoke common.calculate_fee_with_discount and then
    /// implement their own asset transfers, swaps, burns, and event emission.
    public fun process_fee(
        fee_calc: FeeCalculation,
        // Address or handle of the BalanceManager for asset transfers
        _balance_manager: address,
        // Address or handle of the AutoSwap contract to convert fees to UNXV
        _autoswap_contract: address,
        // Percentage of fee to split to bots (in %)
        _bot_split: u64,
        // Address to credit bot rewards
        _bot_address: address,
        ctx: &mut TxContext
    ) {
        // Stub: caller should implement:
        // 1. Transfer `fee_calc.final_fee` from user via BalanceManager
        // 2. If payment_asset != "UNXV", optionally swap to UNXV via AutoSwap
        // 3. Burn or distribute UNXV discount portion
        // 4. Emit FeeCollected and UnxvBurned events via `tx_context.emit_event`
        // Example:
        // let event = FeeCollected { ... };
        // tx_context::emit_event(ctx, event);
    }
}