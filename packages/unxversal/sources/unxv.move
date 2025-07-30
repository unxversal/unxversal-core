module unxversal::unxv {
    use sui::coin::{Self, TreasuryCap};
    use sui::tx_context::TxContext;
    use sui::transfer;
    use sui::coin;
    use sui::package;
    use sui::display;
    use std::string::String;
    use option;

    /// Our UNXV (Unxversal) token type
    public struct UNXV has drop {}

    /// Initialize UNXV:
    /// 1. Claim the package Publisher
    /// 2. Create the coin with 6 decimals, symbol "UNXV", name "Unxversal Token"
    /// 3. Freeze its metadata
    /// 4. Mint 1_000_000_000 UNXV to the deployer
    /// 5. Transfer the TreasuryCap to the deployer (so mint/burn remain possible)
    /// 6. Create a Display<UNXV> with placeholder templates
    /// 7. Transfer both Publisher and Display objects to the deployer
    public entry fun init(
        otw: sui::package::ONE_TIME_WITNESS,
        ctx: &mut TxContext
    ) {
        // 1) claim the Publisher for this package
        let publisher = package::claim(otw, ctx);

        // 2) create the UNXV coin type
        let (mut cap, metadata) = coin::create_currency(
            UNXV {},
            6,                         // decimals
            b"UNXV",                   // symbol
            b"Unxversal Token",        // name
            b"",                       // icon URL (placeholder)
            false,                     // extensions
            ctx
        );

        // 3) freeze the metadata so it can never be altered
        transfer::public_freeze_object(metadata);

        // 4) mint the full 1 000 000 000 supply
        let initial_supply: u64 = 1_000_000_000;
        let coins = coin::mint(&mut cap, initial_supply, ctx);

        // 5) send the minted coins to the deployer
        let owner = ctx.sender();
        transfer::public_transfer(coins, owner);

        // 6) transfer the TreasuryCap to the deployer so they can mint/burn later
        transfer::public_transfer(cap, owner);

        // 7) set up a Display<UNXV> with placeholder templates
        let mut disp = display::new<UNXV>(&publisher, ctx);

        /// UNXV Display metadata
        disp.add(
            b"name".to_string(),
            b"UNXV".to_string()                   
        );
        disp.add(
            b"description".to_string(),
            b"{description}".to_string()            // placeholder: description text
        );
        disp.add(
            b"image_url".to_string(),
            b"{image_url}".to_string()              // placeholder: image URL
        );
        disp.add(
            b"thumbnail_url".to_string(),
            b"{thumbnail_url}".to_string()          // placeholder: thumbnail URL
        );
        disp.add(
            b"project_url".to_string(),
            b"https://unxversal.com".to_string()            // placeholder: project website
        );
        disp.add(
            b"creator".to_string(),
            b"Unxversal Protocol".to_string()                
        );

        // finalize the Display version
        disp.update_version();

        // 8) hand off the Publisher and Display to the deployer
        transfer::public_transfer(publisher, owner);
        transfer::public_transfer(disp, owner);
    }

    /// Mint additional UNXV tokens.
    /// Only callable by whoever holds the TreasuryCap<UNXV>.
    public entry fun mint(
        cap: &mut TreasuryCap<UNXV>,
        amount: u64,
        recipient: address,
        ctx: &mut TxContext
    ) {
        let coins = coin::mint(cap, amount, ctx);
        transfer::public_transfer(coins, recipient);
    }

    /// Burn UNXV tokens.
    /// Only callable by whoever holds the TreasuryCap<UNXV>.
    public entry fun burn(
        cap: &mut TreasuryCap<UNXV>,
        coins: vector<Coin<UNXV>>,
        ctx: &mut TxContext
    ) {
        coin::burn(cap, coins, ctx);
    }
}