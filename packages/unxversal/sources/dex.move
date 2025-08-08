module unxversal::dex {
    /*******************************
    * Minimal P2P DEX helpers (no DeepBook)
    * - Coin <-> Synth OTC settlement
    * - UNXV <-> USDC OTC settlement
    *******************************/
    use sui::tx_context::TxContext;
    use sui::transfer;
    use sui::coin::{Self as Coin, Coin};
    use sui::clock::Clock;
    use sui::event;
    use std::string::String;
    use std::vector;
    use std::time;

    use usdc::usdc::USDC;
    use pyth::price_info::PriceInfoObject;
    use unxversal::unxv::UNXV;
    use unxversal::synthetics::{SynthRegistry, CollateralVault, mint_synthetic, burn_synthetic};
    use unxversal::oracle::OracleConfig;
    use unxversal::common::FeeCollected;

    const E_INSUFFICIENT_PAYMENT: u64 = 1;
    const E_ZERO_AMOUNT: u64 = 2;
    const E_PAUSED: u64 = 3;

    /*******************************
    * Events
    *******************************/
    public struct SwapExecuted has copy, drop {
        market: String,         // e.g., "COIN/SYNTH", "UNXV/USDC"
        base: String,           // base symbol for context (e.g., coin symbol or synth symbol)
        quote: String,          // quote symbol for context
        price: u64,             // units of quote per 1 base
        size: u64,              // base size filled
        payer: address,
        receiver: address,
        timestamp: u64,
    }

    /*******************************
    * OTC: Coin<Base> -> Synth(symbol)
    * Buyer pays with Coin<Base>; Buyer mints synth; Seller burns synth; Seller receives coin.
    * - price is expressed in BaseCoin units per 1 synth
    *******************************/
    public entry fun otc_coin_for_synth<BaseCoin>(
        registry: &mut SynthRegistry,
        oracle_cfg: &OracleConfig,
        clock: &Clock,
        price_info: &PriceInfoObject,
        buyer_vault: &mut CollateralVault,
        seller_vault: &mut CollateralVault,
        synthetic_symbol: String,
        synth_amount: u64,
        coin_price_per_synth: u64,
        mut buyer_payment: Coin<BaseCoin>,
        ctx: &mut TxContext
    ) {
        assert!(!registry.paused, E_PAUSED);
        assert!(synth_amount > 0, E_ZERO_AMOUNT);

        // Notional coin required
        let coin_required = synth_amount * coin_price_per_synth;
        let total_paid = Coin::value(&buyer_payment);
        assert!(total_paid >= coin_required, E_INSUFFICIENT_PAYMENT);

        // Pay seller and refund change
        let pay_coin = Coin::split(&mut buyer_payment, coin_required, ctx);
        transfer::public_transfer(pay_coin, seller_vault.owner);
        // Refund remainder (if any) to buyer
        if (Coin::value(&buyer_payment) > 0) {
            transfer::public_transfer(buyer_payment, buyer_vault.owner);
        } else {
            // ensure we move an empty coin to avoid resource loss (optional no-op)
            let zero = Coin::zero<BaseCoin>(ctx);
            transfer::public_transfer(zero, buyer_vault.owner);
        };

        // Adjust exposures
        mint_synthetic(
            buyer_vault,
            registry,
            oracle_cfg,
            clock,
            price_info,
            synthetic_symbol.clone(),
            synth_amount,
            ctx,
        );
        burn_synthetic(
            seller_vault,
            registry,
            oracle_cfg,
            clock,
            price_info,
            synthetic_symbol,
            synth_amount,
            ctx,
        );

        event::emit(SwapExecuted {
            market: b"COIN/SYNTH".to_string(),
            base: b"COIN".to_string(),
            quote: b"SYNTH".to_string(),
            price: coin_price_per_synth,
            size: synth_amount,
            payer: buyer_vault.owner,
            receiver: seller_vault.owner,
            timestamp: time::now_ms(),
        });
    }

    /*******************************
    * OTC: UNXV <-> USDC swap at agreed price
    * Buyer pays UNXV, receives USDC from seller.
    * price_unxv_in_usdc: USDC units per 1 UNXV
    *******************************/
    public entry fun otc_unxv_for_usdc(
        mut buyer_unxv: vector<Coin<UNXV>>,
        mut seller_usdc: Coin<USDC>,
        price_unxv_in_usdc: u64,
        unxv_amount: u64,
        buyer: address,
        seller: address,
        ctx: &mut TxContext
    ) {
        assert!(unxv_amount > 0, E_ZERO_AMOUNT);

        // Merge buyer UNXV into a single coin
        let mut in_unxv = Coin::zero<UNXV>(ctx);
        let mut i = 0;
        while (i < vector::length(&buyer_unxv)) {
            let c = vector::pop_back(&mut buyer_unxv);
            Coin::merge(&mut in_unxv, c);
            i = i + 1;
        };
        let total_unxv = Coin::value(&in_unxv);
        assert!(total_unxv >= unxv_amount, E_INSUFFICIENT_PAYMENT);

        // Compute USDC owed
        let usdc_owed = unxv_amount * price_unxv_in_usdc;
        let seller_usdc_available = Coin::value(&seller_usdc);
        assert!(seller_usdc_available >= usdc_owed, E_INSUFFICIENT_PAYMENT);

        // Transfer exact UNXV to seller, refund remainder to buyer
        let exact_unxv = Coin::split(&mut in_unxv, unxv_amount, ctx);
        transfer::public_transfer(exact_unxv, seller);
        // Refund any remainder back to buyer
        transfer::public_transfer(in_unxv, buyer);

        // Pay USDC to buyer and refund remainder to seller
        let usdc_to_buyer = Coin::split(&mut seller_usdc, usdc_owed, ctx);
        transfer::public_transfer(usdc_to_buyer, buyer);
        transfer::public_transfer(seller_usdc, seller);

        // Emit fee event (treat as otc trade)
        let trade_fee = (usdc_owed * 30) / 10_000; // 30 bps placeholder
        event::emit(FeeCollected {
            fee_type: b"otc_trade".to_string(),
            amount: trade_fee,
            asset_type: b"USDC".to_string(),
            user: buyer,
            unxv_discount_applied: false,
            timestamp: time::now_ms(),
        });

        event::emit(SwapExecuted {
            market: b"UNXV/USDC".to_string(),
            base: b"UNXV".to_string(),
            quote: b"USDC".to_string(),
            price: price_unxv_in_usdc,
            size: unxv_amount,
            payer: buyer,
            receiver: seller,
            timestamp: time::now_ms(),
        });
    }
}


