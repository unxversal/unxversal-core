/// Module: unxversal_rewards
/// ------------------------------------------------------------
/// On-chain rewards accounting for Unxversal testnet.
/// - Daily accumulators per user with 7-day ring buffer and weekly totals
/// - USD-normalized across products (expect 1e6 USD scale inputs)
/// - Multi-level referrals (L1/L2/L3) with weekly caps
/// - Faucet gating wrapper for USDU via `unxversal::usdu::Faucet`
/// - Weekly leaderboards (Top-K exact) and histogram percentiles
///
/// Design notes:
/// - All updates are O(1) per call; rollovers are lazy and per-user
/// - Leaderboard Top-K is updated on day rollover only
/// - Histogram counts support percentile estimates for non-Top-K users
#[allow(lint(self_transfer))]
module unxversal::rewards {
    use sui::clock::Clock;
    use sui::event;
    use sui::table::{Self as table, Table};

    use std::option;
    use std::vector;

    use unxversal::admin::{Self as AdminMod, AdminRegistry};
    use unxversal::usdu::{Self as usdu, Faucet as UsduFaucet};

    // ===== Constants =====
    const BPS_DENOM: u64 = 10_000;
    const WEIGHT_SCALE: u64 = 1_000_000; // weights in 1e6 scale

    const DEFAULT_TOPK: u32 = 1000;
    const CONC_PENALTY_THRESH_BPS: u64 = 6000; // 60%

    // ===== Errors =====
    const E_NOT_ADMIN: u64 = 1;
    const E_INVALID_TIER: u64 = 2;
    const E_COOLDOWN: u64 = 3;
    const E_MINT_CAP: u64 = 4;
    const E_LOSS_BUDGET: u64 = 5;
    const E_REFERRAL_EXISTS: u64 = 6;
    const E_REFERRAL_SELF: u64 = 7;
    const E_REFERRAL_CYCLE: u64 = 8;

    // ===== Storage types =====
    public struct Rewards has key, store {
        id: UID,
        // weights (1e6 scale)
        wV: u64,
        wM: u64,
        wP: u64,
        wF: u64,
        wB: u64,
        wL: u64,
        wQ: u64,
        // referral settings (bps)
        l1_bps: u64,
        l2_bps: u64,
        l3_bps: u64,
        ref_cap_bps_per_week: u64,
        // faucet policy
        per_day_mint_cap_usdu: u128,
        loss_budget_per_tier_usd_1e6: vector<u128>, // length 4 (tiers A..D)
        cooldown_days: u8,
        // tiers (7d thresholds; non-decreasing, length 4 for A..D)
        tier_thresholds_7d: vector<u128>,
        // leaderboard / histogram config
        leaderboard_topk: u32,
        hist_bucket_edges: vector<u128>,
        // state
        users: Table<address, UserState>,
        referrals: Table<address, address>, // child -> parent
        // per week exact points using composite key (week_id, user)
        week_points: Table<WeekUserKey, u128>,
        // per week top-k vector (exact leaders)
        week_topk: Table<u64, LeaderboardWeek>,
        // per week histogram for percentile
        week_hist: Table<u64, Histogram>,
    }

    public struct WeekUserKey has copy, drop, store { week_id: u64, user: address }

    public struct UserState has store {
        // calendar
        day_id: u64,
        week_id: u64,
        // faucet
        minted_today_usdu: u128,
        cooldown_until_day: u64,
        realized_loss_today_usd_1e6: u128,
        // daily accumulators (USD 1e6 units)
        trade_volume_usd_1e6: u128,
        maker_quality_usd_1e6: u128,
        realized_pnl_pos_usd_1e6: u128,
        funding_abs_usd_1e6: u128,
        option_premium_taker_usd_1e6: u128,
        option_premium_maker_usd_1e6: u128,
        borrow_interest_util_usd_1e6: u128,
        lend_quality_score_usd_1e6: u128,
        liquidations_usd_1e6: u128,
        // anti-abuse (trading)
        total_volume_usd_1e6: u128,
        last_counterparty: address,
        run_volume_usd_1e6: u128,
        top_run_volume_usd_1e6: u128,
        // points
        day_points: u128,
        seven_slots: vector<u128>, // length 7 ring buffer
        seven_day_points_sum: u128,
        current_tier: u8, // 0..3 => A..D
        // weekly
        week_points_own: u128,
        week_referral_earned: u128,
        week_bucket_idx: u64,
        week_bucket_for: u64, // week id of the bucket index above
        // totals
        week_points_total: u128,
        all_time_points: u128,
    }

    public struct LeaderboardWeek has store {
        week_id: u64,
        topk_addrs: vector<address>,
        topk_points: vector<u128>, // parallel array sorted desc
    }

    public struct Histogram has store {
        week_id: u64,
        edges: vector<u128>,
        counts: vector<u64>,
    }

    // ===== Events =====
    public struct ConfigUpdated has copy, drop { by: address, timestamp_ms: u64 }
    public struct ReferralSet has copy, drop { child: address, parent: address, timestamp_ms: u64 }
    public struct DayFinalized has copy, drop { user: address, day_id: u64, points: u128 }
    public struct TierChanged has copy, drop { user: address, new_tier: u8, seven_day_points: u128, timestamp_ms: u64 }
    public struct FaucetClaimed has copy, drop { user: address, amount: u64, day_id: u64 }

    // ===== Init =====
    entry fun init(ctx: &mut TxContext) {
        let mut r = Rewards {
            id: object::new(ctx),
            // weights (defaults from spec; sum < 1e6)
            wV: 230_000,
            wM: 180_000,
            wP: 120_000,
            wF: 80_000,
            wB: 180_000,
            wL: 100_000,
            wQ: 40_000,
            // referrals
            l1_bps: 1000, // 10%
            l2_bps: 300,  // 3%
            l3_bps: 100,  // 1%
            ref_cap_bps_per_week: 10_000, // 100% cap of own points
            // faucet
            per_day_mint_cap_usdu: 100_000_000u128, // 100k USDU (6 decimals)
            loss_budget_per_tier_usd_1e6: vector::empty<u128>(),
            cooldown_days: 1,
            // tiers
            tier_thresholds_7d: vector::empty<u128>(),
            // leaderboard/hist
            leaderboard_topk: DEFAULT_TOPK,
            hist_bucket_edges: vector::empty<u128>(),
            // state
            users: table::new<address, UserState>(ctx),
            referrals: table::new<address, address>(ctx),
            week_points: table::new<WeekUserKey, u128>(ctx),
            week_topk: table::new<u64, LeaderboardWeek>(ctx),
            week_hist: table::new<u64, Histogram>(ctx),
        };
        // defaults: budgets tiers A..D
        vector::push_back<u128>(&mut r.loss_budget_per_tier_usd_1e6, 300_000_000u128);
        vector::push_back<u128>(&mut r.loss_budget_per_tier_usd_1e6, 1_000_000_000u128);
        vector::push_back<u128>(&mut r.loss_budget_per_tier_usd_1e6, 3_000_000_000u128);
        vector::push_back<u128>(&mut r.loss_budget_per_tier_usd_1e6, 10_000_000_000u128);
        // thresholds (A..D); A=0 by convention
        vector::push_back<u128>(&mut r.tier_thresholds_7d, 0u128);
        vector::push_back<u128>(&mut r.tier_thresholds_7d, 25_000u128);
        vector::push_back<u128>(&mut r.tier_thresholds_7d, 150_000u128);
        vector::push_back<u128>(&mut r.tier_thresholds_7d, 1_000_000u128);
        // histogram default edges (adjust via admin): 0,1k,5k,10k,25k,100k,1M
        vector::push_back<u128>(&mut r.hist_bucket_edges, 0u128);
        vector::push_back<u128>(&mut r.hist_bucket_edges, 1_000u128);
        vector::push_back<u128>(&mut r.hist_bucket_edges, 5_000u128);
        vector::push_back<u128>(&mut r.hist_bucket_edges, 10_000u128);
        vector::push_back<u128>(&mut r.hist_bucket_edges, 25_000u128);
        vector::push_back<u128>(&mut r.hist_bucket_edges, 100_000u128);
        vector::push_back<u128>(&mut r.hist_bucket_edges, 1_000_000u128);
        transfer::share_object(r);
    }

    // init_and_share removed: deployment runs `init` directly and shares the object

    // ===== Admin updaters =====
    public fun set_weights(reg_admin: &AdminRegistry, rew: &mut Rewards, wV: u64, wM: u64, wP: u64, wF: u64, wB: u64, wL: u64, wQ: u64, clock: &Clock, ctx: &TxContext) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        rew.wV = wV; rew.wM = wM; rew.wP = wP; rew.wF = wF; rew.wB = wB; rew.wL = wL; rew.wQ = wQ;
        event::emit(ConfigUpdated { by: ctx.sender(), timestamp_ms: clock.timestamp_ms() });
    }
    public fun set_referral_bps(reg_admin: &AdminRegistry, rew: &mut Rewards, l1_bps: u64, l2_bps: u64, l3_bps: u64, cap_bps_week: u64, clock: &Clock, ctx: &TxContext) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        rew.l1_bps = l1_bps; rew.l2_bps = l2_bps; rew.l3_bps = l3_bps; rew.ref_cap_bps_per_week = cap_bps_week;
        event::emit(ConfigUpdated { by: ctx.sender(), timestamp_ms: clock.timestamp_ms() });
    }
    public fun set_faucet_policy(reg_admin: &AdminRegistry, rew: &mut Rewards, per_day_cap_usdu: u128, budgets_per_tier: vector<u128>, cooldown_days: u8, clock: &Clock, ctx: &TxContext) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        rew.per_day_mint_cap_usdu = per_day_cap_usdu;
        rew.loss_budget_per_tier_usd_1e6 = budgets_per_tier;
        rew.cooldown_days = cooldown_days;
        event::emit(ConfigUpdated { by: ctx.sender(), timestamp_ms: clock.timestamp_ms() });
    }
    public fun set_tier_thresholds(reg_admin: &AdminRegistry, rew: &mut Rewards, thresholds_7d: vector<u128>, clock: &Clock, ctx: &TxContext) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        rew.tier_thresholds_7d = thresholds_7d;
        event::emit(ConfigUpdated { by: ctx.sender(), timestamp_ms: clock.timestamp_ms() });
    }
    public fun set_leaderboard_params(reg_admin: &AdminRegistry, rew: &mut Rewards, topk: u32, new_edges: vector<u128>, clock: &Clock, ctx: &TxContext) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        rew.leaderboard_topk = topk;
        rew.hist_bucket_edges = new_edges;
        event::emit(ConfigUpdated { by: ctx.sender(), timestamp_ms: clock.timestamp_ms() });
    }

    // ===== User referral binding =====
    public fun set_referrer(rew: &mut Rewards, parent: address, clock: &Clock, ctx: &TxContext) {
        let child = ctx.sender();
        assert!(child != parent, E_REFERRAL_SELF);
        // cannot change once set
        assert!(!table::contains<&address, address>(&rew.referrals, child), E_REFERRAL_EXISTS);
        // no short cycles (child->parent, parent->child) and no 3-level cycle
        let mut p1: address = parent;
        if (p1 == child) { abort E_REFERRAL_CYCLE; };
        if (table::contains<&address, address>(&rew.referrals, p1)) {
            let p2 = *table::borrow<&address, address>(&rew.referrals, p1);
            if (p2 == child) { abort E_REFERRAL_CYCLE; };
            if (table::contains<&address, address>(&rew.referrals, p2)) {
                let p3 = *table::borrow<&address, address>(&rew.referrals, p2);
                if (p3 == child) { abort E_REFERRAL_CYCLE; };
            }
        };
        table::add<&address, address>(&mut rew.referrals, child, parent);
        event::emit(ReferralSet { child, parent, timestamp_ms: clock.timestamp_ms() });
    }

    // ===== External product hooks =====
    /// Perps/Futures/Gas futures fill update
    public fun on_perp_fill(rew: &mut Rewards, user: address, counterparty: address, notional_usd_1e6: u128, is_maker: bool, maker_improve_bps: u64, clock: &Clock) {
        let day = epoch_day(clock);
        let week = day / 7;
        let mut u = take_or_new_user(rew, user);
        rollover_if_needed(rew, user, &mut u, day, week);
        u.trade_volume_usd_1e6 = u.trade_volume_usd_1e6 + notional_usd_1e6;
        u.total_volume_usd_1e6 = u.total_volume_usd_1e6 + notional_usd_1e6;
        if (is_maker && maker_improve_bps > 0) {
            let add = (notional_usd_1e6 * (maker_improve_bps as u128)) / (BPS_DENOM as u128);
            u.maker_quality_usd_1e6 = u.maker_quality_usd_1e6 + add;
        };
        // update anti-abuse run
        if (u.last_counterparty == counterparty) {
            u.run_volume_usd_1e6 = u.run_volume_usd_1e6 + notional_usd_1e6;
        } else {
            u.last_counterparty = counterparty;
            u.run_volume_usd_1e6 = notional_usd_1e6;
        };
        if (u.run_volume_usd_1e6 > u.top_run_volume_usd_1e6) { u.top_run_volume_usd_1e6 = u.run_volume_usd_1e6; };
        store_user(rew, user, u);
    }

    /// Realized PnL update (USD 1e6 units). Only positive PnL contributes to P; losses tracked for faucet.
    public fun on_realized_pnl(rew: &mut Rewards, user: address, realized_gain_usd_1e6: u128, realized_loss_usd_1e6: u128, clock: &Clock) {
        let day = epoch_day(clock);
        let week = day / 7;
        let mut u = take_or_new_user(rew, user);
        rollover_if_needed(rew, user, &mut u, day, week);
        if (realized_gain_usd_1e6 > 0) { u.realized_pnl_pos_usd_1e6 = u.realized_pnl_pos_usd_1e6 + realized_gain_usd_1e6; };
        if (realized_loss_usd_1e6 > 0) { u.realized_loss_today_usd_1e6 = u.realized_loss_today_usd_1e6 + realized_loss_usd_1e6; };
        store_user(rew, user, u);
    }

    /// Funding paid (+) or received (-). Absolute value contributes to participation.
    public fun on_funding(rew: &mut Rewards, user: address, funding_usd_1e6: i128, clock: &Clock) {
        let day = epoch_day(clock);
        let week = day / 7;
        let mut u = take_or_new_user(rew, user);
        rollover_if_needed(rew, user, &mut u, day, week);
        let abs = if (funding_usd_1e6 >= 0) { funding_usd_1e6 as u128 } else { (0u128 - (funding_usd_1e6 as i256) as u128) };
        u.funding_abs_usd_1e6 = u.funding_abs_usd_1e6 + abs;
        store_user(rew, user, u);
    }

    /// Options premium paid/received (USD 1e6). Both buyer and maker accrue.
    public fun on_option_fill(rew: &mut Rewards, buyer: address, maker: address, premium_usd_1e6: u128, clock: &Clock) {
        let day = epoch_day(clock);
        let week = day / 7;
        // buyer
        let mut ub = take_or_new_user(rew, buyer);
        rollover_if_needed(rew, buyer, &mut ub, day, week);
        ub.option_premium_taker_usd_1e6 = ub.option_premium_taker_usd_1e6 + premium_usd_1e6;
        store_user(rew, buyer, ub);
        // maker
        let mut um = take_or_new_user(rew, maker);
        rollover_if_needed(rew, maker, &mut um, day, week);
        um.option_premium_maker_usd_1e6 = um.option_premium_maker_usd_1e6 + premium_usd_1e6;
        store_user(rew, maker, um);
    }

    /// Lending: record borrow usage at open (use est_interest × util_bps)
    public fun on_borrow(rew: &mut Rewards, user: address, _borrowed_usd_1e6: u128, util_bps_at_borrow: u64, est_interest_usd_1e6: u128, clock: &Clock) {
        let day = epoch_day(clock);
        let week = day / 7;
        let mut u = take_or_new_user(rew, user);
        rollover_if_needed(rew, user, &mut u, day, week);
        let add = (est_interest_usd_1e6 * (util_bps_at_borrow as u128)) / (BPS_DENOM as u128);
        u.borrow_interest_util_usd_1e6 = u.borrow_interest_util_usd_1e6 + add;
        store_user(rew, user, u);
    }

    /// Lending: interest actually repaid (adds to borrow usage term)
    public fun on_repay_interest(rew: &mut Rewards, user: address, interest_paid_usd_1e6: u128, clock: &Clock) {
        let day = epoch_day(clock);
        let week = day / 7;
        let mut u = take_or_new_user(rew, user);
        rollover_if_needed(rew, user, &mut u, day, week);
        u.borrow_interest_util_usd_1e6 = u.borrow_interest_util_usd_1e6 + interest_paid_usd_1e6;
        store_user(rew, user, u);
    }

    /// Lending: supply/withdraw quality snapshot when util > kink
    public fun on_supply_event(rew: &mut Rewards, user: address, delta_supplied_usd_1e6: u128, util_bps: u64, kink_bps: u64, clock: &Clock) {
        if (util_bps <= kink_bps) return;
        let day = epoch_day(clock);
        let week = day / 7;
        let mut u = take_or_new_user(rew, user);
        rollover_if_needed(rew, user, &mut u, day, week);
        let over_bps: u64 = util_bps - kink_bps;
        let add = (delta_supplied_usd_1e6 * (over_bps as u128)) / (BPS_DENOM as u128);
        u.lend_quality_score_usd_1e6 = u.lend_quality_score_usd_1e6 + add;
        store_user(rew, user, u);
    }

    /// Liquidations: reward liquidator (capped internally by admin-tuned weights and caller)
    public fun on_liquidation(rew: &mut Rewards, user: address, debt_repaid_usd_1e6: u128, clock: &Clock) {
        let day = epoch_day(clock);
        let week = day / 7;
        let mut u = take_or_new_user(rew, user);
        rollover_if_needed(rew, user, &mut u, day, week);
        u.liquidations_usd_1e6 = u.liquidations_usd_1e6 + debt_repaid_usd_1e6;
        store_user(rew, user, u);
    }

    // ===== Faucet gating (calls unxversal::usdu::claim under the hood) =====
    public fun claim_usdu_via_rewards(rew: &mut Rewards, usdu_faucet: &mut UsduFaucet, amount: u64, clock: &Clock, ctx: &mut TxContext) {
        let day = epoch_day(clock);
        let week = day / 7;
        let user = ctx.sender();
        let mut u = take_or_new_user(rew, user);
        rollover_if_needed(rew, user, &mut u, day, week);
        assert!(day >= u.cooldown_until_day, E_COOLDOWN);
        let cap = rew.per_day_mint_cap_usdu;
        let want: u128 = (amount as u128);
        assert!(u.minted_today_usdu + want <= cap, E_MINT_CAP);
        let tier = u.current_tier;
        let budget = vector::borrow<&u128>(&rew.loss_budget_per_tier_usd_1e6, (tier as u64));
        assert!(u.realized_loss_today_usd_1e6 < *budget, E_LOSS_BUDGET);
        // mint via USDU faucet (enforces its own supply/addr caps as well)
        usdu::claim(usdu_faucet, amount, clock, ctx);
        u.minted_today_usdu = u.minted_today_usdu + want;
        // if already at/over budget after trade (tracked by on_realized_pnl), set cooldown for next day
        if (u.realized_loss_today_usd_1e6 >= *budget) { u.cooldown_until_day = day + (rew.cooldown_days as u64); };
        store_user(rew, user, u);
        event::emit(FaucetClaimed { user, amount, day_id: day });
    }

    // ===== Views =====
    public fun view_week_points(rew: &Rewards, user: address, week_id: u64): u128 {
        let key = WeekUserKey { week_id, user };
        if (!table::contains<&WeekUserKey, u128>(&rew.week_points, key)) return 0u128;
        *table::borrow<&WeekUserKey, u128>(&rew.week_points, key)
    }

    public fun view_alltime_points(rew: &Rewards, user: address): u128 {
        if (!table::contains<&address, UserState>(&rew.users, user)) return 0u128;
        let u = table::borrow<&address, UserState>(&rew.users, user);
        u.all_time_points
    }

    public fun view_topk_week(rew: &Rewards, week_id: u64): vector<(address, u128)> {
        let mut out: vector<(address, u128)> = vector::empty<(address, u128)>();
        if (!table::contains<&u64, LeaderboardWeek>(&rew.week_topk, week_id)) return out;
        let lb = table::borrow<&u64, LeaderboardWeek>(&rew.week_topk, week_id);
        let n = vector::length<address>(&lb.topk_addrs);
        let mut i = 0u64;
        while (i < n) {
            let a = *vector::borrow<address>(&lb.topk_addrs, i);
            let p = *vector::borrow<u128>(&lb.topk_points, i);
            vector::push_back<(address, u128)>(&mut out, (a, p));
            i = i + 1;
        };
        out
    }

    public fun view_week_rank_exact(rew: &Rewards, user: address, week_id: u64): option::Option<u32> {
        if (!table::contains<&u64, LeaderboardWeek>(&rew.week_topk, week_id)) return option::none<u32>();
        let lb = table::borrow<&u64, LeaderboardWeek>(&rew.week_topk, week_id);
        let n = vector::length<address>(&lb.topk_addrs);
        let mut i = 0u64; let mut rank: u32 = 0u32; let mut found = false;
        while (i < n) {
            if (*vector::borrow<address>(&lb.topk_addrs, i) == user) { rank = (i as u32) + 1u32; found = true; break; };
            i = i + 1;
        };
        if (found) { option::some<u32>(rank) } else { option::none<u32>() }
    }

    /// Percentile (0..10_000 bps) based on histogram
    public fun view_week_percentile(rew: &Rewards, user: address, week_id: u64): u16 {
        let pts = view_week_points(rew, user, week_id);
        if (!table::contains<&u64, Histogram>(&rew.week_hist, week_id)) return 0u16;
        let h = table::borrow<&u64, Histogram>(&rew.week_hist, week_id);
        let edges_ref = &h.edges; let counts_ref = &h.counts;
        let buckets = vector::length<u128>(edges_ref);
        if (buckets == 0) return 0u16;
        // compute cumulative counts below user's bucket
        let mut idx = bucket_index(edges_ref, pts);
        let mut total: u128 = 0u128; let mut below: u128 = 0u128; let mut i = 0u64;
        while (i < buckets) {
            let c = (*vector::borrow<u64>(counts_ref, i)) as u128;
            if (i < idx) { below = below + c; };
            total = total + c; i = i + 1;
        };
        if (total == 0) return 0u16;
        let pct_bps: u16 = (((below * 10_000u128) / total) as u16);
        pct_bps
    }

    // ===== Internals =====
    fun epoch_day(clock: &Clock): u64 { clock.timestamp_ms() / 86_400_000 }

    fun take_or_new_user(rew: &mut Rewards, who: address): UserState {
        if (table::contains<&address, UserState>(&rew.users, who)) { table::remove<&address, UserState>(&mut rew.users, who) } else { empty_user() }
    }

    fun store_user(rew: &mut Rewards, who: address, u: UserState) { table::add<&address, UserState>(&mut rew.users, who, u); }

    fun empty_user(): UserState {
        let mut slots: vector<u128> = vector::empty<u128>();
        let mut i = 0u64; while (i < 7) { vector::push_back<u128>(&mut slots, 0u128); i = i + 1; };
        UserState {
            day_id: 0,
            week_id: 0,
            minted_today_usdu: 0u128,
            cooldown_until_day: 0,
            realized_loss_today_usd_1e6: 0u128,
            trade_volume_usd_1e6: 0u128,
            maker_quality_usd_1e6: 0u128,
            realized_pnl_pos_usd_1e6: 0u128,
            funding_abs_usd_1e6: 0u128,
            option_premium_taker_usd_1e6: 0u128,
            option_premium_maker_usd_1e6: 0u128,
            borrow_interest_util_usd_1e6: 0u128,
            lend_quality_score_usd_1e6: 0u128,
            liquidations_usd_1e6: 0u128,
            total_volume_usd_1e6: 0u128,
            last_counterparty: @0x0,
            run_volume_usd_1e6: 0u128,
            top_run_volume_usd_1e6: 0u128,
            day_points: 0u128,
            seven_slots: slots,
            seven_day_points_sum: 0u128,
            current_tier: 0u8,
            week_points_own: 0u128,
            week_referral_earned: 0u128,
            week_bucket_idx: 0u64,
            week_bucket_for: 0u64,
            week_points_total: 0u128,
            all_time_points: 0u128,
        }
    }

    fun rollover_if_needed(rew: &mut Rewards, who: address, u: &mut UserState, today: u64, this_week: u64) {
        // weekly boundary
        if (u.week_id != this_week) {
            // reset weekly aggregates but keep points persisted in week map
            u.week_id = this_week;
            u.week_points_own = 0u128;
            u.week_referral_earned = 0u128;
            u.week_points_total = 0u128;
            u.week_bucket_for = this_week;
            u.week_bucket_idx = 0u64;
        };
        // daily boundary
        if (u.day_id != today) {
            // finalize yesterday -> compute points and commit
            let day_points = compute_day_points(rew, u);
            u.day_points = day_points;
            // 7-day ring buffer
            let idx: u64 = today % 7;
            let prev = *vector::borrow_mut<&u128>(&mut u.seven_slots, idx);
            // update sum: remove prev, add new
            if (u.seven_day_points_sum >= prev) { u.seven_day_points_sum = u.seven_day_points_sum - prev; } else { u.seven_day_points_sum = 0u128; };
            *vector::borrow_mut<&u128>(&mut u.seven_slots, idx) = day_points;
            u.seven_day_points_sum = u.seven_day_points_sum + day_points;
            // weekly & totals (own points)
            u.week_points_own = u.week_points_own + day_points;
            u.all_time_points = u.all_time_points + day_points;
            // apply referrals for this user
            apply_referrals_for(rew, who, day_points, u.week_id);
            // recompute totals
            u.week_points_total = u.week_points_own + u.week_referral_earned;
            // update tier
            let new_tier = tier_for(&rew.tier_thresholds_7d, u.seven_day_points_sum);
            if (new_tier != u.current_tier) {
                u.current_tier = new_tier;
                event::emit(TierChanged { user: who, new_tier, seven_day_points: u.seven_day_points_sum, timestamp_ms: 0 });
            };
            // reset dailies
            u.minted_today_usdu = 0u128;
            u.realized_loss_today_usd_1e6 = 0u128;
            u.trade_volume_usd_1e6 = 0u128;
            u.maker_quality_usd_1e6 = 0u128;
            u.realized_pnl_pos_usd_1e6 = 0u128;
            u.funding_abs_usd_1e6 = 0u128;
            u.option_premium_taker_usd_1e6 = 0u128;
            u.option_premium_maker_usd_1e6 = 0u128;
            u.borrow_interest_util_usd_1e6 = 0u128;
            u.lend_quality_score_usd_1e6 = 0u128;
            u.liquidations_usd_1e6 = 0u128;
            u.total_volume_usd_1e6 = 0u128;
            u.run_volume_usd_1e6 = 0u128;
            u.top_run_volume_usd_1e6 = 0u128;
            // mark new day
            u.day_id = today;
            // update per-week maps & leaderboards/histogram
            upsert_week_points(rew, who, u.week_id, u.week_points_total);
            upsert_topk(rew, who, u.week_id, u.week_points_total);
            update_histogram(rew, who, u.week_id, u.week_points_total, &mut u.week_bucket_idx, &mut u.week_bucket_for);
            event::emit(DayFinalized { user: who, day_id: today, points: day_points });
        };
        // ensure day set at least once
        if (u.day_id == 0) { u.day_id = today; };
    }

    fun compute_day_points(rew: &Rewards, u: &UserState): u128 {
        // components
        let v_sqrt = isqrt_u128(u.trade_volume_usd_1e6);
        let m_q = u.maker_quality_usd_1e6;
        let p = u.realized_pnl_pos_usd_1e6;
        let f = u.funding_abs_usd_1e6;
        let opt_t = u.option_premium_taker_usd_1e6;
        let opt_m = u.option_premium_maker_usd_1e6;
        let b = u.borrow_interest_util_usd_1e6;
        let l = u.lend_quality_score_usd_1e6;
        let q = u.liquidations_usd_1e6;
        let mut acc: u128 = 0u128;
        acc = acc + ((v_sqrt * (rew.wV as u128)) / (WEIGHT_SCALE as u128));
        acc = acc + ((m_q * (rew.wM as u128)) / (WEIGHT_SCALE as u128));
        acc = acc + ((p * (rew.wP as u128)) / (WEIGHT_SCALE as u128));
        acc = acc + ((f * (rew.wF as u128)) / (WEIGHT_SCALE as u128));
        // options: treat taker+maker as part of volume term (lightweight); weight via wV as sqrt is already counted in trading volume; keep symmetrical via wM small addition
        acc = acc + (((opt_t + opt_m) * (rew.wV as u128)) / (WEIGHT_SCALE as u128));
        acc = acc + ((b * (rew.wB as u128)) / (WEIGHT_SCALE as u128));
        acc = acc + ((l * (rew.wL as u128)) / (WEIGHT_SCALE as u128));
        acc = acc + ((q * (rew.wQ as u128)) / (WEIGHT_SCALE as u128));
        // anti-abuse: counterparty concentration penalty
        let conc_bps: u64 = if (u.total_volume_usd_1e6 == 0u128) { 0 } else { (((u.top_run_volume_usd_1e6 * (BPS_DENOM as u128)) / u.total_volume_usd_1e6) as u64) };
        if (conc_bps > CONC_PENALTY_THRESH_BPS) {
            // subtract a flat penalty equal to 5,000 points (tunable by weights magnitude)
            let pen: u128 = 5_000u128;
            if (acc > pen) { acc = acc - pen; } else { acc = 0u128; };
        };
        acc
    }

    fun tier_for(thresholds: &vector<u128>, seven_sum: u128): u8 {
        let n = vector::length<&u128>(thresholds);
        if (n == 0) return 0u8;
        let mut i: u64 = 0; let mut out: u8 = 0u8;
        while (i < n) { let th = *vector::borrow<&u128>(thresholds, i); if (seven_sum >= th) { out = (i as u8); }; i = i + 1; };
        out
    }

    fun upsert_week_points(rew: &mut Rewards, who: address, week_id: u64, points: u128) {
        let key = WeekUserKey { week_id, user: who };
        if (table::contains<&WeekUserKey, u128>(&rew.week_points, key)) { let _ = table::remove<&WeekUserKey, u128>(&mut rew.week_points, key); };
        table::add<&WeekUserKey, u128>(&mut rew.week_points, key, points);
    }

    fun upsert_topk(rew: &mut Rewards, who: address, week_id: u64, points: u128) {
        if (!table::contains<&u64, LeaderboardWeek>(&rew.week_topk, week_id)) {
            // initialize empty leaderboard
            let lb = LeaderboardWeek { week_id, topk_addrs: vector::empty<address>(), topk_points: vector::empty<u128>() };
            table::add<&u64, LeaderboardWeek>(&mut rew.week_topk, week_id, lb);
        };
        let mut lbm = table::borrow_mut<&u64, LeaderboardWeek>(&mut rew.week_topk, week_id);
        // try find existing
        let mut idx_opt: option::Option<u64> = option::none<u64>();
        let n = vector::length<&address>(&lbm.topk_addrs);
        let mut i = 0u64; while (i < n) { if (*vector::borrow<&address>(&lbm.topk_addrs, i) == who) { idx_opt = option::some<u64>(i); break; }; i = i + 1; };
        if (option::is_some(&idx_opt)) {
            let idx = option::extract(&mut idx_opt);
            *vector::borrow_mut<&u128>(&mut lbm.topk_points, idx) = points;
            // bubble up/down to keep sorted desc (simple insertion sort step)
            rebalance_topk(&mut lbm.topk_addrs, &mut lbm.topk_points);
            option::destroy_none(idx_opt);
            return;
        };
        // insert if capacity or better than tail
        let k = (rew.leaderboard_topk as u64);
        if (n < k) {
            vector::push_back<&address>(&mut lbm.topk_addrs, who);
            vector::push_back<&u128>(&mut lbm.topk_points, points);
            rebalance_topk(&mut lbm.topk_addrs, &mut lbm.topk_points);
            option::destroy_none(idx_opt);
            return;
        } else if (n > 0) {
            let tail_pts = *vector::borrow<&u128>(&lbm.topk_points, n - 1);
            if (points > tail_pts) {
                // replace tail
                *vector::borrow_mut<&address>(&mut lbm.topk_addrs, n - 1) = who;
                *vector::borrow_mut<&u128>(&mut lbm.topk_points, n - 1) = points;
                rebalance_topk(&mut lbm.topk_addrs, &mut lbm.topk_points);
            };
        };
        option::destroy_none(idx_opt);
    }

    fun rebalance_topk(addrs: &mut vector<address>, pts: &mut vector<u128>) {
        // In-place simple insertion sort to maintain desc order (small K)
        let n = vector::length<u128>(pts);
        let mut i: u64 = 1; while (i < n) {
            let mut j = i;
            while (j > 0) {
                let a = *vector::borrow<u128>(pts, j - 1);
                let b = *vector::borrow<u128>(pts, j);
                if (a >= b) { break; };
                // swap
                let addr_a = *vector::borrow<address>(addrs, j - 1);
                let addr_b = *vector::borrow<address>(addrs, j);
                *vector::borrow_mut<address>(addrs, j - 1) = addr_b;
                *vector::borrow_mut<address>(addrs, j) = addr_a;
                *vector::borrow_mut<u128>(pts, j - 1) = b;
                *vector::borrow_mut<u128>(pts, j) = a;
                j = j - 1;
            };
            i = i + 1;
        };
    }

    fun update_histogram(rew: &mut Rewards, who: address, week_id: u64, points: u128, user_bucket_idx: &mut u64, user_bucket_for: &mut u64) {
        // init histogram for week if missing
        if (!table::contains<&u64, Histogram>(&rew.week_hist, week_id)) {
            // clone edges from config
            let mut edges: vector<u128> = vector::empty<u128>();
            let m = vector::length<u128>(&rew.hist_bucket_edges);
            let mut ci = 0u64; while (ci < m) { let e = *vector::borrow<u128>(&rew.hist_bucket_edges, ci); vector::push_back<u128>(&mut edges, e); ci = ci + 1; };
            let mut counts: vector<u64> = vector::empty<u64>();
            let mut i = 0u64; while (i < m) { vector::push_back<u64>(&mut counts, 0u64); i = i + 1; };
            let h = Histogram { week_id, edges, counts };
            table::add<&u64, Histogram>(&mut rew.week_hist, week_id, h);
        };
        let mut hmut = table::borrow_mut<&u64, Histogram>(&mut rew.week_hist, week_id);
        let idx = bucket_index(&hmut.edges, points);
        // decrement old bucket if same week
        if (*user_bucket_for == week_id) {
            let old = *user_bucket_idx;
            if (old < vector::length<u64>(&hmut.counts)) {
                let cur = *vector::borrow<u64>(&hmut.counts, old);
                if (cur > 0) { *vector::borrow_mut<u64>(&mut hmut.counts, old) = cur - 1; };
            };
        };
        // increment new
        let cur2 = *vector::borrow<u64>(&hmut.counts, idx);
        *vector::borrow_mut<u64>(&mut hmut.counts, idx) = cur2 + 1;
        *user_bucket_idx = idx;
        *user_bucket_for = week_id;
        let _ = who; // silence unused param warning
    }

    fun bucket_index(edges: &vector<u128>, points: u128): u64 {
        let n = vector::length<u128>(edges);
        if (n == 0) return 0u64;
        let mut i = 0u64; let mut out = 0u64;
        while (i < n) { let e = *vector::borrow<u128>(edges, i); if (points >= e) { out = i; }; i = i + 1; };
        out
    }

    fun apply_referrals_for(rew: &mut Rewards, child: address, child_day_points: u128, week_id: u64) {
        // propagate to L1..L3
        if (!table::contains<&address, address>(&rew.referrals, child)) return;
        let p1 = *table::borrow<&address, address>(&rew.referrals, child);
        credit_referral(rew, p1, child_day_points, rew.l1_bps, week_id);
        if (table::contains<&address, address>(&rew.referrals, p1)) {
            let p2 = *table::borrow<&address, address>(&rew.referrals, p1);
            credit_referral(rew, p2, child_day_points, rew.l2_bps, week_id);
            if (table::contains<&address, address>(&rew.referrals, p2)) {
                let p3 = *table::borrow<&address, address>(&rew.referrals, p2);
                credit_referral(rew, p3, child_day_points, rew.l3_bps, week_id);
            };
        };
    }

    fun credit_referral(rew: &mut Rewards, referrer: address, base_points: u128, bps: u64, week_id: u64) {
        let mut u = take_or_new_user(rew, referrer);
        if (u.week_id != week_id) {
            // align week context so cap calculation uses current week's own points
            u.week_id = week_id; u.week_points_own = 0u128; u.week_referral_earned = 0u128; u.week_points_total = 0u128;
        };
        let mut add: u128 = (base_points * (bps as u128)) / (BPS_DENOM as u128);
        // cap: referral_earned ≤ cap_bps × own_points
        let cap_total: u128 = (u.week_points_own * (rew.ref_cap_bps_per_week as u128)) / (BPS_DENOM as u128);
        if (u.week_referral_earned + add > cap_total) {
            if (u.week_referral_earned >= cap_total) { add = 0u128; } else { add = cap_total - u.week_referral_earned; };
        };
        if (add > 0) {
            u.week_referral_earned = u.week_referral_earned + add;
            u.week_points_total = u.week_points_own + u.week_referral_earned;
            // persist current totals to week map & topk/hist
            upsert_week_points(rew, referrer, week_id, u.week_points_total);
            upsert_topk(rew, referrer, week_id, u.week_points_total);
            update_histogram(rew, referrer, week_id, u.week_points_total, &mut u.week_bucket_idx, &mut u.week_bucket_for);
        };
        store_user(rew, referrer, u);
    }

    fun isqrt_u128(x: u128): u128 {
        if (x == 0u128) return 0u128;
        let mut z: u128 = (x + 1u128) / 2u128;
        let mut y: u128 = x;
        while (z < y) { y = z; z = (x / z + z) / 2u128; };
        y
    }
}


