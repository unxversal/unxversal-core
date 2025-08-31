explain to me in simple terms how this indexer works:

Build Your First Custom Indexer
info
Refer to Custom Indexing Framework and Indexer Pipeline Architecture for a conceptual overview of the indexer framework.

Refer to Access Sui Data for an overview of options to access Sui network data.

To build a complete custom indexer, you use the sui-indexer-alt-framework. The steps that follow demonstrate how to create a sequential pipeline that extracts transaction digests from Sui checkpoints and stores them in a local PostgreSQL. You can find the source code for the framework in the Sui repo on GitHub.

tip
While this example uses PostgreSQL with Diesel (a popular Rust ORM and query builder) for minimalism and out-of-the-box support, the sui-indexer-alt-framework is designed for flexible storage. You can use different databases (such as MongoDB, CouchDB, or similar) or utilize other database clients if you prefer not to use Diesel. To achieve this, implement the framework's Store and Connection traits and define your database write logic directly within your Handler::commit() method.

Prerequisites
Before starting this exercise, ensure you have:

Required software
You need the following stack installed on your machine.

Rust and Cargo
PostgreSQL
Diesel CLI
If you're unsure whether your system has the necessary software properly installed, you can verify installation with the following commands.

$ psql --version
$ diesel --version

To test PostgreSQL functionality, you can create and delete a test table.

$ createdb test_db && dropdb test_db

If you receive a new prompt with no console output, the test was successful. If you receive a createdb error similar to

createdb: error: connection to server on socket "/tmp/.s.PGSQL.5432" failed: FATAL:  role "username" does not exist

then you need to create the user (replace username with the name provided in your error message).

$ sudo -u postgres createuser --superuser username

Enter the password for your pgAdmin account when prompted, then try the createdb && dropdb command again.

Recommended reading
Read the Custom Indexing Framework and Indexer Pipeline Architecture topics first to understand the overall architecture and concurrent pipeline concepts.

What you build
The following steps show how to create an indexer that:

Connects to Sui Testnet: Uses the remote checkpoint store at https://checkpoints.testnet.sui.io.
Processes checkpoints: Streams checkpoint data continuously.
Extracts transaction data: Pulls transaction digests from each checkpoint.
Stores in local PostgreSQL: Commits data to a local PostgreSQL database.
Implements sequential pipeline: Uses in-order processing with batching for optimal consistency and performance.
In the end, you have a working indexer that demonstrates all core framework concepts and can serve as a foundation for more complex custom indexers.

info
Sui provides checkpoint stores for both Mainnet and Testnet.

Testnet: https://checkpoints.testnet.sui.io
Mainnet: https://checkpoints.mainnet.sui.io
Step 1: Project setup
First, open your console to the directory you want to store your indexer project. Use the cargo new command to create a new Rust project and then navigate to its directory.

$ cargo new simple-sui-indexer
$ cd simple-sui-indexer

Step 2: Configure dependencies
Replace your Cargo.toml code with the following configuration and save.

examples/rust/basic-sui-indexer/Cargo.toml
[package]
name = "basic-sui-indexer"
version = "0.1.0"
edition = "2021"

[dependencies]
# Core framework dependencies
sui-indexer-alt-framework = { git = "https://github.com/MystenLabs/sui.git", branch = "testnet" }

# Async runtime
tokio = { version = "1.0", features = ["full"] }

# Error handling
anyhow = "1.0"

# Diesel PostgreSQL
diesel = { version = "2.0", features = ["postgres", "r2d2"] }
diesel-async = { version = "0.5", features = ["bb8", "postgres", "async-connection-wrapper"] }
diesel_migrations = "2.0"

# Async traits
async-trait = "0.1"

# URL parsing
url = "2.0"

# Use .env file
dotenvy = "0.15"

# Command line parsing
clap = { version = "4.0", features = ["derive"] }

The manifest now includes the following dependencies:

sui-indexer-alt-framework: Core framework providing pipeline infrastructure.
diesel/diesel-async: Type-safe database ORM with asynchronous support.
tokio: Async runtime required by the framework.
clap: Command-line argument parsing for configuration.
anyhow: Error handling and async-trait for trait implementations.
dotenvy: Ingest .env file that stores your PostgreSQL URL.
Step 3: Create database
Before configuring migrations, create and verify your local PostgreSQL database:

$ createdb sui_indexer

Get your connection details:

$ psql sui_indexer -c "\conninfo"

If successful, your console should display a message similar to the following:

You are connected to database "sui_indexer" as user "username" via socket in "/tmp" at port "5432".

You can now set a variable to your database URL as it's used in following commands. Make sure to change username to your actual username.

$ PSQL_URL=postgres://username@localhost:5432/sui_indexer

You can now test your connection with the following command:

$ psql $PSQL_URL -c "SELECT 'Connected';"

If successful, your console or terminal should respond with a message similar to the following:

?column?
-----------
 Connected
(1 row)

Step 4: Database setup
Before you start coding, make sure you set up a local PostgreSQL database from the previous step. This is required for the indexer to store the extracted transaction data.

The following database setup steps have you:

Create a database table to store the data.
Use Diesel to manage the process.
Generate Rust code that maps to the database table.
Step 4.1: Configure Diesel
First, create a diesel.toml file (within the same folder as cargo.toml) to configure database migrations.

$ touch diesel.toml

Update and save the file with the following code:

examples/rust/basic-sui-indexer/diesel.toml
[print_schema]
file = "src/schema.rs"

[migrations_directory]
dir = "migrations"

Step 4.2: Create database table using Diesel migrations
Diesel migrations are a way of creating and managing database tables using SQL files. Each migration has two files:

up.sql: Creates and changes the table.
down.sql: Removes and undoes the changes.
Use the diesel setup command to create the necessary directory structure, passing your database URL with the --database-url argument.

$ diesel setup --database-url $PSQL_URL

Use the diesel migration command at the root of your project to then generate the migration files.

$ diesel migration generate transaction_digests

You should now have a migrations folder in your project. There should be a subdirectory in this folder with the name format YYYY-MM-DD-HHMMSS_transaction_digests. This folder should contain the up.sql and down.sql files.

Open up.sql and replace its contents with the following code (using the actual folder name):

examples/rust/basic-sui-indexer/migrations/YYYY-MM-DD-HHMMSS_transaction_digests/up.sql
CREATE TABLE IF NOT EXISTS transaction_digests (
		tx_digest TEXT PRIMARY KEY,
		checkpoint_sequence_number BIGINT NOT NULL
);

tip
This example uses the TEXT data type for tx_digest, but best practice for a production indexer is to use the BYTEA data type.

The TEXT type is used to make the transaction digest easily readable and directly usable with external tools. Digests are Base58 encoded, and because PostgreSQL cannot natively display BYTEA data in this format, storing it as TEXT allows you to copy the digest from a query and paste it into an explorer like SuiScan.

For a production environment, however, BYTEA is strongly recommended. It offers superior storage and query efficiency by storing the raw byte representation, which is more compact and significantly faster for comparisons than a string. Refer to Binary data performance in PostgreSQL on the CYBERTEC website for more information.

Save up.sql, then open down.sql to edit. Replace the contents of the file with the following code and save it:

examples/rust/basic-sui-indexer/migrations/YYYY-MM-DD-HHMMSS_transaction_digests/down.sql
DROP TABLE IF EXISTS transaction_digests;

Step 4.3: Apply migration and generate Rust schema
From the root of your project, use the diesel migration command to create tables.

$ diesel migration run --database-url $PSQL_URL

Then use the diesel print-schema command to generate the schema.rs file from the actual database.

$ diesel print-schema --database-url $PSQL_URL > src/schema.rs

Your src/schema.rs file should now look like the following:

examples/rust/basic-sui-indexer/src/schema.rs
// @generated automatically by Diesel CLI.

diesel::table! {
		transaction_digests (tx_digest) {
				tx_digest -> Text,
				checkpoint_sequence_number -> Int8,
		}
}

After running the previous commands, your project is set up for the next steps:

PostgreSQL now has a transaction_digests table with the defined columns.
src/schema.rs contains automatically generated Rust code that represents this table structure.
You can now write type-safe Rust code that talks to this specific table.
The Diesel's migration system evolves the database schema over time in a structured and version-controlled way. For a complete walkthrough, see the official Diesel Getting Started guide.

Step 5: Create data structure
To simplify writes to Diesel, you can define a struct that represents a record on the transaction_digests table.

examples/rust/basic-sui-indexer/src/models.rs
use diesel::prelude::*;
use sui_indexer_alt_framework::FieldCount;
use crate::schema::transaction_digests;

#[derive(Insertable, Debug, Clone, FieldCount)]
#[diesel(table_name = transaction_digests)]
pub struct StoredTransactionDigest {
		pub tx_digest: String,
		pub checkpoint_sequence_number: i64,
}

Key annotations:

FieldCount: Required by sui-indexer-alt-framework for memory optimization and batch processing efficiency. It is used to limit the max size of a batch so that we don't exceed the postgres limit on the number of bind parameters a single SQL statement can have.
diesel(table_name = transaction_digests): Maps this Rust struct to the transaction_digests table, whose schema is generated in a previous step.
Insertable: Allows this struct to be inserted into the database using Diesel.
Step 6: Define the Handler struct in handler.rs
Create a handlers.rs file in your src directory.

$ touch ./src/handlers.rs

Open the file and define a concrete struct to implement the Processor and Handler traits:

examples/rust/basic-sui-indexer/src/handlers.rs
pub struct TransactionDigestHandler;

Save the file but keep it open as the next steps add to its code.

Step 7: Implement the Processor
The Processor trait defines how to extract and transform data from checkpoints. The resulting data is then passed to Handler::commit.

Add the necessary dependencies at the top of the file.

examples/rust/basic-sui-indexer/src/handlers.rs
use std::sync::Arc;
use anyhow::Result;
use sui_indexer_alt_framework::{
    pipeline::Processor,
    types::full_checkpoint_content::CheckpointData,
};

use crate::models::StoredTransactionDigest;
use crate::schema::transaction_digests::dsl::*;

After the TransactionDigestHandler struct, add the Processor code:

examples/rust/basic-sui-indexer/src/handlers.rs
impl Processor for TransactionDigestHandler {
    const NAME: &'static str = "transaction_digest_handler";

    type Value = StoredTransactionDigest;

    fn process(&self, checkpoint: &Arc<CheckpointData>) -> Result<Vec<Self::Value>> {
        let checkpoint_seq = checkpoint.checkpoint_summary.sequence_number as i64;

        let digests = checkpoint.transactions.iter().map(|tx| {
            StoredTransactionDigest {
                tx_digest: tx.transaction.digest().to_string(),
                checkpoint_sequence_number: checkpoint_seq,
            }
        }).collect();

        Ok(digests)
    }
}

Key concepts:

NAME: Unique identifier for this processor used in monitoring and logging.
type Value: Defines what data flows through the pipeline, which ensures type safety.
process(): Core logic that transforms checkpoint data into your custom data structure.
Save the handlers.rs file.

Click to open
Processor trait definition

Step 8: Implement the Handler
The Handler trait defines how to commit data to the database. Append the Handler dependencies to bottom of the dependency list you created in the previous step.

examples/rust/basic-sui-indexer/src/handlers.rs
use diesel_async::RunQueryDsl;
use sui_indexer_alt_framework::{
    postgres::{Connection, Db},
    pipeline::sequential::Handler,
};

Add the logic for Handler after the Processor code. The complete code is available at the end of this step.

examples/rust/basic-sui-indexer/src/handlers.rs
#[async_trait::async_trait]
impl Handler for TransactionDigestHandler {
    type Store = Db;
    type Batch = Vec<Self::Value>;

    fn batch(batch: &mut Self::Batch, values: Vec<Self::Value>) {
        batch.extend(values);
    }

    async fn commit<'a>(
        batch: &Self::Batch,
        conn: &mut Connection<'a>,
    ) -> Result<usize> {
        let inserted = diesel::insert_into(transaction_digests)
            .values(batch)
            .on_conflict(tx_digest)
            .do_nothing()
            .execute(conn)
            .await?;

        Ok(inserted)
    }
}

How sequential batching works:

process() returns values for each checkpoint.
batch() accumulates values from multiple checkpoints.
commit() writes the batch when framework reaches limits (H::MAX_BATCH_CHECKPOINTS).
crates/sui-indexer-alt-framework/src/pipeline/sequential/committer.rs
while batch_checkpoints < H::MAX_BATCH_CHECKPOINTS {
    if !can_process_pending(next_checkpoint, checkpoint_lag, &pending) {
        break;
    }

    let Some(entry) = pending.first_entry() else {
        break;
    };

    match next_checkpoint.cmp(entry.key()) {
        // Next pending checkpoint is from the future.
        Ordering::Less => break,

        // This is the next checkpoint -- include it.
        Ordering::Equal => {
            let indexed = entry.remove();
            batch_rows += indexed.len();
            batch_checkpoints += 1;
            H::batch(&mut batch, indexed.values);
            watermark = indexed.watermark;
            next_checkpoint += 1;
        }

        // Next pending checkpoint is in the past, ignore it to avoid double
        // writes.
        Ordering::Greater => {
            metrics
                .total_watermarks_out_of_order
                .with_label_values(&[H::NAME])
                .inc();

            let indexed = entry.remove();
            pending_rows -= indexed.len();
        }
    }
}

tip
You can override the default batch limits by implementing constants in your Handler.

The handlers.rs file is now complete. Save the file.

Click to open
Complete handler.rs file

Click to open
Handler trait definition

Step 9: Create .env file
The main function you create in the next step needs the value you stored to the shell variable $PSQL_URL. To make it available, create a .env file with that data.

Bash/zsh
fish
PowerShell
echo "DATABASE_URL=$PSQL_URL" > .env

After running the command for your environment, make sure the .env file exists at your project root with the correct data.

Step 10: Create main function
Now, to tie everything together in the main function, open your main.rs file. Replace the default code with the following and save the file:

examples/rust/basic-sui-indexer/src/main.rs
mod models;
mod handlers;

use handlers::TransactionDigestHandler;

pub mod schema;

use anyhow::Result;
use clap::Parser;
use diesel_migrations::{embed_migrations, EmbeddedMigrations};
use sui_indexer_alt_framework::{
		cluster::{Args, IndexerCluster},
		pipeline::sequential::SequentialConfig,
};
use tokio;
use url::Url;

// Embed database migrations into the binary so they run automatically on startup
const MIGRATIONS: EmbeddedMigrations = embed_migrations!("migrations");

#[tokio::main]
async fn main() -> Result<()> {
		// Load .env data
		dotenvy::dotenv().ok();

		// Local database URL created in step 3 above
		let database_url = std::env::var("DATABASE_URL")
		.expect("DATABASE_URL must be set in the environment")
		.parse::<Url>()
		.expect("Invalid database URL");
		
		// Parse command-line arguments (checkpoint range, URLs, performance settings)
		let args = Args::parse();
		
		// Build and configure the indexer cluster
		let mut cluster = IndexerCluster::builder()
				.with_args(args)										// Apply command-line configuration
				.with_database_url(database_url)		// Set up database URL
				.with_migrations(&MIGRATIONS)			 // Enable automatic schema migrations
				.build()
				.await?;
		
		// Register our custom sequential pipeline with the cluster
		cluster.sequential_pipeline(
				TransactionDigestHandler,					 // Our processor/handler implementation
				SequentialConfig::default(),				// Use default batch sizes and checkpoint lag
		).await?;
		
		// Start the indexer and wait for completion
		let handle = cluster.run().await?;
		handle.await?;
		
		Ok(())
}

Key components explained:

embed_migrations!: Includes your migration files in the binary so the indexer automatically updates the database schema on startup.
Args::parse(): Provides command-line configuration like --first-checkpoint, --remote-store-url, and so on.
IndexerCluster::builder(): Sets up the framework infrastructure (database connections, checkpoint streaming, monitoring).
sequential_pipeline(): Registers a sequential pipeline that processes checkpoints in order with smart batching.
SequentialConfig::default(): Uses framework defaults for batch sizes and checkpoint lag (how many checkpoints to batch together).
cluster.run(): Starts processing checkpoints and blocks until completion.
Your indexer is now complete. The next steps walk you through running the indexer and checking its functionality.

Step 11: Run your indexer
Use the cargo run command to run your indexer against Testnet with remote checkpoint storage.

$ cargo run -- --remote-store-url https://checkpoints.testnet.sui.io

info
Allow incoming network requests if your operating system requests it for the basic-sui-indexer application.

If successful, your console informs you that the indexer is running.

Step 12: Verify results
Open a new terminal or console and connect to your database to check the results:

$ psql sui_indexer

Ater connecting, run a few queries to verify your indexer is working:

Check how many transaction digests are indexed:

$ SELECT COUNT(*) FROM transaction_digests;

View sample records:

$ SELECT * FROM transaction_digests LIMIT 5;

To confirm your data is accurate, copy any transaction digest from your database and verify it on SuiScan: https://suiscan.xyz/testnet/home

You've built a working custom indexer 🎉

The key concepts covered here apply to any custom indexer: define your data structure, implement the Processor and Handler traits, and let the framework handle the infrastructure.

Related links
Sui Indexer Alt: The sui-indexer-alt crate in the Sui repo.
Move Registry: The indexer that the Move Registry (MVR) implements.
DeepBook Indexer: The indexer that DeepBook implements.
Custom Indexing Framework: The sui-indexer-alt-framework is a powerful Rust framework for building high-performance, custom blockchain indexers on Sui, providing customizable, production-ready components for data ingestion, processing, and storage.
Indexer Pipeline Architecture: The sui-indexer-alt-framework provides two distinct pipeline architectures. Understand the differences between the sequential and concurrent pipelines that the sui-indexer-alt-framework provides to decide which best suits your project needs.
ChatGPT said:

Got it — let me break it down into simple terms so you can see how this Sui indexer works:

1. What the indexer does

Think of the indexer like a translator + librarian:

It listens to the Sui blockchain (by streaming "checkpoints," which are snapshots of what happened on-chain).

It picks out the data you care about (in this example: just the transaction digests + the checkpoint number).

It stores that data into a database (PostgreSQL), so you can query it quickly later without needing to scan the entire chain again.

2. The pipeline flow

The framework gives you a pipeline with three main steps:

Processor

Reads checkpoint data from Sui.

Extracts whatever fields you care about (here: transaction digest + checkpoint number).

Turns it into a simple Rust struct (your own record format).

➝ Output: a batch of "processed" data records.

Batcher

Groups many of those records together into batches (instead of writing one row at a time).

Batching = faster + more efficient database writes.

Handler

Takes each batch and commits it to your database.

In this case, it does INSERT INTO transaction_digests (...) into PostgreSQL.

If a row already exists (same digest), it just skips it.

3. How it’s structured in Rust

You define a Rust struct (StoredTransactionDigest) that represents a row in your table.

You implement:

Processor trait → tells the indexer how to transform a checkpoint into your struct(s).

Handler trait → tells the indexer how to write those structs into your database.

The framework itself handles all the streaming, concurrency, batching, and retries.

4. The database

You create a table transaction_digests (tx_digest TEXT PRIMARY KEY, checkpoint_sequence_number BIGINT).

Diesel (the ORM) auto-generates Rust bindings so you can insert/query in a type-safe way.

The indexer writes every new transaction digest it sees into this table.

5. The big picture

Input = Sui blockchain checkpoints.

Processor = pick what you want.

Handler = store it how you want.

Output = Your database has an ever-growing list of the data you indexed.

You can later:

Run SQL queries (SELECT COUNT(*) FROM transaction_digests;)

Or build analytics, dashboards, bots, etc. on top of that database.

👉 So in short:
The indexer is like a conveyor belt that constantly pulls fresh blocks from Sui, filters them into just the info you want, batches them, and stores them neatly in a database table for easy use.

Do you want me to also give you a visual diagram (flow arrows: Sui → Processor → Batcher → Handler → PostgreSQL)? That might make it even clearer.

You said:
so the indexer is useful for non latency important use cases right
ChatGPT said:

Exactly 👍 — you’ve got it.

Indexers like this one are not designed for ultra-low-latency execution (e.g., high-frequency trading, liquidation bots, MEV). Instead, they’re best suited for use cases where you need reliable, structured historical data, and it’s fine if things are a few seconds or minutes behind.

🔹 When indexers are useful

Analytics & dashboards
Querying trends, charts, and reports from on-chain data.

Governance & DAOs
Storing and displaying proposal histories, votes, parameters.

Compliance & auditing
Keeping an easily queryable record of transactions and states.

Data APIs for apps
Mobile/web frontends that need to load structured blockchain data quickly.

Research / ML training data
Exporting on-chain activity for deeper analysis.

🔹 When NOT to use an indexer

Trading bots / arbitrage / liquidations
These require near real-time reactions (milliseconds). You’d want to listen directly to the chain events or mempool instead.

Order matching / oracle updates
Needs immediate on-chain responses, not delayed indexing.

So yes:
Indexers are about reliable, queryable history → not race-to-the-next-block speed.

Do you want me to also show you how people combine both (indexer + real-time event listeners) in DeFi protocols? That’s often the sweet spot.

You said:
how much space do i need on my computer
ChatGPT said:

Good question — the storage needs depend on what you choose to index. Let me break it down:

🔹 What you’re indexing in the tutorial

In the example you shared:

Only transaction digests + checkpoint numbers are stored.

That’s just a couple of fields per transaction, so the footprint is small.

Back-of-envelope math:

Average transaction digest: ~44 characters in Base58 ≈ 44 bytes (or ~64 bytes if stored as text with overhead).

Checkpoint number: 8 bytes.

Add indexing + row overhead in PostgreSQL → ~150–200 bytes per transaction.

On Sui Testnet/Mainnet:

Sui sees millions of transactions per day. Let’s estimate ~10 million tx/day.

10M × 200 bytes ≈ ~2 GB/day if you index everything.

Over a year, that could be hundreds of GB.

⚠️ But if you’re only running it for development, prototyping, or DAO governance proposals, you’ll use much less (since you don’t need the full history, just the recent checkpoints or specific events).

🔹 Practical setup

Development / learning:
A few GB of disk is enough (you’ll only run it for hours/days, not keep all history).

Light production indexer (only specific tables, like proposals, transfers for a certain contract):
~10–50 GB might last you months before you’d need to prune or archive.

Full archival indexer (all transactions, all checkpoints forever):
Plan for hundreds of GB → multiple TB over time.
(That’s why serious teams run these on dedicated servers or cloud DBs with scaling).

🔹 TL;DR

For experimenting on your laptop: 5–10 GB free disk space is plenty.

For a focused production indexer (only certain events/objects): tens of GB.

For a full history indexer: prepare for TB scale storage (best run in the cloud).

👉 Do you want me to show you how to filter what you index (e.g., only proposals, only certain contracts), so your storage footprint stays small? That’s how most projects keep things manageable.

You said:
Skip to main content
Sui Docs Logo
Guides
Concepts
Standards
References


Search
Overview
Developer Guides

Getting Started

Install Sui
Connect to a Sui Network
Connect to a Local Network
Get Sui Address
Get SUI Tokens
Access Sui Data
Your First Sui dApp

Write a Move Package
Build and Test Packages
Publish a Package
Debugging
Client App with Sui TypeScript SDK
Sui 101

Shared versus Owned Objects
Using Events
Access On-Chain Time
Signing and Sending Transactions
Sponsored Transactions
Avoiding Equivocation
Working with PTBs
Coins and Tokens

Stablecoins
NFTs

Cryptography

Advanced Topics

Migrating to Move 2024
Build Your First Custom Indexer
On-Chain Randomness
Querying Sui RPC with GraphQL (Alpha)
Migrating to GraphQL (Alpha)
Object-Based Local Fee Markets
App Examples

Dev Cheat Sheet
Operator Guides

SuiPlay0X1

SDK Integrations
Broader Sui Ecosystem Support
Wallet Integration Options
Best Practices
Developer GuidesSui 101Using Events
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

Click to open
event-indexer.ts from Trustless Swap

Trustless Swap incorporates handlers to process each event type that triggers. For the locked event, the handler in locked-handler.ts fires and updates the Prisma database accordingly.

Click to open
locked-handler.ts from Trustless Swap

Related links
Custom Indexer: For near-real time monitoring of events, you can use a custom indexer.
Events: The Move Book shows how to emit events in Move.
Trustless Swap: The Trustless Swap guide uses events to update the state of its frontend.
Edit this page
Previous
Shared versus Owned Objects
Next
Access On-Chain Time
Move event structure
Emit events in Move
Query events with RPC
Query events in Rust
Query events with GraphQL
Monitoring events
Poll events
Related links
Sui Logo
© 2025 Sui Foundation | Documentation distributed under CC BY 4.0

if i wanted a lower latency thing, how do i go about making a poll based event listener?
ChatGPT said:
Thought for 7s

If you want lower-latency without running a full custom indexer, you can build a poll-based event listener that repeatedly calls suix_queryEvents (or the SDK wrapper) with a cursor so you only fetch new events. Think: a tight loop → fetch latest events → process → remember “where you left off” → repeat.

Here’s the blueprint and a ready-to-use TypeScript example.

How a fast poller works (in practice)

Choose your filter
Narrow to exactly what you care about (e.g., your package & module, a Move event type, or a sender). Less noise = faster, cheaper.

Keep a durable cursor
Sui’s event API returns a nextCursor. Save it (disk/db). On restart, you resume from that cursor and you won’t double-handle events.

Tight polling loop
Call client.queryEvents(filter, { cursor, limit }).

If you got events: process them all (oldest→newest), update the cursor, and loop again immediately (don’t sleep when you’re catching up).

If no events: sleep a short interval (e.g., 250–1000 ms), then try again.

Idempotency & dedupe
Every event has (txDigest, eventSeq). Use that as a unique key in your DB to avoid duplicates if you ever reprocess.

Backoff, jitter, limits
If the RPC rate-limits or errors, back off (e.g., 200 → 400 → 800 ms) with a bit of jitter.

Persistence
Store last nextCursor and your processed events in a tiny DB (SQLite/SQLite-wal is perfect for a laptop). That gives you durability and resume.

Latency knob
Main knob is your sleep interval when idle. Start at 300–500 ms; drop to 100–250 ms if you really need it. (Below ~100 ms you’ll mostly hammer the endpoint without much win.)

Minimal TypeScript poller (Node.js)
// package.json deps:
//   @mysten/sui.js
//   better-sqlite3 (or use Postgres/Redis if you prefer)

import { SuiClient, getFullnodeUrl } from '@mysten/sui.js/client';
import Database from 'better-sqlite3';

type Cursor = { txDigest: string; eventSeq: number } | null;

const DB_PATH = './events.db';
const FULLNODE = getFullnodeUrl('mainnet'); // or 'testnet'
const POLL_IDLE_MS = 300;                   // lower = lower latency, more RPC calls
const PAGE_LIMIT = 100;                     // tune for your endpoint

// ---- 1) Setup DB (SQLite) ----
const db = new Database(DB_PATH);
db.exec(`
  PRAGMA journal_mode = WAL;
  CREATE TABLE IF NOT EXISTS cursor_state (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    tx_digest TEXT,
    event_seq INTEGER
  );
  INSERT OR IGNORE INTO cursor_state (id, tx_digest, event_seq) VALUES (1, NULL, NULL);

  CREATE TABLE IF NOT EXISTS events (
    tx_digest TEXT NOT NULL,
    event_seq INTEGER NOT NULL,
    ts_ms INTEGER,
    sender TEXT,
    package_id TEXT,
    module TEXT,
    move_type TEXT,
    parsed_json TEXT,
    PRIMARY KEY (tx_digest, event_seq)
  );
`);

function loadCursor(): Cursor {
  const row = db.prepare(`SELECT tx_digest, event_seq FROM cursor_state WHERE id = 1`).get();
  if (!row || row.tx_digest == null || row.event_seq == null) return null;
  return { txDigest: row.tx_digest, eventSeq: row.event_seq };
}

function saveCursor(c: Cursor) {
  const stmt = db.prepare(`UPDATE cursor_state SET tx_digest = ?, event_seq = ? WHERE id = 1`);
  if (!c) stmt.run(null, null);
  else stmt.run(c.txDigest, c.eventSeq);
}

// ---- 2) Sui client ----
const client = new SuiClient({ url: FULLNODE });

// ---- 3) Your event filter (narrow it!) ----
// Examples:
//  - MoveModule: { MoveModule: { package, module } }
//  - MoveEventType: { MoveEventType: '0x...::my_mod::MyEvent' }
//  - Sender: { Sender: '0x...' }
//  - Any, All, Transaction, TimeRange are also available.
const filter = {
  MoveModule: {
    package: '0xYOUR_PACKAGE_ID',
    module: 'your_module_name',
  },
} as const;

// ---- 4) Processing ----
function insertEvent(e: any) {
  // e has data like { id: { txDigest, eventSeq }, timestampMs, sender, packageId, transactionModule, type, parsedJson, ... }
  const stmt = db.prepare(`
    INSERT OR IGNORE INTO events (tx_digest, event_seq, ts_ms, sender, package_id, module, move_type, parsed_json)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
  `);
  stmt.run(
    e.id.txDigest,
    Number(e.id.eventSeq),
    e.timestampMs ?? null,
    e.sender ?? null,
    e.packageId ?? null,
    e.transactionModule ?? null,
    e.type ?? null,
    e.parsedJson ? JSON.stringify(e.parsedJson) : null,
  );
}

function lastEventCursorOfPage(events: any[]): Cursor {
  if (!events.length) return null;
  const last = events[events.length - 1];
  return { txDigest: last.id.txDigest, eventSeq: Number(last.id.eventSeq) };
}

// ---- 5) Poll loop ----
async function run() {
  let cursor: Cursor = loadCursor();
  let idleMs = POLL_IDLE_MS;

  // When catching up (lots of data), we loop without sleeping to reduce latency.
  while (true) {
    try {
      const res = await client.queryEvents({
        // filter, cursor, limit, order
        // NOTE: depending on SDK version, the shape may be:
        //   { filter, cursor, limit, order: 'ascending' | 'descending' }
        // or a positional tuple. This is the typical v0.52+ style.
        filter,
        cursor: cursor ? { txDigest: cursor.txDigest, eventSeq: String(cursor.eventSeq) } : null,
        limit: PAGE_LIMIT,
        order: 'ascending',
      });

      const events = res.data ?? [];

      if (events.length > 0) {
        // Process in order for deterministic effects
        for (const ev of events) insertEvent(ev);

        // Advance cursor (prefer the returned nextCursor if present)
        cursor = res.nextCursor
          ? { txDigest: res.nextCursor.txDigest, eventSeq: Number(res.nextCursor.eventSeq) }
          : lastEventCursorOfPage(events);

        saveCursor(cursor);

        // Since we had data, immediately poll again (no sleep) to catch up quickly
        idleMs = POLL_IDLE_MS; // reset idle wait
        continue;
      }

      // No data: sleep briefly to avoid hammering the node
      await sleep(idleMs);

      // Optional: adaptive backoff on consecutive empties
      // idleMs = Math.min(idleMs + 50, 1000);
    } catch (err: any) {
      // Backoff on errors, add jitter
      const backoff = Math.floor(200 + Math.random() * 400);
      await sleep(backoff);
    }
  }
}

function sleep(ms: number) {
  return new Promise((r) => setTimeout(r, ms));
}

run().catch((e) => {
  console.error('Poller crashed:', e);
  process.exit(1);
});


What you get:

~sub-second latency when idle interval is small (e.g., 300 ms).

Exactly-once processing (idempotent via PK (tx_digest, event_seq)).

Crash-safe resume (cursor saved to SQLite).

Tip: If you want even faster perceived latency, run parallel pollers with disjoint filters (e.g., one per module or per event type). Don’t run multiple pollers on the same filter unless they coordinate on cursor & dedupe.

Rust flavor (quick sketch)

If you prefer Rust:

Use SuiClientBuilder::default().build(fullnode_url)

Call query_events(filter, cursor, Some(limit), /*descending=*/ false) in a loop

Keep cursor: Option<EventID> and store it (e.g., SQLite via rusqlite)

Same logic: process events → update cursor → quick loop if data, short sleep if empty → backoff on errors

The unique key remains (tx_digest, event_seq).

Production touches

Rate limits: Respect HTTP 429, backoff with jitter.

Health checks: Track last successful fetch time; alert if stale.

Metrics: Events/sec, RPC latency, error rate.

Schema: Add useful indexes (e.g., on move_type, sender, ts_ms).

Archiving: Periodically vacuum/partition if high volume.

Auth: If you pay for a dedicated RPC, store the key securely and set a user-agent.

If you tell me what event(s) you want (package/module/type), I can drop in the exact filter and tailor the DB schema to your use case (governance proposals, trades, liquidations, etc.), plus add handlers that call your bot logic as soon as an event arrives.

You said:
let's syay you wanted to "catch up" though, is there a way to poll to get all the data then continue doing your slices method

ChatGPT said:
Thought for 17s

Yes—do a backfill-then-follow loop:

Backfill (old → new)

Pick a start point: either a timestamp (sinceMs) or a known cursor (txDigest,eventSeq).

Page through history in ascending order using queryEvents({ filter, cursor, limit, order:'ascending' }).

After each page, process + persist events and save nextCursor.

Keep looping until the page returns no events (or nextCursor is null for that range).

Switch to tail-follow (live)

Keep the last saved cursor.

Run the same query in a tight polling loop: if you got events → process immediately and loop again; if none → sleep 200–500 ms and retry.

You’re now “caught up” and staying current.

Why chunk by time?

If your filter matches a lot of events, add a TimeRange to backfill in windows (e.g., 1–7 days at a time). That keeps each pass bounded and friendly to RPC limits.

Minimal TypeScript pattern
import { SuiClient, getFullnodeUrl } from '@mysten/sui.js/client';
import Database from 'better-sqlite3';

const client = new SuiClient({ url: getFullnodeUrl('mainnet') });
const db = new Database('./events.db');
db.exec(`
  PRAGMA journal_mode = WAL;
  CREATE TABLE IF NOT EXISTS cursor_state (id INTEGER PRIMARY KEY CHECK (id=1), tx_digest TEXT, event_seq INTEGER);
  INSERT OR IGNORE INTO cursor_state (id, tx_digest, event_seq) VALUES (1, NULL, NULL);
  CREATE TABLE IF NOT EXISTS events (
    tx_digest TEXT, event_seq INTEGER, ts_ms INTEGER, move_type TEXT, parsed_json TEXT,
    PRIMARY KEY (tx_digest, event_seq)
  );
`);

const filter = {
  MoveModule: { package: '0xYOUR_PACKAGE', module: 'your_module' },
} as const;

type Cursor = { txDigest: string; eventSeq: number } | null;
const PAGE_LIMIT = 100;
const IDLE_MS = 300;

// ---- persistence helpers ----
function loadCursor(): Cursor {
  const row = db.prepare(`SELECT tx_digest, event_seq FROM cursor_state WHERE id=1`).get();
  if (!row?.tx_digest && row?.event_seq == null) return null;
  return row?.tx_digest ? { txDigest: row.tx_digest, eventSeq: Number(row.event_seq) } : null;
}
function saveCursor(c: Cursor) {
  db.prepare(`UPDATE cursor_state SET tx_digest=?, event_seq=? WHERE id=1`)
    .run(c?.txDigest ?? null, c?.eventSeq ?? null);
}
function insertEvent(e: any) {
  db.prepare(`
    INSERT OR IGNORE INTO events (tx_digest, event_seq, ts_ms, move_type, parsed_json)
    VALUES (?, ?, ?, ?, ?)
  `).run(e.id.txDigest, Number(e.id.eventSeq), e.timestampMs ?? null, e.type ?? null,
         e.parsedJson ? JSON.stringify(e.parsedJson) : null);
}

// ---- backfill in time windows, then follow ----
async function backfillThenFollow(sinceMs: number) {
  let cursor: Cursor = null;

  // 1) Backfill in windows (e.g., 7 days each)
  const WINDOW = 7 * 24 * 3600 * 1000;
  let start = sinceMs;
  while (start < Date.now()) {
    const end = Math.min(start + WINDOW, Date.now());
    cursor = await drainWindow(filter, cursor, start, end);
    start = end; // next window
  }

  // 2) Follow (live)
  cursor = loadCursor() || cursor;
  while (true) {
    try {
      const res = await client.queryEvents({
        filter,
        cursor: cursor ? { txDigest: cursor.txDigest, eventSeq: String(cursor.eventSeq) } : null,
        limit: PAGE_LIMIT,
        order: 'ascending',
      });

      const events = res.data ?? [];
      if (events.length > 0) {
        for (const ev of events) insertEvent(ev);
        cursor = res.nextCursor
          ? { txDigest: res.nextCursor.txDigest, eventSeq: Number(res.nextCursor.eventSeq) }
          : { txDigest: events[events.length - 1].id.txDigest,
              eventSeq: Number(events[events.length - 1].id.eventSeq) };
        saveCursor(cursor);
        continue; // immediately poll again if we had data
      }

      await sleep(IDLE_MS); // idle wait when no events
    } catch {
      await sleep(300 + Math.random() * 400); // backoff on errors
    }
  }
}

async function drainWindow(filter: any, cursor: Cursor, startMs: number, endMs: number): Promise<Cursor> {
  while (true) {
    const res = await client.queryEvents({
      filter: { Any: [filter, { TimeRange: { startTime: startMs, endTime: endMs } }] }, // filter ∩ time window
      cursor: cursor ? { txDigest: cursor.txDigest, eventSeq: String(cursor.eventSeq) } : null,
      limit: PAGE_LIMIT,
      order: 'ascending',
    });

    const events = res.data ?? [];
    if (events.length === 0) break;

    for (const ev of events) insertEvent(ev);

    cursor = res.nextCursor
      ? { txDigest: res.nextCursor.txDigest, eventSeq: Number(res.nextCursor.eventSeq) }
      : { txDigest: events[events.length - 1].id.txDigest,
          eventSeq: Number(events[events.length - 1].id.eventSeq) };
    saveCursor(cursor);

    // If the returned page is smaller than limit and nextCursor is null, we’ve likely exhausted this window.
    if (!res.hasNextPage && events.length < PAGE_LIMIT) break;
  }
  return cursor;
}

function sleep(ms: number) { return new Promise(r => setTimeout(r, ms)); }

// Kick off from a chosen historical point (e.g., contract deploy time)
backfillThenFollow(/* sinceMs= */ Date.parse('2025-01-01T00:00:00Z'));

Notes & knobs

Starting point: Use your contract deploy time, or “first known event” time to avoid scanning irrelevant history.

Window size: Increase if you need faster catch-up and your RPC allows it; decrease if you hit limits.

Order: Always use order: 'ascending' so effects that depend on event order are deterministic.

Filter strategy: If you have multiple high-volume event types, backfill each with its own poller and DB table/partition.

Done signal: You’re “caught up” when the latest processed event’s timestampMs is within, say, 1–2 blocks of Date.now(); then you rely on the live polling loop.

This gives you complete historical coverage plus low-latency tailing, all with polling—no custom indexer required.

You said:
the docs say this:

RPC Best Practices
This topic provides some best practices for configuring your RPC settings to ensure a reliable infrastructure for your projects and services built on Sui.

caution
Use dedicated nodes/shared services rather than public endpoints for production apps. The public endpoints maintained by Mysten Labs (fullnode.<NETWORK>.sui.io:443) are rate-limited, and support only 100 requests per 30 seconds. Do not use public endpoints in production applications with high traffic volume.

You can either run your own Full nodes, or outsource this to a professional infrastructure provider (preferred for apps that have high traffic). You can find a list of reliable RPC endpoint providers for Sui on the Sui Dev Portal using the Node Service tag.

RPC provisioning guidance
Consider the following when working with a provider:

SLA and 24-hour support: Choose a provider that offers a SLA that meets your needs and 24-hour support.
Onboarding call: Always do an onboarding call with the provider you select to ensure they can provide service that meets your needs. If you have a high-traffic event, such as an NFT mint coming up, notify your RPC provider with the expected traffic increase at least 48 hours in advance.
Redundancy: It is important for high-traffic and time-sensitive apps, like NFT marketplaces and DeFi protocols, to ensure they don't rely on just one provider for RPCs. Many projects default to just using a single provider, but that's extremely risky and you should use other providers to provide redundancy.
Traffic estimate: You should have a good idea about the amount and type of traffic you expect, and you should communicate that information in advance with your RPC provider. During high-traffic events (such as NFT mints), request increased capacity from your RPC provider in advance. Bot mitigation - As Sui matures, a lot of bots will emerge on the network. Sui dApp builders should think about bot mitigation at the infrastructure level. This depends heavily on use cases. For NFT minting, bots are undesirable. However, for certain DeFi use cases, bots are necessary. Think about the implications and prepare your infrastructure accordingly.
Provisioning notice: Make RPC provisioning requests at least one week in advance. This gives operators and providers advance notice so they can arrange for the configure hardware/servers as necessary. If there’s a sudden, unexpected demand, please reach out to us so we can help set you up with providers that have capacity for urgent situations.

but if every user is running their own lgiht node that satays within the limits, then it's within the rules right, since I'm not one server pinging hella
ChatGPT said:
Thought for 9s

Short answer: maybe, but it’s risky to rely on that.

Public Sui endpoints (e.g. fullnode.<network>.sui.io) are rate-limited. If each user’s own machine polls within the published limit (≈100 req / 30s) from their own IP, you’re technically within the rules. But there are gotchas:

Aggregate load still lands on the same public nodes. If your app scales, thousands of light nodes can collectively hammer the shared public infra. Providers can throttle or block based on IP, user-agent, request patterns, or app signatures—not just per-IP token buckets.

Fair-use isn’t a SLA. Public endpoints are best-effort. You’ll see intermittent 429s/5xx, latency spikes, and inconsistent tail behavior—bad for DeFi bots.

Incidents hit everyone at once. One outage = all your users break simultaneously if you only target public nodes.

A pragmatic setup for “light nodes”

If you keep the light-node model, design it so you’re a good citizen and production-grade:

Default to a dedicated RPC

Ship a configurable RPC URL (env/GUI).

Provide a default paid provider (or your own fullnode) with capacity + SLA for production users.

Multi-provider redundancy

Maintain a small pool of RPC URLs.

Health-check & failover on 429/5xx or high latency.

Use sticky selection per client (hash(user_id) → provider) so load spreads predictably.

Client-side rate hygiene

Implement a token bucket per process (e.g., 3 req/sec max, burst 10).

Add jittered polling intervals (e.g., 300–700 ms) to avoid sync storms.

Respect Retry-After on 429, exponential backoff with jitter.

Cut requests dramatically

Use cursors for events; never re-fetch history.

Batch RPC calls where supported.

Prefer checkpoint stores for bulk catch-up, then poll tail only.

Cache stable data (e.g., package metadata) locally.

Opt-in power users

Allow advanced users to plug in their own RPC key/provider (common in wallets/dapps).

Detect public-endpoint usage and display a “reliability: low” banner with a one-click “add provider” flow.

Observability & circuit breakers

Track per-client QPS, error rates, and p95 latency.

If a node starts failing, open circuit, switch provider, then half-open to test recovery.

Event ingestion alternatives

For catch-up: use remote checkpoint stores (designed for bulk reads), then switch to polling with cursors.

If/when stable, consider GraphQL for richer queries (still alpha; keep RPC fallback).

Bottom line

For dev/testing: okay to use public endpoints with gentle polling.

For production: don’t depend on “lots of users each staying under the cap.” Use dedicated RPCs, redundancy, and rate-aware clients. That gives you low-latency behavior without risking mass throttling or surprise outages.

You said:
are the slices set by sui or can you set the slice, so can you configure it so that you ping every second, and for each ping you get all the data for the last second for the event of interest?
ChatGPT said:
Thought for 7s

Short version: you choose the slice; Sui doesn’t push a fixed “server slice.”
You can poll every 1s and ask for “events from [now−1s, now]”, but you must handle a few gotchas.

What you can control

Polling cadence: you decide to ping every 1000 ms (or whatever).

Time window: use the TimeRange filter in suix_queryEvents (or SDK) to request [startTime, endTime] in ms since epoch.

Other filters: intersect your TimeRange with MoveModule/MoveEventType/Sender, etc.

What you can’t assume

Completeness in one page: if more events occurred than your limit, you must paginate until hasNextPage === false (or nextCursor == null).

Perfect wall-clock alignment: timestampMs is tied to checkpointing; expect small drift vs your local clock. Boundaries right at second marks can be tricky.

No gaps at boundaries: clocks can skew; checkpoints can bunch. Use overlap + dedupe.

Recommended pattern (per-second slices)

Every second, compute a window: end = now(), start = end - 1000ms - overlap (e.g., +200–500 ms overlap).

Query with intersection of your event filter and the TimeRange.

Paginate until done.

Dedupe by (txDigest, eventSeq) so overlaps don’t double-count.

Keep a lastSeenCursor too; if you ever fall behind, switch to a cursor catch-up loop (ascending order), then return to time-slices.

TypeScript sketch
const filterCore = { MoveEventType: '0x...::my_mod::MyEvent' } as const;
const PAGE_LIMIT = 200;

async function fetchWindow(client, startMs, endMs, seen) {
  let cursor = null;
  while (true) {
    const res = await client.queryEvents({
      filter: { Any: [filterCore, { TimeRange: { startTime: startMs, endTime: endMs } }] },
      cursor, limit: PAGE_LIMIT, order: 'ascending',
    });

    for (const ev of res.data ?? []) {
      const key = `${ev.id.txDigest}:${String(ev.id.eventSeq)}`;
      if (!seen.has(key)) { seen.add(key); handle(ev); } // your handler
    }

    if (!res.hasNextPage || !res.nextCursor) break;
    cursor = res.nextCursor; // keep paging
  }
}

async function pollEverySecond(client) {
  const seen = new Set();             // or a DB table with PK(txDigest,eventSeq)
  const OVERLAP_MS = 300;             // handles boundary skew
  const INTERVAL_MS = 1000;

  setInterval(async () => {
    const end = Date.now();
    const start = end - INTERVAL_MS - OVERLAP_MS;
    try { await fetchWindow(client, start, end, seen); }
    catch (e) { /* backoff/log */ }
  }, INTERVAL_MS);
}

When to prefer cursors over time slices

High volume: time slices can return many pages; cursors are more efficient and exact.

Strict ordering needed: order: 'ascending' + cursor guarantees deterministic processing.

Catch-up from history: use cursor paging (optionally with coarse TimeRange windows) until you reach “near-now,” then switch to your 1s slices if you still want that shape.

Practical tips

Pick a sane limit (100–500) and retry with backoff on 429/5xx.

Jitter your 1s timer (±100 ms) across many clients to avoid synchronized thundering herd.

Watch your provider’s rate limits; 1 req/s per client is fine, but aggregate load matters.

Bottom line: you can absolutely “slice” per second via TimeRange; just paginate, dedupe, and add a small overlap for reliability. For heavy flow or guaranteed ordering, use cursors as your primary and keep time-slices as a convenience view.

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


Click to close
A successful curl return

{
	"jsonrpc": "2.0",
	"result": {
		"data": [
			{
				"id": {
					"txDigest": "8NB8sXb4m9PJhCyLB7eVH4onqQWoFFzVUrqPoYUhcQe2",
					"eventSeq": "0"
				},
				"packageId": "0x158f2027f60c89bb91526d9bf08831d27f5a0fcb0f74e6698b9f0e1fb2be5d05",
				"transactionModule": "deepbook_utils",
				"sender": "0x8b35e67a519fffa11a9c74f169228ff1aa085f3a3d57710af08baab8c02211b9",
				"type": "0xdee9::clob_v2::WithdrawAsset<0x5d4b302506645c37ff133b98c4b50a5ae14841659738d6d733d59d0d217a93bf::coin::COIN>",
				"parsedJson": {
					"owner": "0x704c8c0d8052be7b5ca7174222a8980fb2ad3cd640f4482f931deb6436902627",
					"pool_id": "0x7f526b1263c4b91b43c9e646419b5696f424de28dda3c1e6658cc0a54558baa7",
					"quantity": "6956"
				},
				"bcs": "2szz6igTRuGmD7YATo8BEg81VLaei4od62wehadwMXYJv63UzJE16USL9pHFYBAGbwNkDYLCk53d45eFj3tEZK1vDGqtXcqH5US",
				"timestampMs": "1691757698019"
			},
			{
				"id": {
					"txDigest": "8NB8sXb4m9PJhCyLB7eVH4onqQWoFFzVUrqPoYUhcQe2",
					"eventSeq": "1"
				},
				"packageId": "0x158f2027f60c89bb91526d9bf08831d27f5a0fcb0f74e6698b9f0e1fb2be5d05",
				"transactionModule": "deepbook_utils",
				"sender": "0x8b35e67a519fffa11a9c74f169228ff1aa085f3a3d57710af08baab8c02211b9",
				"type": "0xdee9::clob_v2::OrderFilled<0x2::sui::SUI, 0x5d4b302506645c37ff133b98c4b50a5ae14841659738d6d733d59d0d217a93bf::coin::COIN>",
				"parsedJson": {
					"base_asset_quantity_filled": "0",
					"base_asset_quantity_remaining": "1532800000000",
					"is_bid": false,
					"maker_address": "0x78a1ff467e9c15b56caa0dedfcfbdfe47c0c385f28b05fdc120b2de188cc8736",
					"maker_client_order_id": "1691757243084",
					"maker_rebates": "0",
					"order_id": "9223372036854839628",
					"original_quantity": "1614700000000",
					"pool_id": "0x7f526b1263c4b91b43c9e646419b5696f424de28dda3c1e6658cc0a54558baa7",
					"price": "605100",
					"taker_address": "0x704c8c0d8052be7b5ca7174222a8980fb2ad3cd640f4482f931deb6436902627",
					"taker_client_order_id": "20082022",
					"taker_commission": "0"
				},
				"bcs": "DcVGz85dWTLU4S33N7VYrhgbkm79ENhHVnp5kBfENEWEeMxHQuvsczg94teh6WHdYtwPqdEsPWdvSJ7ne5qiMxxn3kBm36KLyuuzHV1QdzF45GN8ZU1MDGU4XppiaqcMeRpPPiW8JpUDyeQoobKEV8fMqcyYpDq6KWtZ1WMoGvEDxFKDgFvW9Q7bt1JAzQehRkEKEDZ6dTwfiHw92QuFqczmZ5MKJLYzeysUsSw",
				"timestampMs": "1691757698019"
			},
			{
				"id": {
					"txDigest": "8b3byDuRojHXqmSz16PsyzfdXJEY5nZBGTM23gMsMAY8",
					"eventSeq": "0"
				},
				"packageId": "0x158f2027f60c89bb91526d9bf08831d27f5a0fcb0f74e6698b9f0e1fb2be5d05",
				"transactionModule": "deepbook_utils",
				"sender": "0x8b35e67a519fffa11a9c74f169228ff1aa085f3a3d57710af08baab8c02211b9",
				"type": "0xdee9::clob_v2::OrderFilled<0x2::sui::SUI, 0x5d4b302506645c37ff133b98c4b50a5ae14841659738d6d733d59d0d217a93bf::coin::COIN>",
				"parsedJson": {
					"base_asset_quantity_filled": "700000000",
					"base_asset_quantity_remaining": "0",
					"is_bid": false,
					"maker_address": "0x03b86e93d80b27763ee1fc2c37e285465dff835769de9462d9ad4ebcf46ac6df",
					"maker_client_order_id": "20082022",
					"maker_rebates": "634",
					"order_id": "9223372036854839643",
					"original_quantity": "1000000000",
					"pool_id": "0x7f526b1263c4b91b43c9e646419b5696f424de28dda3c1e6658cc0a54558baa7",
					"price": "604100",
					"taker_address": "0x704c8c0d8052be7b5ca7174222a8980fb2ad3cd640f4482f931deb6436902627",
					"taker_client_order_id": "20082022",
					"taker_commission": "1058"
				},
				"bcs": "DcVGz85dWTLU4S33N7VYrhgbkm79ENhHVnp5kBfENEWEjN45pa9U3AkNhxfTRZbaHTQLugLBXttE32hpJKRsbrZGdryXMPmNA8EpHJnVcnYMXZmWXkNXvY1XjEYnAKU4BnhyJ9BQuxRJDXLA4DEu5uWEpWjLPD2ZHuxqHCn7GpUxvxJjHkKjr9jVVfeR6sN2uRhUXkThEDjCekrqaqwidkyXNmTzmZG4fre3eoZ",
				"timestampMs": "1691758372427"
			}
		],
		"nextCursor": {
			"txDigest": "8b3byDuRojHXqmSz16PsyzfdXJEY5nZBGTM23gMsMAY8",
			"eventSeq": "0"
		},
		"hasNextPage": true
	},
	"id": 1
}


The TypeScript SDK provides a wrapper for the suix_queryEvents method: client.queryEvents.

Click to close
TypeScript SDK queryEvents example

import { useCurrentAccount, useSignAndExecuteTransaction, useSuiClient } from "@mysten/dapp-kit";
import { Transaction } from "@mysten/sui/transactions";
import { Button, Flex, Heading } from "@radix-ui/themes";

export function Creategame({ onCreated }: { onCreated: (id: string) => void }) {
  const { mutateAsync: signAndExecute } = useSignAndExecuteTransaction();
  const currentAccount = useCurrentAccount();
  const client = useSuiClient();

  const executeMoveCall = async (method: "small" | "large") => {
    if (!currentAccount?.address) {
      console.error("No connected account found.");
      return;
    }

    try {
      const tx = new Transaction();

      tx.moveCall({
        arguments: [tx.pure.u64(method === "small" ? 0 : 1)],
        target: `<PACKAGE-ID>::<MODULE>::create_game`,
      });

      const txResult = await signAndExecute({
        transaction: tx,
      });

      await client.waitForTransaction({
        digest: txResult.digest
      });

      const eventsResult = await client.queryEvents({
        query: { Transaction: txResult.digest },
      });

      if (eventsResult.data.length > 0) {
        const firstEvent = eventsResult.data[0]?.parsedJson as { msg?: string };
        const result = firstEvent?.msg || "No events found for the given criteria.";
        onCreated(result);
      } else {
        onCreated("No events found for the given criteria.");
      }
    } catch (error) {
      console.error("Error creating game or querying events:", error);
    }
  };

  return (
    <>
      <Heading size="3">Game Start</Heading>
      <Flex direction="column" gap="2">
        <Flex direction="row" gap="2">
          <Button onClick={() => executeMoveCall("small")}>small</Button>
          <Button onClick={() => executeMoveCall("large")}>large</Button>
        </Flex>
      </Flex>
    </>
  );
}

The example displays the following JSON representation of the event.

{
  "id": {
    "txDigest": "46vSzYS9PaTWZDju2N8ECebAGLrXBdrP9NmvvydtDW2c",
    "eventSeq": "0"
  },
  "packageId": "<PACKAGE-ID>",
  "transactionModule": "<MODULE>",
  "sender": "<SENDER-ADDRESS>",
  "type": "<PACKAGE-ID>::<MODULE>::Result",
  "parsedJson": {
    "msg": "You Lose :("
  },
  "bcs": "DRUZAsJK2DLrBj27"
}

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
You can use GraphQL to query events instead of JSON RPC. The following example queries are in the sui-graphql-rpc crate in the Sui repo.

Click to close
Event connection

crates/sui-graphql-rpc/examples/event_connection/event_connection.graphql
{
  events(
    filter: {
      eventType: "0x3164fcf73eb6b41ff3d2129346141bd68469964c2d95a5b1533e8d16e6ea6e13::Market::ChangePriceEvent<0x2::sui::SUI>"
    }
  ) {
    nodes {
      sendingModule {
        name
        package { digest }
      }
      sender {
        address
      }
      timestamp
      contents {
        type {
          repr
        }
        json
      }
      bcs
    }
  }
}


Click to close
Filter events by sender

crates/sui-graphql-rpc/examples/event_connection/filter_by_sender.graphql
query ByTxSender {
  events(
    first: 1
    filter: {
      sender: "0xdff57c401e125a7e0e06606380560b459a179aacd08ed396d0162d57dbbdadfb"
    }
  ) {
    pageInfo {
      hasNextPage
      endCursor
    }
    nodes {
      sendingModule {
        name
      }
      contents {
        type {
          repr
        }
        json
      }
      sender {
        address
      }
      timestamp
      bcs
    }
  }
}

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
 *  or from the running cursors.
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

  //  As part of the demo and to avoid having external dependencies, we use SQLite as our database.
  //   Prisma + SQLite does not support bulk insertion & conflict handling, so we have to insert these 1 by 1
  //   (resulting in multiple round-trips to the database).
  //  Always use a single `bulkInsert` query with proper `onConflict` handling in production databases (e.g Postgres)
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


Related links
Custom Indexer: For near-real time monitoring of events, you can use a custom indexer.
Events: The Move Book shows how to emit events in Move.
Trustless Swap: The Trustless Swap guide uses events to update the state of its frontend.

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

Network Interactions with SuiClient
The Sui TypeScript SDK provides a SuiClient class to connect to a network's JSON-RPC server. Use SuiClient for all JSON-RPC operations.

Connecting to a Sui network
To establish a connection to a network, import SuiClient from @mysten/sui/client and pass the relevant URL to the url parameter. The following example establishes a connection to Testnet and requests SUI from that network's faucet.


import { getFullnodeUrl, SuiClient } from '@mysten/sui/client';
// use getFullnodeUrl to define Devnet RPC location
const rpcUrl = getFullnodeUrl('devnet');
// create a client connected to devnet
const client = new SuiClient({ url: rpcUrl });
// get coins owned by an address
// replace <OWNER_ADDRESS> with actual address in the form of 0x123...
await client.getCoins({
	owner: '<OWNER_ADDRESS>',
});
The getFullnodeUrl helper in the previous code provides the URL for the specified network, useful during development. In a production application, however, you should use the Mainnet RPC address. The function supports the following values:

localnet
devnet
testnet
mainnet
For local development, you can run cargo run --bin sui -- start --with-faucet --force-regenesis to spin up a local network with a local validator, a Full node, and a faucet server. Refer to the Local Network guide for more information.

Manually calling unsupported RPC methods
You can use SuiClient to call any RPC method the node you're connecting to exposes. Most RPC methods are built into SuiClient, but you can use call to leverage any methods available in the RPC.


import { getFullnodeUrl, SuiClient } from '@mysten/sui/client';
const client = new SuiClient({ url: getFullnodeUrl('devnet') });
// asynchronously call suix_getCommitteeInfo
const committeeInfo = await client.call('suix_getCommitteeInfo', []);
For a full list of available RPC methods, see the RPC documentation.

Customizing the transport
The SuiClient uses a Transport class to manage connections to the RPC node. The default SuiHTTPTransport makes both JSON RPC requests, as well as websocket requests for subscriptions. You can construct a custom transport instance if you need to pass any custom options, such as headers or timeout values.


import { getFullnodeUrl, SuiClient, SuiHTTPTransport } from '@mysten/sui/client';
const client = new SuiClient({
	transport: new SuiHTTPTransport({
		url: 'https://my-custom-node.com/rpc',
		websocket: {
			reconnectTimeout: 1000,
			url: 'https://my-custom-node.com/websockets',
		},
		rpc: {
			headers: {
				'x-custom-header': 'custom value',
			},
		},
	}),
});
Pagination
SuiClient exposes a number of RPC methods that return paginated results. These methods return a result object with 3 fields:

data: The list of results for the current page
nextCursor: a cursor pointing to the next page of results
hasNextPage: a boolean indicating whether there are more pages of results
Some APIs also accept an order option that can be set to either ascending or descending to change the order in which the results are returned.

You can pass the nextCursor to the cursor option of the RPC method to retrieve the next page, along with a limit to specify the page size:


const page1 = await client.getCheckpoints({
	limit: 10,
});
const page2 =
	page1.hasNextPage &&
	client.getCheckpoints({
		cursor: page1.nextCursor,
		limit: 10,
	});
Methods
In addition to the RPC methods mentioned above, SuiClient also exposes some methods for working with Transactions.

executeTransactionBlock

const tx = new Transaction();
// add transaction data to tx...
const { bytes, signature } = tx.sign({ client, signer: keypair });
const result = await client.executeTransactionBlock({
	transactionBlock: bytes,
	signature,
	requestType: 'WaitForLocalExecution',
	options: {
		showEffects: true,
	},
});
Arguments
transactionBlock - either a Transaction or BCS serialized transaction data bytes as a Uint8Array or as a base-64 encoded string.
signature - A signature, or list of signatures committed to the intent message of the transaction data, as a base-64 encoded string.
requestType: WaitForEffectsCert or WaitForLocalExecution. Determines when the RPC node should return the response. Default to be WaitForLocalExecution
options:
showBalanceChanges: Whether to show balance_changes. Default to be False
showEffects: Whether to show transaction effects. Default to be False
showEvents: Whether to show transaction events. Default to be False
showInput: Whether to show transaction input data. Default to be False
showObjectChanges: Whether to show object_changes. Default to be False
showRawInput: Whether to show bcs-encoded transaction input data
signAndExecuteTransaction

const tx = new Transaction();
// add transaction data to tx
const result = await client.signAndExecuteTransaction({
	transaction: tx,
	signer: keypair,
	requestType: 'WaitForLocalExecution',
	options: {
		showEffects: true,
	},
});
Arguments
transaction - BCS serialized transaction data bytes as a Uint8Array or as a base-64 encoded string.
signer - A Keypair instance to sign the transaction
requestType: WaitForEffectsCert or WaitForLocalExecution. Determines when the RPC node should return the response. Default to be WaitForLocalExecution
options:
showBalanceChanges: Whether to show balance_changes. Default to be False
showEffects: Whether to show transaction effects. Default to be False
showEvents: Whether to show transaction events. Default to be False
showInput: Whether to show transaction input data. Default to be False
showObjectChanges: Whether to show object_changes. Default to be False
showRawInput: Whether to show bcs-encoded transaction input data
waitForTransaction
Wait for a transaction result to be available over the API. This can be used in conjunction with executeTransactionBlock to wait for the transaction to be available via the API. This currently polls the getTransactionBlock API to check for the transaction.


const tx = new Transaction();
const result = await client.signAndExecuteTransaction({
	transaction: tx,
	signer: keypair,
});
const transaction = await client.waitForTransaction({
	digest: result.digest,
	options: {
		showEffects: true,
	},
});
Arguments
digest - the digest of the queried transaction
signal - An optional abort signal that can be used to cancel the request
timeout - The amount of time to wait for a transaction. Defaults to one minute.
pollInterval - The amount of time to wait between checks for the transaction. Defaults to 2 seconds.
options:
showBalanceChanges: Whether to show balance_changes. Default to be False
showEffects: Whether to show transaction effects. Default to be False
showEvents: Whether to show transaction events. Default to be False
showInput: Whether to show transaction input data. Default to be False
showObjectChanges: Whether to show object_changes. Default to be False
showRawInput: Whether to show bcs-encoded transaction input data

---
title: Sui Programmable Transaction Basics
---

This example starts by constructing a transaction to send SUI. To construct transactions, import the
`Transaction` class and construct it:

```tsx
import { Transaction } from '@mysten/sui/transactions';

const tx = new Transaction();
```

You can then add commands to the transaction .

```tsx
// create a new coin with balance 100, based on the coins used as gas payment
// you can define any balance here
const [coin] = tx.splitCoins(tx.gas, [100]);

// transfer the split coin to a specific address
tx.transferObjects([coin], '0xSomeSuiAddress');
```

You can attach multiple commands of the same type to a transaction, as well. For example, to get a
list of transfers and iterate over them to transfer coins to each of them:

```tsx
interface Transfer {
	to: string;
	amount: number;
}

// procure a list of some Sui transfers to make
const transfers: Transfer[] = getTransfers();

const tx = new Transaction();

// first, split the gas coin into multiple coins
const coins = tx.splitCoins(
	tx.gas,
	transfers.map((transfer) => transfer.amount),
);

// next, create a transfer command for each coin
transfers.forEach((transfer, index) => {
	tx.transferObjects([coins[index]], transfer.to);
});
```

After you have the transaction defined, you can directly execute it with a signer using
`signAndExecuteTransaction`.

```tsx
client.signAndExecuteTransaction({ signer: keypair, transaction: tx });
```

## Observing the results of a transaction

When you use `client.signAndExecuteTransaction` or `client.executeTransactionBlock`, the transaction
will be finalized on the blockchain before the function resolves, but the effects of the transaction
may not be immediately observable.

There are 2 ways to observe the results of a transaction. Methods like
`client.signAndExecuteTransaction` accept an `options` object with options like `showObjectChanges`
and `showBalanceChanges` (see
[the SuiClient docs for more details](/typescript/sui-client#arguments)). These options will cause
the request to contain additional details about the effects of the transaction that can be
immediately displayed to the user, or used for further processing in your application.

The other way effects of transactions can be observed is by querying other RPC methods like
`client.getBalances` that return objects or balances owned by a specific address. These RPC calls
depend on the RPC node having indexed the effects of the transaction, which may not have happened
immediately after a transaction has been executed. To ensure that effects of a transaction are
represented in future RPC calls, you can use the `waitForTransaction` method on the client:

```typescript
const result = await client.signAndExecuteTransaction({ signer: keypair, transaction: tx });
await client.waitForTransaction({ digest: result.digest });
```

Once `waitForTransaction` resolves, any future RPC calls will be guaranteed to reflect the effects
of the transaction.

## Transactions

Programmable Transactions have two key concepts: inputs and commands.

Commands are steps of execution in the transaction. Each command in a Transaction takes a set of
inputs, and produces results. The inputs for a transaction depend on the kind of command. Sui
supports following commands:

- `tx.splitCoins(coin, amounts)` - Creates new coins with the defined amounts, split from the
  provided coin. Returns the coins so that it can be used in subsequent transactions.
  - Example: `tx.splitCoins(tx.gas, [100, 200])`
- `tx.mergeCoins(destinationCoin, sourceCoins)` - Merges the sourceCoins into the destinationCoin.
  - Example: `tx.mergeCoins(tx.object(coin1), [tx.object(coin2), tx.object(coin3)])`
- `tx.transferObjects(objects, address)` - Transfers a list of objects to the specified address.
  - Example: `tx.transferObjects([tx.object(thing1), tx.object(thing2)], myAddress)`
- `tx.moveCall({ target, arguments, typeArguments  })` - Executes a Move call. Returns whatever the
  Sui Move call returns.
  - Example:
    `tx.moveCall({ target: '0x2::devnet_nft::mint', arguments: [tx.pure.string(name), tx.pure.string(description), tx.pure.string(image)] })`
- `tx.makeMoveVec({ type, elements })` - Constructs a vector of objects that can be passed into a
  `moveCall`. This is required as there’s no way to define a vector as an input.
  - Example: `tx.makeMoveVec({ elements: [tx.object(id1), tx.object(id2)] })`
- `tx.publish(modules, dependencies)` - Publishes a Move package. Returns the upgrade capability
  object.

## Passing inputs to a command

Command inputs can be provided in a number of different ways, depending on the command, and the type
of value being provided.

#### JavaScript values

For specific command arguments (`amounts` in `splitCoins`, and `address` in `transferObjects`) the
expected type is known ahead of time, and you can directly pass raw javascript values when calling
the command method. appropriate Move type automatically.

```ts
// the amount to split off the gas coin is provided as a pure javascript number
const [coin] = tx.splitCoins(tx.gas, [100]);
// the address for the transfer is provided as a pure javascript string
tx.transferObjects([coin], '0xSomeSuiAddress');
```

#### Pure values

When providing inputs that are not on chain objects, the values must be serialized as

[BCS](https://sdk.mystenlabs.com/bcs), which can be done using `tx.pure` eg,
`tx.pure.address(address)` or `tx.pure(bcs.vector(bcs.U8).serialize(bytes))`.

`tx.pure` can be called as a function that accepts a SerializedBcs object, or as a namespace that
contains functions for each of the supported types.

```ts
const [coin] = tx.splitCoins(tx.gas, [tx.pure.u64(100)]);
const [coin] = tx.splitCoins(tx.gas, [tx.pure(bcs.U64.serialize(100))]);
tx.transferObjects([coin], tx.pure.address('0xSomeSuiAddress'));
tx.transferObjects([coin], tx.pure(bcs.Address.serialize('0xSomeSuiAddress')));
```

To pass `vector` or `option` types, you can pass use the corresponding methods on `tx.pure`, use
tx.pure as a function with a type argument, or serialize the value before passing it to tx.pure
using the bcs sdk:

```ts
import { bcs } from '@mysten/sui/bcs';

tx.moveCall({
	target: '0x2::foo::bar',
	arguments: [
		// using vector and option methods
		tx.pure.vector('u8', [1, 2, 3]),
		tx.pure.option('u8', 1),
		tx.pure.option('u8', null),

		// Using pure with type arguments
		tx.pure('vector<u8>', [1, 2, 3]),
		tx.pure('option<u8>', 1),
		tx.pure('option<u8>', null),
		tx.pure('vector<option<u8>>', [1, null, 2]),

		// Using bcs.serialize
		tx.pure(bcs.vector(bcs.U8).serialize([1, 2, 3])),
		tx.pure(bcs.option(bcs.U8).serialize(1)),
		tx.pure(bcs.option(bcs.U8).serialize(null)),
		tx.pure(bcs.vector(bcs.option(bcs.U8)).serialize([1, null, 2])),
	],
});
```

#### Object references

To use an on chain object as a transaction input, you must pass a reference to that object. This can
be done by calling `tx.object` with the object id. Transaction arguments that only accept objects
(like `objects` in `transferObjects`) will automatically treat any provided strings as objects ids.
For methods like `moveCall` that accept both objects and other types, you must explicitly call
`tx.object` to convert the id to an object reference.

```ts
// Object IDs can be passed to some methods like (transferObjects) directly
tx.transferObjects(['0xSomeObject'], 'OxSomeAddress');
// tx.object can be used anywhere an object is accepted
tx.transferObjects([tx.object('0xSomeObject')], 'OxSomeAddress');

tx.moveCall({
	target: '0x2::nft::mint',
	// object IDs must be wrapped in moveCall arguments
	arguments: [tx.object('0xSomeObject')],
});

// tx.object automatically converts the object ID to receiving transaction arguments if the moveCall expects it
tx.moveCall({
	target: '0xSomeAddress::example::receive_object',
	// 0xSomeAddress::example::receive_object expects a receiving argument and has a Move definition that looks like this:
	// public fun receive_object<T: key>(parent_object: &mut ParentObjectType, receiving_object: Receiving<ChildObjectType>) { ... }
	arguments: [tx.object('0xParentObjectID'), tx.object('0xReceivingObjectID')],
});
```

When building a transaction, Sui expects all objects to be fully resolved, including the object
version. The SDK automatically looks up the current version of objects for any provided object
reference when building a transaction. If the object reference is used as a receiving argument to a
`moveCall`, the object reference is automatically converted to a receiving transaction argument.
This greatly simplifies building transactions, but requires additional RPC calls. You can optimize
this process by providing a fully resolved object reference instead:

```ts
// for owned or immutable objects
tx.object(Inputs.ObjectRef({ digest, objectId, version }));

// for shared objects
tx.object(Inputs.SharedObjectRef({ objectId, initialSharedVersion, mutable }));

// for receiving objects
tx.object(Inputs.ReceivingRef({ digest, objectId, version }));
```

##### Object helpers

There are a handful of specific object types that can be referenced through helper methods on
tx.object:

```ts
tx.object.system(),
tx.object.clock(),
tx.object.random(),
tx.object.denyList(),

tx.object.option({
	type: '0x123::example::Thing',
	// value can be an Object ID, or any other object reference, or null for `none`
	value: '0x456',
}),
```

#### Transaction results

You can also use the result of a command as an argument in a subsequent commands. Each method on the
transaction builder returns a reference to the transaction result.

```tsx
// split a coin object off of the gas object
const [coin] = tx.splitCoins(tx.gas, [100]);
// transfer the resulting coin object
tx.transferObjects([coin], address);
```

When a command returns multiple results, you can access the result at a specific index either using
destructuring, or array indexes.

```tsx
// destructuring (preferred, as it gives you logical local names)
const [nft1, nft2] = tx.moveCall({ target: '0x2::nft::mint_many' });
tx.transferObjects([nft1, nft2], address);

// array indexes
const mintMany = tx.moveCall({ target: '0x2::nft::mint_many' });
tx.transferObjects([mintMany[0], mintMany[1]], address);
```

## Get transaction bytes

If you need the transaction bytes, instead of signing or executing the transaction, you can use the
`build` method on the transaction builder itself.

**Important:** You might need to explicitly call `setSender()` on the transaction to ensure that the
`sender` field is populated. This is normally done by the signer before signing the transaction, but
will not be done automatically if you’re building the transaction bytes yourself.

```tsx
const tx = new Transaction();

// ... add some transactions...

await tx.build({ client });
```

In most cases, building requires your SuiClient to fully resolve input values.

If you have transaction bytes, you can also convert them back into a `Transaction` class:

```tsx
const bytes = getTransactionBytesFromSomewhere();
const tx = Transaction.from(bytes);
```

---
title: Paying for Sui Transactions with Gas Coins
---

With Programmable Transactions, you can use the gas payment coin to construct coins with a set
balance using `splitCoin`. This is useful for Sui payments, and avoids the need for up-front coin
selection. You can use `tx.gas` to access the gas coin in a transaction, and it is valid as input
for any arguments, as long as it is used
[by-reference](https://docs.sui.io/guides/developer/sui-101/simulating-refs). Practically speaking,
this means you can also add to the gas coin with `mergeCoins` and borrow it for Move functions with
`moveCall`.

You can also transfer the gas coin using `transferObjects`, in the event that you want to transfer
all of your coin balance to another address.

## Gas configuration

The new transaction builder comes with default behavior for all gas logic, including automatically
setting the gas price, budget, and selecting coins to be used as gas. This behavior can be
customized.

### Gas price

By default, the gas price is set to the reference gas price of the network. You can also explicitly
set the gas price of the transaction by calling `setGasPrice` on the transaction builder.

```tsx
tx.setGasPrice(gasPrice);
```

### Budget

By default, the gas budget is automatically derived by executing a dry-run of the transaction
beforehand. The dry run gas consumption is then used to determine a balance for the transaction. You
can override this behavior by explicitly setting a gas budget for the transaction, by calling
`setGasBudget` on the transaction builder.

**Note:** The gas budget is represented in Sui, and should take the gas price of the transaction
into account.

```tsx
tx.setGasBudget(gasBudgetAmount);
```

### Gas payment

By default, the gas payment is automatically determined by the SDK. The SDK selects all of the users
coins that are not used as inputs in the transaction.

The list of coins used as gas payment will be merged down into a single gas coin before executing
the transaction, and all but one of the gas objects will be deleted. The gas coin at the 0-index
will be the coin that all others are merged into.

```tsx
// you need to ensure that the coins do not overlap with any
// of the input objects for the transaction
tx.setGasPayment([coin1, coin2]);
```

Gas coins should be objects containing the coins objectId, version, and digest.

<auto-type-table type="{ objectId: string, version: string | number, digest: string }" />

---
title: Transaction Intents
---

Transaction Intents enable 3rd party SDKs and [Transaction Plugins](../plugins) to more easily add
complex operations to a Transaction. The Typescript SDK currently only includes a single Intent
(CoinWithBalance), but more will be added in the future.

## The CoinWithBalance intent

The `CoinWithBalance` intent makes it easy to get a coin with a specific balance. For SUI, this has
generally been done by splitting the gas coin:

```typescript
const tx = new Transaction();

const [coin] = tx.splitCoins(tx.gas, [100]);

tx.transferObjects([coin], recipient);
```

This approach works well for SUI, but can't be used for other coin types. The CoinWithBalance intent
solves this by providing a helper function that automatically adds the correct SplitCoins and
MergeCoins commands to the transaction:

```typescript
import { coinWithBalance, Transaction } from '@mysten/sui/transactions';

const tx = new Transaction();

// Setting the sender is required for the CoinWithBalance intent to resolve coins when not using the gas coin
tx.setSender(keypair.toSuiAddress());

tx.transferObjects(
	[
		// Create a SUI coin (balance is in MIST)
		coinWithBalance({ balance: 100 }),
		// Create a coin of another type
		coinWithBalance({ balance: 100, type: '0x123::foo:Bar' }),
	],
	recipient,
);
```

Splitting the gas coin also causes problems for sponsored transactions. When sponsoring
transactions, the gas coin comes from the sponsor instead of the transaction sender. Transaction
sponsors usually do not sponsor transactions that use the gas coin for anything other than gas. To
transfer SUI that does not use the gas coin, you can set the `useGasCoin` option to `false`:

```typescript
const tx = new Transaction();
tx.transferObjects([coinWithBalance({ balance: 100, useGasCoin: false })], recipient);
```

It's important to only set `useGasCoin` option to false for sponsored transactions, otherwise the
coinWithBalance intent may use all the SUI coins, leaving no coins to use for gas.

## How it works

When the `CoinWithBalance` intent is resolved, it will look up the senders owned coins for each type
that needs to be created. It will then find a set of coins with sufficient balance to cover the
desired balance, to combine them into a single coin. This coin is then used in a `SplitCoins`
command to create the desired coin.