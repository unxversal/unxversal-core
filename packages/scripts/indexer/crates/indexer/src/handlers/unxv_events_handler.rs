use crate::handlers::try_extract_move_call_package;
use async_trait::async_trait;
use diesel_async::RunQueryDsl;
use std::collections::HashSet;
use std::sync::Arc;
use sui_indexer_alt_framework::pipeline::concurrent::Handler;
use sui_indexer_alt_framework::pipeline::Processor;
use sui_pg_db::{Connection, Db};
use sui_types::full_checkpoint_content::CheckpointData;
use tracing::debug;

use unxv_schema::models::UnxvEvent;
use unxv_schema::schema::unxv_events;

/// Generic Unxversal event catcher. Inserts raw events for modules in the
/// unxversal package family (modules: futures, gas_futures, perpetuals, x* variants, staking, lending, rewards, dex, options).
pub struct UnxvEventsHandler {
    /// Lowercased module names to accept (e.g. "futures", "perpetuals"). Empty => accept all modules under unxversal.
    modules_filter: Option<HashSet<String>>,
}

impl UnxvEventsHandler {
    pub fn new(modules_filter: Option<Vec<&str>>) -> Self {
        let modules_filter = modules_filter.map(|v| v.into_iter().map(|s| s.to_ascii_lowercase()).collect());
        Self { modules_filter }
    }

    fn allow_module(&self, module: &str) -> bool {
        match &self.modules_filter {
            None => true,
            Some(set) => set.contains(&module.to_ascii_lowercase()),
        }
    }
}

impl Processor for UnxvEventsHandler {
    const NAME: &'static str = "unxv_events";
    type Value = UnxvEvent;

    fn process(&self, checkpoint: &Arc<CheckpointData>) -> anyhow::Result<Vec<Self::Value>> {
        let mut out = Vec::new();
        for tx in &checkpoint.transactions {
            let Some(events) = &tx.events else { continue; };
            let package = try_extract_move_call_package(tx).unwrap_or_default();
            let checkpoint_timestamp_ms = checkpoint.checkpoint_summary.timestamp_ms as i64;
            let checkpoint_no = checkpoint.checkpoint_summary.sequence_number as i64;
            let digest = tx.transaction.digest().to_string();

            for (idx, ev) in events.data.iter().enumerate() {
                let type_tag = &ev.type_;
                let module_name = type_tag.module.to_string();
                let struct_name = type_tag.name.to_string();
                if !self.allow_module(&module_name) { continue; }

                let type_params = serde_json::json!(type_tag.type_params.iter().map(|t| t.to_string()).collect::<Vec<_>>());
                let event_digest = format!("{digest}{idx}");
                let row = UnxvEvent {
                    event_digest,
                    digest: digest.clone(),
                    sender: tx.transaction.sender_address().to_string(),
                    checkpoint: checkpoint_no,
                    checkpoint_timestamp_ms,
                    package: package.clone(),
                    module: module_name,
                    event_type: struct_name,
                    type_params,
                    contents_bcs: ev.contents.clone(),
                };
                debug!("Observed Unxv event {:?}", row);
                out.push(row);
            }
        }
        Ok(out)
    }
}

#[async_trait]
impl Handler for UnxvEventsHandler {
    type Store = Db;

    async fn commit<'a>(values: &[Self::Value], conn: &mut Connection<'a>) -> anyhow::Result<usize> {
        Ok(diesel::insert_into(unxv_events::table)
            .values(values)
            .on_conflict_do_nothing()
            .execute(conn)
            .await?)
    }
}

