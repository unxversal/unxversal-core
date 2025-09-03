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
    };
    use std::string::{Self as string, String};
    use unxversal::admin::{Self as AdminMod, AdminRegistry};
    use unxversal::unxv::UNXV;

    const E_NOT_ADMIN: u64 = 1;
    const E_ZERO_AMOUNT: u64 = 2;
    const E_INSUFFICIENT_ACTIVE: u64 = 3;

    /// 7 days in milliseconds
    const WEEK_MS: u64 = 7 * 24 * 60 * 60 * 1000;

    /// Per-account staking state stored as a dynamic field off the pool id
    public struct Staker has store {
        active_stake: u64,
        pending_stake: u64,
        /// The week number when pending stake activates
        activate_week: u64,
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
        who: address,
        amount: u64,
        activate_week: u64,
        timestamp_ms: u64,
    }

    public struct Unstaked has copy, drop {
        who: address,
        amount: u64,
        effective_week: u64,
        timestamp_ms: u64,
    }

    public struct RewardAdded has copy, drop {
        amount: u64,
        week: u64,
        timestamp_ms: u64,
    }

    public struct RewardsClaimed has copy, drop {
        who: address,
        from_week: u64,
        to_week: u64,
        amount: u64,
        timestamp_ms: u64,
    }

    /// Initialize staking pool (admins only)
    entry fun init(reg_admin: &AdminRegistry, ctx: &mut TxContext) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
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
        transfer::share_object(pool);
    }

    /// Stake UNXV. Activates next week for fairness.
    entry fun stake_unx(pool: &mut StakingPool, amount: Coin<UNXV>, clock: &sui::clock::Clock, ctx: &mut TxContext) {
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
        // Schedule activation delta at next_week (global + per-account)
        add_delta(&mut pool.pos_delta_by_week, next_week, amt);
        record_staker_delta(pool, ctx.sender(), next_week, true, amt);
        // Persist staker
        write_staker(pool, ctx.sender(), staker);
        event::emit(Staked { who: ctx.sender(), amount: amt, activate_week: next_week, timestamp_ms: sui::clock::timestamp_ms(clock) });
    }

    /// Unstake active UNXV. Effective at next week boundary.
    entry fun unstake_unx(pool: &mut StakingPool, amount: u64, clock: &sui::clock::Clock, ctx: &mut TxContext): Coin<UNXV> {
        assert!(amount > 0, E_ZERO_AMOUNT);
        update_to_now(pool, clock);
        let mut staker = borrow_or_new_staker(pool, ctx.sender());
        assert!(staker.active_stake >= amount, E_INSUFFICIENT_ACTIVE);
        staker.active_stake = staker.active_stake - amount;
        let eff_week = pool.current_week + 1;
        add_delta(&mut pool.neg_delta_by_week, eff_week, amount);
        record_staker_delta(pool, ctx.sender(), eff_week, false, amount);
        write_staker(pool, ctx.sender(), staker);
        // Transfer principal out immediately is not fair; we unlock at claim time or immediate? 
        // We unlock principal immediately into user's wallet (no slashing), reducing vault balance.
        let c = balance::into_coin(&mut pool.stake_vault, amount, ctx);
        event::emit(Unstaked { who: ctx.sender(), amount, effective_week: eff_week, timestamp_ms: sui::clock::timestamp_ms(clock) });
        c
    }

    /// Add reward for the current week. Protocol modules should call this with the stakers' UNXV portion.
    entry fun add_weekly_reward(pool: &mut StakingPool, reward: Coin<UNXV>, clock: &sui::clock::Clock) {
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
        event::emit(RewardAdded { amount: amt, week: w, timestamp_ms: sui::clock::timestamp_ms(clock) });
    }

    /// Claim rewards for all fully completed weeks since last claim.
    entry fun claim_rewards(pool: &mut StakingPool, clock: &sui::clock::Clock, ctx: &mut TxContext): Coin<UNXV> {
        update_to_now(pool, clock);
        let mut staker = borrow_or_new_staker(pool, ctx.sender());
        let start = staker.last_claimed_week + 1;
        // You can only claim up to current_week - 1
        if (pool.current_week == 0 || start > pool.current_week - 1) { return coin::zero(ctx); };
        let end = pool.current_week - 1;
        let mut acc: u64 = 0;
        let mut active = staker.active_stake;
        let mut w = start;
        while (w <= end) {
            // Apply per-account deltas that activate/deactivate at week boundary w
            // For simplicity, reuse pool deltas to adjust staker.active when scheduled for this address
            // We store per-account deltas as dynamic fields under (address, week) pairs.
            let delta_pos = read_staker_delta(pool, ctx.sender(), w, true);
            let delta_neg = read_staker_delta(pool, ctx.sender(), w, false);
            if (delta_pos > 0) { active = active + delta_pos; };
            if (delta_neg > 0) { active = active - delta_neg; };
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
        if (acc == 0) { return coin::zero(ctx); };
        let c = balance::into_coin(&mut pool.reward_vault, acc, ctx);
        event::emit(RewardsClaimed { who: ctx.sender(), from_week: start, to_week: end, amount: acc, timestamp_ms: sui::clock::timestamp_ms(clock) });
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
        if (df::exists_(&pool.id, who)) { *df::borrow::<address, Staker>(&pool.id, who) } else { Staker { active_stake: 0, pending_stake: 0, activate_week: 0, last_claimed_week: 0 } }
    }

    fun write_staker(pool: &mut StakingPool, who: address, st: Staker) {
        if (df::exists_(&pool.id, who)) { df::borrow_mut::<address, Staker>(&mut pool.id, who).swap(st); } else { df::add::<address, Staker>(&mut pool.id, who, st); };
    }

    fun add_delta(tbl: &mut Table<u64, u64>, week: u64, amount: u64) {
        let cur = if (table::contains(tbl, week)) { *table::borrow(tbl, week) } else { 0 };
        if (table::contains(tbl, week)) { let _ = table::remove(tbl, week); };
        table::add(tbl, week, cur + amount);
    }

    fun store_u64(tbl: &mut Table<u64, u64>, k: u64, v: u64) { if (table::contains(tbl, k)) { let _ = table::remove(tbl, k); }; table::add(tbl, k, v) }

    /// Per-account delta tracking: we key dynamic fields by (who, week, is_pos) encoded as nested keys.
    /// To keep it simple and gas-cheap, we only record deltas we create in stake/unstake paths.
    fun record_staker_delta(pool: &mut StakingPool, who: address, week: u64, is_pos: bool, amount: u64) {
        let key = staker_delta_key(who, week, is_pos);
        if (df::exists_::<String, u64>(&pool.id, key)) {
            let cur = *df::borrow::<String, u64>(&pool.id, key);
            *df::borrow_mut::<String, u64>(&mut pool.id, key) = cur + amount;
        } else {
            df::add::<String, u64>(&mut pool.id, key, amount);
        }
    }

    fun read_staker_delta(pool: &StakingPool, who: address, week: u64, is_pos: bool): u64 {
        let key = staker_delta_key(who, week, is_pos);
        if (df::exists_::<String, u64>(&pool.id, key)) { *df::borrow::<String, u64>(&pool.id, key) } else { 0 }
    }

    fun staker_delta_key(who: address, week: u64, is_pos: bool): String {
        let mut s = string::utf8(b"stk:");
        let addr_bytes = address::to_bytes(&who);
        let mut i = 0; let n = vector::length(&addr_bytes);
        while (i < n) { vector::push_back(&mut s, *vector::borrow(&addr_bytes, i)); i = i + 1; };
        // delimiter
        vector::push_back(&mut s, b'|');
        // encode week as bytes (u64 -> 8 bytes big endian)
        let mut k = week;
        let mut j = 0;
        let mut buf = vector::empty<u8>();
        while (j < 8) { vector::push_back(&mut buf, (k & 0xFF) as u8); k = k >> 8; j = j + 1; };
        // reverse to big-endian
        let mut r = vector::empty<u8>();
        let mut t = 8;
        while (t > 0) { vector::push_back(&mut r, *vector::borrow(&buf, t - 1)); t = t - 1; };
        let mut m = 0; let mlen = vector::length(&r);
        while (m < mlen) { vector::push_back(&mut s, *vector::borrow(&r, m)); m = m + 1; };
        vector::push_back(&mut s, b'|');
        vector::push_back(&mut s, if (is_pos) { b'+' } else { b'-' });
        s
    }
}


