use sui_types::full_checkpoint_content::CheckpointTransaction;
use sui_types::transaction::{Command, TransactionDataAPI};

pub mod unxv_events_handler;

pub(crate) fn try_extract_move_call_package(tx: &CheckpointTransaction) -> Option<String> {
    let txn_kind = tx.transaction.transaction_data().kind();
    let first_command = txn_kind.iter_commands().next()?;
    if let Command::MoveCall(move_call) = first_command {
        Some(move_call.package.to_string())
    } else {
        None
    }
}

