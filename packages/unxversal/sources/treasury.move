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
    use sui::table::{Self as table, Table};
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
    public struct TreasuryCfg has store, drop { unxv_burn_bps: u64, auto_bot_rewards_bps: u64 }

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

    /// Bot rewards treasury – accumulates automatic splits for bots
    public struct BotRewardsTreasury<phantom C> has key, store {
        id: UID,
        collateral: Balance<C>,
        unxv: Balance<UNXV>,
        epoch_collateral: Table<u64, u64>,
        epoch_unxv: Table<u64, u64>,
    }

    /*******************************
    * Init and Display
    *******************************/
    entry fun init_treasury<C>(ctx: &mut TxContext) {
        let t = Treasury<C> { id: object::new(ctx), collateral: balance::zero<C>(), unxv: balance::zero<UNXV>(), cfg: TreasuryCfg { unxv_burn_bps: 0, auto_bot_rewards_bps: 0 } };
        let tid = object::id(&t);
        event::emit(TreasuryInitialized { treasury_id: tid, by: ctx.sender(), timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
        transfer::share_object(t);
        transfer::public_transfer(TreasuryCap { id: object::new(ctx) }, ctx.sender());
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

    /// Create a BotRewardsTreasury for collateral type C
    entry fun init_bot_rewards_treasury<C>(ctx: &mut TxContext) {
        let b = BotRewardsTreasury<C> {
            id: object::new(ctx),
            collateral: balance::zero<C>(),
            unxv: balance::zero<UNXV>(),
            epoch_collateral: table::new<u64, u64>(ctx),
            epoch_unxv: table::new<u64, u64>(ctx),
        };
        transfer::share_object(b);
    }

    /*******************************
    * Deposits (anyone)
    *******************************/
    public(package) fun deposit_collateral<C>(treasury: &mut Treasury<C>, c: Coin<C>, source: String, payer: address, ctx: &TxContext) {
        let amount = coin::value(&c);
        assert!(amount > 0, E_ZERO_AMOUNT);
        let bal = coin::into_balance(c);
        balance::join(&mut treasury.collateral, bal);
        event::emit(FeeReceived { source, asset: b"COLLATERAL".to_string(), amount, payer, timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
    }

    public(package) fun deposit_unxv<C>(treasury: &mut Treasury<C>, mut v: vector<Coin<UNXV>>, source: String, payer: address, ctx: &mut TxContext) {
        let mut merged = coin::zero<UNXV>(ctx);
        let mut total: u64 = 0;
        while (!vector::is_empty(&v)) {
            let c = vector::pop_back(&mut v);
            total = total + coin::value(&c);
            coin::join(&mut merged, c);
        };
        assert!(total > 0, E_ZERO_AMOUNT);
        let bal = coin::into_balance(merged);
        balance::join(&mut treasury.unxv, bal);
        event::emit(FeeReceived { source, asset: b"UNXV".to_string(), amount: total, payer, timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
        vector::destroy_empty<Coin<UNXV>>(v);
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

    /// Set automatic bot rewards split (bps in [0,10000])
    entry fun set_auto_bot_rewards_bps<C>(_cap: &TreasuryCap, treasury: &mut Treasury<C>, bps: u64, _ctx: &TxContext) {
        treasury.cfg.auto_bot_rewards_bps = bps;
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

    // Cross-module deposit helpers (callable from other unxversal modules)
    public(package) fun deposit_collateral_ext<C>(treasury: &mut Treasury<C>, c: Coin<C>, source: String, payer: address, ctx: &TxContext) {
        let amount = coin::value(&c);
        assert!(amount > 0, E_ZERO_AMOUNT);
        let bal = coin::into_balance(c);
        balance::join(&mut treasury.collateral, bal);
        event::emit(FeeReceived { source, asset: b"COLLATERAL".to_string(), amount, payer, timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
    }

    public(package) fun deposit_unxv_ext<C>(treasury: &mut Treasury<C>, mut v: vector<Coin<UNXV>>, source: String, payer: address, ctx: &mut TxContext) {
        let mut merged = coin::zero<UNXV>(ctx);
        let mut total: u64 = 0;
        while (!vector::is_empty(&v)) {
            let c = vector::pop_back(&mut v);
            total = total + coin::value(&c);
            coin::join(&mut merged, c);
        };
        assert!(total > 0, E_ZERO_AMOUNT);
        let bal = coin::into_balance(merged);
        balance::join(&mut treasury.unxv, bal);
        event::emit(FeeReceived { source, asset: b"UNXV".to_string(), amount: total, payer, timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
        vector::destroy_empty<Coin<UNXV>>(v);
    }

    /// Deposit variants that apply automatic bot reward split
    public(package) fun deposit_collateral_with_rewards<C>(treasury: &mut Treasury<C>, bot: &mut BotRewardsTreasury<C>, c: Coin<C>, source: String, payer: address, ctx: &mut TxContext) {
        let amount = coin::value(&c);
        assert!(amount > 0, E_ZERO_AMOUNT);
        let bps = treasury.cfg.auto_bot_rewards_bps;
        if (bps == 0) {
            let bal = coin::into_balance(c);
            balance::join(&mut treasury.collateral, bal);
            event::emit(FeeReceived { source, asset: b"COLLATERAL".to_string(), amount, payer, timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
            return
        };
        let to_bot = (amount * bps) / 10_000;
        let mut tmp = c;
        let bot_coin = if (to_bot > 0) { coin::split(&mut tmp, to_bot, ctx) } else { coin::zero<C>(ctx) };
        let tre_coin = tmp;
        if (to_bot > 0) { let bot_bal = coin::into_balance(bot_coin); balance::join(&mut bot.collateral, bot_bal); } else { coin::destroy_zero(bot_coin); };
        let tre_bal = coin::into_balance(tre_coin); balance::join(&mut treasury.collateral, tre_bal);
        event::emit(FeeReceived { source, asset: b"COLLATERAL".to_string(), amount, payer, timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
    }

    /// Epoch-aware variant: also increments epoch reserve counters
    public(package) fun deposit_collateral_with_rewards_for_epoch<C>(treasury: &mut Treasury<C>, bot: &mut BotRewardsTreasury<C>, epoch_id: u64, c: Coin<C>, source: String, payer: address, ctx: &mut TxContext) {
        let amount = coin::value(&c);
        assert!(amount > 0, E_ZERO_AMOUNT);
        let bps = treasury.cfg.auto_bot_rewards_bps;
        let mut tmp = c;
        let to_bot = (amount * bps) / 10_000;
        let bot_coin = if (to_bot > 0) { coin::split(&mut tmp, to_bot, ctx) } else { coin::zero<C>(ctx) };
        let tre_coin = tmp;
        if (to_bot > 0) {
            let bot_bal = coin::into_balance(bot_coin); balance::join(&mut bot.collateral, bot_bal);
            let cur = if (table::contains(&bot.epoch_collateral, epoch_id)) { *table::borrow(&bot.epoch_collateral, epoch_id) } else { 0 };
            let newv = cur + to_bot;
            if (table::contains(&bot.epoch_collateral, epoch_id)) { let _ = table::remove(&mut bot.epoch_collateral, epoch_id); };
            table::add(&mut bot.epoch_collateral, epoch_id, newv);
        } else { coin::destroy_zero(bot_coin); };
        let tre_bal = coin::into_balance(tre_coin); balance::join(&mut treasury.collateral, tre_bal);
        event::emit(FeeReceived { source, asset: b"COLLATERAL".to_string(), amount, payer, timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
    }

    public(package) fun deposit_unxv_with_rewards<C>(treasury: &mut Treasury<C>, bot: &mut BotRewardsTreasury<C>, mut v: vector<Coin<UNXV>>, source: String, payer: address, ctx: &mut TxContext) {
        let mut merged = coin::zero<UNXV>(ctx);
        let mut total: u64 = 0;
        while (!vector::is_empty(&v)) { let c = vector::pop_back(&mut v); total = total + coin::value(&c); coin::join(&mut merged, c); };
        assert!(total > 0, E_ZERO_AMOUNT);
        let bps = treasury.cfg.auto_bot_rewards_bps;
        if (bps == 0) {
            let bal = coin::into_balance(merged); balance::join(&mut treasury.unxv, bal);
            event::emit(FeeReceived { source, asset: b"UNXV".to_string(), amount: total, payer, timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
            vector::destroy_empty<Coin<UNXV>>(v);
            return
        };
        let to_bot = (total * bps) / 10_000;
        let mut tmpu = merged;
        let bot_unxv = if (to_bot > 0) { coin::split(&mut tmpu, to_bot, ctx) } else { coin::zero<UNXV>(ctx) };
        let tre_unxv = tmpu;
        if (to_bot > 0) { let bot_bal_u = coin::into_balance(bot_unxv); balance::join(&mut bot.unxv, bot_bal_u); } else { coin::destroy_zero(bot_unxv); };
        let tre_bal_u = coin::into_balance(tre_unxv); balance::join(&mut treasury.unxv, tre_bal_u);
        event::emit(FeeReceived { source, asset: b"UNXV".to_string(), amount: total, payer, timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
        vector::destroy_empty<Coin<UNXV>>(v);
    }

    /// Epoch-aware variant for UNXV
    public(package) fun deposit_unxv_with_rewards_for_epoch<C>(treasury: &mut Treasury<C>, bot: &mut BotRewardsTreasury<C>, epoch_id: u64, mut v: vector<Coin<UNXV>>, source: String, payer: address, ctx: &mut TxContext) {
        let mut merged = coin::zero<UNXV>(ctx);
        let mut total: u64 = 0;
        while (!vector::is_empty(&v)) { let c = vector::pop_back(&mut v); total = total + coin::value(&c); coin::join(&mut merged, c); };
        assert!(total > 0, E_ZERO_AMOUNT);
        let bps = treasury.cfg.auto_bot_rewards_bps;
        let mut tmpu = merged;
        let to_bot = (total * bps) / 10_000;
        let bot_unxv = if (to_bot > 0) { coin::split(&mut tmpu, to_bot, ctx) } else { coin::zero<UNXV>(ctx) };
        let tre_unxv = tmpu;
        if (to_bot > 0) {
            let bot_bal_u = coin::into_balance(bot_unxv); balance::join(&mut bot.unxv, bot_bal_u);
            let curu = if (table::contains(&bot.epoch_unxv, epoch_id)) { *table::borrow(&bot.epoch_unxv, epoch_id) } else { 0 };
            let newu = curu + to_bot;
            if (table::contains(&bot.epoch_unxv, epoch_id)) { let _ = table::remove(&mut bot.epoch_unxv, epoch_id); };
            table::add(&mut bot.epoch_unxv, epoch_id, newu);
        } else { coin::destroy_zero(bot_unxv); };
        let tre_bal_u = coin::into_balance(tre_unxv); balance::join(&mut treasury.unxv, tre_bal_u);
        event::emit(FeeReceived { source, asset: b"UNXV".to_string(), amount: total, payer, timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
        vector::destroy_empty<Coin<UNXV>>(v);
    }

    /*******************************
     * BotRewardsTreasury epoch helpers (package scope)
     *******************************/
    public(package) fun epoch_reserves<C>(bot: &BotRewardsTreasury<C>, epoch_id: u64): (u64, u64) {
        let coll = if (table::contains(&bot.epoch_collateral, epoch_id)) { *table::borrow(&bot.epoch_collateral, epoch_id) } else { 0 };
        let unxv_amt = if (table::contains(&bot.epoch_unxv, epoch_id)) { *table::borrow(&bot.epoch_unxv, epoch_id) } else { 0 };
        (coll, unxv_amt)
    }

    public(package) fun payout_epoch_shares<C>(bot: &mut BotRewardsTreasury<C>, epoch_id: u64, pay_coll: u64, pay_unxv: u64, to: address, ctx: &mut TxContext) {
        if (pay_coll > 0) {
            let bal_c = balance::split(&mut bot.collateral, pay_coll);
            let coin_c: Coin<C> = coin::from_balance(bal_c, ctx);
            transfer::public_transfer(coin_c, to);
        };
        if (pay_unxv > 0) {
            let bal_u = balance::split(&mut bot.unxv, pay_unxv);
            let coin_u: Coin<UNXV> = coin::from_balance(bal_u, ctx);
            transfer::public_transfer(coin_u, to);
        };
        let (cur_coll, cur_unxv) = epoch_reserves(bot, epoch_id);
        let new_coll = if (cur_coll > pay_coll) { cur_coll - pay_coll } else { 0 };
        let new_unxv = if (cur_unxv > pay_unxv) { cur_unxv - pay_unxv } else { 0 };
        if (table::contains(&bot.epoch_collateral, epoch_id)) { let _ = table::remove(&mut bot.epoch_collateral, epoch_id); };
        table::add(&mut bot.epoch_collateral, epoch_id, new_coll);
        if (table::contains(&bot.epoch_unxv, epoch_id)) { let _ = table::remove(&mut bot.epoch_unxv, epoch_id); };
        table::add(&mut bot.epoch_unxv, epoch_id, new_unxv);
    }

    /*******************************
     * Test-only constructors and getters
     *******************************/
    #[test_only]
    public fun new_treasury_for_testing<C>(ctx: &mut TxContext): Treasury<C> {
        Treasury<C> { id: object::new(ctx), collateral: balance::zero<C>(), unxv: balance::zero<UNXV>(), cfg: TreasuryCfg { unxv_burn_bps: 0, auto_bot_rewards_bps: 0 } }
    }

    #[test_only]
    public fun new_bot_rewards_treasury_for_testing<C>(ctx: &mut TxContext): BotRewardsTreasury<C> {
        BotRewardsTreasury<C> { id: object::new(ctx), collateral: balance::zero<C>(), unxv: balance::zero<UNXV>(), epoch_collateral: table::new<u64, u64>(ctx), epoch_unxv: table::new<u64, u64>(ctx) }
    }

    #[test_only]
    public fun set_auto_bot_rewards_bps_for_testing<C>(treasury: &mut Treasury<C>, bps: u64) { treasury.cfg.auto_bot_rewards_bps = bps }

    public(package) fun tre_balance_collateral<C>(treasury: &Treasury<C>): u64 { balance::value(&treasury.collateral) }
    public(package) fun tre_balance_unxv<C>(treasury: &Treasury<C>): u64 { balance::value(&treasury.unxv) }

    #[test_only]
    public fun tre_balance_collateral_for_testing<C>(treasury: &Treasury<C>): u64 { tre_balance_collateral<C>(treasury) }
    public(package) fun bot_balance_collateral<C>(bot: &BotRewardsTreasury<C>): u64 { balance::value(&bot.collateral) }
    public(package) fun bot_balance_unxv<C>(bot: &BotRewardsTreasury<C>): u64 { balance::value(&bot.unxv) }
}


