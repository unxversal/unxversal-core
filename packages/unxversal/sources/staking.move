/// Module: unxversal_staking
/// ------------------------------------------------------------
/// Weekly-epoch UNXV staking with fair entry (activates next week) and
/// pro-rata weekly reward claims. Protocols deposit UNXV rewards into the
/// current week, and stakers can claim any fully elapsed weeks.
module unxversal::staking {
    use sui::{
        table::{Self as table, Table},
        dynamic_field as df,
        balance::{Self as balance, Balance},
        coin::{Self as coin, Coin},
        event,
        display,
        package,
        transfer,
    };
    use unxversal::unxv::UNXV;
    use std::string::String;

    const E_ZERO_AMOUNT: u64 = 1;
    const E_INSUFFICIENT_ACTIVE: u64 = 2;

    /// 7 days in milliseconds
    const WEEK_MS: u64 = 7 * 24 * 60 * 60 * 1000;

    /// One-Time Witness for module init
    public struct STAKING has drop {}

    /// Per-account staking state stored as a dynamic field off the pool id
    public struct Staker has store, drop {
        active_stake: u64,
        pending_stake: u64,
        /// The week number when pending stake activates
        activate_week: u64,
        /// Amount scheduled to deactivate at a week boundary
        pending_unstake: u64,
        /// The week number when pending_unstake applies
        deactivate_week: u64,
        /// Last fully-settled week claimed (inclusive). Claims start from last_claimed_week + 1
        last_claimed_week: u64,
    }

    /// Staking pool
    public struct StakingPool has key, store {
        id: UID,
        /// Current week number the pool state is at
        current_week: u64,
        /// Total active stake effective in the current week
        total_active_stake: u64,
        /// Aggregate stake deltas scheduled for a given week (activations)
        pos_delta_by_week: Table<u64, u64>,
        /// Aggregate stake deltas scheduled for a given week (deactivations)
        neg_delta_by_week: Table<u64, u64>,
        /// Snapshot of total active stake for each finalized week (used in claims)
        active_by_week: Table<u64, u64>,
        /// Rewards added per week (UNXV units)
        reward_by_week: Table<u64, u64>,
        /// Vault holding staked UNXV principal
        stake_vault: Balance<UNXV>,
        /// Vault holding UNXV rewards to be distributed
        reward_vault: Balance<UNXV>,
    }

    /// Events
    public struct Staked has copy, drop {
        pool_id: ID,
        who: address,
        amount: u64,
        activate_week: u64,
        timestamp_ms: u64,
    }

    public struct Unstaked has copy, drop {
        pool_id: ID,
        who: address,
        amount: u64,
        effective_week: u64,
        timestamp_ms: u64,
    }

    public struct RewardAdded has copy, drop {
        pool_id: ID,
        amount: u64,
        week: u64,
        timestamp_ms: u64,
    }

    public struct RewardsClaimed has copy, drop {
        pool_id: ID,
        who: address,
        from_week: u64,
        to_week: u64,
        amount: u64,
        timestamp_ms: u64,
    }

    /// Initialize staking pool (one-time witness) and set up on-chain Display metadata.
    fun init(w: STAKING, ctx: &mut TxContext) {
        let now = sui::tx_context::epoch_timestamp_ms(ctx);
        let week = week_of(now);
        let pool = StakingPool {
            id: object::new(ctx),
            current_week: week,
            total_active_stake: 0,
            pos_delta_by_week: table::new<u64, u64>(ctx),
            neg_delta_by_week: table::new<u64, u64>(ctx),
            active_by_week: table::new<u64, u64>(ctx),
            reward_by_week: table::new<u64, u64>(ctx),
            stake_vault: balance::zero<UNXV>(),
            reward_vault: balance::zero<UNXV>(),
        };
        // Create Display<StakingPool> using Publisher claimed via the module's OTW
        let publisher = package::claim(w, ctx);
        let keys = vector[
            b"name".to_string(),
            b"description".to_string(),
            b"link".to_string(),
            b"image_url".to_string(),
            b"thumbnail_url".to_string(),
            b"project_url".to_string(),
            b"creator".to_string(),
        ];
        let values = vector[
            b"UNXV Staking Pool".to_string(),
            b"Stake UNXV to earn weekly UNXV rewards. Weekly epochs with fair-entry (activates next week). Current week: {current_week}. TVL (UNXV): {total_active_stake}.".to_string(),
            b"https://unxversal.wal.app".to_string(),
            b"https://unxversal.com/branding/unxv-staking.png".to_string(),
            b"https://unxversal.com/branding/unxv-staking-thumb.png".to_string(),
            b"https://unxversal.com".to_string(),
            b"Unxversal".to_string(),
        ];
        let mut display = display::new_with_fields<StakingPool>(&publisher, keys, values, ctx);
        display.update_version();
        transfer::public_transfer(publisher, ctx.sender());
        transfer::public_transfer(display, ctx.sender());
        transfer::share_object(pool);
    }

    /// Stake UNXV. Activates next week for fairness.
    public fun stake_unx(pool: &mut StakingPool, amount: Coin<UNXV>, clock: &sui::clock::Clock, ctx: &mut TxContext) {
        let amt = coin::value(&amount);
        assert!(amt > 0, E_ZERO_AMOUNT);
        // Bring pool to current week boundary
        update_to_now(pool, clock);
        // Move principal into the stake vault
        let bal = coin::into_balance(amount);
        pool.stake_vault.join(bal);
        // Load or create staker record
        let mut staker = borrow_or_new_staker(pool, ctx.sender());
        let next_week = pool.current_week + 1;
        staker.pending_stake = staker.pending_stake + amt;
        if (staker.activate_week < next_week) { staker.activate_week = next_week; };
        // Schedule activation delta at next_week
        add_delta(&mut pool.pos_delta_by_week, next_week, amt);
        // Persist staker
        write_staker(pool, ctx.sender(), staker);
        event::emit(Staked { pool_id: object::id(pool), who: ctx.sender(), amount: amt, activate_week: next_week, timestamp_ms: sui::clock::timestamp_ms(clock) });
    }

    /// Unstake active UNXV. Effective at next week boundary.
    public fun unstake_unx(pool: &mut StakingPool, amount: u64, clock: &sui::clock::Clock, ctx: &mut TxContext): Coin<UNXV> {
        assert!(amount > 0, E_ZERO_AMOUNT);
        update_to_now(pool, clock);
        let mut staker = borrow_or_new_staker(pool, ctx.sender());
        assert!(staker.active_stake >= amount, E_INSUFFICIENT_ACTIVE);
        staker.active_stake = staker.active_stake - amount;
        let eff_week = pool.current_week + 1;
        add_delta(&mut pool.neg_delta_by_week, eff_week, amount);
        write_staker(pool, ctx.sender(), staker);
        // Transfer principal out immediately
        let bal_part = balance::split(&mut pool.stake_vault, amount);
        let c = coin::from_balance(bal_part, ctx);
        event::emit(Unstaked { pool_id: object::id(pool), who: ctx.sender(), amount, effective_week: eff_week, timestamp_ms: sui::clock::timestamp_ms(clock) });
        c
    }

    /// Add reward for the current week. Protocol modules should call this with the stakers' UNXV portion.
    public fun add_weekly_reward(pool: &mut StakingPool, reward: Coin<UNXV>, clock: &sui::clock::Clock) {
        let amt = coin::value(&reward);
        assert!(amt > 0, E_ZERO_AMOUNT);
        update_to_now(pool, clock);
        // Deposit reward into reward vault
        let bal = coin::into_balance(reward);
        pool.reward_vault.join(bal);
        // Increment reward for current week
        let w = pool.current_week;
        let cur = if (table::contains(&pool.reward_by_week, w)) { *table::borrow(&pool.reward_by_week, w) } else { 0 };
        if (table::contains(&pool.reward_by_week, w)) { let _ = table::remove(&mut pool.reward_by_week, w); };
        table::add(&mut pool.reward_by_week, w, cur + amt);
        event::emit(RewardAdded { pool_id: object::id(pool), amount: amt, week: w, timestamp_ms: sui::clock::timestamp_ms(clock) });
    }

    /// Claim rewards for all fully completed weeks since last claim.
    public fun claim_rewards(pool: &mut StakingPool, clock: &sui::clock::Clock, ctx: &mut TxContext): Coin<UNXV> {
        update_to_now(pool, clock);
        let mut staker = borrow_or_new_staker(pool, ctx.sender());
        let start = staker.last_claimed_week + 1;
        // You can only claim up to current_week - 1
        if (pool.current_week == 0 || start > pool.current_week - 1) {
            // persist unchanged
            write_staker(pool, ctx.sender(), staker);
            return coin::zero(ctx)
        };
        let end = pool.current_week - 1;
        let mut acc: u64 = 0;
        let mut active = staker.active_stake;
        let mut w = start;
        while (w <= end) {
            // Apply per-account scheduled stake/unstake
            if (staker.activate_week != 0 && w == staker.activate_week && staker.pending_stake > 0) {
                active = active + staker.pending_stake;
                staker.active_stake = active;
                staker.pending_stake = 0;
                staker.activate_week = 0;
            };
            if (staker.deactivate_week != 0 && w == staker.deactivate_week && staker.pending_unstake > 0) {
                if (active >= staker.pending_unstake) { active = active - staker.pending_unstake; } else { active = 0; };
                staker.active_stake = active;
                staker.pending_unstake = 0;
                staker.deactivate_week = 0;
            };
            // Compute week reward share
            let pool_active = if (table::contains(&pool.active_by_week, w)) { *table::borrow(&pool.active_by_week, w) } else { pool.total_active_stake };
            if (pool_active > 0 && active > 0 && table::contains(&pool.reward_by_week, w)) {
                let week_reward = *table::borrow(&pool.reward_by_week, w);
                let share = (week_reward as u128 * (active as u128) / (pool_active as u128)) as u64;
                acc = acc + share;
            };
            w = w + 1;
        };
        staker.last_claimed_week = end;
        // Persist staker state
        write_staker(pool, ctx.sender(), staker);
        if (acc == 0) { return coin::zero(ctx) };
        let balp = balance::split(&mut pool.reward_vault, acc);
        let c = coin::from_balance(balp, ctx);
        event::emit(RewardsClaimed { pool_id: object::id(pool), who: ctx.sender(), from_week: start, to_week: end, amount: acc, timestamp_ms: sui::clock::timestamp_ms(clock) });
        c
    }

    /// Internal: progress pool to current week and finalize snapshots for completed weeks.
    fun update_to_now(pool: &mut StakingPool, clock: &sui::clock::Clock) {
        let now = sui::clock::timestamp_ms(clock);
        let target = week_of(now);
        if (target <= pool.current_week) return;
        // finalize current week snapshot then apply deltas forward
        let mut w = pool.current_week;
        while (w < target) {
            // finalize snapshot for week w
            store_u64(&mut pool.active_by_week, w, pool.total_active_stake);
            // apply deltas scheduled for the next week w+1
            let w1 = w + 1;
            let pos = if (table::contains(&pool.pos_delta_by_week, w1)) { *table::borrow(&pool.pos_delta_by_week, w1) } else { 0 };
            let neg = if (table::contains(&pool.neg_delta_by_week, w1)) { *table::borrow(&pool.neg_delta_by_week, w1) } else { 0 };
            let after_pos = pool.total_active_stake + pos;
            pool.total_active_stake = if (after_pos >= neg) { after_pos - neg } else { 0 };
            // cleanup deltas
            if (pos > 0) { let _ = table::remove(&mut pool.pos_delta_by_week, w1); };
            if (neg > 0) { let _ = table::remove(&mut pool.neg_delta_by_week, w1); };
            // advance week
            w = w1;
        };
        pool.current_week = target;
    }

    /// Helpers
    fun week_of(ts_ms: u64): u64 { ts_ms / WEEK_MS }

    fun borrow_or_new_staker(pool: &StakingPool, who: address): Staker {
        if (df::exists_(&pool.id, who)) {
            let sref = df::borrow<address, Staker>(&pool.id, who);
            Staker {
                active_stake: sref.active_stake,
                pending_stake: sref.pending_stake,
                activate_week: sref.activate_week,
                pending_unstake: sref.pending_unstake,
                deactivate_week: sref.deactivate_week,
                last_claimed_week: sref.last_claimed_week,
            }
        } else {
            Staker { active_stake: 0, pending_stake: 0, activate_week: 0, pending_unstake: 0, deactivate_week: 0, last_claimed_week: 0 }
        }
    }

    /// View: active stake of a user
    public fun active_stake_of(pool: &StakingPool, who: address): u64 {
        if (df::exists_(&pool.id, who)) {
            let st_ref = df::borrow<address, Staker>(&pool.id, who);
            st_ref.active_stake
        } else { 0 }
    }

    fun write_staker(pool: &mut StakingPool, who: address, st: Staker) {
        if (df::exists_(&pool.id, who)) {
            let sref = df::borrow_mut<address, Staker>(&mut pool.id, who);
            let Staker { active_stake, pending_stake, activate_week, pending_unstake, deactivate_week, last_claimed_week } = st;
            sref.active_stake = active_stake;
            sref.pending_stake = pending_stake;
            sref.activate_week = activate_week;
            sref.pending_unstake = pending_unstake;
            sref.deactivate_week = deactivate_week;
            sref.last_claimed_week = last_claimed_week;
        } else {
            df::add<address, Staker>(&mut pool.id, who, st);
        };
    }

    fun add_delta(tbl: &mut Table<u64, u64>, week: u64, amount: u64) {
        let cur = if (table::contains(tbl, week)) { *table::borrow(tbl, week) } else { 0 };
        if (table::contains(tbl, week)) { let _ = table::remove(tbl, week); };
        table::add(tbl, week, cur + amount);
    }

    fun store_u64(tbl: &mut Table<u64, u64>, k: u64, v: u64) { if (table::contains(tbl, k)) { let _ = table::remove(tbl, k); }; table::add(tbl, k, v) }

    #[test_only]
    public fun new_staking_pool_for_testing(ctx: &mut TxContext): StakingPool {
        let now = sui::tx_context::epoch_timestamp_ms(ctx);
        let week = week_of(now);
        StakingPool {
            id: object::new(ctx),
            current_week: week,
            total_active_stake: 0,
            pos_delta_by_week: table::new<u64, u64>(ctx),
            neg_delta_by_week: table::new<u64, u64>(ctx),
            active_by_week: table::new<u64, u64>(ctx),
            reward_by_week: table::new<u64, u64>(ctx),
            stake_vault: balance::zero<UNXV>(),
            reward_vault: balance::zero<UNXV>(),
        }
    }

}



