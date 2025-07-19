Write a Move Package
To begin, open a terminal or console at the location you plan to store your package. Use the sui move new command to create an empty Move package with the name my_first_package:

$ sui move new my_first_package

Running the previous command creates a directory with the name you provide (my_first_package in this case). The command populates the new directory with a skeleton Move project that consists of a sources directory and a Move.toml manifest file. Open the manifest with a text editor to review its contents:

[package]
name = "my_first_package"
edition = "2024.beta" # edition = "legacy" to use legacy (pre-2024) Move
# license = ""           # e.g., "MIT", "GPL", "Apache 2.0"
# authors = ["..."]      # e.g., ["Joe Smith (joesmith@noemail.com)", "John Snow (johnsnow@noemail.com)"]

[dependencies]
# For remote import, use the `{ git = "...", subdir = "...", rev = "..." }`.
# Revision can be a branch, a tag, and a commit hash.
# MyRemotePackage = { git = "https://some.remote/host.git", subdir = "remote/path", rev = "main" }

# For local dependencies use `local = path`. Path is relative to the package root
# Local = { local = "../path/to" }

# To resolve a version conflict and force a specific version for dependency
# override use `override = true`
# Override = { local = "../conflicting/version", override = true }

[addresses]
my_first_package = "0x0"

# Named addresses will be accessible in Move as `@name`. They're also exported:
# for example, `std = "0x1"` is exported by the Standard Library.
# alice = "0xA11CE"

[dev-dependencies]
# The dev-dependencies section allows overriding dependencies for `--test` and
# `--dev` modes. You can introduce test-only dependencies here.
# Local = { local = "../path/to/dev-build" }

[dev-addresses]
# The dev-addresses section allows overwriting named addresses for the `--test`
# and `--dev` modes.
# alice = "0xB0B"


The manifest file contents include available sections of the manifest and comments that provide additional information. In Move, you prepend the hash mark (#) to a line to denote a comment.

[package]: Contains metadata for the package. By default, the sui move new command populates only the name value of the metadata. In this case, the example passes my_first_package to the command, which becomes the name of the package. You can delete the first # of subsequent lines of the [package] section to provide values for the other available metadata fields.
[dependencies]: Lists the other packages that your package depends on to run. By default, the sui move new command lists the Sui package on GitHub (Testnet version) as the lone dependency.
[addresses]: Declares named addresses that your package uses. By default, the section includes the package you create with the sui move new command and an address of 0x0. This value can be left as-is and indicates that package addresses are automatically managed when published and upgraded.
[dev-dependencies]: Includes only comments that describe the section.
[dev-addresses]: Includes only comments that describe the section.
Defining the package
You have a package now but it doesn't do anything. To make your package useful, you must add logic contained in .move source files that define modules. The sui move new command creates a .move file in the sources directory that defaults to the same name as your project (my_first_package.move in this case). For the purpose of this guide, rename the file to example.move and open it with a text editor.

Populate the example.move file with the following code:

examples/move/first_package/sources/example.move
module my_first_package::example;

// Part 1: These imports are provided by default
// use sui::object::{Self, UID};
// use sui::transfer;
// use sui::tx_context::{Self, TxContext};

// Part 2: struct definitions
public struct Sword has key, store {
    id: UID,
    magic: u64,
    strength: u64,
}

public struct Forge has key {
    id: UID,
    swords_created: u64,
}

// Part 3: Module initializer to be executed when this module is published
fun init(ctx: &mut TxContext) {
    let admin = Forge {
        id: object::new(ctx),
        swords_created: 0,
    };

    // Transfer the forge object to the module/package publisher
    transfer::transfer(admin, ctx.sender());
}

// Part 4: Accessors required to read the struct fields
public fun magic(self: &Sword): u64 {
    self.magic
}

public fun strength(self: &Sword): u64 {
    self.strength
}

public fun swords_created(self: &Forge): u64 {
    self.swords_created
}

// Part 5: Public/entry functions (introduced later in the tutorial)

// Part 6: Tests

The comments in the preceding code highlight different parts of a typical Move source file.

Part 1: Imports - Code reuse is a necessity in modern programming. Move supports this concept with use aliases that allow your module to refer to types and functions declared in other modules. In this example, the module imports from object, transfer, and tx_context modules, but it does not need to do so explicitly, because the compiler provides these use statements by default. These modules are available to the package because the Move.toml file defines the Sui dependency (along with the sui named address) where they are defined.

Part 2: Struct declarations - Structs define types that a module can create or destroy. Struct definitions can include abilities provided with the has keyword. The structs in this example, for instance, have the key ability, which indicates that these structs are Sui objects that you can transfer between addresses. The store ability on the structs provides the ability to appear in other struct fields and be transferred freely.

Part 3: Module initializer - A special function that is invoked exactly once when the module publishes.

Part 4: Accessor functions - These functions allow the fields of the module's structs to be read from other modules.

After you save the file, you have a complete Move package.


Build and Test Packages
If you followed Write a Move Package, you have a basic module that you need to build. If you didn't, then either start with that topic or use your package, substituting that information where appropriate.

Building your package
Make sure your terminal or console is in the directory that contains your package (my_first_package if you're following along). Use the following command to build your package:

$ sui move build

A successful build returns a response similar to the following:

UPDATING GIT DEPENDENCY https://github.com/MystenLabs/sui.git
INCLUDING DEPENDENCY Sui
INCLUDING DEPENDENCY MoveStdlib
BUILDING my_first_package

If the build fails, you can use the verbose error messaging in output to troubleshoot and resolve root issues.

Now that you have designed your asset and its accessor functions, it's time to test the package code before publishing.

Testing a package
Sui includes support for the Move testing framework. Using the framework, you can write unit tests that analyze Move code much like test frameworks for other languages, such as the built-in Rust testing framework or the JUnit framework for Java.

An individual Move unit test is encapsulated in a public function that has no parameters, no return values, and has the #[test] annotation. The testing framework executes such functions when you call the sui move test command from the package root (my_move_package directory as per the current running example):

$ sui move test

If you execute this command for the package created in Write a Package, you see the following output. Unsurprisingly, the test result has an OK status because there are no tests written yet to fail.

BUILDING Sui
BUILDING MoveStdlib
BUILDING my_first_package
Running Move unit tests
Test result: OK. Total tests: 0; passed: 0; failed: 0

To actually test your code, you need to add test functions. Start with adding a basic test function to the example.move file, inside the module definition:

examples/move/first_package/sources/example.move
#[test]
fun test_sword_create() {
    // Create a dummy TxContext for testing
    let mut ctx = tx_context::dummy();

    // Create a sword
    let sword = Sword {
        id: object::new(&mut ctx),
        magic: 42,
        strength: 7,
    };

    // Check if accessor functions return correct values
    assert!(sword.magic() == 42 && sword.strength() == 7, 1);

}

As the code shows, the unit test function (test_sword_create()) creates a dummy instance of the TxContext struct and assigns it to ctx. The function then creates a sword object using ctx to create a unique identifier and assigns 42 to the magic parameter and 7 to strength. Finally, the test calls the magic and strength accessor functions to verify that they return correct values.

The function passes the dummy context, ctx, to the object::new function as a mutable reference argument (&mut), but passes sword to its accessor functions as a read-only reference argument, &sword.

Now that you have a test function, run the test command again:

$ sui move test

After running the test command, however, you get a compilation error instead of a test result:

error[E06001]: unused value without 'drop'
   ┌─ ./sources/example.move:59:65
   │
 9 │       public struct Sword has key, store {
   │                     ----- To satisfy the constraint, the 'drop' ability would need to be added here
   ·
52 │           let sword = Sword {
   │               ----- The local variable 'sword' still contains a value. The value does not have the 'drop' ability and must be consumed before the function returns
   │ ╭─────────────────────'
53 │ │             id: object::new(&mut ctx),
54 │ │             magic: 42,
55 │ │             strength: 7,
56 │ │         };
   │ ╰─────────' The type 'my_first_package::example::Sword' does not have the ability 'drop'
   · │
59 │           assert!(sword.magic() == 42 && sword.strength() == 7, 1);
   │                                                                   ^ Invalid return


The error message contains all the necessary information to debug the code. The faulty code is meant to highlight one of the Move language's safety features.

The Sword struct represents a game asset that digitally mimics a real-world item. Obviously, a real sword cannot simply disappear (though it can be explicitly destroyed), but there is no such restriction on a digital one. In fact, this is exactly what's happening in the test function - you create an instance of a Sword struct that simply disappears at the end of the function call. If you saw something disappear before your eyes, you'd be dumbfounded, too.

One of the solutions (as suggested in the error message), is to add the drop ability to the definition of the Sword struct, which would allow instances of this struct to disappear (be dropped). The ability to drop a valuable asset is not a desirable asset property in this case, so another solution is needed. Another way to solve this problem is to transfer ownership of the sword.

To get the test to work, we will need to use the transfer module, which is imported by default. Add the following lines to the end of the test function (after the assert! call) to transfer ownership of the sword to a freshly created dummy address:

examples/move/first_package/sources/example.move
let dummy_address = @0xCAFE;
transfer::public_transfer(sword, dummy_address);

Run the test command again. Now the output shows a single successful test has run:

BUILDING MoveStdlib
BUILDING Sui
BUILDING my_first_package
Running Move unit tests
[ PASS    ] 0x0::example::test_sword_create
Test result: OK. Total tests: 1; passed: 1; failed: 0

tip
Use a filter string to run only a matching subset of the unit tests. With a filter string provided, the sui move test checks the fully qualified (<address>::<module_name>::<fn_name>) name for a match.

Example:

$ sui move test sword

The previous command runs all tests whose name contains sword.

You can discover more testing options through:

$ sui move test -h

Sui-specific testing
The previous testing example uses Move but isn't specific to Sui beyond using some Sui packages, such as sui::tx_context and sui::transfer. While this style of testing is already useful for writing Move code for Sui, you might also want to test additional Sui-specific features. In particular, a Move call in Sui is encapsulated in a Sui transaction, and you might want to test interactions between different transactions within a single test (for example, one transaction creating an object and the other one transferring it).

Sui-specific testing is supported through the test_scenario module that provides Sui-related testing functionality otherwise unavailable in pure Move and its testing framework.

The test_scenario module provides a scenario that emulates a series of Sui transactions, each with a potentially different user executing them. A test using this module typically starts the first transaction using the test_scenario::begin function. This function takes an address of the user executing the transaction as its argument and returns an instance of the Scenario struct representing a scenario.

An instance of the Scenario struct contains a per-address object pool emulating Sui object storage, with helper functions provided to manipulate objects in the pool. After the first transaction finishes, subsequent test transactions start with the test_scenario::next_tx function. This function takes an instance of the Scenario struct representing the current scenario and an address of a user as arguments.

Update your example.move file to include a function callable from Sui that implements sword creation. With this in place, you can then add a multi-transaction test that uses the test_scenario module to test these new capabilities. Put this functions after the accessors (Part 5 in comments).

examples/move/first_package/sources/example.move
public fun sword_create(magic: u64, strength: u64, ctx: &mut TxContext): Sword {
    Sword {
        id: object::new(ctx),
        magic: magic,
        strength: strength,
    }
}

The code of the new functions uses struct creation and Sui-internal modules (tx_context) in a way similar to what you have seen in the previous sections. The important part is for the function to have correct signatures.

With the new function included, add another test function to make sure it behaves as expected.

examples/move/first_package/sources/example.move
#[test]
fun test_sword_transactions() {
    use sui::test_scenario;

    // Create test addresses representing users
    let initial_owner = @0xCAFE;
    let final_owner = @0xFACE;

    // First transaction executed by initial owner to create the sword
    let mut scenario = test_scenario::begin(initial_owner);
    {
        // Create the sword and transfer it to the initial owner
        let sword = sword_create(42, 7, scenario.ctx());
        transfer::public_transfer(sword, initial_owner);
    };

    // Second transaction executed by the initial sword owner
    scenario.next_tx(initial_owner);
    {
        // Extract the sword owned by the initial owner
        let sword = scenario.take_from_sender<Sword>();
        // Transfer the sword to the final owner
        transfer::public_transfer(sword, final_owner);
    };

    // Third transaction executed by the final sword owner
    scenario.next_tx(final_owner);
    {
        // Extract the sword owned by the final owner
        let sword = scenario.take_from_sender<Sword>();
        // Verify that the sword has expected properties
        assert!(sword.magic() == 42 && sword.strength() == 7, 1);
        // Return the sword to the object pool (it cannot be simply "dropped")
        scenario.return_to_sender(sword)
    };
    scenario.end();
}

There are some details of the new testing function to pay attention to. The first thing the code does is create some addresses that represent users participating in the testing scenario. The test then creates a scenario by starting the first transaction on behalf of the initial sword owner.

The initial owner then executes the second transaction (passed as an argument to the test_scenario::next_tx function), who then transfers the sword they now own to the final owner. In pure Move there is no notion of Sui storage; consequently, there is no easy way for the emulated Sui transaction to retrieve it from storage. This is where the test_scenario module helps - its take_from_sender function allows an address-owned object of a given type (Sword) executing the current transaction to be available for Move code manipulation. For now, assume that there is only one such object. In this case, the test transfers the object it retrieves from storage to another address.

tip
Transaction effects, such as object creation and transfer become visible only after a given transaction completes. For example, if the second transaction in the running example created a sword and transferred it to the administrator's address, it would only become available for retrieval from the administrator's address (via test_scenario, take_from_sender, or take_from_address functions) in the third transaction.

The final owner executes the third and final transaction that retrieves the sword object from storage and checks if it has the expected properties. Remember, as described in Testing a package, in the pure Move testing scenario, after an object is available in Move code (after creation or retrieval from emulated storage), it cannot simply disappear.

In the pure Move testing function, the function transfers the sword object to the fake address to handle the disappearing problem. The test_scenario package provides a more elegant solution, however, which is closer to what happens when Move code actually executes in the context of Sui - the package simply returns the sword to the object pool using the test_scenario::return_to_sender function. For scenarios where returning to the sender is not desirable or if you would like to simply destroy the object, the test_utils module also provides the generic destroy<T> function, that can be used on any type T regardless of its ability. It is advisable to check out other useful functions in the test_scenario and test_utils modules as well.

Run the test command again to see two successful tests for our module:

BUILDING Sui
BUILDING MoveStdlib
BUILDING my_first_package
Running Move unit tests
[ PASS    ] 0x0::example::test_sword_create
[ PASS    ] 0x0::example::test_sword_transactions
Test result: OK. Total tests: 2; passed: 2; failed: 0

Module initializers
Each module in a package can include a special initializer function that runs at publication time. The goal of an initializer function is to pre-initialize module-specific data (for example, to create singleton objects). The initializer function must have the following properties for it to execute at publication:

Function name must be init.
The parameter list must end with either a &mut TxContext or a &TxContext type.
No return values.
Private visibility.
Optionally, the parameter list starts by accepting the module's one-time witness by value. See One Time Witness in The Move Book for more information.
For example, the following init functions are all valid:

fun init(ctx: &TxContext)
fun init(ctx: &mut TxContext)
fun init(otw: EXAMPLE, ctx: &TxContext)
fun init(otw: EXAMPLE, ctx: &mut TxContext)
While the sui move command does not support publishing explicitly, you can still test module initializers using the testing framework by dedicating the first transaction to executing the initializer function.

The init function for the module in the running example creates a Forge object.

examples/move/first_package/sources/example.move
fun init(ctx: &mut TxContext) {
    let admin = Forge {
        id: object::new(ctx),
        swords_created: 0,
    };

    transfer::transfer(admin, ctx.sender());
}

The tests you have so far call the init function, but the initializer function itself isn't tested to ensure it properly creates a Forge object. To test this functionality, add a new_sword function to take the forge as a parameter and to update the number of created swords at the end of the function. If this were an actual module, you'd replace the sword_create function with new_sword. To keep the existing tests from failing, however, we will keep both functions.

examples/move/first_package/sources/example.move
public fun new_sword(forge: &mut Forge, magic: u64, strength: u64, ctx: &mut TxContext): Sword {
    forge.swords_created = forge.swords_created + 1;
    Sword {
        id: object::new(ctx),
        magic: magic,
        strength: strength,
    }
}


Now, create a function to test the module initialization:

examples/move/first_package/sources/example.move
#[test]
fun test_module_init() {
    use sui::test_scenario;

    // Create test addresses representing users
    let admin = @0xAD;
    let initial_owner = @0xCAFE;

    // First transaction to emulate module initialization
    let mut scenario = test_scenario::begin(admin);
    {
        init(scenario.ctx());
    };

    // Second transaction to check if the forge has been created
    // and has initial value of zero swords created
    scenario.next_tx(admin);
    {
        // Extract the Forge object
        let forge = scenario.take_from_sender<Forge>();
        // Verify number of created swords
        assert!(forge.swords_created() == 0, 1);
        // Return the Forge object to the object pool
        scenario.return_to_sender(forge);
    };

    // Third transaction executed by admin to create the sword
    scenario.next_tx(admin);
    {
        let mut forge = scenario.take_from_sender<Forge>();
        // Create the sword and transfer it to the initial owner
        let sword = forge.new_sword(42, 7, scenario.ctx());
        transfer::public_transfer(sword, initial_owner);
        scenario.return_to_sender(forge);
    };
    scenario.end();
}

As the new test function shows, the first transaction (explicitly) calls the initializer. The next transaction checks if the Forge object has been created and properly initialized. Finally, the admin uses the Forge to create a sword and transfer it to the initial owner.

You can refer to the source code for the package (with all the tests and functions properly adjusted) in the first_package module in the sui/examples directory. You can also use the following toggle to review the complete code.

Click to close
example.move

examples/move/first_package/sources/example.move
module my_first_package::example;

// Part 1: These imports are provided by default
// use sui::object::{Self, UID};
// use sui::transfer;
// use sui::tx_context::{Self, TxContext};

// Part 2: struct definitions
public struct Sword has key, store {
		id: UID,
		magic: u64,
		strength: u64,
}

public struct Forge has key {
		id: UID,
		swords_created: u64,
}

// Part 3: Module initializer to be executed when this module is published
fun init(ctx: &mut TxContext) {
		let admin = Forge {
				id: object::new(ctx),
				swords_created: 0,
		};

		// Transfer the forge object to the module/package publisher
		transfer::transfer(admin, ctx.sender());
}

// Part 4: Accessors required to read the struct fields
public fun magic(self: &Sword): u64 {
		self.magic
}

public fun strength(self: &Sword): u64 {
		self.strength
}

public fun swords_created(self: &Forge): u64 {
		self.swords_created
}

// Part 5: Public/entry functions (introduced later in the tutorial)
public fun sword_create(magic: u64, strength: u64, ctx: &mut TxContext): Sword {
		// Create a sword
		Sword {
				id: object::new(ctx),
				magic: magic,
				strength: strength,
		}
}

/// Constructor for creating swords
public fun new_sword(forge: &mut Forge, magic: u64, strength: u64, ctx: &mut TxContext): Sword {
		forge.swords_created = forge.swords_created + 1;
		Sword {
				id: object::new(ctx),
				magic: magic,
				strength: strength,
		}
}
// Part 6: Tests
#[test]
fun test_sword_create() {
		// Create a dummy TxContext for testing
		let mut ctx = tx_context::dummy();

		// Create a sword
		let sword = Sword {
				id: object::new(&mut ctx),
				magic: 42,
				strength: 7,
		};

		// Check if accessor functions return correct values
		assert!(sword.magic() == 42 && sword.strength() == 7, 1);
		// Create a dummy address and transfer the sword
		let dummy_address = @0xCAFE;
		transfer::public_transfer(sword, dummy_address);
}

#[test]
fun test_sword_transactions() {
		use sui::test_scenario;

		// Create test addresses representing users
		let initial_owner = @0xCAFE;
		let final_owner = @0xFACE;

		// First transaction executed by initial owner to create the sword
		let mut scenario = test_scenario::begin(initial_owner);
		{
				// Create the sword and transfer it to the initial owner
				let sword = sword_create(42, 7, scenario.ctx());
				transfer::public_transfer(sword, initial_owner);
		};

		// Second transaction executed by the initial sword owner
		scenario.next_tx(initial_owner);
		{
				// Extract the sword owned by the initial owner
				let sword = scenario.take_from_sender<Sword>();
				// Transfer the sword to the final owner
				transfer::public_transfer(sword, final_owner);
		};

		// Third transaction executed by the final sword owner
		scenario.next_tx(final_owner);
		{
				// Extract the sword owned by the final owner
				let sword = scenario.take_from_sender<Sword>();
				// Verify that the sword has expected properties
				assert!(sword.magic() == 42 && sword.strength() == 7, 1);
				// Return the sword to the object pool (it cannot be simply "dropped")
				scenario.return_to_sender(sword)
		};
		scenario.end();
}

#[test]
fun test_module_init() {
		use sui::test_scenario;

		// Create test addresses representing users
		let admin = @0xAD;
		let initial_owner = @0xCAFE;

		// First transaction to emulate module initialization
		let mut scenario = test_scenario::begin(admin);
		{
				init(scenario.ctx());
		};

		// Second transaction to check if the forge has been created
		// and has initial value of zero swords created
		scenario.next_tx(admin);
		{
				// Extract the Forge object
				let forge = scenario.take_from_sender<Forge>();
				// Verify number of created swords
				assert!(forge.swords_created() == 0, 1);
				// Return the Forge object to the object pool
				scenario.return_to_sender(forge);
		};

		// Third transaction executed by admin to create the sword
		scenario.next_tx(admin);
		{
				let mut forge = scenario.take_from_sender<Forge>();
				// Create the sword and transfer it to the initial owner
				let sword = forge.new_sword(42, 7, scenario.ctx());
				transfer::public_transfer(sword, initial_owner);
				scenario.return_to_sender(forge);
		};
		scenario.end();
}

Publish a Package
Before you can call functions in a Move package (beyond an emulated Sui execution scenario), that package must be available on the Sui network. When you publish a package, you are actually creating an immutable Sui object on the network that anyone can access.

To publish your package to the Sui network, use the publish CLI command in the root of your package. Use the --gas-budget flag to set a value for the maximum amount of gas the transaction can cost. If the cost of the transaction is more than the budget you set, the transaction fails and your package doesn't publish.

tip
Beginning with the Sui v1.24.1 release, the --gas-budget option is no longer required for CLI commands.

$ sui client publish --gas-budget 5000000

If the publish transaction is successful, your terminal or console responds with the details of the publish transaction separated into sections, including transaction data, transaction effects, transaction block events, object changes, and balance changes.

In the Object Changes table, you can find the information about the package you just published in the Published Objects section. Your response has the actual PackageID that identifies the package (instead of <PACKAGE-ID>) in the form 0x123...ABC.

╭─────────────────────────────────────────────────────────────────────╮
│ Object Changes                                                      │
├─────────────────────────────────────────────────────────────────────┤
│ Created Objects:                                                    │
│  ...                                                                │
|                                                                     |
│ Mutated Objects:                                                    │
│  ...                                                                │
|                                                                     |
│ Published Objects:                                                  │
│  ┌──                                                                │
│  │ PackageID: <PACKAGE-ID>                                          │
│  │ Version: 1                                                       │
│  │ Digest: <DIGEST-HASH>                                            │
│  │ Modules: my_module                                               │
│  └──                                                                │
╰─────────────────────────────────────────────────────────────────────╯

Your currently active address now has three objects (or more, if you had objects prior to this example). Assuming you are using a new address, running the sui objects command reveals what those objects are.

$ sui client objects

╭───────────────────────────────────────────────────────────────────────────────────────╮
│ ╭────────────┬──────────────────────────────────────────────────────────────────────╮ │
│ │ objectId   │  <OBJECT-ID>                                                         │ │
│ │ version    │  10                                                                  │ │
│ │ digest     │  <DIGEST-HASH>                                                       │ │
│ │ objectType │  <PACKAGE-ID>::my_module::Forge                                      │ │
│ ╰────────────┴──────────────────────────────────────────────────────────────────────╯ │
│ ╭────────────┬──────────────────────────────────────────────────────────────────────╮ │
│ │ objectId   │  <OBJECT-ID>                                                         │ │
│ │ version    │  10                                                                  │ │
│ │ digest     │  <DIGEST-HASH>                                                       │ │
│ │ objectType │  0x0000..0002::coin::Coin                                            │ │
│ ╰────────────┴──────────────────────────────────────────────────────────────────────╯ │
│ ╭────────────┬──────────────────────────────────────────────────────────────────────╮ │
│ │ objectId   │  <OBJECT-ID>                                                         │ │
│ │ version    │  10                                                                  │ │
│ │ digest     │  <DIGEST-HASH>                                                       │ │
│ │ objectType │  0x0000..0002::package::UpgradeCap                                   │ │
│ ╰────────────┴──────────────────────────────────────────────────────────────────────╯ │
╰───────────────────────────────────────────────────────────────────────────────────────╯


The objectId field is the unique identifier of each object.

Coin object: You received the Coin object from the Testnet faucet. It's value is slightly less than when you received it because of the cost of gas for the publish transaction.
Forge object: Recall that the init function runs when the package gets published. The init function for this example package creates a Forge object and transfers it to the publisher (you).
UpgradeCap object: Each package you publish results in the receipt of an UpgradeCap object. You use this object to upgrade the package later or to burn it so the package cannot be upgraded.
Sui Blockchain
Forge
address
UpgradeCap
Coin
Interact with the package
Now that the package is on chain, you can call its functions to interact with the package. You can use the sui client call command to make individual calls to package functions, or you can construct more advanced blocks of transactions using the sui client ptb command. The ptb part of the command stands for programmable transaction blocks. In basic terms, PTBs allow you to group commands together in a single transaction for more efficient and cost-effective network activity.

Sui Blockchain
Sword
PTB
my_module::new_sword(&Forge, strength, magic)
address
Sui client
For example, you can create a new Sword object defined in the package by calling the new_sword function in the my_module package, and then transfer the Sword object to any address:

$ sui client ptb \
	--assign forge @<FORGE-ID> \
	--assign to_address @<TO-ADDRESS> \
	--move-call <PACKAGE-ID>::my_module::new_sword forge 3 3 \
	--assign sword \
	--transfer-objects "[sword]" to_address \
	--gas-budget 20000000

info
You can pass literal addresses and objects IDs by prefixing them with '@'. This is needed to distinguish a hexadecimal value from an address in some situations.

For addresses that are in your local wallet, you can use their alias instead (passing them without '@', for example, --transfer-objects my_alias).

Depending on your shell and operating system, you might need to pass some values with quotes ("), for example: --assign "forge @<FORGE-ID>".

Make sure to replace <FORGE-ID>, <TO-ADDRESS>, and <PACKAGE-ID> with the actual objectId of the Forge object, the address of the recipient (your address in this case), and the packageID of the package, respectively.

After the transaction executes, you can check the status of the Sword object by using the sui client objects command again. Provided you used your address as the <TO-ADDRESS>, you should now see a total of four objects:

╭───────────────────────────────────────────────────────────────────────────────────────╮
│ ╭────────────┬──────────────────────────────────────────────────────────────────────╮ │
│ │ objectId   │  <OBJECT-ID>                                                         │ │
│ │ version    │  11                                                                  │ │
│ │ digest     │  <DIGEST-HASH>                                                       │ │
│ │ objectType │  <PACKAGE-ID>::my_module::Forge                                      │ │
│ ╰────────────┴──────────────────────────────────────────────────────────────────────╯ │
│ ╭────────────┬──────────────────────────────────────────────────────────────────────╮ │
│ │ objectId   │  <OBJECT-ID>                                                         │ │
│ │ version    │  11                                                                  │ │
│ │ digest     │  <DIGEST-HASH>                                                       │ │
│ │ objectType │  0x0000..0002::coin::Coin                                            │ │
│ ╰────────────┴──────────────────────────────────────────────────────────────────────╯ │
│ ╭────────────┬──────────────────────────────────────────────────────────────────────╮ │
│ │ objectId   │  <OBJECT-ID>                                                         │ │
│ │ version    │  11                                                                  │ │
│ │ digest     │  <DIGEST-HASH>                                                       │ │
│ │ objectType │  <PACKAGE-ID>::my_module::Sword                                      │ │
│ ╰────────────┴──────────────────────────────────────────────────────────────────────╯ │
│ ╭────────────┬──────────────────────────────────────────────────────────────────────╮ │
│ │ objectId   │  <OBJECT-ID>                                                         │ │
│ │ version    │  10                                                                  │ │
│ │ digest     │  <DIGEST-HASH>                                                       │ │
│ │ objectType │  0x0000..0002::package::UpgradeCap                                   │ │
│ ╰────────────┴──────────────────────────────────────────────────────────────────────╯ │
╰───────────────────────────────────────────────────────────────────────────────────────╯


Congratulations! You have successfully published a package to the Sui network and modified the blockchain state by using a programmable transaction block.

Client App with Sui TypeScript SDK
This exercise diverges from the example built in the previous topics in this section. Rather than adding a frontend to the running example, the instruction walks you through setting up dApp Kit in a React App, allowing you to connect to wallets, and query data from Sui RPC nodes to display in your app. You can use it to create your own frontend for the example used previously, but if you want to get a fully functional app up and running quickly, run the following command in a terminal or console to scaffold a new app with all steps in this exercise already implemented:

info
You must use the pnpm or yarn package managers to create Sui project scaffolds. Follow the pnpm install or yarn install instructions, if needed.

$ pnpm create @mysten/dapp --template react-client-dapp

or

$ yarn create @mysten/dapp --template react-client-dapp

What is the Sui TypeScript SDK?
The Sui TypeScript SDK (@mysten/sui) provides all the low-level functionality needed to interact with Sui ecosystem from TypeScript. You can use it in any TypeScript or JavaScript project, including web apps, Node.js apps, or mobile apps written with tools like React Native that support TypeScript.

For more information on the Sui TypeScript SDK, see the Sui TypeScript SDK documentation.

What is dApp Kit?
dApp Kit (@mysten/dapp-kit) is a collection of React hooks, components, and utilities that make building dApps on Sui straightforward. For more information on dApp Kit, see the dApp Kit documentation.

Installing dependencies
To get started, you need a React app. The following steps apply to any React, so you can follow the same steps to add dApp Kit to an existing React app. If you are starting a new project, you can use Vite to scaffold a new React app.

Run the following command in your terminal or console, and select React as the framework, and then select one of the TypeScript templates:

npm
Yarn
pnpm
$ npm init vite

Now that you have a React app, you can install the necessary dependencies to use dApp Kit:

npm
Yarn
pnpm
$ npm install @mysten/sui @mysten/dapp-kit @tanstack/react-query

Setting up Provider components
To use all the features of dApp Kit, wrap your app with a couple of Provider components.

Open the root component that renders your app (the default location the Vite template uses is src/main.tsx) and integrate or replace the current code with the following.

The first Provider to set up is the QueryClientProvider from @tanstack/react-query. This Provider manages request state for various hooks in dApp kit. If you're already using @tanstack/react-query, dApp Kit can share the same QueryClient instance.

import { QueryClient, QueryClientProvider } from '@tanstack/react-query';

const queryClient = new QueryClient();

ReactDOM.createRoot(document.getElementById('root')!).render(
	<React.StrictMode>
		<QueryClientProvider client={queryClient}>
			<App />
		</QueryClientProvider>
	</React.StrictMode>,
);

Next, set up the SuiClientProvider. This Provider delivers a SuiClient instance from @mysten/sui to all the hooks in dApp Kit. This provider manages which network dApp Kit connects to, and can accept configuration for multiple networks. This exercise connects to devnet.

import { SuiClientProvider } from '@mysten/dapp-kit';
import { getFullnodeUrl } from '@mysten/sui/client';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';

const queryClient = new QueryClient();
const networks = {
	devnet: { url: getFullnodeUrl('devnet') },
	mainnet: { url: getFullnodeUrl('mainnet') },
};

ReactDOM.createRoot(document.getElementById('root')!).render(
	<React.StrictMode>
		<QueryClientProvider client={queryClient}>
			<SuiClientProvider networks={networks} defaultNetwork="devnet">
				<App />
			</SuiClientProvider>
		</QueryClientProvider>
	</React.StrictMode>,
);

Finally, set up the WalletProvider from @mysten/dapp-kit, and import styles for the dapp-kit components.

import '@mysten/dapp-kit/dist/index.css';

import { SuiClientProvider, WalletProvider } from '@mysten/dapp-kit';
import { getFullnodeUrl } from '@mysten/sui/client';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';

const queryClient = new QueryClient();
const networks = {
	devnet: { url: getFullnodeUrl('devnet') },
	mainnet: { url: getFullnodeUrl('mainnet') },
};

ReactDOM.createRoot(document.getElementById('root')!).render(
	<React.StrictMode>
		<QueryClientProvider client={queryClient}>
			<SuiClientProvider networks={networks} defaultNetwork="devnet">
				<WalletProvider>
					<App />
				</WalletProvider>
			</SuiClientProvider>
		</QueryClientProvider>
	</React.StrictMode>,
);

Connecting to a wallet
With all Providers set up, you can use dApp Kit hooks and components. To allow users to connect their wallets to your dApp, add a ConnectButton.

import { ConnectButton } from '@mysten/dapp-kit';

function App() {
	return (
		<div className="App">
			<header className="App-header">
				<ConnectButton />
			</header>
		</div>
	);
}

The ConnectButton component displays a button that opens a modal on click, enabling the user to connect their wallet. Upon connection, it displays their address, and provides the option to disconnect.

Getting the connected wallet address
Now that you have a way for users to connect their wallets, you can start using the useCurrentAccount hook to get details about the connected wallet account.

import { ConnectButton, useCurrentAccount } from '@mysten/dapp-kit';

function App() {
	return (
		<div className="App">
			<header className="App-header">
				<ConnectButton />
			</header>

			<ConnectedAccount />
		</div>
	);
}

function ConnectedAccount() {
	const account = useCurrentAccount();

	if (!account) {
		return null;
	}

	return <div>Connected to {account.address}</div>;
}

Querying data from Sui RPC nodes
Now that you have the account to connect to, you can query for objects the connected account owns:

import { useCurrentAccount, useSuiClientQuery } from '@mysten/dapp-kit';

function ConnectedAccount() {
	const account = useCurrentAccount();

	if (!account) {
		return null;
	}

	return (
		<div>
			<div>Connected to {account.address}</div>;
			<OwnedObjects address={account.address} />
		</div>
	);
}

function OwnedObjects({ address }: { address: string }) {
	const { data } = useSuiClientQuery('getOwnedObjects', {
		owner: address,
	});
	if (!data) {
		return null;
	}

	return (
		<ul>
			{data.data.map((object) => (
				<li key={object.data?.objectId}>
					<a href={`https://example-explorer.com/object/${object.data?.objectId}`}>
						{object.data?.objectId}
					</a>
				</li>
			))}
		</ul>
	);
}

You now have a dApp connected to wallets and can query data from RPC nodes.


Building Programmable Transaction Blocks
This guide explores creating a programmable transaction block (PTB) on Sui using the TypeScript SDK. For an overview of what a PTB is, see Programmable Transaction Blocks in the Concepts section. If you don't already have the Sui TypeScript SDK, follow the install instructions on the Sui TypeScript SDK site.

This example starts by constructing a PTB to send Sui. If you are familiar with the legacy Sui transaction types, this is similar to a paySui transaction. To construct transactions, import the Transaction class, and construct it:

import { Transaction } from '@mysten/sui/transactions';

const tx = new Transaction();

Using this, you can then add transactions to this PTB.

// Create a new coin with balance 100, based on the coins used as gas payment.
// You can define any balance here.
const [coin] = tx.splitCoins(tx.gas, [tx.pure('u64', 100)]);

// Transfer the split coin to a specific address.
tx.transferObjects([coin], tx.pure('address', '0xSomeSuiAddress'));

You can attach multiple transaction commands of the same type to a PTB as well. For example, to get a list of transfers, and iterate over them to transfer coins to each of them:

interface Transfer {
	to: string;
	amount: number;
}

// Procure a list of some Sui transfers to make:
const transfers: Transfer[] = getTransfers();

const tx = new Transaction();

// First, split the gas coin into multiple coins:
const coins = tx.splitCoins(
	tx.gas,
	transfers.map((transfer) => tx.pure('u64', transfer.amount)),
);

// Next, create a transfer transaction for each coin:
transfers.forEach((transfer, index) => {
	tx.transferObjects([coins[index]], tx.pure('address', transfer.to));
});

After you have the Transaction defined, you can directly execute it with a SuiClient and KeyPair using client.signAndExecuteTransaction.

client.signAndExecuteTransaction({ signer: keypair, transaction: tx });

Constructing inputs
Inputs are how you provide external values to PTBs. For example, defining an amount of Sui to transfer, or which object to pass into a Move call, or a shared object.

There are currently two ways to define inputs:

For objects: the tx.object(objectId) function is used to construct an input that contains an object reference.
For pure values: the tx.pure(type, value) function is used to construct an input for a non-object input.
If value is a Uint8Array, then the value is assumed to be raw bytes and is used directly: tx.pure(SomeUint8Array).
Otherwise, it's used to generate the BCS serialization layout for the value.
In the new version, a more intuitive way of writing is provided, for example: tx.pure.u64(100), tx.pure.string('SomeString'), tx.pure.address('0xSomeSuiAddress'), tx.pure.vector('bool', [true, false])...
Available transactions
Sui supports following transaction commands:

tx.splitCoins(coin, amounts): Creates new coins with the defined amounts, split from the provided coin. Returns the coins so that it can be used in subsequent transactions.
Example: tx.splitCoins(tx.gas, [tx.pure.u64(100), tx.pure.u64(200)])
tx.mergeCoins(destinationCoin, sourceCoins): Merges the sourceCoins into the destinationCoin.
Example: tx.mergeCoins(tx.object(coin1), [tx.object(coin2), tx.object(coin3)])
tx.transferObjects(objects, address): Transfers a list of objects to the specified address.
Example: tx.transferObjects([tx.object(thing1), tx.object(thing2)], tx.pure.address(myAddress))
tx.moveCall({ target, arguments, typeArguments }): Executes a Move call. Returns whatever the Sui Move call returns.
Example: tx.moveCall({ target: '0x2::devnet_nft::mint', arguments: [tx.pure.string(name), tx.pure.string(description), tx.pure.string(image)] })
tx.makeMoveVec({ type, elements }): Constructs a vector of objects that can be passed into a moveCall. This is required as there's no other way to define a vector as an input.
Example: tx.makeMoveVec({ elements: [tx.object(id1), tx.object(id2)] })
tx.publish(modules, dependencies): Publishes a Move package. Returns the upgrade capability object.
Passing transaction results as arguments
You can use the result of a transaction command as an argument in subsequent transaction commands. Each transaction command method on the transaction builder returns a reference to the transaction result.

// Split a coin object off of the gas object:
const [coin] = tx.splitCoins(tx.gas, [tx.pure.u64(100)]);
// Transfer the resulting coin object:
tx.transferObjects([coin], tx.pure.address(address));

When a transaction command returns multiple results, you can access the result at a specific index either using destructuring, or array indexes.

// Destructuring (preferred, as it gives you logical local names):
const [nft1, nft2] = tx.moveCall({ target: '0x2::nft::mint_many' });
tx.transferObjects([nft1, nft2], tx.pure.address(address));

// Array indexes:
const mintMany = tx.moveCall({ target: '0x2::nft::mint_many' });
tx.transferObjects([mintMany[0], mintMany[1]], tx.pure.address(address));

Use the gas coin
With PTBs, you can use the gas payment coin to construct coins with a set balance using splitCoin. This is useful for Sui payments, and avoids the need for up-front coin selection. You can use tx.gas to access the gas coin in a PTB, and it is valid as input for any arguments; with the exception of transferObjects, tx.gas must be used by-reference. Practically speaking, this means you can also add to the gas coin with mergeCoins or borrow it for Move functions with moveCall.

You can also transfer the gas coin using transferObjects, in the event that you want to transfer all of your coin balance to another address.

Of course, you can also transfer other coins in your wallet using their Object ID. For example,

const otherCoin = tx.object('0xCoinObjectId');
const coin = tx.splitCoins(otherCoin, [tx.pure.u64(100)]);
tx.transferObjects([coin], tx.pure.address(address));

Get PTB bytes
If you need the PTB bytes, instead of signing or executing the PTB, you can use the build method on the transaction builder itself.

tip
You might need to explicitly call setSender() on the PTB to ensure that the sender field is populated. This is normally done by the signer before signing the transaction, but will not be done automatically if you're building the PTB bytes yourself.

const tx = new Transaction();

// ... add some transactions...

await tx.build({ provider });

In most cases, building requires your JSON RPC provider to fully resolve input values.

If you have PTB bytes, you can also convert them back into a Transaction class:

const bytes = getTransactionBytesFromSomewhere();
const tx = Transaction.from(bytes);

Building offline
In the event that you want to build a PTB offline (as in with no provider required), you need to fully define all of your input values, and gas configuration (see the following example). For pure values, you can provide a Uint8Array which is used directly in the transaction. For objects, you can use the Inputs helper to construct an object reference.

import { Inputs } from '@mysten/sui/transactions';

// For pure values:
tx.pure(pureValueAsBytes);

// For owned or immutable objects:
tx.object(Inputs.ObjectRef({ digest, objectId, version }));

// For shared objects:
tx.object(Inputs.SharedObjectRef({ objectId, initialSharedVersion, mutable }));

You can then omit the provider object when calling build on the transaction. If there is any required data that is missing, this will throw an error.

Gas configuration
The new transaction builder comes with default behavior for all gas logic, including automatically setting the gas price, budget, and selecting coins to be used as gas. This behavior can be customized.

Gas price
By default, the gas price is set to the reference gas price of the network. You can also explicitly set the gas price of the PTB by calling setGasPrice on the transaction builder.

tx.setGasPrice(gasPrice);

Budget
By default, the gas budget is automatically derived by executing a dry-run of the PTB beforehand. The dry run gas consumption is then used to determine a balance for the transaction. You can override this behavior by explicitly setting a gas budget for the transaction, by calling setGasBudget on the transaction builder.

info
The gas budget is represented in Sui, and should take the gas price of the PTB into account.

tx.setGasBudget(gasBudgetAmount);

Gas payment
By default, the gas payment is automatically determined by the SDK. The SDK selects all coins at the provided address that are not used as inputs in the PTB.

The list of coins used as gas payment will be merged down into a single gas coin before executing the PTB, and all but one of the gas objects will be deleted. The gas coin at the 0-index will be the coin that all others are merged into.

// NOTE: You need to ensure that the coins do not overlap with any
// of the input objects for the PTB.
tx.setGasPayment([coin1, coin2]);

Gas coins should be objects containing the coins objectId, version, and digest (ie { objectId: string, version: string | number, digest: string }).

dApp / Wallet integration
The Wallet Standard interface has been updated to support the Transaction kind directly. All signTransaction and signAndExecuteTransaction calls from dApps into wallets is expected to provide a Transaction class. This PTB class can then be serialized and sent to your wallet for execution.

To serialize a PTB for sending to a wallet, Sui recommends using the tx.serialize() function, which returns an opaque string representation of the PTB that can be passed from the wallet standard dApp context to your wallet. This can then be converted back into a Transaction using Transaction.from().

tip
You should not build the PTB from bytes in the dApp code. Using serialize instead of build allows you to build the PTB bytes within the wallet itself. This allows the wallet to perform gas logic and coin selection as needed.

// Within a dApp
const tx = new Transaction();
wallet.signTransaction({ transaction: tx });

// Your wallet standard code:
function handleSignTransaction(input) {
	sendToWalletContext({ transaction: input.transaction.serialize() });
}

// Within your wallet context:
function handleSignRequest(input) {
	const userTx = Transaction.from(input.transaction);
}

Sponsored PTBs
The PTB builder can support sponsored PTBs by using the onlyTransactionKind flag when building the PTB.

const tx = new Transaction();
// ... add some transactions...

const kindBytes = await tx.build({ provider, onlyTransactionKind: true });

// Construct a sponsored transaction from the kind bytes:
const sponsoredTx = Transaction.fromKind(kindBytes);

// You can now set the sponsored transaction data that is required:
sponsoredTx.setSender(sender);
sponsoredTx.setGasOwner(sponsor);
sponsoredTx.setGasPayment(sponsorCoins);

Using Events
The Sui network stores countless objects on chain where Move code can perform actions using those objects. Tracking this activity is often desired, for example, to discover how many times a module mints an NFT or to tally the amount of SUI in transactions that a smart contract generates.

To support activity monitoring, Move provides a structure to emit events on the Sui network. You can then leverage a custom indexer to process checkpoint data that includes events that have been emitted. See the custom indexer topic in the Advanced section to learn how to stream checkpoints and filter events continuously.

If you don't want to run a custom indexer, you can poll the Sui network to query for emitted events instead. This approach typically includes a database to store the data retrieved from these calls. The Poll events section provides an example of using this method.

Move event structure
An event object in Sui consists of the following attributes:

id: JSON object containing the transaction digest ID and event sequence.
packageId: The object ID of the package that emits the event.
transactionModule: The module that performs the transaction.
sender: The Sui network address that triggered the event.
type: The type of event being emitted.
parsedJson: JSON object describing the event.
bcs: Binary canonical serialization value.
timestampMs: Unix epoch timestamp in milliseconds.
Emit events in Move
To create an event in your Move modules, add the sui::event dependency.

use sui::event;

With the dependency added, you can use the emit function to trigger an event whenever the action you want to monitor fires. For example, the following code is part of an example application that enables the locking of objects. The lock function handles the locking of objects and emits an event whenever the function is called.

examples/trading/contracts/escrow/sources/lock.move
public fun lock<T: key + store>(obj: T, ctx: &mut TxContext): (Locked<T>, Key) {
    let key = Key { id: object::new(ctx) };
    let mut lock = Locked {
        id: object::new(ctx),
        key: object::id(&key),
    };

    event::emit(LockCreated {
        lock_id: object::id(&lock),
        key_id: object::id(&key),
        creator: ctx.sender(),
        item_id: object::id(&obj),
    });

    dof::add(&mut lock.id, LockedObjectKey {}, obj);

    (lock, key)
}

Query events with RPC
The Sui RPC provides a queryEvents method to query on-chain packages and return available events. As an example, the following curl command queries the Deepbook package on Mainnet for a specific type of event:

$ curl -X POST https://fullnode.mainnet.sui.io:443 \
-H "Content-Type: application/json" \
-d '{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "suix_queryEvents",
  "params": [
    {
      "MoveModule": {
        "package": "0x158f2027f60c89bb91526d9bf08831d27f5a0fcb0f74e6698b9f0e1fb2be5d05",
        "module": "deepbook_utils",
        "type": "0xdee9::clob_v2::DepositAsset<0x5d4b302506645c37ff133b98c4b50a5ae14841659738d6d733d59d0d217a93bf::coin::COIN>"
      }
    },
    null,
    3,
    false
  ]
}'


Click to open
A successful curl return

The TypeScript SDK provides a wrapper for the suix_queryEvents method: client.queryEvents.

Click to open
TypeScript SDK queryEvents example

Filtering event queries
To filter the events returned from your queries, use the following data structures.

Query	Description	JSON-RPC Parameter Example
All	All events	{"All": []}
Any	Events emitted from any of the given filter	{"Any": SuiEventFilter[]}
Transaction	Events emitted from the specified transaction	{"Transaction":"DGUe2TXiJdN3FI6MH1FwghYbiHw+NKu8Nh579zdFtUk="}
MoveModule	Events emitted from the specified Move module	{"MoveModule":{"package":"<PACKAGE-ID>", "module":"nft"}}
MoveEventModule	Events emitted, defined on the specified Move module.	{"MoveEventModule": {"package": "<DEFINING-PACKAGE-ID>", "module": "nft"}}
MoveEventType	Move struct name of the event	{"MoveEventType":"::nft::MintNFTEvent"}
Sender	Query by sender address	{"Sender":"0x008e9c621f4fdb210b873aab59a1e5bf32ddb1d33ee85eb069b348c234465106"}
TimeRange	Return events emitted in [start_time, end_time] interval	{"TimeRange":{"startTime":1669039504014, "endTime":1669039604014}}
Query events in Rust
The Sui by Example repo on GitHub contains a code sample that demonstrates how to query events using the query_events function. The package that PACKAGE_ID_CONST points to exists on Mainnet, so you can test this code using Cargo. To do so, clone the sui-by-example repo locally and follow the Example 05 directions.

use sui_sdk::{rpc_types::EventFilter, types::Identifier, SuiClientBuilder};

const PACKAGE_ID_CONST: &str = "0x279525274aa623ef31a25ad90e3b99f27c8dbbad636a6454918855c81d625abc";

#[tokio::main]
async fn main() -> Result<(), anyhow::Error> {
    let sui_mainnet = SuiClientBuilder::default()
        .build("https://fullnode.mainnet.sui.io:443")
        .await?;

    let events = sui_mainnet
        .event_api()
        .query_events(
            EventFilter::MoveModule {
                package: PACKAGE_ID_CONST.parse()?,
                module: Identifier::new("dev_trophy")?,
            },
            None,
            None,
            false,
        )
        .await?;

    for event in events.data {
        println!("Event: {:?}", event.parsed_json);
    }

    Ok(())
}


Query events with GraphQL
⚙️Early-Stage Feature
This content describes an alpha/beta feature or service. These early stage features and services are in active development, so details are likely to change.

You can use GraphQL to query events instead of JSON RPC. The following example queries are in the sui-graphql-rpc crate in the Sui repo.

Click to open
Event connection

Click to open
Filter events by sender

The TypeScript SDK provides functionality to interact with the Sui GraphQL service.

Monitoring events
Firing events is not very useful in a vacuum. You also need the ability to respond to those events. There are two methods from which to choose when you need to monitor on-chain events:

Incorporate a custom indexer to take advantage of Sui's micro-data ingestion framework.
Poll the Sui network on a schedule to query events.
Using a custom indexer provides a near-real time monitoring of events, so is most useful when your project requires immediate reaction to the firing of events. Polling the network is most useful when the events you're monitoring don't fire often or the need to act on those events are not immediate. The following section provides a polling example.

Poll events
To monitor events, you need a database to store checkpoint data. The Trustless Swap example uses a Prisma database to store checkpoint data from the Sui network. The database is populated from polling the network to retrieve emitted events.

Click to close
event-indexer.ts from Trustless Swap

examples/trading/api/indexer/event-indexer.ts
import { EventId, SuiClient, SuiEvent, SuiEventFilter } from '@mysten/sui/client';

import { CONFIG } from '../config';
import { prisma } from '../db';
import { getClient } from '../sui-utils';
import { handleEscrowObjects } from './escrow-handler';
import { handleLockObjects } from './locked-handler';

type SuiEventsCursor = EventId | null | undefined;

type EventExecutionResult = {
	cursor: SuiEventsCursor;
	hasNextPage: boolean;
};

type EventTracker = {
	type: string;
	filter: SuiEventFilter;
	callback: (events: SuiEvent[], type: string) => any;
};

const EVENTS_TO_TRACK: EventTracker[] = [
	{
		type: `${CONFIG.SWAP_CONTRACT.packageId}::lock`,
		filter: {
			MoveEventModule: {
				module: 'lock',
				package: CONFIG.SWAP_CONTRACT.packageId,
			},
		},
		callback: handleLockObjects,
	},
	{
		type: `${CONFIG.SWAP_CONTRACT.packageId}::shared`,
		filter: {
			MoveEventModule: {
				module: 'shared',
				package: CONFIG.SWAP_CONTRACT.packageId,
			},
		},
		callback: handleEscrowObjects,
	},
];

const executeEventJob = async (
	client: SuiClient,
	tracker: EventTracker,
	cursor: SuiEventsCursor,
): Promise<EventExecutionResult> => {
	try {
		const { data, hasNextPage, nextCursor } = await client.queryEvents({
			query: tracker.filter,
			cursor,
			order: 'ascending',
		});

		await tracker.callback(data, tracker.type);

		if (nextCursor && data.length > 0) {
			await saveLatestCursor(tracker, nextCursor);

			return {
				cursor: nextCursor,
				hasNextPage,
			};
		}
	} catch (e) {
		console.error(e);
	}
	return {
		cursor,
		hasNextPage: false,
	};
};

const runEventJob = async (client: SuiClient, tracker: EventTracker, cursor: SuiEventsCursor) => {
	const result = await executeEventJob(client, tracker, cursor);

	setTimeout(
		() => {
			runEventJob(client, tracker, result.cursor);
		},
		result.hasNextPage ? 0 : CONFIG.POLLING_INTERVAL_MS,
	);
};

/**
 * Gets the latest cursor for an event tracker, either from the DB (if it's undefined)
 *	or from the running cursors.
 */
const getLatestCursor = async (tracker: EventTracker) => {
	const cursor = await prisma.cursor.findUnique({
		where: {
			id: tracker.type,
		},
	});

	return cursor || undefined;
};

/**
 * Saves the latest cursor for an event tracker to the db, so we can resume
 * from there.
 * */
const saveLatestCursor = async (tracker: EventTracker, cursor: EventId) => {
	const data = {
		eventSeq: cursor.eventSeq,
		txDigest: cursor.txDigest,
	};

	return prisma.cursor.upsert({
		where: {
			id: tracker.type,
		},
		update: data,
		create: { id: tracker.type, ...data },
	});
};

export const setupListeners = async () => {
	for (const event of EVENTS_TO_TRACK) {
		runEventJob(getClient(CONFIG.NETWORK), event, await getLatestCursor(event));
	}
};

Trustless Swap incorporates handlers to process each event type that triggers. For the locked event, the handler in locked-handler.ts fires and updates the Prisma database accordingly.

Click to close
locked-handler.ts from Trustless Swap

examples/trading/api/indexer/locked-handler.ts
import { SuiEvent } from '@mysten/sui/client';
import { Prisma } from '@prisma/client';

import { prisma } from '../db';

type LockEvent = LockCreated | LockDestroyed;

type LockCreated = {
	creator: string;
	lock_id: string;
	key_id: string;
	item_id: string;
};

type LockDestroyed = {
	lock_id: string;
};

/**
 * Handles all events emitted by the `lock` module.
 * Data is modelled in a way that allows writing to the db in any order (DESC or ASC) without
 * resulting in data incosistencies.
 * We're constructing the updates to support multiple events involving a single record
 * as part of the same batch of events (but using a single write/record to the DB).
 * */
export const handleLockObjects = async (events: SuiEvent[], type: string) => {
	const updates: Record<string, Prisma.LockedCreateInput> = {};

	for (const event of events) {
		if (!event.type.startsWith(type)) throw new Error('Invalid event module origin');
		const data = event.parsedJson as LockEvent;
		const isDeletionEvent = !('key_id' in data);

		if (!Object.hasOwn(updates, data.lock_id)) {
			updates[data.lock_id] = {
				objectId: data.lock_id,
			};
		}

		// Handle deletion
		if (isDeletionEvent) {
			updates[data.lock_id].deleted = true;
			continue;
		}

		// Handle creation event
		updates[data.lock_id].keyId = data.key_id;
		updates[data.lock_id].creator = data.creator;
		updates[data.lock_id].itemId = data.item_id;
	}

	//	As part of the demo and to avoid having external dependencies, we use SQLite as our database.
	//	 Prisma + SQLite does not support bulk insertion & conflict handling, so we have to insert these 1 by 1
	//	 (resulting in multiple round-trips to the database).
	//	Always use a single `bulkInsert` query with proper `onConflict` handling in production databases (e.g Postgres)
	const promises = Object.values(updates).map((update) =>
		prisma.locked.upsert({
			where: {
				objectId: update.objectId,
			},
			create: {
				...update,
			},
			update,
		}),
	);
	await Promise.all(promises);
};