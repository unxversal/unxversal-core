module unxversal::treasury {
    /*******************************
    * UnXversal Treasury – shared across protocol modules
    * - Centralizes fee deposits (USDC / UNXV)
    * - Admin-gated withdrawals and policy updates
    * - Optional UNXV burn via unxv::SupplyCap holder
    *******************************/
    use sui::tx_context::TxContext;
    use sui::transfer;
    use sui::display;
    use sui::package::Publisher;
    use sui::object;
    use sui::event;
    use sui::coin::{Self as Coin, Coin};
    use std::string::String;
    use std::time;

    use usdc::usdc::USDC;
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
    public struct TreasuryCfg has store { unxv_burn_bps: u64 }

    public struct TreasuryCap has key, store { id: UID }

    /*******************************
    * Treasury shared object
    *******************************/
    public struct Treasury has key, store {
        id: UID,
        usdc: Coin<USDC>,
        unxv: Coin<UNXV>,
        cfg: TreasuryCfg,
    }

    /*******************************
    * Init and Display
    *******************************/
    public entry fun init_treasury(ctx: &mut TxContext) {
        let t = Treasury { id: object::new(ctx), usdc: Coin::zero<USDC>(ctx), unxv: Coin::zero<UNXV>(ctx), cfg: TreasuryCfg { unxv_burn_bps: 0 } };
        transfer::share_object(t);
        transfer::public_transfer(TreasuryCap { id: object::new(ctx) }, ctx.sender());
        event::emit(TreasuryInitialized { treasury_id: object::id(&t), by: ctx.sender(), timestamp: time::now_ms() });
    }

    public entry fun init_treasury_with_display(publisher: &Publisher, ctx: &mut TxContext) {
        init_treasury(ctx);
        let mut disp = display::new<Treasury>(publisher, ctx);
        disp.add(b"name".to_string(),        b"Unxversal Treasury".to_string());
        disp.add(b"description".to_string(), b"Central fee treasury for Unxversal Protocol".to_string());
        disp.add(b"project_url".to_string(), b"https://unxversal.com".to_string());
        disp.update_version();
        transfer::public_transfer(disp, ctx.sender());
    }

    /*******************************
    * Deposits (anyone)
    *******************************/
    public entry fun deposit_usdc(treasury: &mut Treasury, mut c: Coin<USDC>, source: String, payer: address, ctx: &mut TxContext) {
        let amount = Coin::value(&c);
        assert!(amount > 0, E_ZERO_AMOUNT);
        Coin::merge(&mut treasury.usdc, c);
        event::emit(FeeReceived { source, asset: b"USDC".to_string(), amount, payer, timestamp: time::now_ms() });
    }

    public entry fun deposit_unxv(treasury: &mut Treasury, mut v: vector<Coin<UNXV>>, source: String, payer: address, ctx: &mut TxContext) {
        let mut merged = Coin::zero<UNXV>(ctx);
        let mut i = 0;
        let mut total: u64 = 0;
        while (i < vector::length(&v)) {
            let c = vector::pop_back(&mut v);
            total = total + Coin::value(&c);
            Coin::merge(&mut merged, c);
            i = i + 1;
        };
        assert!(total > 0, E_ZERO_AMOUNT);
        Coin::merge(&mut treasury.unxv, merged);
        event::emit(FeeReceived { source, asset: b"UNXV".to_string(), amount: total, payer, timestamp: time::now_ms() });
        // Note: actual burning requires SupplyCap; use burn_unxv below
    }

    /*******************************
    * Withdrawals and Policy (admin-gated by TreasuryCap)
    *******************************/
    public entry fun withdraw_usdc(_cap: &TreasuryCap, treasury: &mut Treasury, to: address, amount: u64, ctx: &mut TxContext) {
        assert!(amount > 0, E_ZERO_AMOUNT);
        let out = Coin::split(&mut treasury.usdc, amount, ctx);
        transfer::public_transfer(out, to);
        event::emit(TreasuryWithdrawn { asset: b"USDC".to_string(), amount, to, by: ctx.sender(), timestamp: time::now_ms() });
    }

    public entry fun withdraw_unxv(_cap: &TreasuryCap, treasury: &mut Treasury, to: address, amount: u64, ctx: &mut TxContext) {
        assert!(amount > 0, E_ZERO_AMOUNT);
        let out = Coin::split(&mut treasury.unxv, amount, ctx);
        transfer::public_transfer(out, to);
        event::emit(TreasuryWithdrawn { asset: b"UNXV".to_string(), amount, to, by: ctx.sender(), timestamp: time::now_ms() });
    }

    public entry fun set_policy(_cap: &TreasuryCap, treasury: &mut Treasury, new_cfg: TreasuryCfg, ctx: &TxContext) {
        treasury.cfg = new_cfg;
        event::emit(TreasuryPolicyUpdated { by: ctx.sender(), timestamp: time::now_ms() });
    }

    /// Burn UNXV from treasury using the protocol's SupplyCap
    public entry fun burn_unxv(_cap: &TreasuryCap, treasury: &mut Treasury, sc: &mut SupplyCap, amount: u64, ctx: &mut TxContext) {
        assert!(amount > 0, E_ZERO_AMOUNT);
        let exact = Coin::split(&mut treasury.unxv, amount, ctx);
        let mut vec = vector::empty<Coin<UNXV>>();
        vector::push_back(&mut vec, exact);
        unxversal::unxv::burn(sc, vec, ctx);
        event::emit(UNXVBurned { amount, by: ctx.sender(), timestamp: time::now_ms() });
    }
}


