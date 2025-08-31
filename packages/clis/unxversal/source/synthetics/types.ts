// Synthetics API types

export interface OkResponse { ok: true }
export interface TxOkResponse extends OkResponse { txDigest: string }

export type SuiEventsCursor = { txDigest: string; eventSeq: string } | null;

// Queries
export interface SynthOrdersQuery { symbol?: string; status?: string; owner?: string; minTs?: string; maxTs?: string; limit?: string }
export interface VaultsQuery { owner?: string; minTs?: string; maxTs?: string; limit?: string }
export interface LiquidationsQuery { vaultId?: string; symbol?: string; liquidator?: string; minTs?: string; maxTs?: string; limit?: string }
export interface FeesQuery { market?: string; payer?: string; reason?: string; minTs?: string; maxTs?: string; limit?: string }
export interface RebatesQuery { market?: string; taker?: string; maker?: string; minTs?: string; maxTs?: string; limit?: string }
export interface EventsQuery { type?: string; minTs?: string; maxTs?: string; limit?: string }
export interface CandlesQuery { bucket?: 'minute' | 'hour' | 'day'; limit?: string }

// Rows
export interface OrderRow { order_id: string; symbol: string; side: number; price: number; size: number; remaining: number; owner: string; created_at_ms: number; expiry_ms: number | null; status: string }
export interface VaultRow { vault_id: string; owner: string | null; last_update_ms: number | null; collateral: number }
export interface LiquidationRow { tx_digest: string; event_seq: string; vault_id: string; liquidator: string; liquidated_amount: number; collateral_seized: number; liquidation_penalty: number; synthetic_type: string; timestamp_ms: number }
export interface FeeRow { tx_digest: string; event_seq: string; amount: number; payer: string; market: string; reason: string; timestamp_ms: number }
export interface RebateRow { tx_digest: string; event_seq: string; amount: number; taker: string; maker: string; market: string; timestamp_ms: number }
export interface CandlePoint { t: string; v: number }
export type MarketsMap = Record<string, { marketId: string; escrowId: string }>;

// Keeper actions
export interface MatchMarketBody { maxSteps?: number; priceBandBps?: number }
export interface GcMarketBody { maxRemovals?: number }

// PTBs
export interface PlaceOrderBody {
  symbol: string;
  takerIsBid: boolean;
  price: string | number | bigint;
  size: string | number | bigint;
  expiryMs?: number;
  marketId: string;
  escrowId: string;
  registryId: string;
  vaultId: string;
  treasuryId: string;
}
export interface ModifyOrderBody { newQty: string | number | bigint; nowMs?: number; registryId: string; marketId: string; escrowId: string; vaultId: string }
export interface CancelOrderBody { marketId: string; escrowId: string; vaultId: string }
export interface ClaimOrderBody { registryId: string; marketId: string; escrowId: string; vaultId: string }

export interface CreateVaultBody { collateralCfgId: string; registryId: string }
export interface DepositBody { coinId: string }
export interface WithdrawBody { amount: string | number | bigint; symbol: string; priceObj: string }
export interface MintBody { symbol: string; amount: string | number | bigint; priceObj: string; unxvPriceObj: string; treasuryId: string; unxvCoins?: string[] }
export interface BurnBody extends MintBody {}
export interface LiquidateBody { symbol: string; repay?: string | number | bigint }

export interface VaultDetailDebt { symbol: string; units: number; priceMicro: number | null; valueMicro: number | null }
export interface VaultDetailResponse {
  ok: boolean;
  vault: { id: string; owner: string | null; last_update_ms: number; collateralUnits: number };
  debts: VaultDetailDebt[];
  totals: { totalDebtValueMicro: number };
  collateralPriceMicro: number | null;
  collateralValueMicro: number | null;
  ratio: number | null;
}

// Oracles
export interface OraclesMapResponse { ok: boolean; aggregators: Record<string, string> }
export interface OraclePriceResponse { ok: boolean; microPrice: number | null; minTimestampMs: number; maxTimestampMs: number }


