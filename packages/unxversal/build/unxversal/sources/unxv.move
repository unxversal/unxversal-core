module unxversal::unxv {
    use sui::coin::{Self, TreasuryCap, Coin};



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
    /// 6) Create a `Display<UNXV>` with your placeholders  
    /// 7) Transfer Publisher, Display, and `SupplyCap` to `owner`
    fun init(otw: UNXV, ctx: &mut tx_context::TxContext) {
        // 2) Create the coin + raw mint cap (use otw first)
        let (mut raw_cap, metadata) = coin::create_currency(
            otw, 
            6,                         // decimals
            b"UNXV",                   // symbol
            b"Unxversal Token",        // name
            b"",                       // icon URL placeholder
            option::none(),            // no extensions
            ctx
        );
        
        // Can't use otw again since it's consumed
        // let publisher = package::claim(otw, ctx);
        // 3) Freeze metadata
        transfer::public_freeze_object(metadata);

        // 4) Mint all 1 000 000 000 up-front
        let initial: u64 = 1_000_000_000;
        let coins = coin::mint(&mut raw_cap, initial, ctx);
        let owner = ctx.sender();
        sui::transfer::public_transfer(coins, owner);

        // 5) Wrap cap + supply tracking
        let sc = SupplyCap {
            id: sui::object::new(ctx),
            cap: raw_cap,
            max_supply: initial,
            current: initial,
        };
        transfer::transfer(sc, owner);

        // 6) Note: Publisher would need to be claimed from package::claim(otw, ctx)
        // but we can't reuse the OTW that was consumed in coin::create_currency
        // This would typically be done in a two-step process or with separate OTW
    }

    /// Mint additional UNXV, up to the 1 000 000 000 cap.
    /// Only callable by whoever holds the SupplyCap.
    public entry fun mint(
        sc: &mut SupplyCap,
        amount: u64,
        recipient: address,
        ctx: &mut tx_context::TxContext
    ) {
        // enforce hard cap
        assert!(sc.current + amount <= sc.max_supply, 1);
        let coins = coin::mint(&mut sc.cap, amount, ctx);
        sc.current = sc.current + amount;
        sui::transfer::public_transfer(coins, recipient);
    }

    /// Burn UNXV and reduce the tracked supply.
    /// Only callable by whoever holds the SupplyCap.
    public entry fun burn(
        sc: &mut SupplyCap,
        mut coins: vector<Coin<UNXV>>,
        ctx: &mut tx_context::TxContext
    ) {
        // burn on‐chain (merge coins and sum amount)
        let mut merged = coin::zero<UNXV>(ctx);
        let mut burned: u64 = 0;
        while (std::vector::length(&coins) > 0) {
            let c = std::vector::pop_back(&mut coins);
            burned = burned + coin::value(&c);
            coin::join(&mut merged, c);
        };
        std::vector::destroy_empty(coins);
        coin::burn(&mut sc.cap, merged);
        sc.current = sc.current - burned;
    }
}