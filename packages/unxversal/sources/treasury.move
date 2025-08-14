module unxversal::treasury {
    // Unxversal Treasury – shared across protocol modules
    // - Centralizes fee deposits (Collateral / UNXV)
    // - Admin-gated withdrawals and policy updates
    // - Optional UNXV burn via unxv::SupplyCap holder
    // TxContext, transfer, and object aliases are provided by default
    use sui::display;
    use sui::package::Publisher;
    use sui::event;
    use sui::coin::{Self as coin, Coin};
    use sui::balance::{Self as balance, Balance};
    use std::string::String;
    // timestamp helpers available via sui::tx_context::epoch_timestamp_ms

    use unxversal::unxv::{UNXV, SupplyCap};

    /*******************************
    * Errors
    *******************************/
    const E_ZERO_AMOUNT: u64 = 1;

    /*******************************
    * Events
    *******************************/
    public struct TreasuryInitialized has copy, drop { treasury_id: ID, by: address, timestamp: u64 }
    public struct FeeReceived has copy, drop { source: String, asset: String, amount: u64, payer: address, timestamp: u64 }
    public struct TreasuryWithdrawn has copy, drop { asset: String, amount: u64, to: address, by: address, timestamp: u64 }
    public struct UNXVBurned has copy, drop { amount: u64, by: address, timestamp: u64 }
    public struct TreasuryPolicyUpdated has copy, drop { by: address, timestamp: u64 }

    /*******************************
    * Config and capabilities
    *******************************/
    public struct TreasuryCfg has store, drop { unxv_burn_bps: u64 }

    public struct TreasuryCap has key, store { id: UID }

    /*******************************
    * Treasury shared object
    *******************************/
    public struct Treasury<phantom C> has key, store {
        id: UID,
        collateral: Balance<C>,
        unxv: Balance<UNXV>,
        cfg: TreasuryCfg,
    }

    /*******************************
    * Init and Display
    *******************************/
    entry fun init_treasury<C>(ctx: &mut TxContext) {
        let t = Treasury<C> { id: object::new(ctx), collateral: balance::zero<C>(), unxv: balance::zero<UNXV>(), cfg: TreasuryCfg { unxv_burn_bps: 0 } };
        transfer::share_object(t);
        transfer::public_transfer(TreasuryCap { id: object::new(ctx) }, ctx.sender());
        event::emit(TreasuryInitialized { treasury_id: object::id(&t), by: ctx.sender(), timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
    }

    entry fun init_treasury_with_display<C>(publisher: &Publisher, ctx: &mut TxContext) {
        init_treasury<C>(ctx);
        let mut disp = display::new<Treasury<C>>(publisher, ctx);
        disp.add(b"name".to_string(),        b"Unxversal Treasury".to_string());
        disp.add(b"description".to_string(), b"Central fee treasury for Unxversal Protocol".to_string());
        disp.add(b"project_url".to_string(), b"https://unxversal.com".to_string());
        disp.update_version();
        transfer::public_transfer(disp, ctx.sender());
    }

    /*******************************
    * Deposits (anyone)
    *******************************/
    entry fun deposit_collateral<C>(treasury: &mut Treasury<C>, mut c: Coin<C>, source: String, payer: address, ctx: &mut TxContext) {
        let amount = coin::value(&c);
        assert!(amount > 0, E_ZERO_AMOUNT);
        let bal = coin::into_balance(c);
        balance::join(&mut treasury.collateral, bal);
        event::emit(FeeReceived { source, asset: b"COLLATERAL".to_string(), amount, payer, timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
    }

    entry fun deposit_unxv<C>(treasury: &mut Treasury<C>, mut v: vector<Coin<UNXV>>, source: String, payer: address, ctx: &mut TxContext) {
        let mut merged = coin::zero<UNXV>(ctx);
        let mut i = 0;
        let mut total: u64 = 0;
        while (i < vector::length(&v)) {
            let c = vector::pop_back(&mut v);
            total = total + coin::value(&c);
            coin::join(&mut merged, c);
            i = i + 1;
        };
        assert!(total > 0, E_ZERO_AMOUNT);
        let bal = coin::into_balance(merged);
        balance::join(&mut treasury.unxv, bal);
        event::emit(FeeReceived { source, asset: b"UNXV".to_string(), amount: total, payer, timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
        // Note: actual burning requires SupplyCap; use burn_unxv below
    }

    /*******************************
    * Withdrawals and Policy (admin-gated by TreasuryCap)
    *******************************/
    entry fun withdraw_collateral<C>(_cap: &TreasuryCap, treasury: &mut Treasury<C>, to: address, amount: u64, ctx: &mut TxContext) {
        assert!(amount > 0, E_ZERO_AMOUNT);
        let out_bal = balance::split(&mut treasury.collateral, amount);
        let out = coin::from_balance(out_bal, ctx);
        transfer::public_transfer(out, to);
        event::emit(TreasuryWithdrawn { asset: b"COLLATERAL".to_string(), amount, to, by: ctx.sender(), timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
    }

    entry fun withdraw_unxv<C>(_cap: &TreasuryCap, treasury: &mut Treasury<C>, to: address, amount: u64, ctx: &mut TxContext) {
        assert!(amount > 0, E_ZERO_AMOUNT);
        let out_bal = balance::split(&mut treasury.unxv, amount);
        let out = coin::from_balance(out_bal, ctx);
        transfer::public_transfer(out, to);
        event::emit(TreasuryWithdrawn { asset: b"UNXV".to_string(), amount, to, by: ctx.sender(), timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
    }

    entry fun set_policy<C>(_cap: &TreasuryCap, treasury: &mut Treasury<C>, unxv_burn_bps: u64, ctx: &TxContext) {
        treasury.cfg.unxv_burn_bps = unxv_burn_bps;
        event::emit(TreasuryPolicyUpdated { by: ctx.sender(), timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
    }

    /// Burn UNXV from treasury using the protocol's SupplyCap
    entry fun burn_unxv<C>(_cap: &TreasuryCap, treasury: &mut Treasury<C>, sc: &mut SupplyCap, amount: u64, ctx: &mut TxContext) {
        assert!(amount > 0, E_ZERO_AMOUNT);
        let bal = balance::split(&mut treasury.unxv, amount);
        let exact = coin::from_balance(bal, ctx);
        let mut vec = vector::empty<Coin<UNXV>>();
        vector::push_back(&mut vec, exact);
        unxversal::unxv::burn(sc, vec, ctx);
        event::emit(UNXVBurned { amount, by: ctx.sender(), timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
    }

    // Helper: returns the address of the Treasury object (useful for transfers)
    public fun treasury_address<C>(t: &Treasury<C>): address { object::uid_to_address(&t.id) }
}


