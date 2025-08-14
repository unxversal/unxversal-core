module unxversal::unxv {
    use sui::coin::{Self as coin, TreasuryCap, Coin};
    
    /// Our UNXV (Unxversal) token type
    public struct UNXV has drop {}

    /// Wraps the raw mint cap plus supply‐tracking fields.
    public struct SupplyCap has key, store {
        id: UID,
        cap: TreasuryCap<UNXV>,
        max_supply: u64,
        current: u64,
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
    }
}