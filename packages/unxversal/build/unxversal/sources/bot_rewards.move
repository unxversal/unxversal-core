module unxversal::bot_rewards {
    use sui::table::{Self as table, Table};
    use sui::clock::Clock;
    use std::string::String;
    use sui::event;
    use sui::balance::{Self as balance};
    use sui::coin::{Self as coin};
    use unxversal::admin::{Self as AdminMod, AdminRegistry};
    use unxversal::unxv::UNXV;
    use unxversal::treasury::{Self as TreasuryMod, BotRewardsTreasury};

    /// Tracks task weights and per-actor points for the current accounting window
    public struct BotPointsRegistry has key, store {
        id: UID,
        epoch_zero_ms: u64,
        epoch_duration_ms: u64,
        weights: Table<String, u64>,          // task_key -> weight
        points: Table<address, u64>,          // actor -> points in current period
        points_by_epoch: Table<u64, Table<address, u64>>,  // epoch -> (actor -> points)
        total_points_by_epoch: Table<u64, u128>,           // epoch -> total
    }

    /// Canonical event for bot point awards
    public struct PointsAwarded has copy, drop { task: String, points: u64, actor: address, timestamp: u64 }

    /// Per-recipient payout event during distribution
    public struct BotPayout has copy, drop { recipient: address, collateral_paid: u64, unxv_paid: u64, timestamp: u64 }

    /// Create the registry (admin-gated via AdminRegistry)
    public fun init_points_registry(admin_reg: &AdminRegistry, ctx: &mut TxContext) {
        assert!(AdminMod::is_admin(admin_reg, ctx.sender()), 0);
        let reg = BotPointsRegistry {
            id: object::new(ctx),
            epoch_zero_ms: 0,
            epoch_duration_ms: 2_592_000_000, // ~30 days
            weights: table::new<String, u64>(ctx),
            points: table::new<address, u64>(ctx),
            points_by_epoch: table::new<u64, Table<address, u64>>(ctx),
            total_points_by_epoch: table::new<u64, u128>(ctx),
        };
        transfer::share_object(reg);
    }

    /// Set or update a task weight
    public fun set_weight(admin_reg: &AdminRegistry, reg: &mut BotPointsRegistry, task_key: String, weight: u64, _ctx: &TxContext) {
        assert!(AdminMod::is_admin(admin_reg, _ctx.sender()), 0);
        if (table::contains(&reg.weights, clone_string(&task_key))) { let _ = table::remove(&mut reg.weights, clone_string(&task_key)); };
        table::add(&mut reg.weights, task_key, weight);
    }

    /// Admin: configure epoch schedule
    public fun set_epoch_config(admin_reg: &AdminRegistry, reg: &mut BotPointsRegistry, zero_ms: u64, duration_ms: u64, _ctx: &TxContext) {
        assert!(AdminMod::is_admin(admin_reg, _ctx.sender()), 0);
        assert!(duration_ms > 0, 0);
        reg.epoch_zero_ms = zero_ms;
        reg.epoch_duration_ms = duration_ms;
    }

    public fun current_epoch(reg: &BotPointsRegistry, clock: &Clock): u64 {
        let now = sui::clock::timestamp_ms(clock);
        if (now <= reg.epoch_zero_ms) { 0 } else { (now - reg.epoch_zero_ms) / reg.epoch_duration_ms }
    }

    /// Award points to an actor for a given task; timestamp sourced from Clock
    public fun award_points(reg: &mut BotPointsRegistry, task_key: String, actor: address, clock: &Clock, ctx: &mut TxContext) {
        let now = sui::clock::timestamp_ms(clock);
        let w = if (table::contains(&reg.weights, clone_string(&task_key))) { *table::borrow(&reg.weights, clone_string(&task_key)) } else { 0 };
        if (w > 0) {
            let cur = if (table::contains(&reg.points, actor)) { *table::borrow(&reg.points, actor) } else { 0 };
            let newp = cur + w;
            if (table::contains(&reg.points, actor)) { let _ = table::remove(&mut reg.points, actor); };
            table::add(&mut reg.points, actor, newp);
            event::emit(PointsAwarded { task: task_key, points: w, actor, timestamp: now });
            // epoch-scoped accumulation
            let e = current_epoch(reg, clock);
            if (!table::contains(&reg.points_by_epoch, e)) {
                let sub_tbl = table::new<address, u64>(ctx);
                table::add(&mut reg.points_by_epoch, e, sub_tbl);
            };
            let sub = table::borrow_mut(&mut reg.points_by_epoch, e);
            let cur_ep = if (table::contains(sub, actor)) { *table::borrow(sub, actor) } else { 0 };
            let new_ep = cur_ep + w;
            if (table::contains(sub, actor)) { let _ = table::remove(sub, actor); };
            table::add(sub, actor, new_ep);
            let tot = if (table::contains(&reg.total_points_by_epoch, e)) { *table::borrow(&reg.total_points_by_epoch, e) } else { 0 };
            let new_tot: u128 = tot + (w as u128);
            if (table::contains(&reg.total_points_by_epoch, e)) { let _ = table::remove(&mut reg.total_points_by_epoch, e); };
            table::add(&mut reg.total_points_by_epoch, e, new_tot);
        };
    }

    #[test_only]
    public fun new_points_registry_for_testing(ctx: &mut TxContext): BotPointsRegistry {
        BotPointsRegistry {
            id: object::new(ctx),
            epoch_zero_ms: 0,
            epoch_duration_ms: 1_000,
            weights: table::new<String, u64>(ctx),
            points: table::new<address, u64>(ctx),
            points_by_epoch: table::new<u64, Table<address, u64>>(ctx),
            total_points_by_epoch: table::new<u64, u128>(ctx),
        }
    }

    /// Distribute rewards from BotRewardsTreasury pro-rata to provided recipients based on current points.
    /// Resets points for processed recipients. Can be called in chunks by passing a subset list.
    public entry fun claim_rewards_for_epoch<C>(
        reg: &mut BotPointsRegistry,
        bot: &mut BotRewardsTreasury<C>,
        epoch: u64,
        ctx: &mut TxContext
    ) {
        // Claim pro-rata for caller for a closed epoch (callers determine 'epoch')
        let now = sui::tx_context::epoch_timestamp_ms(ctx);
        let claimant = ctx.sender();
        // Compute totals and claimant points
        let total = if (table::contains(&reg.total_points_by_epoch, epoch)) { *table::borrow(&reg.total_points_by_epoch, epoch) } else { 0 };
        if (total == 0) { return };
        if (!table::contains(&reg.points_by_epoch, epoch)) { return };
        let sub = table::borrow_mut(&mut reg.points_by_epoch, epoch);
        let p = if (table::contains(sub, claimant)) { *table::borrow(sub, claimant) } else { 0 };
        if (p == 0) { return };
        // Compute shares from epoch reserves via treasury helpers
        let (epoch_coll, epoch_unxv) = TreasuryMod::epoch_reserves(bot, epoch);
        let share_coll = ((epoch_coll as u128) * (p as u128) / total) as u64;
        let share_unxv = ((epoch_unxv as u128) * (p as u128) / total) as u64;
        TreasuryMod::payout_epoch_shares(bot, epoch, share_coll, share_unxv, claimant, ctx);
        // zero claimant epoch points
        if (table::contains(sub, claimant)) { let _ = table::remove(sub, claimant); };
        table::add(sub, claimant, 0);
        event::emit(BotPayout { recipient: claimant, collateral_paid: share_coll, unxv_paid: share_unxv, timestamp: now });
    }

    fun clone_string(s: &String): String {
        let bytes = std::string::as_bytes(s);
        let mut out = vector::empty<u8>();
        let mut i = 0; let n = vector::length(bytes);
        while (i < n) { vector::push_back(&mut out, *vector::borrow(bytes, i)); i = i + 1; };
        std::string::utf8(out)
    }
}


