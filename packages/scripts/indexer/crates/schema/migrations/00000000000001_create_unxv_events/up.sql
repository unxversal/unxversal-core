CREATE TABLE IF NOT EXISTS unxv_events (
    event_digest TEXT PRIMARY KEY,
    digest TEXT NOT NULL,
    sender TEXT NOT NULL,
    checkpoint BIGINT NOT NULL,
    checkpoint_timestamp_ms BIGINT NOT NULL,
    package TEXT NOT NULL,
    module TEXT NOT NULL,
    event_type TEXT NOT NULL,
    type_params JSONB NOT NULL,
    contents_bcs BYTEA NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_unxv_events_checkpoint ON unxv_events (checkpoint);
CREATE INDEX IF NOT EXISTS idx_unxv_events_event_type ON unxv_events (event_type);
CREATE INDEX IF NOT EXISTS idx_unxv_events_module ON unxv_events (module);
CREATE INDEX IF NOT EXISTS idx_unxv_events_sender ON unxv_events (sender);

