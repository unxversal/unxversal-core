module unxversal::unxv_treasury {
    /*******************************
    * UnXversal Treasury - shared across protocol modules
    * - Centralizes fee deposits (admin-set collateral / UNXV)
    * - Admin-gated withdrawals and policy updates
    * - Optional UNXV burn via unxv::SupplyCap holder
    *******************************/

    use sui::display;
    use sui::package::Publisher;
    use sui::event;
    use sui::coin::{Self, Coin};
    use std::string::String;

    use unxversal::unxv::{Self as unxv, UNXV, SupplyCap};

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
        collateral: Coin<C>,
        unxv: Coin<UNXV>,
        cfg: TreasuryCfg,
    }

    /// Getter function for treasury ID (for cross-module access)
    public fun treasury_id<C>(treasury: &Treasury<C>): ID {
        sui::object::id(treasury)
    }

    /// Getter function for treasury object ID as address (for transfers)
    public fun treasury_address<C>(treasury: &Treasury<C>): address {
        sui::object::id_address(treasury)
    }

    /*******************************
    * Init and Display (Admin must set collateral type)
    *******************************/
    public entry fun init_treasury<C>(ctx: &mut tx_context::TxContext) {
        let t = Treasury<C> { id: sui::object::new(ctx), collateral: coin::zero<C>(ctx), unxv: coin::zero<UNXV>(ctx), cfg: TreasuryCfg { unxv_burn_bps: 0 } };
        let treasury_id = sui::object::id(&t);
        sui::transfer::share_object(t);
        sui::transfer::public_transfer(TreasuryCap { id: sui::object::new(ctx) }, tx_context::sender(ctx));
        event::emit(TreasuryInitialized { treasury_id, by: tx_context::sender(ctx), timestamp: 0u64 });
    }

    public entry fun init_treasury_with_display<C>(publisher: &Publisher, ctx: &mut tx_context::TxContext) {
        init_treasury<C>(ctx);
        let mut disp = display::new<Treasury<C>>(publisher, ctx);
        disp.add(b"name".to_string(),        b"Unxversal Treasury".to_string());
        disp.add(b"description".to_string(), b"Central fee treasury for Unxversal Protocol".to_string());
        disp.add(b"project_url".to_string(), b"https://unxversal.com".to_string());
        disp.update_version();
        sui::transfer::public_transfer(disp, tx_context::sender(ctx));
    }

    /*******************************
    * Deposits (anyone)
    *******************************/
    public fun deposit_collateral<C>(treasury: &mut Treasury<C>, mut c: Coin<C>, source: String, payer: address, _ctx: &mut tx_context::TxContext) {
        let amount = c.value();
        assert!(amount > 0, E_ZERO_AMOUNT);
        treasury.collateral.join(c);
        event::emit(FeeReceived { source, asset: b"COLLATERAL".to_string(), amount, payer, timestamp: 0u64 });
    }

    public fun deposit_unxv<C>(treasury: &mut Treasury<C>, mut v: vector<Coin<UNXV>>, source: String, payer: address, ctx: &mut tx_context::TxContext) {
        let mut merged = coin::zero<UNXV>(ctx);
        let mut i = 0;
        let mut total: u64 = 0;
        while (i < std::vector::length(&v)) {
            let c = std::vector::pop_back(&mut v);
            total = total + c.value();
            merged.join(c);
            i = i + 1;
        };
        std::vector::destroy_empty(v);
        assert!(total > 0, E_ZERO_AMOUNT);
        treasury.unxv.join(merged);
        event::emit(FeeReceived { source, asset: b"UNXV".to_string(), amount: total, payer, timestamp: 0u64 });
        // Note: actual burning requires SupplyCap; use burn_unxv below
    }

    /*******************************
    * Withdrawals and Policy (admin-gated by TreasuryCap)
    *******************************/
    public entry fun withdraw_collateral<C>(_cap: &TreasuryCap, treasury: &mut Treasury<C>, to: address, amount: u64, ctx: &mut tx_context::TxContext) {
        assert!(amount > 0, E_ZERO_AMOUNT);
        let out = treasury.collateral.split(amount, ctx);
        sui::transfer::public_transfer(out, to);
        event::emit(TreasuryWithdrawn { asset: b"COLLATERAL".to_string(), amount, to, by: tx_context::sender(ctx), timestamp: 0u64 });
    }

    public entry fun withdraw_unxv<C>(_cap: &TreasuryCap, treasury: &mut Treasury<C>, to: address, amount: u64, ctx: &mut tx_context::TxContext) {
        assert!(amount > 0, E_ZERO_AMOUNT);
        let out = treasury.unxv.split(amount, ctx);
        sui::transfer::public_transfer(out, to);
        event::emit(TreasuryWithdrawn { asset: b"UNXV".to_string(), amount, to, by: tx_context::sender(ctx), timestamp: 0u64 });
    }

    public fun set_policy<C>(_cap: &TreasuryCap, treasury: &mut Treasury<C>, new_cfg: TreasuryCfg, ctx: &tx_context::TxContext) {
        treasury.cfg = new_cfg;
        event::emit(TreasuryPolicyUpdated { by: tx_context::sender(ctx), timestamp: 0u64 });
    }

    /// Burn UNXV from treasury using the protocol's SupplyCap
    public entry fun burn_unxv<C>(_cap: &TreasuryCap, treasury: &mut Treasury<C>, sc: &mut SupplyCap, amount: u64, ctx: &mut tx_context::TxContext) {
        assert!(amount > 0, E_ZERO_AMOUNT);
        let exact = treasury.unxv.split(amount, ctx);
        let mut vec = std::vector::empty<Coin<UNXV>>();
        std::vector::push_back(&mut vec, exact);
        unxv::burn(sc, vec, ctx);
        event::emit(UNXVBurned { amount, by: tx_context::sender(ctx), timestamp: 0u64 });
    }

    /*******************************
    * Backward compatibility functions (for modules that haven't migrated yet)
    *******************************/
    /// DEPRECATED: Use deposit_collateral instead
    public fun deposit_usdc<C>(treasury: &mut Treasury<C>, c: Coin<C>, source: String, payer: address, ctx: &mut tx_context::TxContext) {
        deposit_collateral(treasury, c, source, payer, ctx);
    }
}


