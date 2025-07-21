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

Access Sui Data
You can access Sui network data like Transactions, Checkpoints, Objects, Events, and more through the available interfaces. You can use this data in your application workflows, to analyze network behavior across applications or protocols of interest, or to perform audits on parts or the whole of the network.

This document outlines the interfaces that are currently available to access the Sui network data, along with an overview of how that's gradually evolving. Refer to the following definitions for release stages mentioned in this document:

Alpha - Experimental release that is subject to change and is not recommended for production use. You can use it for exploration in non-production environments.
Beta - Somewhat stable release that is subject to change based on user feedback. You can use it for testing and production readiness in non-production environments. If you use it in production, do so at your own risk. Only entertain using after verifying the desired functional, performance, and other relevant characteristics in a non-production environment, and if you are comfortable keeping your application regularly updated for any changes.
Generally available (GA) - Fully stable release that you can use in production. Notifications for any breaking changes are made in advance.
Current data access interfaces
Currently, you can use any of the following mechanisms to access Sui network data:

Directly connect to JSON-RPC hosted on Sui Full nodes that are operated by RPC providers (filter by RPC) or Data indexer operators.
The Mainnet, Testnet, or Devnet load balancer URLs abstract the Sui Foundation-managed Full nodes. Those are not recommended for production use.
Set up your own custom indexer to continuously load the data of interest into a Postgres database.
info
You can also use one of the future-oriented interfaces that are available in alpha or beta, but those are not recommended for production use.

JSON-RPC
You can currently get real-time or historical data from a Sui Full node. Retention period for historical data depends on the pruning strategy that node operators implement, though currently the default configuration for all Full nodes is to implicitly fall back on a Sui Foundation-managed key-value store for historical transaction data.

caution
WebSocket-based JSON RPCs suix_subscribeEvent and suix_subscribeTransaction were deprecated in July 2024. Do not rely on those RPCs in your applications. Refer to Future data access interfaces to learn about a future alternative.

Custom indexer
If you need more control over the types, granularity, and retention period of the data that you need in your application, or if you have specific query patterns that could be best served from a relational database, then you can set up your own custom indexer or reach out to a Data indexer operator that might already have set one up.

If you set up your own indexer, you are responsible for its ongoing maintenance and the related infrastructure and operational costs. You can reduce your costs by implementing a pruning strategy for the relational database by taking into account the retention needs of your application.

Future data access interfaces
Future state data serving stack

Primary interfaces to access Sui access data in the future include:

gRPC API will replace JSON-RPC on Full nodes, and is currently available in beta. If you already use the JSON-RPC or are starting to utilize it as a dependency for your use case, you would need to migrate to gRPC or GraphQL (see below) within a reasonable duration. Refer to the high-level timeline for gRPC availability.
Indexer 2.0 will include a performant and scalable implementation of the Sui indexer framework and is currently available in alpha. You can use it to load data at scale from Full nodes into a Postgres relational database.
GraphQL RPC will include a lightweight GraphQL RPC Server that you can use to read data from the Indexer 2.0's relational database. It is currently available in alpha. You can use it as an alternative to gRPC, including for migration from JSON-RPC for an existing application. Refer to the high-level timeline for GraphQL availability.
You could still utilize an RPC provider (filter by RPC) or a Data indexer operator with these options, assuming some or all of those providers choose to operate the Indexer 2.0 and the GraphQL RPC Server.

gRPC API
As mentioned previously, gRPC API will replace the JSON-RPC on Full nodes, such that JSON-RPC will be deprecated when gRPC API is generally available. Apart from the message and request format changes between the two, the gRPC API comes with a couple of key functional differences:

It will have streaming or subscription API endpoints to consume real-time streaming data in your application without having to poll for those records. This support will be a proper replacement of the deprecated WebSocket support in JSON-RPC.
It will not have implicit fallback on the previously mentioned Sui Foundation-managed key-value store for historical transaction data. Full node operators, RPC providers, and data indexer operators are encouraged to run their own instance of a similar archival store, which you can explicitly define a dependency on to get the relevant historical data.
See When to use gRPC vs GraphQL with Indexer 2.0 for a comparison with GraphQL RPC.

info
The gRPC API is in beta, which is a somewhat stable release that is subject to change based on user feedback. You can use it for testing and production readiness in non-production environments.

High-level timeline

The target times indicated below are tentative and subject to updates based on project progress and your feedback.

Tentative time	Milestone	Description
✔️ April 2025	Beta release of initial set of polling-based APIs.	You can start validating the initial gRPC integration from your application and share feedback on the improvements you want to see.
June 2025	Beta release of streaming APIs and the remaining set of polling-based APIs.	If your use case requires streaming low-latency data, this is an apt time to start validating that integration. Also, the functionality of the API coverage will be complete at this point, so you can start migrating your application in non-production environments.
August 2025	GA release of polling-based APIs with appropriate SDK support.	You can start migration and cutover of your application in the production environment, with the support for streaming APIs still in beta.
October 2025	GA release of scalable streaming APIs.	If your use case requires streaming low-latency data, you can now use those APIs at scale. JSON-RPC will be deprecated at this point and migration notice period will start.
June 2026	End of migration timeline.	JSON-RPC will be fully deactivated at this point. This timeline assumes about 9 months of migration notice period.
Indexer 2.0
As mentioned, Indexer 2.0 will include a performant and scalable implementation of the indexer framework. The underlying framework uses the Full node RPCs to ingest the data, initially using the current generally available JSON-RPC, and later using the gRPC API.

Indexer 2.0 will be declarative such that you can seamlessly configure it to load different kinds of Sui network data into Postgres relational tables in parallel. This change is being implemented to improve the performance of the data ingestion into the Postgres database. In addition, you can configure pruning for different tables in the Postgres database, allowing you to tune it for the desired combination of performance and cost characteristics.

info
Indexer 2.0 is currently in alpha and not recommended for production use. A sneak preview of how you could set up Indexer 2.0 today is available on GitHub.

GraphQL RPC
The GraphQL RPC Server will provide a performant GraphQL RPC layer while reading data from the Indexer 2.0's Postgres database. GraphQL RPC will be an alternative to gRPC API. If you are already using JSON-RPC in your application today, you would have an option to migrate to GraphQL RPC by either operating the combined stack of Indexer 2.0, Postgres database, and GraphQL RPC server on your own, or by utilizing it as a service from an RPC provider or data indexer operator.

GraphQL RPC Server will be a lightweight server component that will allow you to combine data from multiple Postgres database tables using GraphQL's expressive querying system, which is appealing to frontend developers.

See When to use gRPC vs GraphQL with Indexer 2.0 for a comparison with the gRPC API.

info
GraphQL RPC Server is currently in alpha and not recommended for production use. Check out this getting started document for GraphQL RPCs that refers to the Mysten Labs-managed stack of GraphQL RPC Server along with the underlying Postgres database and Indexer 2.0.

Based on valuable feedback from the community, the GraphQL RPC release stage has been updated to alpha. Refer to the high-level timeline for beta and GA releases in this document.

High-level timeline

The target times indicated in this table are tentative and subject to updates based on project progress and your feedback.

Tentative time	Milestone	Description
July 2025	Beta release of GraphQL RPC Server and Indexer 2.0.	You can start validating the setup of Indexer 2.0, along with testing the GraphQL RPC Server to access the indexed Sui data. You can also start migrating your application in the non-production environments, and share feedback on the improvements you want to see.
October 2025	Deprecation of JSON-RPC.	JSON-RPC will be deprecated at this point and migration notice period will start.
December 2025	GA release of GraphQL RPC Server and Indexer 2.0.	You can start migration and cutover of your application in the production environment.
June 2026	End of migration timeline.	JSON-RPC will be fully deactivated at this point. This timeline assumes about 9 months of migration notice period.
When to use gRPC vs GraphQL with Indexer 2.0
You can use the high-level criteria mentioned in the following table to determine whether gRPC API or GraphQL RPC with Indexer 2.0 would better serve your use case. It's not an exhaustive list and it's expected that either of the options could work suitably for some of the use cases.

Dimension	gRPC API	GraphQL RPC with Indexer 2.0
Type of application or data consumer.	Ideal for Web3 exchanges, defi market maker apps, other defi protocols or apps with ultra low-latency needs.	Ideal for webapp builders or builders with slightly relaxed latency needs.
Query patterns.	Okay to read data from different endpoints separately and combine on the client-side; faster serialization, parsing, and validation due to binary format.	Allows easier decoupling of the client with the ability to combine data from different tables in a single request; returns consistent data from different tables across similar checkpoints, including for paginated results.
Retention period requirements.	Default retention period will be two weeks with actual configuration dependent on the Full node operator and their needs and goals; see history-related note after the table.	Default retention period in Postgres database will be four weeks with actual configuration depending on your or a RPC provider or Data indexer operator's needs; see history-related note after the table.
Streaming needs.	Will include a streaming or subscription API before beta release.	Subscription API is planned but will be available after GA.
Incremental costs.	Little to no incremental costs if already using Full node JSON-RPC.	Somewhat significant incremental costs if already using Full node JSON-RPC and if retention period and query patterns differences are insignificant.
info
This table only mentions the default retention period for both options. The expectation is that it's reasonable for a Full node operator, RPC provider, or data indexer operator to configure that to a few times higher without significantly impacting the performance. Also by default, GraphQL RPC Server can directly connect to a archival key-value store for historical data beyond the retention period configured for the underlying Postgres database. Whereas in comparison, gRPC API will not have such direct connectivity to an archival key-value store.

Relevant guidelines will be provided before each option's respective GA release. Those will include recommendations for how to access historical data beyond the configured retention period for your interface of choice.

Refer to the following articles outlining general differences between gRPC and GraphQL. Please validate the accuracy and authenticity of the differences using your own experiments.

https://stackoverflow.blog/2022/11/28/when-to-use-grpc-vs-graphql/
https://blog.postman.com/grpc-vs-graphql/


gRPC Overview (Beta)
⚙️Early-Stage Feature
This content describes an alpha/beta feature or service. These early stage features and services are in active development, so details are likely to change.

This feature or service is currently available in
Devnet
Testnet
Mainnet

The Sui Full Node gRPC API provides a fast, type-safe, and efficient interface for interacting with the Sui blockchain. Designed for power users, indexers, explorers, and decentralized apps, this API enables access to Sui data with high performance and low latency.

info
Refer to Access Sui Data for an overview of options to access Sui network data.

What is gRPC?
gRPC offers a high-performance, efficient communication protocol that uses Protocol Buffers for fast, compact data serialization. Its strongly typed interfaces reduce runtime errors and simplify client/server development across multiple languages. With built-in support for code generation, you can scaffold clients in Typescript, Go, Rust, and more. This makes it ideal for scalable backend systems like indexers, blockchain explorers, and data-intensive decentralized apps.

In addition to request-response calls, gRPC supports server-side streaming, enabling real-time data delivery without constant polling. This is especially useful in environments where you need to track events and transactions live. gRPC's binary format is significantly faster and lighter than JSON, saving bandwidth and improving latency.

Refer to when to use gRPC vs GraphQL to access Sui data.

gRPC on Sui
Protocol buffers define the gRPC interface. You can find the relevant beta .proto files at sui-rpc-api on Github, which apart from the gRPC messages (request and response payloads) include the following services and types:

sui/rpc/v2beta/transaction_execution_service.proto
sui/rpc/v2beta/ledger_service.proto
These definitions can be used to generate client libraries in various programming languages.

info
There are some proto files in the folder sui/rpc/v2alpha as well. Those are in alpha because they are early experimental versions that are subject to change and not recommended for production use.

The TransactionExecutionService currently offers a single RPC method: ExecuteTransaction(ExecuteTransactionRequest), which is used to execute a transaction request. Whereas the LedgerService includes the core lookup queries for Sui data. Some of the RPCs in that service include:

GetObject(GetObjectRequest): Retrieves details of a specific on-chain object.
GetTransaction(GetTransactionRequest): Fetches information about a particular transaction.
GetCheckpoint(GetCheckpointRequest): Fetches information about a particular checkpoint.
Field masks
A FieldMask in Protocol Buffers is a mechanism used to specify a subset of fields within a message that should be read, updated, or returned. Instead of retrieving the entire object, a client can request only the specific fields they need by providing a list of field paths. This improves performance and reduces unnecessary data transfer.

In the Sui gRPC API, FieldMasks are used in requests like GetTransaction to control which parts of the transaction (such as, effects, events) are included in the response. Field paths must match the structure of the response message. This selective querying is especially useful for building efficient applications and tools.

Encoding
In the Sui gRPC API, identifiers with standard human-readable formats are represented as strings in the proto schema:

Address and ObjectId: Represented as 64 hexadecimal characters with a leading 0x.
Digests: Represented as Base58.
TypeTag and StructTag: Represented in their canonical string format (for example, 0x0000000000000000000000000000000000000000000000000000000000000002::coin::Coin<0x0000000000000000000000000000000000000000000000000000000000000002::sui::SUI>)
Access using grpcurl
Simplest way to experiment with gRPC is by using grpcurl.

note
Your results might differ from the examples that follow, depending on the breadth and maturity of the gRPC APIs available on Sui Full nodes.

List available gRPC services
$ grpcurl <full node URL:port> list

where the port on Sui Foundation managed Full nodes is 443. It should return something like:

grpc.health.v1.Health
grpc.reflection.v1.ServerReflection
sui.rpc.v2alpha.LiveDataService
sui.rpc.v2alpha.SubscriptionService
sui.rpc.v2beta.LedgerService
sui.rpc.v2beta.TransactionExecutionService

List available APIs in the LedgerService
$ grpcurl <full node URL:port> list sui.rpc.v2beta.LedgerService

which should return something like:

sui.rpc.v2beta.LedgerService.BatchGetObjects
sui.rpc.v2beta.LedgerService.BatchGetTransactions
sui.rpc.v2beta.LedgerService.GetCheckpoint
sui.rpc.v2beta.LedgerService.GetEpoch
sui.rpc.v2beta.LedgerService.GetObject
sui.rpc.v2beta.LedgerService.GetServiceInfo
sui.rpc.v2beta.LedgerService.GetTransaction

Get the events and effects details of a particular transaction
$ grpcurl -d '{ "digest": "3ByWphQ5sAVojiTrTrGXGM5FmCVzpzYmhsjbhYESJtxp" }' <full node URL:port> sui.rpc.v2beta.LedgerService/GetTransaction


Get the transactions in a particular checkpoint
$ grpcurl -d '{ "sequence_number": "180529334", "read_mask": { "paths": ["transactions"]} }' <full node URL:port> sui.rpc.v2beta.LedgerService/GetCheckpoint


Sample clients in different programming languages
TypeScript
Golang
Python
This is an example to build a Typescript client for Sui gRPC API. If you want to use a different set of tools or modules that you’re comfortable with, you can adjust the instructions accordingly.

Install dependencies

npm init -y

npm install @grpc/grpc-js @grpc/proto-loader

npm i -D tsx

Project structure

.
├── protos/
│   └── sui/
│       └── node/
│           └── v2beta/
│               ├── ledger_service.proto
│               └── *.proto
├── client.ts
├── package.json

Download all the sui/rpc/v2beta proto files from Github v2beta in the same folder.

Sample client.ts to get events and effects details of a particular transaction

import * as grpc from '@grpc/grpc-js';
import * as protoLoader from '@grpc/proto-loader';
import * as path from 'path';

const PROTO_PATH = path.join(__dirname, 'protos/sui/rpc/v2beta/ledger_service.proto');

// Load proto definitions
const packageDefinition = protoLoader.loadSync(PROTO_PATH, {
  keepCase: true,
  longs: String,
  enums: String,
  defaults: true,
  oneofs: true,
  includeDirs: [path.join(__dirname, 'protos')],
});

const suiProto = grpc.loadPackageDefinition(packageDefinition) as any;
const LedgerService = suiProto.sui.rpc.v2beta.LedgerService;

// Create gRPC client
const client = new LedgerService(
  '<full node URL>:443',
  grpc.credentials.createSsl()
);

// Sample transaction digest in Base58 format
const base58Digest = '3ByWphQ5sAVojiTrTrGXGM5FmCVzpzYmhsjbhYESJtxp';

// Construct the request
const request = {
  digest: base58Digest,
  read_mask: {
    paths: ['events', 'effects'],
  },
};

// Make gRPC call
client.GetTransaction(request, (err: any, response: any) => {
  if (err) {
    console.error('Error:', err);
  } else {
    console.log('Response:', JSON.stringify(response, null, 2));
  }
});

Run the sample client

npx tsx c

info
proto-loader handles any nested .proto files - just make sure paths and imports are correct.
The example assumes that gRPC is available on port 443 which requires SSL.
Digest in the request is directly provided in the Base58 format, but check if you need to decode from your source format.
Frequently asked questions
Q: In a batch object request (BatchGetObjects), does the field mask specified in individual GetObjectRequests override the top-level field mask in the BatchGetObjectsRequest?

A: No, only the top-level field mask defined in the BatchGetObjectsRequest is used. Any field masks specified within individual GetObjectRequest entries are ignored. This behavior also applies to other batch request APIs in the LedgerService interface.
Q: In ExecuteTransactionRequest, why is the transaction field marked as optional?

A: While the transaction field is marked as optional in the TransactionExecutionService .proto file, it is not optional in the API contract. It is required when making the request. This is a quirk of Protocol Buffers: marking a field as optional enables field presence, which allows the API to distinguish between fields that were explicitly set and those that were left unset. Some of the benefits of field presence include:
Differentiating between missing and default values
Enabling patch or partial update semantics
Avoiding ambiguity when default values (like 0, "", or false) are valid inputs

Sui RPC
info
Refer to Access Sui Data for an overview of options to access Sui network data.

SuiJSON is a JSON-based format with restrictions that allow Sui to align JSON inputs more closely with Move call arguments.

This table shows the restrictions placed on JSON types to make them SuiJSON compatible:

JSON	SuiJSON Restrictions	Move Type Mapping
Number	Must be unsigned integer	u8, u6, u32, u64 (encoded as String), u128 (encoded as String), u256 (encoded as String)
String	No restrictions	Vector<u8>, Address, ObjectID, TypeTag, Identifier, Unsigned integer (256 bit max)
Boolean	No restrictions	Bool
Array	Must be homogeneous JSON and of SuiJSON type	Vector
Null	Not allowed	N/A
Object	Not allowed	N/A
Type coercion reasoning
Due to the loosely typed nature of JSON/SuiJSON and the strongly typed nature of Move types, you sometimes need to overload SuiJSON types to represent multiple Move types.

For example SuiJSON::Number can represent both u8 and u32. This means you have to coerce and sometimes convert types.

Which type you coerce depends on the expected Move type. For example, if the Move function expects a u8, you must have received a SuiJSON::Number with a value less than 256. More importantly, you have no way to easily express Move addresses in JSON, so you encode them as hex strings prefixed by 0x.

Additionally, Move supports u128 and u256 but JSON doesn't. As a result Sui allows encoding numbers as strings.

Type coercion rules
Move Type	SuiJSON Representations	Valid Examples	Invalid Examples
Bool	Bool	true, false	
u8	Supports 3 formats: Unsigned number < 256. Decimal string with value < 256. One byte hex string prefixed with 0x.	7 "70" "0x43"	-5: negative not allowed 3.9: float not allowed NaN: not allowed 300: U8 must be less than 256 " 9": Spaces not allowed in string "9A": Hex num must be prefixed with 0x "0x09CD": Too large for U8
u16	Three formats are supported Unsigned number < 65536. Decimal string with value < 65536. Two byte hex string prefixed with 0x.	712 "570" "0x423"	-5: negative not allowed 3.9: float not allowed NaN: not allowed 98342300: U16 must be less than 65536 " 19": Spaces not allowed in string "9EA": Hex num must be prefixed with 0x "0x049C1D": Too large for U16
u32	Three formats are supported Unsigned number < 4294967296. Decimal string with value < 4294967296. One byte hex string prefixed with 0x.	9823247 "987120" "0x4BADE93"	-5: negative not allowed 3.9: float not allowed NaN: not allowed 123456789123456: U32 must be less than 4294967296 " 9": Spaces not allowed in string "9A": Hex num must be prefixed with 0x "0x3FF1FF9FFDEFF": Too large for U32
u64	Supports two formats Decimal string with value < U64::MAX. Up to 8 byte hex string prefixed with 0x.	"747944370" "0x2B1A39A15E"	123434: Although this is a valid U64 number, it must be encoded as a string
u128	Two formats are supported Decimal string with value < U128::MAX. Up to 16 byte hex string prefixed with 0x.	"74794734937420002470" "0x2B1A39A1514E1D8A7CE"	34: Although this is a valid U128 number, it must be encoded as a string
u256	Two formats are supported Decimal string with value < U256::MAX. Up to 32 byte hex string prefixed with 0x.	"747947349374200024707479473493742000247" "0x2B1762FECADA39753FCAB2A1514E1D8A7CE"	123434: Although this is a valid U256 number, it must be encoded as a string 0xbc33e6e4818f9f2ef77d020b35c24be738213e64d9e58839ee7b4222029610de
Address	32 byte hex string prefixed with 0x	"0xbc33e6e4818f9f2ef77d020b35c24be738213e64d9e58839ee7b4222029610de"	0xbc33: string too short bc33e6e4818f9f2ef77d020b35c24be738213e64d9e58839ee7b4222029610de: missing 0x prefix 0xG2B1A39A1514E1D8A7CE45919CFEB4FEE70B4E01: invalid hex char G
ObjectID	32 byte hex string prefixed with 0x	"0x1b879f00b03357c95a908b7fb568712f5be862c5cb0a5894f62d06e9098de6dc"	Similar to above
Identifier	Typically used for module and function names. Encoded as one of the following: A String whose first character is a letter and the remaining characters are letters, digits or underscore. A String whose first character is an underscore, and there is at least one further letter, digit or underscore	"function", "_function", "some_name", "____some_name", "Another"	"_": missing trailing underscore, digit or letter, "8name": cannot start with digit, ".function": cannot start with period, " ": cannot be empty space, "func name": cannot have spaces
Vector<Move Type> / Option<Move Type>	Homogeneous vector of aforementioned types including nested vectors of primitive types (only "flat" vectors of ObjectIDs are allowed)	[1,2,3,4]: simple U8 vector [[3,600],[],[0,7,4]]: nested U32 vector ["0x2B1A39A1514E1D8A7CE45919CFEB4FEE", "0x2B1A39A1514E1D8A7CE45919CFEB4FEF"]: ObjectID vector	[1,2,3,false]: not homogeneous JSON [1,2,null,4]: invalid elements [1,2,"7"]: although Sui allows encoding numbers as strings meaning this array can evaluate to [1,2,7], the array is still ambiguous so it fails the homogeneity check.
Vector<u8>	For convenience, Sui allows: U8 vectors represented as UTF-8 (and ASCII) strings.	"√®ˆbo72 √∂†∆˚–œ∑π2ie": UTF-8 "abcdE738-2 _=?": ASCII	

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