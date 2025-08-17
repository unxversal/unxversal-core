module unxversal::bot_rewards {
    use sui::table::{Self as table, Table};
    use sui::clock::Clock;
    use std::string::String;
    use sui::event;
    use unxversal::admin::{Self as AdminMod, AdminRegistry};

    /// Tracks task weights and per-actor points for the current accounting window
    public struct BotPointsRegistry has key, store {
        id: UID,
        weights: Table<String, u64>,          // task_key -> weight
        points: Table<address, u64>,          // actor -> points in current period
    }

    /// Canonical event for bot point awards
    public struct PointsAwarded has copy, drop { task: String, points: u64, actor: address, timestamp: u64 }

    /// Create the registry (admin-gated via AdminRegistry)
    public fun init_points_registry(admin_reg: &AdminRegistry, ctx: &mut TxContext) {
        assert!(AdminMod::is_admin(admin_reg, ctx.sender()), 0);
        let reg = BotPointsRegistry { id: object::new(ctx), weights: table::new<String, u64>(ctx), points: table::new<address, u64>(ctx) };
        transfer::share_object(reg);
    }

    /// Set or update a task weight
    public fun set_weight(admin_reg: &AdminRegistry, reg: &mut BotPointsRegistry, task_key: String, weight: u64, _ctx: &TxContext) {
        assert!(AdminMod::is_admin(admin_reg, _ctx.sender()), 0);
        if (table::contains(&reg.weights, clone_string(&task_key))) { let _ = table::remove(&mut reg.weights, clone_string(&task_key)); };
        table::add(&mut reg.weights, task_key, weight);
    }

    /// Award points to an actor for a given task; timestamp sourced from Clock
    public fun award_points(reg: &mut BotPointsRegistry, task_key: String, actor: address, clock: &Clock) {
        let now = sui::clock::timestamp_ms(clock);
        let w = if (table::contains(&reg.weights, clone_string(&task_key))) { *table::borrow(&reg.weights, clone_string(&task_key)) } else { 0 };
        if (w > 0) {
            let cur = if (table::contains(&reg.points, actor)) { *table::borrow(&reg.points, actor) } else { 0 };
            let newp = cur + w;
            if (table::contains(&reg.points, actor)) { let _ = table::remove(&mut reg.points, actor); };
            table::add(&mut reg.points, actor, newp);
            event::emit(PointsAwarded { task: task_key, points: w, actor, timestamp: now });
        };
    }

    fun clone_string(s: &String): String {
        let bytes = std::string::as_bytes(s);
        let mut out = vector::empty<u8>();
        let mut i = 0; let n = vector::length(bytes);
        while (i < n) { vector::push_back(&mut out, *vector::borrow(bytes, i)); i = i + 1; };
        std::string::utf8(out)
    }
}


