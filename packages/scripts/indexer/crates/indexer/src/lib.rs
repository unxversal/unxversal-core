use move_core_types::language_storage::StructTag;
use url::Url;

pub mod handlers;

pub const MAINNET_REMOTE_STORE_URL: &str = "https://checkpoints.mainnet.sui.io";
pub const TESTNET_REMOTE_STORE_URL: &str = "https://checkpoints.testnet.sui.io";

#[derive(Debug, Clone, Copy, clap::ValueEnum)]
pub enum UnxvEnv {
    Mainnet,
    Testnet,
}

impl UnxvEnv {
    pub fn remote_store_url(&self) -> Url {
        let remote_store_url = match self {
            UnxvEnv::Mainnet => MAINNET_REMOTE_STORE_URL,
            UnxvEnv::Testnet => TESTNET_REMOTE_STORE_URL,
        };
        Url::parse(remote_store_url).unwrap()
    }
}

// Helper: parse a StructTag string into move_core_types::language_storage::StructTag
pub fn parse_struct_tag(tag: &str) -> StructTag {
    tag.parse().expect("valid struct tag")
}

