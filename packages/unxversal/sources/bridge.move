/// Module: unxversal_bridge
/// Lightweight adapters to charge protocol fees/discounts and record rewards
/// for off-chain DeepBook SDK trades. No DeepBook dependency on-chain.
module unxversal::bridge {
    use sui::coin::{Self as coin, Coin};
    use sui::clock::Clock;
    use sui::event;

    use unxversal::fees::{Self as fees, FeeConfig, FeeVault};
    use unxversal::staking::StakingPool;
    use unxversal::unxv::UNXV;
    use unxversal::rewards::{Self as rewards, Rewards};
    use unxversal::oracle::{Self as uoracle, OracleRegistry};
    use std::string::String;

    use pyth::price_info::PriceInfoObject;

    /// Event: recorded spot volume in USD 1e6
    public struct SpotRecorded has copy, drop { who: address, usd_1e6: u128, timestamp_ms: u64 }

    /// Charge a taker protocol fee from the input base coin with optional UNXV discount flag.
    /// Returns the reduced input coin back to the caller.
    public fun take_protocol_fee_in_base<Base>(
        cfg: &FeeConfig,
        vault: &mut FeeVault,
        staking_pool: &mut StakingPool,
        mut base_in: Coin<Base>,
        maybe_unxv: Option<Coin<UNXV>>, // presence toggles discount path; refunded intact
        taker_fee_bps_override: Option<u64>, // None → cfg default; Some(x) → override
        clock: &Clock,
        ctx: &mut TxContext
    ): Coin<Base> {
        let amt = coin::value(&base_in);
        let mut unxv_opt = maybe_unxv;
        if (amt == 0) {
            if (option::is_some(&unxv_opt)) {
                let unxv = option::extract(&mut unxv_opt);
                transfer::public_transfer(unxv, ctx.sender());
            };
            option::destroy_none(unxv_opt);
            return base_in
        };

        let (taker_bps, _maker_bps_eff) = fees::apply_discounts_dex(
            match_bps(taker_fee_bps_override, fees::dex_taker_fee_bps(cfg)),
            fees::dex_maker_fee_bps(cfg),
            option::is_some(&unxv_opt),
            staking_pool,
            ctx.sender(),
            cfg,
        );
        let fee_amt = (amt as u128 * (taker_bps as u128) / (fees::bps_denom() as u128)) as u64;
        if (fee_amt > 0) {
            let fee_coin = coin::split(&mut base_in, fee_amt, ctx);
            fees::accrue_generic<Base>(vault, fee_coin, clock, ctx);
        };

        if (option::is_some(&unxv_opt)) {
            let unxv = option::extract(&mut unxv_opt);
            transfer::public_transfer(unxv, ctx.sender());
        };
        option::destroy_none(unxv_opt);
        base_in
    }

    /// Record spot rewards using quote output; computes USD 1e6 via OracleRegistry with Pyth PriceInfoObject.
    /// Returns the same coin unchanged to chain callers.
    public fun record_spot_from_quote<Quote>(
        rew: &mut Rewards,
        reg: &OracleRegistry,
        symbol: String, // e.g., "USDC/USD"
        price_info: &PriceInfoObject,
        quote_out: Coin<Quote>,
        clock: &Clock,
        ctx: &mut TxContext
    ): Coin<Quote> {
        let q = coin::value(&quote_out) as u128;
        if (q > 0) {
            let price_1e6 = uoracle::get_price_for_symbol(reg, clock, &symbol, price_info) as u128;
            let usd_1e6 = (q * price_1e6) / 1_000_000u128;
            rewards::on_spot_swap(rew, ctx.sender(), usd_1e6, clock);
            event::emit(SpotRecorded { who: ctx.sender(), usd_1e6, timestamp_ms: sui::clock::timestamp_ms(clock) });
        };
        quote_out
    }

    /// Record spot rewards using base output; multiplies base units by price_1e6 into USD 1e6.
    public fun record_spot_from_base<Base>(
        rew: &mut Rewards,
        reg: &OracleRegistry,
        symbol: String, // e.g., "SUI/USDC"
        price_info: &PriceInfoObject,
        base_out: Coin<Base>,
        clock: &Clock,
        ctx: &mut TxContext
    ): Coin<Base> {
        let b = coin::value(&base_out) as u128;
        if (b > 0) {
            let price_1e6 = uoracle::get_price_for_symbol(reg, clock, &symbol, price_info) as u128;
            let usd_1e6 = b * price_1e6 / 1_000_000u128;
            rewards::on_spot_swap(rew, ctx.sender(), usd_1e6, clock);
            event::emit(SpotRecorded { who: ctx.sender(), usd_1e6, timestamp_ms: sui::clock::timestamp_ms(clock) });
        };
        base_out
    }

    fun match_bps(mut override: Option<u64>, def: u64): u64 { if (option::is_some(&override)) option::extract(&mut override) else def }
}


