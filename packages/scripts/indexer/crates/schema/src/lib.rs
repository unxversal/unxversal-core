use diesel_migrations::{embed_migrations, EmbeddedMigrations};

pub mod schema;
pub mod models;

pub const MIGRATIONS: EmbeddedMigrations = embed_migrations!("migrations");

