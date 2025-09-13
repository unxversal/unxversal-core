// Synthetic asset sets for xperps/xfutures/xoptions
// These are intentionally separate from the standard derivative symbol maps.
// No overlap with existing assets used by options/futures/perpetuals.

export const X_ASSET_SETS = {
  privateCos: [
    'xOPENAI',
    'xANTHROPIC',
    'xSPACEX',
    'xXAI',
    'xKRAKEN',
    'xANDURIL',
    'xCURSOR',
    'xSTRIPE',
    'xBREX',
    'xDISCORD',
    'xPOLYMARKET',
    'xKALSHI',
  ],
  gasPerps: [
    'xgETH', 'xgPOL', 'xgNEAR', 'xgSOL', 'xgARB', 'xgBASE', 'xgAVAX', 'xgBNB', 'xgOP',
  ],
} as const;


