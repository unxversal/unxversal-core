// Lending API types

export interface TxOkResponse { ok: true; txDigest: string }

// Queries
export interface PoolsQuery { asset?: string; minTs?: string; maxTs?: string; limit?: string }
export interface AccountBalancesQuery { asset?: string }
export interface LendFeesQuery { asset?: string; minTs?: string; maxTs?: string; limit?: string }

// Rows
export interface LendingPoolRow { pool_id: string; asset: string; total_supply: number | null; total_borrows: number | null; total_reserves: number | null; last_update_ms: number | null }
export interface LendingBalanceRow { account_id: string; asset: string; supply_scaled: number; borrow_scaled: number }
export interface LendingFeeRow { tx_digest: string; event_seq: string; asset: string; amount: number; timestamp_ms: number }

// PTBs
export interface SupplyBody { poolId: string; coinId: string; amount: string | number | bigint }
export interface WithdrawLendBody { poolId: string; amount: string | number | bigint; oracleRegistryId: string; oracleConfigId: string; priceSelfAggId: string; symbols: string[]; pricesSetId: string; supplyIdx: (string | number | bigint)[]; borrowIdx: (string | number | bigint)[] }
export interface BorrowBody { poolId: string; amount: string | number | bigint; oracleRegistryId: string; oracleConfigId: string; priceDebtAggId: string; symbols: string[]; pricesSetId: string; supplyIdx: (string | number | bigint)[]; borrowIdx: (string | number | bigint)[] }
export interface RepayBody { poolId: string; paymentCoinId: string }

export interface LendingPoolDetailResponse { ok: boolean; pool: LendingPoolRow; totals: { totalSupplyScaled: number; totalBorrowScaled: number } }


