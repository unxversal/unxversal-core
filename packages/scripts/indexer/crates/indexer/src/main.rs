use anyhow::Context;
use clap::Parser;
use prometheus::Registry;
use std::net::SocketAddr;
use sui_indexer_alt_framework::ingestion::ClientArgs;
use sui_indexer_alt_framework::{Indexer, IndexerArgs};
use sui_indexer_alt_metrics::db::DbConnectionStatsCollector;
use sui_indexer_alt_metrics::{MetricsArgs, MetricsService};
use sui_pg_db::{Db, DbArgs};
use tokio_util::sync::CancellationToken;
use url::Url;

use unxv_indexer::handlers::unxv_events_handler::UnxvEventsHandler;
use unxv_indexer::UnxvEnv;
use unxv_schema::MIGRATIONS;

#[derive(Parser)]
#[clap(rename_all = "kebab-case", author, version)]
struct Args {
    #[command(flatten)]
    db_args: DbArgs,
    #[command(flatten)]
    indexer_args: IndexerArgs,
    #[clap(env, long, default_value = "0.0.0.0:9184")]
    metrics_address: SocketAddr,
    #[clap(env, long, default_value = "postgres://postgres:postgrespw@localhost:5432/unxv_indexer")]
    database_url: Url,
    /// Optional positional network: mainnet | testnet
    #[clap(value_enum)]
    network: Option<UnxvEnv>,
    /// Optional flag/env override for network
    #[clap(env, long)]
    env: Option<UnxvEnv>,
}

const BANNER: &str = r#"
██╗░░░██╗███╗░░██╗██╗░░██╗██╗░░░██╗██╗███╗░░██╗██████╗░███████╗██╗░░██╗███████╗██████╗░
██║░░░██║████╗░██║╚██╗██╔╝██║░░░██║██║████╗░██║██╔══██╗██╔════╝╚██╗██╔╝██╔════╝██╔══██╗
██║░░░██║██╔██╗██║░╚███╔╝░╚██╗░██╔╝██║██╔██╗██║██║░░██║█████╗░░░╚███╔╝░█████╗░░██████╔╝
██║░░░██║██║╚████║░██╔██╗░░╚████╔╝░██║██║╚████║██║░░██║██╔══╝░░░██╔██╗░██╔══╝░░██╔══██╗
╚██████╔╝██║░╚███║██╔╝╚██╗░░╚██╔╝░░██║██║░╚███║██████╔╝███████╗██╔╝╚██╗███████╗██║░░██║
░╚═════╝░╚═╝░░╚══╝╚═╝░░╚═╝░░░╚═╝░░░╚═╝╚═╝░░╚══╝╚═════╝░╚══════╝╚═╝░░╚═╝╚══════╝╚═╝░░╚═╝
"#;

#[tokio::main]
async fn main() -> Result<(), anyhow::Error> {
    let _guard = telemetry_subscribers::TelemetryConfig::new().with_env().init();

    let args = Args::parse();
    let env = args.env.or(args.network).unwrap_or(UnxvEnv::Mainnet);
    let Args { db_args, indexer_args, metrics_address, database_url, .. } = args;

    println!("{}", BANNER);
    println!("Unxversal Indexer starting...");
    println!("Network:   {:?}", env);
    println!("Database:  {}", database_url);
    println!("Metrics:   {}", metrics_address);

    let cancel = CancellationToken::new();
    let registry = Registry::new_custom(Some("unxv".into()), None)
        .context("Failed to create Prometheus registry.")?;
    let metrics = MetricsService::new(
        MetricsArgs { metrics_address },
        registry.clone(),
        cancel.child_token(),
    );

    // Prepare DB store
    let store = Db::for_write(database_url, db_args)
        .await
        .context("Failed to connect to database")?;
    store
        .run_migrations(Some(&MIGRATIONS))
        .await
        .context("Failed to run pending migrations")?;

    registry.register(Box::new(DbConnectionStatsCollector::new(
        Some("unxv_indexer_db"),
        store.clone(),
    )))?;

    let mut indexer = Indexer::new(
        store,
        indexer_args,
        ClientArgs {
            remote_store_url: Some(env.remote_store_url()),
            local_ingestion_path: None,
            rpc_api_url: None,
            rpc_username: None,
            rpc_password: None,
        },
        Default::default(),
        metrics.registry(),
        cancel.clone(),
    )
    .await?;

    // Pipeline: generic Unxv events
    // Allowlist package addresses from env var UNXV_PACKAGE_IDS (comma-separated), e.g. "0xabc,0xdef"
    let package_allowlist: Option<Vec<String>> = std::env::var("UNXV_PACKAGE_IDS")
        .ok()
        .map(|s| s.split(',').map(|x| x.trim().to_ascii_lowercase()).filter(|x| !x.is_empty()).collect());
    indexer
        .concurrent_pipeline(
            UnxvEventsHandler::new(Some(vec![
                "dex",
                "futures",
                "gas_futures",
                "lending",
                "options",
                "perpetuals",
                "rewards",
                "staking",
                "unxv",
                "usdu",
                "xfutures",
                "xoptions",
                "xperps",
            ]), package_allowlist),
            Default::default(),
        )
        .await?;

    let h_indexer = indexer.run().await?;
    let h_metrics = metrics.run().await?;

    let _ = h_indexer.await;
    cancel.cancel();
    let _ = h_metrics.await;
    Ok(())
}

