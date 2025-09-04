/// Module: unxversal_usdu
/// ------------------------------------------------------------
/// Testnet USD stablecoin: USDU (USD Unxversal)
/// - 6 decimals
/// - Hard total supply cap: 1 trillion tokens (1e12) → 1e18 base units
/// - Faucet with admin-configurable per-address cumulative claim limit
/// - Public claim function mints directly to caller, respecting caps
module unxversal::usdu {
    use sui::coin::{Self as coin, TreasuryCap};
    use sui::table::{Self as table, Table};
    use sui::clock::Clock;
    use sui::event;
    use unxversal::admin::{Self as AdminMod, AdminRegistry};

    /// USDU token type
    public struct USDU has drop {}

    /// Faucet state holding the mint cap and limits
    public struct Faucet has key, store {
        id: UID,
        /// TreasuryCap enabling mint/burn for USDU
        cap: TreasuryCap<USDU>,
        /// Hard cap of total minted supply in base units (6 decimals)
        max_supply: u64,
        /// Current total minted supply in base units
        current: u64,
        /// Max cumulative amount any single address can claim from faucet (base units)
        max_per_address: u64,
        /// Per-address claimed amount (base units)
        claims: Table<address, u64>,
        /// Pause flag for emergency stops
        paused: bool,
    }

    /// Errors
    const E_LIMIT_NOT_SET: u64 = 1;
    const E_PAUSED: u64 = 2;
    const E_AMOUNT_ZERO: u64 = 3;
    const E_OVER_SUPPLY_CAP: u64 = 4;
    const E_OVER_ADDR_LIMIT: u64 = 5;
    const E_NOT_ADMIN: u64 = 6;

    /// 1e12 tokens * 1e6 decimals = 1e18 base units
    const MAX_SUPPLY_UNITS: u64 = 1_000_000_000_000_000_000;

    /// Events
    public struct FaucetInitialized has copy, drop { per_address_limit: u64, by: address, timestamp_ms: u64 }
    public struct Claimed has copy, drop { who: address, amount: u64, total_claimed: u64, timestamp_ms: u64 }
    public struct PerAddressLimitUpdated has copy, drop { new_limit: u64, by: address, timestamp_ms: u64 }
    public struct Paused has copy, drop { paused: bool, by: address, timestamp_ms: u64 }

    /// Initialize the USDU currency and share a Faucet with zero per-address limit by default.
    /// Admins should call `set_per_address_limit` afterwards to configure the faucet.
    fun init(witness: USDU, ctx: &mut TxContext) {
        let (cap, metadata) = coin::create_currency(
            witness,
            6,                  // decimals
            b"USDU",            // symbol
            b"USD Unxversal",   // name
            b"",                // icon URL / description
            option::none(),
            ctx
        );
        transfer::public_freeze_object(metadata);

        let faucet = Faucet {
            id: object::new(ctx),
            cap,
            max_supply: MAX_SUPPLY_UNITS,
            current: 0,
            max_per_address: 0,
            claims: table::new<address, u64>(ctx),
            paused: false,
        };
        transfer::share_object(faucet);
        // Initial event for off-chain indexers
        event::emit(FaucetInitialized { per_address_limit: 0, by: ctx.sender(), timestamp_ms: sui::tx_context::epoch_timestamp_ms(ctx) });
    }

    /// Admin: set or update the per-address faucet claim limit (in base units).
    entry fun set_per_address_limit(reg_admin: &AdminRegistry, faucet: &mut Faucet, new_limit: u64, clock: &Clock, ctx: &TxContext) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        faucet.max_per_address = new_limit;
        event::emit(PerAddressLimitUpdated { new_limit, by: ctx.sender(), timestamp_ms: sui::clock::timestamp_ms(clock) });
    }

    /// Admin: pause or unpause the faucet.
    entry fun set_paused(reg_admin: &AdminRegistry, faucet: &mut Faucet, paused: bool, clock: &Clock, ctx: &TxContext) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        faucet.paused = paused;
        event::emit(Paused { paused, by: ctx.sender(), timestamp_ms: sui::clock::timestamp_ms(clock) });
    }

    /// Public: claim USDU from the faucet up to the per-address limit and global cap.
    /// - `amount` is specified in base units (6 decimals)
    entry fun claim(faucet: &mut Faucet, amount: u64, clock: &Clock, ctx: &mut TxContext) {
        assert!(!faucet.paused, E_PAUSED);
        assert!(faucet.max_per_address > 0, E_LIMIT_NOT_SET);
        assert!(amount > 0, E_AMOUNT_ZERO);

        // Enforce global cap
        let new_total = faucet.current + amount;
        assert!(new_total <= faucet.max_supply, E_OVER_SUPPLY_CAP);

        // Enforce per-address cumulative limit
        let who = ctx.sender();
        let claimed = get_claimed(&faucet.claims, who);
        let new_claimed = claimed + amount;
        assert!(new_claimed <= faucet.max_per_address, E_OVER_ADDR_LIMIT);

        // Mint and transfer
        let minted = coin::mint(&mut faucet.cap, amount, ctx);
        faucet.current = new_total;
        set_claimed(&mut faucet.claims, who, new_claimed);
        transfer::public_transfer(minted, who);

        event::emit(Claimed { who, amount, total_claimed: new_claimed, timestamp_ms: sui::clock::timestamp_ms(clock) });
    }

    /// View: remaining claimable amount for an address (base units)
    public fun remaining_for(faucet: &Faucet, who: address): u64 {
        if (faucet.max_per_address == 0) return 0;
        let claimed = get_claimed(&faucet.claims, who);
        if (faucet.max_per_address > claimed) { faucet.max_per_address - claimed } else { 0 }
    }

    /// View: total minted so far (base units)
    public fun total_minted(faucet: &Faucet): u64 { faucet.current }

    /// View: per-address limit (base units)
    public fun per_address_limit(faucet: &Faucet): u64 { faucet.max_per_address }

    /// Internal: read claimed amount
    fun get_claimed(tbl: &Table<address, u64>, who: address): u64 {
        if (table::contains(tbl, who)) { *table::borrow(tbl, who) } else { 0 }
    }

    /// Internal: set claimed amount
    fun set_claimed(tbl: &mut Table<address, u64>, who: address, v: u64) {
        if (table::contains(tbl, who)) { let _ = table::remove(tbl, who); };
        table::add(tbl, who, v);
    }

    #[test_only]
    public fun new_faucet_for_testing(ctx: &mut TxContext): Faucet {
        let (cap, metadata) = coin::create_currency(
            USDU{},
            6,
            b"USDU",
            b"USD Unxversal",
            b"",
            option::none(),
            ctx
        );
        transfer::public_freeze_object(metadata);
        Faucet { id: object::new(ctx), cap, max_supply: MAX_SUPPLY_UNITS, current: 0, max_per_address: 0, claims: table::new<address, u64>(ctx), paused: false }
    }
}


