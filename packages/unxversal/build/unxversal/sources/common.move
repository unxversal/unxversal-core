module unxversal::common {
    use std::string::String;

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

}