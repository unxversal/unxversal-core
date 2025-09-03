/// Module: unxversal_admin – centralized admin registry
/// - Single shared registry of admin addresses for the package
/// - Other modules reference this to gate admin-only entry functions

module unxversal::admin {
    use sui::vec_set::{Self as vec_set, VecSet};

    public struct AdminRegistry has key, store {
        id: UID,
        admins: VecSet<address>,
    }

    public struct ADMIN has drop {}

    /// Initialize the admin registry with the publisher/creator as the first admin.
    fun init(_w: ADMIN, ctx: &mut TxContext) {
        let mut set = vec_set::empty<address>();
        vec_set::insert(&mut set, ctx.sender());
        let reg = AdminRegistry { id: object::new(ctx), admins: set };
        transfer::share_object(reg);
    }

    /// Add a new admin. Callable by existing admins.
    public fun add_admin(reg: &mut AdminRegistry, new_admin: address, ctx: &TxContext) {
        assert!(is_admin(reg, ctx.sender()), 0);
        vec_set::insert(&mut reg.admins, new_admin);
    }

    /// Remove an admin. Callable by existing admins.
    public fun remove_admin(reg: &mut AdminRegistry, bad_admin: address, ctx: &TxContext) {
        assert!(is_admin(reg, ctx.sender()), 0);
        vec_set::remove(&mut reg.admins, &bad_admin);
    }

    public fun is_admin(reg: &AdminRegistry, who: address): bool { vec_set::contains(&reg.admins, &who) }

    #[test_only]
    public fun new_admin_registry_for_testing(ctx: &mut TxContext): AdminRegistry {
        let mut set = vec_set::empty<address>();
        vec_set::insert(&mut set, ctx.sender());
        AdminRegistry { id: object::new(ctx), admins: set }
    }
}


