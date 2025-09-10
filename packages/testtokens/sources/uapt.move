/// Module: testtokens_uapt (Testnet token + USDU-priced faucet)
/// - Symbol: UAPT, 6 decimals. Price from Pyth symbol "APT/USDC".
module testtokens::uapt {
    use sui::coin::{Self as coin, Coin, TreasuryCap};
    use sui::balance::{Self as balance, Balance};
    use sui::clock::Clock;
    use sui::event;
    use std::string::{Self as string, String};

    use unxversal::admin::{Self as AdminMod, AdminRegistry};
    use unxversal::oracle::{Self as oracle, OracleRegistry};
    use unxversal::usdu::USDU;
    use pyth::price_info::PriceInfoObject;

    public struct UAPT has drop {}
    public struct Faucet has key, store { id: UID, cap: TreasuryCap<UAPT>, usdu_treasury: Balance<USDU>, paused: bool }

    const E_NOT_ADMIN: u64 = 1; const E_PAUSED: u64 = 2; const E_TOO_SMALL_OUT: u64 = 3;

    public struct FaucetInitialized has copy, drop { by: address, timestamp_ms: u64 }
    public struct Paused has copy, drop { paused: bool, by: address, timestamp_ms: u64 }
    public struct BoughtWithUSDU has copy, drop { buyer: address, usdu_in: u64, uapt_out: u64, price_1e6: u64, timestamp_ms: u64 }

    fun init(witness: UAPT, ctx: &mut TxContext) {
        let (cap, metadata) = coin::create_currency(witness, 6, b"UAPT", b"Unxversal Testnet APT", b"", option::none(), ctx);
        transfer::public_freeze_object(metadata);
        let faucet = Faucet { id: object::new(ctx), cap, usdu_treasury: balance::zero<USDU>(), paused: false };
        transfer::share_object(faucet);
        event::emit(FaucetInitialized { by: ctx.sender(), timestamp_ms: sui::tx_context::epoch_timestamp_ms(ctx) });
    }

    public fun set_paused(reg_admin: &AdminRegistry, faucet: &mut Faucet, paused: bool, clock: &Clock, ctx: &TxContext) { assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN); faucet.paused = paused; event::emit(Paused { paused, by: ctx.sender(), timestamp_ms: sui::clock::timestamp_ms(clock) }); }
    public fun withdraw_usdu(reg_admin: &AdminRegistry, faucet: &mut Faucet, amount: u64, ctx: &mut TxContext): Coin<USDU> { assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN); coin::from_balance(balance::split(&mut faucet.usdu_treasury, amount), ctx) }

    public fun buy_with_usdu(reg: &OracleRegistry, faucet: &mut Faucet, price_info_object: &PriceInfoObject, usdu_in: Coin<USDU>, min_out: u64, clock: &Clock, ctx: &mut TxContext): Coin<UAPT> {
        assert!(!faucet.paused, E_PAUSED);
        let price_1e6 = oracle::get_price_for_symbol(reg, clock, &symbol_apt_usdc(), price_info_object);
        let usdu_amount = coin::value(&usdu_in);
        let out = compute_tokens_out_1e6(usdu_amount, price_1e6);
        assert!(out > 0 && out >= min_out, E_TOO_SMALL_OUT);
        faucet.usdu_treasury.join(coin::into_balance(usdu_in));
        let minted = coin::mint(&mut faucet.cap, out, ctx);
        event::emit(BoughtWithUSDU { buyer: ctx.sender(), usdu_in: usdu_amount, uapt_out: out, price_1e6, timestamp_ms: sui::clock::timestamp_ms(clock) });
        minted
    }

    fun compute_tokens_out_1e6(usdu_in: u64, price_1e6: u64): u64 { if (price_1e6 == 0) { 0 } else { (((usdu_in as u128) * 1_000_000) / (price_1e6 as u128)) as u64 } }
    fun symbol_apt_usdc(): String { string::utf8(b"APT/USDC") }
}


