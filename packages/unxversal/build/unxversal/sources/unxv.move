module unxversal::unxv {
    use sui::coin::{Self as coin, TreasuryCap, Coin};
    use sui::event;
    
    /// Our UNXV (Unxversal) token type
    public struct UNXV has drop {}

    /// Wraps the raw mint cap plus supply‐tracking fields.
    public struct SupplyCap has key, store {
        id: UID,
        cap: TreasuryCap<UNXV>,
        max_supply: u64,
        current: u64,
    }

    /// Emitted on successful mint operations
    public struct UNXVMinted has copy, drop {
        /// Amount of UNXV minted (units)
        amount: u64,
        /// Recipient address that received the minted coins
        to: address,
        /// Transaction sender that invoked the mint
        by: address,
        /// Timestamp (ms) at execution time
        timestamp_ms: u64,
    }

    /// Emitted on successful burn operations
    public struct UNXVBurned has copy, drop {
        /// Amount of UNXV burned (units)
        amount: u64,
        /// Transaction sender that invoked the burn
        by: address,
        /// Timestamp (ms) at execution time
        timestamp_ms: u64,
    }

    /// Initialize UNXV:
    /// 1) Claim your package Publisher  
    /// 2) Create the coin (6 decimals, symbol "UNXV", name "Unxversal Token")  
    /// 3) Freeze metadata  
    /// 4) Mint 1_000_000_000 UNXV to `owner`  
    /// 5) Wrap & store the mint cap in a `SupplyCap` (so you can enforce a max later)  
    /// 6) Transfer `SupplyCap` to `owner`
    fun init(
        witness: UNXV,
        ctx: &mut TxContext
    ) {
        // 2) Create the coin + raw mint cap
        let (mut raw_cap, metadata) = coin::create_currency(
            witness,
            6,                         // decimals
            b"UNXV",                   // symbol
            b"Unxversal Token",        // name
            b"",                       // icon URL placeholder / description
            option::none(),            // no extensions
            ctx
        );
        // 3) Freeze metadata
        transfer::public_freeze_object(metadata);

        // 4) Mint all 1_000_000_000 up‑front
        let initial: u64 = 1_000_000_000;
        let coins_all = coin::mint(&mut raw_cap, initial, ctx);
        let owner = ctx.sender();
        transfer::public_transfer(coins_all, owner);

        // 5) Wrap cap + supply tracking and transfer to owner
        let sc = SupplyCap { id: object::new(ctx), cap: raw_cap, max_supply: initial, current: initial };
        transfer::public_transfer(sc, owner);
    }

    /// Mint additional UNXV, up to the 1 000 000 000 cap.
    /// Only callable by whoever holds the SupplyCap.
    public fun mint(
        sc: &mut SupplyCap,
        amount: u64,
        recipient: address,
        ctx: &mut TxContext
    ) {
        // enforce hard cap
        assert!(sc.current + amount <= sc.max_supply, 1);
        let coins = coin::mint(&mut sc.cap, amount, ctx);
        sc.current = sc.current + amount;
        transfer::public_transfer(coins, recipient);
        // Emit event for observability
        event::emit(UNXVMinted { amount, to: recipient, by: ctx.sender(), timestamp_ms: sui::tx_context::epoch_timestamp_ms(ctx) });
    }

    /// Burn UNXV and reduce the tracked supply.
    /// Only callable by whoever holds the SupplyCap.
    public fun burn(
        sc: &mut SupplyCap,
        mut coins: vector<Coin<UNXV>>,
        ctx: &mut TxContext
    ) {
        // merge vector into single coin and track amount
        let mut burned: u64 = 0;
        let mut merged = coin::zero<UNXV>(ctx);
        while (!vector::is_empty(&coins)) {
            let c = vector::pop_back(&mut coins);
            burned = burned + coin::value(&c);
            coin::join(&mut merged, c);
        };
        // burn on‑chain
        coin::burn(&mut sc.cap, merged);
        sc.current = sc.current - burned;
        // consume the emptied vector of non-drop coins
        vector::destroy_empty<Coin<UNXV>>(coins);
        // Emit event for observability
        event::emit(UNXVBurned { amount: burned, by: ctx.sender(), timestamp_ms: sui::tx_context::epoch_timestamp_ms(ctx) });
    }

    #[test_only]
    public fun new_supply_cap_for_testing(ctx: &mut TxContext): SupplyCap {
        let witness = UNXV {};
        let (raw_cap, metadata) = coin::create_currency(
            witness,
            6,
            b"UNXV",
            b"Unxversal Token",
            b"",
            option::none(),
            ctx
        );
        transfer::public_freeze_object(metadata);
        SupplyCap { id: object::new(ctx), cap: raw_cap, max_supply: 1_000_000_000, current: 0 }
    }

    #[test_only]
    public fun mint_coin_for_testing(sc: &mut SupplyCap, amount: u64, ctx: &mut TxContext): Coin<UNXV> {
        assert!(sc.current + amount <= sc.max_supply, 1);
        let c = coin::mint(&mut sc.cap, amount, ctx);
        sc.current = sc.current + amount;
        c
    }

    /// Mirror structure for testing event semantics without relying on event indexing
    #[test_only]
    public struct UnxvEventMirror has key, store {
        id: UID,
        mint_count: u64,
        burn_count: u64,
        last_mint_amount: u64,
        last_mint_to: address,
        last_burn_amount: u64,
    }

    #[test_only]
    public fun new_event_mirror_for_testing(ctx: &mut TxContext): UnxvEventMirror {
        UnxvEventMirror { id: object::new(ctx), mint_count: 0, burn_count: 0, last_mint_amount: 0, last_mint_to: @0x0, last_burn_amount: 0 }
    }

    /// Test-only wrapper to mint and update the mirror
    #[test_only]
    public fun mint_with_event_mirror(sc: &mut SupplyCap, amount: u64, recipient: address, mirror: &mut UnxvEventMirror, ctx: &mut TxContext) {
        mint(sc, amount, recipient, ctx);
        mirror.mint_count = mirror.mint_count + 1;
        mirror.last_mint_amount = amount;
        mirror.last_mint_to = recipient;
    }

    /// Test-only wrapper to burn and update the mirror
    #[test_only]
    public fun burn_with_event_mirror(sc: &mut SupplyCap, mut coins: vector<Coin<UNXV>>, mirror: &mut UnxvEventMirror, ctx: &mut TxContext) {
        // compute total before moving into burn
        let mut total: u64 = 0;
        let mut tmp = coin::zero<UNXV>(ctx);
        while (!vector::is_empty(&coins)) {
            let c = vector::pop_back(&mut coins);
            total = total + coin::value(&c);
            coin::join(&mut tmp, c);
        };
        // reconstruct vector to call burn (split tmp back into a vector of one)
        let mut v2 = vector::empty<Coin<UNXV>>();
        vector::push_back(&mut v2, tmp);
        burn(sc, v2, ctx);
        mirror.burn_count = mirror.burn_count + 1;
        mirror.last_burn_amount = total;
        vector::destroy_empty<Coin<UNXV>>(coins);
    }

    // Test-only getters
    #[test_only]
    public fun supply_current_for_testing(sc: &SupplyCap): u64 { sc.current }
    #[test_only]
    public fun em_mint_count(m: &UnxvEventMirror): u64 { m.mint_count }
    #[test_only]
    public fun em_last_mint_amount(m: &UnxvEventMirror): u64 { m.last_mint_amount }
    #[test_only]
    public fun em_last_mint_to(m: &UnxvEventMirror): address { m.last_mint_to }
    #[test_only]
    public fun em_burn_count(m: &UnxvEventMirror): u64 { m.burn_count }
    #[test_only]
    public fun em_last_burn_amount(m: &UnxvEventMirror): u64 { m.last_burn_amount }
}