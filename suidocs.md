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

To serialize a PTB for sending to a wallet, Sui recommends using the tx.serialize() function, which returns an opaque string representation of the PTB that can be passed from the Wallet Standard dApp context to your wallet. This can then be converted back into a Transaction using Transaction.from().

tip
You should not build the PTB from bytes in the dApp code. Using serialize instead of build allows you to build the PTB bytes within the wallet itself. This allows the wallet to perform gas logic and coin selection as needed.

// Within a dApp
const tx = new Transaction();
wallet.signTransaction({ transaction: tx });

// Your Wallet Standard code:
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

Sui TypeScript SDK Quick Start
The Sui TypeScript SDK is a modular library of tools for interacting with the Sui blockchain. Use it to send queries to RPC nodes, build and sign transactions, and interact with a Sui or local network.

Installation

npm i @mysten/sui
Network locations
The following table lists the locations for Sui networks.

Network	Full node	faucet
local	http://127.0.0.1:9000 (default)	http://127.0.0.1:9123/v2/gas (default)
Devnet	https://fullnode.devnet.sui.io:443	https://faucet.devnet.sui.io/v2/gas
Testnet	https://fullnode.testnet.sui.io:443	https://faucet.testnet.sui.io/v2/gas
Mainnet	https://fullnode.mainnet.sui.io:443	null
Use dedicated nodes/shared services rather than public endpoints for production apps. The public endpoints maintained by Mysten Labs (fullnode.<NETWORK>.sui.io:443) are rate-limited, and support only 100 requests per 30 seconds or so. Do not use public endpoints in production applications with high traffic volume.

You can either run your own Full nodes, or outsource this to a professional infrastructure provider (preferred for apps that have high traffic). You can find a list of reliable RPC endpoint providers for Sui on the Sui Dev Portal using the Node Service tab.

Module packages
The SDK contains a set of modular packages that you can use independently or together. Import just what you need to keep your code light and compact.

@mysten/sui/client - A client for interacting with Sui RPC nodes.
@mysten/sui/bcs - A BCS builder with pre-defined types for Sui.
@mysten/sui/transactions - Utilities for building and interacting with transactions.
@mysten/sui/keypairs/* - Modular exports for specific KeyPair implementations.
@mysten/sui/verify - Methods for verifying transactions and messages.
@mysten/sui/cryptography - Shared types and classes for cryptography.
@mysten/sui/multisig - Utilities for working with multisig signatures.
@mysten/sui/utils - Utilities for formatting and parsing various Sui types.
@mysten/sui/faucet - Methods for requesting SUI from a faucet.
@mysten/sui/zklogin - Utilities for working with zkLogin.

Programmable Transaction Blocks
On Sui, a transaction is more than a basic record of the flow of assets. Transactions on Sui are composed of a number of commands that execute on inputs to define the result of the transaction. Termed programmable transaction blocks (PTBs), these groups of commands define all user transactions on Sui. PTBs allow a user to call multiple Move functions, manage their objects, and manage their coins in a single transaction--without publishing a new Move package. Designed with automation and transaction builders in mind, PTBs are a lightweight and flexible way of generating transactions. More intricate programming patterns, such as loops, are not supported, however, and in those cases you must publish a new Move package.

As mentioned, each PTB is comprised of individual transaction commands (sometimes referred to simply as transactions or commands). Each transaction command executes in order, and you can use the results from one transaction command in any subsequent transaction command. The effects, specifically object modifications or transfers, of all transaction commands in a block are applied atomically at the end of the transaction. If one transaction command fails, the entire block fails and no effects from the commands are applied.

A PTB can perform up to 1,024 unique operations in a single execution, whereas transactions on traditional blockchains would require 1,024 individual executions to accomplish the same result. The structure also promotes cheaper gas fees. The cost of facilitating individual transactions is always more than the cost of those same transactions blocked together in a PTB.

The remainder of this topic covers the semantics of the execution of the transaction commands. It assumes familiarity with the Sui object model and the Move language. For more information on those topics, see the following documents:

Object model
Move concepts
Transaction type
There are two parts of a PTB that are relevant to execution semantics. Other transaction information, such as the transaction sender or the gas limit, might be referenced but are out of scope. The structure of a PTB is:

{
    inputs: [Input],
    commands: [Command],
}

Looking closer at the two main components:

The inputs value is a vector of arguments, [Input]. These arguments are either objects or pure values that you can use in the commands. The objects are either owned by the sender or are shared/immutable objects. The pure values represent simple Move values, such as u64 or String values, which you can be construct purely from their bytes. For historical reasons, Input is CallArg in the Rust implementation.
The commands value is a vector of commands, [Command]. The possible commands are:
TransferObjects sends multiple (one or more) objects to a specified address.
SplitCoins splits off multiple (one or more) coins from a single coin. It can be any sui::coin::Coin<_> object.
MergeCoins merges multiple (one or more) coins into a single coin. Any sui::coin::Coin<_> objects can be merged, as long as they are all of the same type.
MakeMoveVec creates a vector (potentially empty) of Move values. This is used primarily to construct vectors of Move values to be used as arguments to MoveCall.
MoveCall invokes either an entry or a public Move function in a published package.
Publish creates a new package and calls the init function of each module in the package.
Upgrade upgrades an existing package. The upgrade is gated by the sui::package::UpgradeCap for that package.
Inputs and results
Inputs and results are the two types of values you can use in transaction commands. Inputs are the values that are provided to the PTB, and results are the values that are produced by the PTB commands. The inputs are either objects or simple Move values, and the results are arbitrary Move values (including objects).

The inputs and results can be seen as populating an array of values. For inputs, there is a single array, but for results, there is an array for each individual transaction command, creating a 2D-array of result values. You can access these values by borrowing (mutably or immutably), by copying (if the type permits), or by moving (which takes the value out of the array without re-indexing).

Inputs
Input arguments to a PTB are broadly categorized as either objects or pure values. The direct implementation of these arguments is often obscured by transaction builders or SDKs. This section describes information or data the Sui network needs when specifying the list of inputs, [Input]. Each Input is either an object, Input::Object(ObjectArg), which contains the necessary metadata to specify to object being used, or a pure value, Input::Pure(PureArg), which contains the bytes of the value.

For object inputs, the metadata needed differs depending on the type of ownership of the object. The data for the ObjectArg enum follows:

If the object is owned by an address (or it is immutable), then use ObjectArg::ImmOrOwnedObject(ObjectID, SequenceNumber, ObjectDigest). The triple respectively specifies the object's ID, its sequence number (also known as its version), and the digest of the object's data.

If an object is shared, then use Object::SharedObject { id: ObjectID, initial_shared_version: SequenceNumber, mutable: bool }. Unlike ImmOrOwnedObject, a shared objects version and digest are determined by the network's consensus protocol. The initial_shared_version is the version of the object when it was first shared, which is used by consensus when it has not yet seen a transaction with that object. While all shared objects can be mutated, the mutable flag indicates whether the object is to be used mutably in this transaction. In the case where the mutable flag is set to false, the object is read-only, and the system can schedule other read-only transactions in parallel.

If the object is owned by another object, as in it was sent to an object's ID via the TransferObjects command or the sui::transfer::transfer function, then use ObjectArg::Receiving(ObjectID, SequenceNumber, ObjectDigest). The object data is the same as for the ImmOrOwnedObject case.

For pure inputs, the only data provided is the BCS bytes, which are deserialized to construct Move values. Not all Move values can be constructed from BCS bytes. This means that even if the bytes match the expected layout for a given Move type, they cannot be deserialized into a value of that type unless the type is one of the types permitted for Pure values. The following types are allowed to be used with pure values:

All primitive types:
u8
u16
u32
u64
u128
u256
bool
address
A string, either an ASCII string (std::ascii::String) or UTF8 string (std::string::String). In either case, the bytes are validated to be a valid string with the respective encoding.
An object ID sui::object::ID.
A vector, vector<T>, where T is a valid type for a pure input, checked recursively.
An option, std::option::Option<T>, where T is a valid type for a pure input, checked recursively.
Interestingly, the bytes are not validated until the type is specified in a command, for example in MoveCall or MakeMoveVec. This means that a given pure input could be used to instantiate Move values of several types. See the Arguments section for more details.

Results
Each transaction command produces a (possibly empty) array of values. The type of the value can be any arbitrary Move type, so unlike inputs, the values are not limited to objects or pure values. The number of results generated and their types are specific to each transaction command. The specifics for each command can be found in the section for that command, but in summary:

MoveCall: the number of results and their types are determined by the Move function being called. Move functions that return references are not supported at this time.
SplitCoins: produces (one or more) coins from a single coin. The type of each coin is sui::coin::Coin<T> where the specific coin type T matches the coin being split.
Publish: returns the upgrade capability, sui::package::UpgradeCap, for the newly published package.
Upgrade: returns the upgrade receipt, sui::package::UpgradeReceipt, for the upgraded package.
TransferObjects and MergeCoins do not produce any results (an empty result vector).
Argument structure and usage
Each command takes Arguments that specify the input or result being used. The usage (by-reference or by-value) is inferred based on the type of the argument and the expected argument of the command. First, examine the structure of the Argument enum.

Input(u16) is an input argument, where the u16 is the index of the input in the input vector. For example, given an input vector of [Object1, Object2, Pure1, Object3], Object1 is accessed with Input(0) and Pure1 is accessed with Input(2).

GasCoin is a special input argument representing the object for the SUI coin used to pay for gas. It is kept separate from the other inputs because the gas coin is always present in each transaction and has special restrictions (see below) not present for other inputs. Additionally, the gas coin being separate makes its usage explicit, which is helpful for sponsored transactions where the sponsor might not want the sender to use the gas coin for anything other than gas.

The gas coin cannot be taken by-value except with the TransferObjects command. If you need an owned version of the gas coin, you can first use SplitCoins to split off a single coin.

This limitation exists to make it easy for the remaining gas to be returned to the coin at the end of execution. In other words, if the gas coin was wrapped or deleted, then there would not be an obvious spot for the excess gas to be returned. See the Execution section for more details.

NestedResult(u16, u16) uses the value from a previous command. The first u16 is the index of the command in the command vector, and the second u16 is the index of the result in the result vector of that command. For example, given a command vector of [MoveCall1, MoveCall2, TransferObjects] where MoveCall2 has a result vector of [Value1, Value2], Value1 would be accessed with NestedResult(1, 0) and Value2 would be accessed with NestedResult(1, 1).

Result(u16) is a special form of NestedResult where Result(i) is roughly equivalent to NestedResult(i, 0). Unlike NestedResult(i, 0), Result(i), however, this errors if the result array at index i is empty or has more than one value. The ultimate intention of Result is to allow accessing the entire result array, but that is not yet supported. So in its current state, NestedResult can be used instead of Result in all circumstances.

Execution
For the execution of PTBs, the input vector is populated by the input objects or pure value bytes. The transaction commands are then executed in order, and the results are stored in the result vector. Finally, the effects of the transaction are applied atomically. The following sections describe each aspect of execution in greater detail.

Start of execution
At the beginning of execution, the PTB runtime takes the already loaded input objects and loads them into the input array. The objects are already verified by the network, checking rules like existence and valid ownership. The pure value bytes are also loaded into the array but not validated until usage.

The most important thing to note at this stage is the effects on the gas coin. At the beginning of execution, the maximum gas budget (in terms of SUI) is withdrawn from the gas coin. Any unused gas is returned to the gas coin at the end of execution, even if the coin has changed owners.

Executing a transaction command
Each transaction command is then executed in order. First, examine the rules around arguments, which are shared by all commands.

Arguments
You can use each argument by-reference or by-value. The usage is based on the type of the argument and the type signature of the command.

If the signature expects an &mut T, the runtime checks the argument has type T and it is then mutably borrowed.
If the signature expects an &T, the runtime checks the argument has type T and it is then immutably borrowed.
If the signature expects a T, the runtime checks the argument has type T and it is copied if T: copy and moved otherwise. No object in Sui has copy because the unique ID field sui::object::UID present in all objects does not have the copy ability.
The transaction fails if an argument is used in any form after being moved. There is no way to restore an argument to its position (its input or result index) after it is moved.

If an argument is copied but does not have the drop ability, then the last usage is inferred to be a move. As a result, if an argument has copy and does not have drop, the last usage must be by value. Otherwise, the transaction will fail because a value without drop has not been used.

The borrowing of arguments has other rules to ensure unique safe usage of an argument by reference. If an argument is:

Mutably borrowed, there must be no outstanding borrows. Duplicate borrows with an outstanding mutable borrow could lead to dangling references (references that point to invalid memory).
Immutably borrowed, there must be no outstanding mutable borrows. Duplicate immutable borrows are allowed.
Moved, there must be no outstanding borrows. Moving a borrowed value would dangle those outstanding borrows, making them unsafe.
Copied, there can be outstanding borrows, mutable or immutable. While it might lead to some unexpected results in some cases, there is no safety concern.
Object inputs have the type of their object T as you might expect. However, for ObjectArg::Receiving inputs, the object type T is instead wrapped as sui::transfer::Receiving<T>. This is because the object is not owned by the sender, but instead by another object. And to prove ownership with that parent object, you call the sui::transfer::receive function to remove the wrapper.

The GasCoin has special restrictions on being used by-value (moved). You can only use it by-value with the TransferObjects command.

Shared objects also have restrictions on being used by-value. These restrictions exist to ensure that at the end of the transaction the shared object is either still shared or deleted. A shared object cannot be unshared (having the owner changed) and it cannot be wrapped. A shared object:

Marked as not mutable (being used read-only) cannot be used by value.
Cannot be transferred or frozen. These checks are not done dynamically, however, but rather at the end of the transaction only. For example, TransferObjects succeeds if passed a shared object, but at the end of execution the transaction fails.
Can be wrapped and can become a dynamic field transiently, but by the end of the transaction it must be re-shared or deleted.
Pure values are not type checked until their usage. When checking if a pure value has type T, it is checked whether T is a valid type for a pure value (see the previous list). If it is, the bytes are then validated. You can use a pure value with multiple types as long as the bytes are valid for each type. For example, you can use a string as an ASCII string std::ascii::String and as a UTF8 string std::string::String. However, after you mutably borrow the pure value, the type becomes fixed, and all future usages must be with that type.

TransferObjects
The command has the form TransferObjects(ObjectArgs, AddressArg) where ObjectArgs is a vector of objects and AddressArg is the address the objects are sent to.

Each argument ObjectArgs: [Argument] must be an object, however, the objects do not need to have the same type.
The address argument AddressArg: Argument must be an address, which could come from a Pure input or a result.
All arguments, objects and address, are taken by value.
The command does not produce any results (an empty result vector).
While the signature of this command cannot be expressed in Move, you can think of it roughly as having the signature (vector<forall T: key + store. T>, address): () where forall T: key + store. T is indicating that the vector is a heterogeneous vector of objects.
SplitCoins
The command has the form SplitCoins(CoinArg, AmountArgs) where CoinArg is the coin being split and AmountArgs is a vector of amounts to split off.

When the transaction is signed, the network verifies that the AmountArgs is non-empty.
The coin argument CoinArg: Argument must be a coin of type sui::coin::Coin<T> where T is the type of the coin being split. It can be any coin type and is not limited to SUI coins.
The amount arguments AmountArgs: [Argument] must be u64 values, which could come from a Pure input or a result.
The coin argument CoinArg is taken by mutable reference.
The amount arguments AmountArgs are taken by value (copied).
The result of the command is a vector of coins, sui::coin::Coin<T>. The coin type T is the same as the coin being split, and the number of results matches the number of arguments
For a rough signature expressed in Move, it is similar to a function <T: key + store>(coin: &mut sui::coin::Coin<T>, amounts: vector<u64>): vector<sui::coin::Coin<T>> where the result vector is guaranteed to have the same length as the amounts vector.
MergeCoins
The command has the form MergeCoins(CoinArg, ToMergeArgs) where the CoinArg is the target coin in which the ToMergeArgs coins are merged into. In other words, you merge multiple coins (ToMergeArgs) into a single coin (CoinArg).

When the transaction is signed, the network verifies that the ToMergeArgs is non-empty.
The coin argument CoinArg: Argument must be a coin of type sui::coin::Coin<T> where T is the type of the coin being merged. It can be any coin type and is not limited to SUI coins.
The coin arguments ToMergeArgs: [Argument] must be sui::coin::Coin<T> values where the T is the same type as the CoinArg.
The coin argument CoinArg is taken by mutable reference.
The merge arguments ToMergeArgs are taken by value (moved).
The command does not produce any results (an empty result vector).
For a rough signature expressed in Move, it is similar to a function <T: key + store>(coin: &mut sui::coin::Coin<T>, to_merge: vector<sui::coin::Coin<T>>): ()
MakeMoveVec
The command has the form MakeMoveVec(VecTypeOption, Args) where VecTypeOption is an optional argument specifying the type of the elements in the vector being constructed and Args is a vector of arguments to be used as elements in the vector.

When the transaction is signed, the network verifies that if that the type must be specified for an empty vector of Args.
The type VecTypeOption: Option<TypeTag> is an optional argument specifying the type of the elements in the vector being constructed. The TypeTag is a Move type for the elements in the vector, i.e. the T in the produced vector<T>.
The type does not have to be specified for an object vector--when T: key.
The type must be specified if the type is not an object type or when the vector is empty.
The arguments Args: [Argument] are the elements of the vector. The arguments can be any type, including objects, pure values, or results from previous commands.
The arguments Args are taken by value. Copied if T: copy and moved otherwise.
The command produces a single result of type vector<T>. The elements of the vector cannot then be accessed individually using NestedResult. Instead, the entire vector must be used as an argument to another command. If you wish to access the elements individually, you can use the MoveCall command and do so inside of Move code.
While the signature of this command cannot be expressed in Move, you can think of it roughly as having the signature (T...): vector<T> where T... indicates a variadic number of arguments of type T.
MoveCall
This command has the form MoveCall(Package, Module, Function, TypeArgs, Args) where Package::Module::Function combine to specify the Move function being called, TypeArgs is a vector of type arguments to that function, and Args is a vector of arguments for the Move function.

The package Package: ObjectID is the Object ID of the package containing the module being called.
The module Module: String is the name of the module containing the function being called.
The function Function: String is the name of the function being called.
The type arguments TypeArgs: [TypeTag] are the type arguments to the function being called. They must satisfy the constraints of the type parameters for the function.
The arguments Args: [Argument] are the arguments to the function being called. The arguments must be valid for the parameters as specified in the function's signature.
Unlike the other commands, the usage of the arguments and the number of results are dynamic in that they both depend on the signature of the Move function being called.
Publish
The command has the form Publish(ModuleBytes, TransitiveDependencies) where ModuleBytes are the bytes of the module being published and TransitiveDependencies is a vector of package Object ID dependencies to link against.

When the transaction is signed, the network verifies that the ModuleBytes are not empty. The module bytes ModuleBytes: [[u8]] contain the bytes of the modules being published with each [u8] element is a module.

The transitive dependencies TransitiveDependencies: [ObjectID] are the Object IDs of the packages that the new package depends on. While each module indicates the packages used as dependencies, the transitive object IDs must be provided to select the version of those packages. In other words, these object IDs are used to select the version of the packages marked as dependencies in the modules.

After the modules in the package are verified, the init function of each module is called in same order as the module byte vector ModuleBytes.

The command produces a single result of type sui::package::UpgradeCap, which is the upgrade capability for the newly published package.

Upgrade
The command has the form Upgrade(ModuleBytes, TransitiveDependencies, Package, UpgradeTicket), where the Package indicates the object ID of the package being upgraded. The ModuleBytes and TransitiveDependencies work similarly as the Publish command.

For details on the ModuleBytes and TransitiveDependencies, see the Publish command. Note though, that no init functions are called for the upgraded modules.

The Package: ObjectID is the Object ID of the package being upgraded. The package must exist and be the latest version.

The UpgradeTicket: sui::package::UpgradeTicket is the upgrade ticket for the package being upgraded and is generated from the sui::package::UpgradeCap. The ticket is taken by value (moved).

The command produces a single result type sui::package::UpgradeReceipt which provides proof for that upgrade. For more details on upgrades, see Upgrading Packages.

End of execution
At the end of execution, the remaining values are checked and effects for the transaction are calculated.

For inputs, the following checks are performed:

Any remaining immutable or readonly input objects are skipped since no modifications have been made to them.
Any remaining mutable input objects are returned to their original owners--if they were shared they remain shared, if they were owned they remain owned.
Any remaining pure input values are dropped. Note that pure input values must have copy and drop since all permissible types for those values have copy and drop.
For any shared object you must also check that it has only been deleted or re-shared. Any other operation (wrap, transfer, freezing, and so on) results in an error.
For results, the following checks are performed:

Any remaining result with the drop ability is dropped.
If the value has copy but not drop, it's last usage must have been by-value. In that way, it's last usage is treated as a move.
Otherwise, an error is given because there is an unused value without drop.
Any remaining SUI deducted from the gas coin at the beginning of execution is returned to the coin, even if the owner has changed. In other words, the maximum possible gas is deducted at the beginning of execution, and then the unused gas is returned at the end of execution (all in SUI). Because you can take the gas coin only by-value with TransferObjects, it will not have been wrapped or deleted.

The total effects (which contain the created, mutated, and deleted objects) are then passed out of the execution layer and are applied by the Sui network.

Example
Let's walk through an example of a PTB's execution. While this example is not exhaustive in demonstrating all the rules, it does show the general flow of execution.

Suppose you want to buy two items from a marketplace costing 100 MIST. You keep one for yourself, and then send the object and the remaining coin to a friend at address 0x808. You can do that all in one PTB:

{
  inputs: [
    Pure(/* @0x808 BCS bytes */ ...),
    Object(SharedObject { /* Marketplace shared object */ id: market_id, ... }),
    Pure(/* 100u64 BCS bytes */ ...),
  ]
  commands: [
    SplitCoins(GasCoin, [Input(2)]),
    MoveCall("some_package", "some_marketplace", "buy_two", [], [Input(1), NestedResult(0, 0)]),
    TransferObjects([GasCoin, NestedResult(1, 0)], Input(0)),
    MoveCall("sui", "tx_context", "sender", [], []),
    TransferObjects([NestedResult(1, 1)], NestedResult(3, 0)),
  ]
}

The inputs include the friend's address, the marketplace object, and the value for the coin split. For the commands, split off the coin, call the market place function, send the gas coin and one object, grab your address (via sui::tx_context::sender), and then send the remaining object to yourself. For simplicity, the documentation refers to the package names by name, but note that in practice they are referenced by the package's Object ID.

To walk through this, first look at the memory locations, for the gas object, inputs, and results

Gas Coin: sui::coin::Coin<SUI> { id: gas_coin, balance: sui::balance::Balance<SUI> { value: 1_000_000u64 } }
Inputs: [
  Pure(/* @0x808 BCS bytes */ ...),
  some_package::some_marketplace::Marketplace { id: market_id, ... },
  Pure(/* 100u64 BCS bytes */ ...),
]
Results: []

Here you have two objects loaded so far, the gas coin with a value of 1_000_000u64 and the marketplace object of type some_package::some_marketplace::Marketplace (these names and representations are shortened for simplicity going forward). The pure arguments are not loaded, and are present as BCS bytes.

Note that while gas is deducted at each command, that aspect of execution is not demonstrated in detail.

Before commands: start of execution
Before execution, remove the gas budget from the gas coin. Assume a gas budget of 500_000 so the gas coin now has a value of 500_000u64.

Gas Coin: Coin<SUI> { id: gas_coin, ... value: 500_000u64 ... } // The maximum gas is deducted
Inputs: [
  Pure(/* @0x808 BCS bytes */ ...),
  Marketplace { id: market_id, ... },
  Pure(/* 100u64 BCS bytes */ ...),
]
Results: []

Now you can execute the commands.

Command 0: SplitCoins
The first command SplitCoins(GasCoin, [Input(2)]) accesses the gas coin by mutable reference and loads the pure argument at Input(2) as a u64 value of 100u64. Because u64 has the copy ability, you do not move the Pure input at Input(2). Instead, the bytes are copied out.

For the result, a new coin object is made.

This gives us updated memory locations of

Gas Coin: Coin<SUI> { id: gas_coin, ... value: 499_900u64 ... }
Inputs: [
  Pure(/* @0x808 BCS bytes */ ...),
  Marketplace { id: market_id, ... },
  Pure(/* 100u64 BCS bytes */ ...),
]
Results: [
  [Coin<SUI> { id: new_coin, value: 100u64 ... }], // The result of SplitCoins
],

Command 1: MoveCall
Now the command, MoveCall("some_package", "some_marketplace", "buy_two", [], [Input(1), NestedResult(0, 0)]). Call the function some_package::some_marketplace::buy_two with the arguments Input(1) and NestedResult(0, 0). To determine how they are used, you need to look at the function's signature. For this example, assume the signature is

entry fun buy_two(
    marketplace: &mut Marketplace,
    coin: Coin<Sui>,
    ctx: &mut TxContext,
): (Item, Item)

where Item is the type of the two objects being sold.

Since the marketplace parameter has type &mut Marketplace, use Input(1) by mutable reference. Assume some modifications are being made into the value of the Marketplace object. However, the coin parameter has type Coin<Sui>, so use NestedResult(0, 0) by value. The TxContext input is automatically provided by the runtime.

This gives updated memory locations, where _ indicates the object has been moved.

Gas Coin: Coin<SUI> { id: gas_coin, ... value: 499_900u64 ... }
Inputs: [
  Pure(/* @0x808 BCS bytes */ ...),
  Marketplace { id: market_id, ...  }, // Any mutations are applied
  Pure(/* 100u64 BCS bytes */ ...),
]
Results: [
  [ _ ], // The coin was moved
  [Item { id: id1 }, Item { id: id2 }], // The results from the Move call
],

Assume that buy_two deletes its Coin<SUI> object argument and transfers the Balance<SUI> into the Marketplace object.

Command 2: TransferObjects
TransferObjects([GasCoin, NestedResult(1, 0)], Input(0)) transfers the gas coin and first item to the address at Input(0). All inputs are by value, and the objects do not have copy so they are moved. While no results are given, the ownership of the objects is changed. This cannot be seen in the memory locations, but rather in the transaction effects.

You now have updated memory locations of

Gas Coin: _ // The gas coin is moved
Inputs: [
  Pure(/* @0x808 BCS bytes */ ...),
  Marketplace { id: market_id, ... },
  Pure(/* 100u64 BCS bytes */ ...),
]
Results: [
  [ _ ],
  [ _ , Item { id: id2 }], // One item was moved
  [], // No results from TransferObjects
],

Command 3: MoveCall
Make another Move call, this one to sui::tx_context::sender with the signature

public fun sender(ctx: &TxContext): address

While you could have just passed in the sender's address as a Pure input, this example demonstrates calling some of the additional utility of PTBs; while this function is not an entry function, you can call the public function, too, because you can provide all of the arguments. In this case, the only argument, the TxContext, is provided by the runtime. The result of the function is the sender's address. Note that this value is not treated like the Pure inputs--the type is fixed to address and it cannot be deserialized into a different type, even if it has a compatible BCS representation.

You now have updated memory locations of

Gas Coin: _
Inputs: [
  Pure(/* @0x808 BCS bytes */ ...),
  Marketplace { id: market_id, ... },
  Pure(/* 100u64 BCS bytes */ ...),
]
Results: [
  [ _ ],
  [ _ , Item { id: id2 }],
  [],
  [/* senders address */ ...], // The result of the Move call
],

Command 4: TransferObjects
Finally, transfer the remaining item to yourself. This is similar to the previous TransferObjects command. You are using the last Item by-value and the sender's address by-value. The item is moved because Item does not have copy, and the address is copied because address does have copy.

The final memory locations are

Gas Coin: _
Inputs: [
  Pure(/* @0x808 BCS bytes */ ...),
  Marketplace { id: market_id, ... },
  Pure(/* 100u64 BCS bytes */ ...),
]
Results: [
  [ _ ],
  [ _ , _ ],
  [],
  [/* senders address */ ...],
  [], // No results from TransferObjects
],

After commands: end of execution
At the end of execution, the runtime checks the remaining values, which are the three inputs and the sender's address. The following summarizes the checks performed before effects are given:

Any remaining input objects are marked as being returned to their original owners.
The gas coin has been Moved. And the Marketplace keeps the same owner, which is shared.
All remaining values must have drop.
The Pure inputs have drop because any type they can instantiate has drop.
The sender's address has drop because the primitive type address has drop.
All other results have been moved.
Any remaining shared objects must have been deleted or re-shared.
The Marketplace object was not moved, so the owner remains as shared.
After these checks are performed, generate the effects.

The coin split off from the gas coin, new_coin, does not appear in the effects because it was created and deleted in the same transaction.
The gas coin and the item with id1 are transferred to 0x808.
The gas coin is mutated to update its balance. The remaining gas of the maximum budget of 500_000 is returned to the gas coin even though the owner has changed.
The Item with id1 is a newly created object.
The item with id2 is transferred to the sender's address.
The Item with id2 is a newly created object.
The Marketplace object is returned, remains shared, and it's mutated.
The object remains shared but its contents are mutated.