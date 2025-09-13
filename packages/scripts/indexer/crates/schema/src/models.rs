use diesel::{Identifiable, Insertable, Queryable, Selectable};
use sui_field_count::FieldCount;
use serde::Serialize;

use crate::schema::unxv_events;

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, Serialize, FieldCount)]
#[diesel(table_name = unxv_events, primary_key(event_digest))]
pub struct UnxvEvent {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub module: String,
    pub event_type: String,
    pub type_params: serde_json::Value,
    pub contents_bcs: Vec<u8>,
}

