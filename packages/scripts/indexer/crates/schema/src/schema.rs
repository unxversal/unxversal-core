// @generated automatically by Diesel CLI.
diesel::table! {
    unxv_events (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> BigInt,
        checkpoint_timestamp_ms -> BigInt,
        package -> Text,
        module -> Text,
        event_type -> Text,
        type_params -> Jsonb,
        contents_bcs -> Bytea,
    }
}

