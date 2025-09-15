/// Module: testtokens_ueth (Testnet token + USDU-priced faucet)
/// ------------------------------------------------------------
/// - Defines `UETH` (Unxversal Testnet ETH) with 6 decimals
/// - Faucet mints `UETH` in exchange for `USDU` at the on-chain Pyth price
/// - Price source: `ETH/USDC` from `unxversal::oracle::OracleRegistry`
/// - Collected `USDU` is stored in an internal treasury and withdrawable by admins
module testtokens::ueth {
    use sui::coin::{Self as coin, Coin, TreasuryCap};
    use sui::balance::{Self as balance, Balance};
    use sui::clock::Clock;
    use sui::event;
    use std::string::{Self as string, String};

    use unxvcore::admin::{Self as AdminMod, AdminRegistry};
    use unxvcore::oracle::{Self as oracle, OracleRegistry};
    use unxvcore::usdu::USDU;

    use pyth::price_info::PriceInfoObject;

    /// Testnet UETH token type
    public struct UETH has drop {}

    /// Faucet state and USDU treasury
    public struct Faucet has key, store {
        id: UID,
        cap: TreasuryCap<UETH>,
        usdu_treasury: Balance<USDU>,
        paused: bool,
    }

    /// Errors
    const E_NOT_ADMIN: u64 = 1;
    const E_PAUSED: u64 = 2;
    const E_TOO_SMALL_OUT: u64 = 3;

    /// Events
    public struct FaucetInitialized has copy, drop { by: address, timestamp_ms: u64 }
    public struct Paused has copy, drop { paused: bool, by: address, timestamp_ms: u64 }
    public struct BoughtWithUSDU has copy, drop {
        buyer: address,
        usdu_in: u64,
        ueth_out: u64,
        price_1e6: u64,
        timestamp_ms: u64,
    }

    /// Initialize the UETH currency and share a Faucet.
    /// Decimals: 6, Symbol: "UETH", Name: "Unxversal Testnet ETH"
    fun init(witness: UETH, ctx: &mut TxContext) {
        let (cap, metadata) = coin::create_currency(
            witness,
            6,                          // decimals
            b"UETH",                    // symbol
            b"Unxversal Testnet ETH",  // name
            b"",                        // icon URL / description
            option::none(),
            ctx
        );
        transfer::public_freeze_object(metadata);

        let faucet = Faucet { id: object::new(ctx), cap, usdu_treasury: balance::zero<USDU>(), paused: false };
        transfer::share_object(faucet);
        event::emit(FaucetInitialized { by: ctx.sender(), timestamp_ms: sui::tx_context::epoch_timestamp_ms(ctx) });
    }

    /// Admin: pause or unpause the faucet.
    public fun set_paused(reg_admin: &AdminRegistry, faucet: &mut Faucet, paused: bool, clock: &Clock, ctx: &TxContext) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        faucet.paused = paused;
        event::emit(Paused { paused, by: ctx.sender(), timestamp_ms: sui::clock::timestamp_ms(clock) });
    }

    /// Admin: withdraw an exact `amount` of collected USDU to the caller (admin).
    public fun withdraw_usdu(reg_admin: &AdminRegistry, faucet: &mut Faucet, amount: u64, ctx: &mut TxContext): Coin<USDU> {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        let part = balance::split(&mut faucet.usdu_treasury, amount);
        coin::from_balance(part, ctx)
    }

    /// Public: buy UETH by paying USDU at the current oracle price (ETH/USDC).
    /// - `min_out` protects against price increases between tx creation and execution.
    public fun buy_with_usdu(
        reg: &OracleRegistry,
        faucet: &mut Faucet,
        price_info_object: &PriceInfoObject,
        usdu_in: Coin<USDU>,
        min_out: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ): Coin<UETH> {
        assert!(!faucet.paused, E_PAUSED);

        // Read ETH/USDC price scaled to 1e6
        let price_1e6 = oracle::get_price_for_symbol(reg, clock, &symbol_eth_usdc(), price_info_object);

        // Compute output UETH amount with 6 decimals: out = floor(usdu * 1e6 / price)
        let usdu_amount: u64 = coin::value(&usdu_in);
        let out: u64 = compute_tokens_out_1e6(usdu_amount, price_1e6);
        assert!(out > 0 && out >= min_out, E_TOO_SMALL_OUT);

        // Accrue USDU and mint UETH to buyer
        faucet.usdu_treasury.join(coin::into_balance(usdu_in));
        let minted = coin::mint(&mut faucet.cap, out, ctx);

        event::emit(BoughtWithUSDU { buyer: ctx.sender(), usdu_in: usdu_amount, ueth_out: out, price_1e6, timestamp_ms: sui::clock::timestamp_ms(clock) });
        minted
    }

    /// Compute tokens out given USDU in and price (both 1e6-scaled). Uses u128 for headroom.
    fun compute_tokens_out_1e6(usdu_in: u64, price_1e6: u64): u64 {
        if (price_1e6 == 0) { 0 } else { (((usdu_in as u128) * 1_000_000) / (price_1e6 as u128)) as u64 }
    }

    /// Constant symbol used for oracle lookup: "ETH/USDC"
    fun symbol_eth_usdc(): String { string::utf8(b"ETH/USDC") }
}



