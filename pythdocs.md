How to Use Real-Time Data in Sui Contracts
This guide explains how to use real-time Pyth data in Sui applications.

Install Pyth SDK
Use the following dependency in your Move.toml file to use the latest Pyth Sui package and its dependencies:

[dependencies.Pyth]
git = "https://github.com/pyth-network/pyth-crosschain.git"
subdir = "target_chains/sui/contracts"
rev = "sui-contract-testnet"
 
[dependencies.Wormhole]
git = "https://github.com/wormhole-foundation/wormhole.git"
subdir = "sui/wormhole"
rev = "sui/testnet"
 
# Pyth is locked into this specific `rev` because the package depends on Wormhole and is pinned to this version.
[dependencies.Sui]
git = "https://github.com/MystenLabs/sui.git"
subdir = "crates/sui-framework/packages/sui-framework"
rev = "041c5f2bae2fe52079e44b70514333532d69f4e6"

Pyth also provides a javascript SDK to construct transaction blocks that update price feeds:

# NPM
npm install --save @pythnetwork/pyth-sui-js
 
# Yarn
yarn add @pythnetwork/pyth-sui-js
Write Contract Code
The code snippet below provides a general template for what your contract code should look like:

/// Module: oracle
module oracle::oracle;
 
use sui::clock::Clock;
use pyth::price_info;
use pyth::price_identifier;
use pyth::price;
use pyth::i64::I64;
use pyth::pyth;
use pyth::price_info::PriceInfoObject;
 
const E_INVALID_ID: u64 = 1;
 
public fun get_sui_price(
    // Other arguments
    clock: &Clock,
    price_info_object: &PriceInfoObject,
): I64 {
    let max_age = 60;
 
    // Make sure the price is not older than max_age seconds
    let price_struct = pyth::get_price_no_older_than(price_info_object, clock, max_age);
 
    // Check the price feed ID
    let price_info = price_info::get_price_info_from_price_info_object(price_info_object);
    let price_id = price_identifier::get_bytes(&price_info::get_price_identifier(&price_info));
 
    // SUI/USD price feed ID
    // The complete list of feed IDs is available at https://pyth.network/developers/price-feed-ids
    // Note: Sui uses the Pyth price feed ID without the `0x` prefix.
    let testnet_sui_price_id = x"50c67b3fd225db8912a424dd4baed60ffdde625ed2feaaf283724f9608fea266";
    assert!(price_id == testnet_sui_price_id, E_INVALID_ID);
 
    // Extract the price, decimal, and timestamp from the price struct and use them.
    let _decimal_i64 = price::get_expo(&price_struct);
    let price_i64 = price::get_price(&price_struct);
    let _timestamp_sec = price::get_timestamp(&price_struct);
 
    price_i64
}

One can consume the price by calling pyth::get_price abovementioned or other utility functions on the PriceInfoObject in the Move module

The code snippet below provides an example of how to update the Pyth price feeds:

import {
  SuiPythClient,
  SuiPriceServiceConnection,
} from "@pythnetwork/pyth-sui-js";
import { SuiClient } from "@mysten/sui/client";
import { Transaction } from "@mysten/sui/transactions";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
 
/// Step 1: Get the off-chain data.
const connection = new SuiPriceServiceConnection(
  "https://hermes-beta.pyth.network", // [!] Only for Sui Testnet
  // "https://hermes.pyth.network/", // Use this for Mainnet
  {
    // Provide this option to retrieve signed price updates for on-chain contracts!
    priceFeedRequestConfig: {
      binary: true,
    },
  }
);
const priceIDs = [
  // You can find the IDs of prices at:
  // - https://pyth.network/developers/price-feed-ids for Mainnet
  // - https://www.pyth.network/developers/price-feed-ids#beta for Testnet
  "0x50c67b3fd225db8912a424dd4baed60ffdde625ed2feaaf283724f9608fea266", // SUI/USD price ID
];
const priceUpdateData = await connection.getPriceFeedsUpdateData(priceIDs);
 
/// Step 2: Submit the new price on-chain and verify it using the contract.
const suiClient = new SuiClient({ url: "https://fullnode.testnet.sui.io:443" });
 
// Fixed the StateIds using the CLI example extracting them from
// here: https://docs.pyth.network/price-feeds/contract-addresses/sui
const pythTestnetStateId =
  "0x243759059f4c3111179da5878c12f68d612c21a8d54d85edc86164bb18be1c7c"; // Testnet
const wormholeTestnetStateId =
  "0x31358d198147da50db32eda2562951d53973a0c0ad5ed738e9b17d88b213d790"; // Testnet
 
const pythClient = new SuiPythClient(
  suiClient,
  pythTestnetStateId,
  wormholeTestnetStateId
);
 
const transaction = new Transaction();
 
/// By calling the updatePriceFeeds function, the SuiPythClient adds the necessary
/// transactions to the transaction block to update the price feeds.
const priceInfoObjectIds = await pythClient.updatePriceFeeds(
  transaction,
  priceUpdateData,
  priceIDs
);
 
let suiPriceObjectId = priceInfoObjectIds[0];
if (!suiPriceObjectId) {
  throw new Error("suiPriceObjectId is undefined");
}
 
/// This is the package id that we receive after publishing `oracle` contract from the previous step.
let testnetExampleContractPackageId =
  "0x42d05111a160febe4144338647e0b7a80daea459c765c1e29a7a6198b235f67c";
const CLOCK =
  "0x0000000000000000000000000000000000000000000000000000000000000006";
transaction.moveCall({
  target: `${testnetExampleContractPackageId}::oracle::get_sui_price`,
  arguments: [transaction.object(CLOCK), transaction.object(suiPriceObjectId)],
});
transaction.setGasBudget(1000000000);
 
const keypair = Ed25519Keypair.fromSecretKey(
  process.env.ADMIN_SECRET_KEY!.toLowerCase()
);
const result = await suiClient.signAndExecuteTransaction({
  transaction,
  signer: keypair,
  options: {
    showEffects: true,
    showEvents: true,
  },
});

By calling the updatePriceFeeds function, the SuiPythClient adds the necessary transactions to the transaction block to update the price feeds.

Your Sui Move module should NOT have a hard-coded call to pyth::update_single_price_feed. In other words, a contract should never call the Sui Pyth pyth::update_single_price_feed entry point. Instead, it should be called directly from client code (e.g., Typescript or Rust).

When Sui contracts are upgraded, the address changes, which makes the old address no longer valid. If your module has a hard-coded call to pyth::update_single_price_feed living at a fixed call-site, it may eventually get bricked due to how Pyth upgrades are implemented. (Pyth only allow users to interact with the most recent package version for security reasons).

Therefore, you should build a Sui programmable transaction that first updates the price by calling pyth::update_single_price_feed at the latest call-site from the client-side and then call a function in your contract that invokes pyth::get_price on the PriceInfoObject to get the recently updated price. You can use SuiPythClient to build such transactions and handle all the complexity of updating the price feeds.

Consult Fetch Price Updates for more information on how to fetch the pyth_price_update.

Additional Resources
You may find these additional resources helpful for developing your Sui application.

CLI Example
This example shows how to update prices on a Sui network. It does the following:

Fetches update data from Hermes for the given price feeds.
Call the Pyth Sui contract with a price update.
You can run this example with npm run example-relay. A full command that updates prices on the Sui testnet looks like this:

export SUI_KEY=YOUR_PRIV_KEY;
npm run example-relay -- --feed-id "5a035d5440f5c163069af66062bac6c79377bf88396fa27e6067bfca8096d280" \
--hermes "https://hermes-beta.pyth.network" \
--full-node "https://fullnode.testnet.sui.io:443" \
--pyth-state-id "0x243759059f4c3111179da5878c12f68d612c21a8d54d85edc86164bb18be1c7c" \
--wormhole-state-id "0x31358d198147da50db32eda2562951d53973a0c0ad5ed738e9b17d88b213d790"
Contract Addresses
Consult Sui Contract Addresses to find the package IDs.

Pyth Price Feed IDs
Consult Pyth Price Feed IDs to find Pyth price feed IDs for various assets.