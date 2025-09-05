import type { SuiClient } from '@mysten/sui/client';

export type RiskCaps = {
  max_order_size_base: number;
  max_inventory_tilt_bps: number;
  min_distance_bps: number;
  paused: boolean;
};

export async function readRiskCaps(client: SuiClient, pkg: string, vaultId: string): Promise<RiskCaps | null> {
  try {
    const res = await client.getObject({ id: vaultId, options: { showContent: true } });
    const fields = (res.data as any)?.content?.fields;
    if (!fields) return null;
    const caps = fields.risk_caps?.fields;
    if (!caps) return null;
    return {
      max_order_size_base: Number(caps.max_order_size_base),
      max_inventory_tilt_bps: Number(caps.max_inventory_tilt_bps),
      min_distance_bps: Number(caps.min_distance_bps),
      paused: Boolean(caps.paused),
    };
  } catch {
    return null;
  }
}

export function clampOrderQtyByCaps(qty: bigint, caps: RiskCaps | null): bigint {
  if (!caps || !caps.max_order_size_base || caps.max_order_size_base <= 0) return qty;
  const mx = BigInt(Math.max(0, caps.max_order_size_base));
  return qty > mx ? mx : qty;
}


