module unxversal::unxv {
    use sui::coin::{Self, TreasuryCap, Coin};
    use sui::tx_context::TxContext;
    use sui::transfer;
    use sui::coin;
    use sui::package;
    use sui::display;
    use std::string::String;
    use std::vector;
    use option;

    /// Our UNXV (Unxversal) token type
    public struct UNXV has drop {}

    /// Wraps the raw mint cap plus supply‐tracking fields.
    resource struct SupplyCap has key {
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
    public entry fun init(
        otw: sui::package::ONE_TIME_WITNESS,
        ctx: &mut TxContext
    ) {
        let publisher = package::claim(otw, ctx);

        // 2) Create the coin + raw mint cap
        let (mut raw_cap, metadata) = coin::create_currency(
            UNXV {}, 
            6,                         // decimals
            b"UNXV",                   // symbol
            b"Unxversal Token",        // name
            b"",                       // icon URL placeholder
            option::none(),            // no extensions
            ctx
        );
        // 3) Freeze metadata
        transfer::public_freeze_object(metadata);

        // 4) Mint all 1 000 000 000 up‑front
        let initial: u64 = 1_000_000_000;
        let coins = coin::mint(&mut raw_cap, initial, ctx);
        let owner = ctx.sender();
        transfer::public_transfer(coins, owner);

        // 5) Wrap cap + supply tracking
        let sc = SupplyCap {
            cap: raw_cap,
            max_supply: initial,
            current: initial,
        };
        move_to(owner, sc);

        // 6) Display setup with your placeholders
        let mut disp = display::new<UNXV>(&publisher, ctx);
        disp.add(b"name".to_string(),           b"UNXV".to_string());
        disp.add(b"description".to_string(),    b"{description}".to_string());
        disp.add(b"image_url".to_string(),      b"{image_url}".to_string());
        disp.add(b"thumbnail_url".to_string(),  b"{thumbnail_url}".to_string());
        disp.add(b"project_url".to_string(),    b"https://unxversal.com".to_string());
        disp.add(b"creator".to_string(),        b"Unxversal Protocol".to_string());
        disp.update_version();

        // 7) Hand off Publisher and Display to owner
        transfer::public_transfer(publisher, owner);
        transfer::public_transfer(disp, owner);
    }

    /// Mint additional UNXV, up to the 1 000 000 000 cap.
    /// Only callable by whoever holds the SupplyCap.
    public entry fun mint(
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
    public entry fun burn(
        sc: &mut SupplyCap,
        coins: vector<Coin<UNXV>>,
        ctx: &mut TxContext
    ) {
        // sum up burned amount
        let mut i = 0;
        let mut burned: u64 = 0;
        while (i < vector::length(&coins)) {
            let c_ref = vector::borrow(&coins, i);
            burned = burned + coin::value(c_ref);
            i = i + 1;
        }
        // burn on‐chain
        coin::burn(&mut sc.cap, coins, ctx);
        sc.current = sc.current - burned;
    }
}