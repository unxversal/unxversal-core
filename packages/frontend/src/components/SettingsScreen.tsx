import { useEffect, useState } from 'react';
import styles from './SettingsScreen.module.css';
import { loadSettings, saveSettings, type AppSettings } from '../lib/settings.config';
import { MARKETS, type MarketCategory } from '../lib/markets';

export function SettingsScreen({ onClose }: { onClose?: () => void }) {
  const [s, setS] = useState<AppSettings>(loadSettings());

  useEffect(() => { saveSettings(s); }, [s]);

  return (
    <div className={styles.root}>
      <div className={styles.section}>
        <div className={styles.title}>Indexers</div>
        <div className={styles.grid2}>
          {Object.entries(s.indexers).map(([k, v]) => (
            <label key={k} className={styles.switchRow}>
              <input type="checkbox" checked={v} onChange={(e) => setS({ ...s, indexers: { ...s.indexers, [k]: e.target.checked } as any })} />
              <span>{k}</span>
            </label>
          ))}
        </div>
      </div>

      <div className={styles.section}>
        <div className={styles.title}>Markets</div>
        <div className={styles.row}>
          <label>Autostart on connect</label>
          <label className={styles.switchRow}>
            <input type="checkbox" checked={s.markets.autostartOnConnect} onChange={(e)=>setS({ ...s, markets: { ...s.markets, autostartOnConnect: e.target.checked } })} />
            <span>Warm charts and orderbooks automatically</span>
          </label>
        </div>
        <div className={styles.title}>Watchlist</div>
        <div className={styles.grid2}>
          {Object.entries(MARKETS).map(([cat, pools]) => (
            <div key={cat} className={styles.marketGroup}>
              <div className={styles.marketGroupTitle}>{(cat as MarketCategory).toUpperCase()}</div>
              <div className={styles.marketList}>
                {pools.map((p)=>{
                  const checked = s.markets.watchlist.includes(p);
                  return (
                    <label key={p} className={styles.switchRow}>
                      <input type="checkbox" checked={checked} onChange={(e)=>{
                        const next = e.target.checked
                          ? Array.from(new Set([...s.markets.watchlist, p]))
                          : s.markets.watchlist.filter(x=>x!==p);
                        setS({ ...s, markets: { ...s.markets, watchlist: next } })
                      }} />
                      <span>{p}</span>
                    </label>
                  );
                })}
              </div>
            </div>
          ))}
        </div>
      </div>

      <div className={styles.section}>
        <div className={styles.title}>Keepers</div>
        <div className={styles.grid2}>
          <label className={styles.switchRow}>
            <input type="checkbox" checked={s.keepers.autoResume} onChange={(e) => setS({ ...s, keepers: { ...s.keepers, autoResume: e.target.checked } })} />
            <span>Auto-resume in leader tab</span>
          </label>
        </div>
      </div>
      <div className={styles.section}>
        <div className={styles.title}>Network</div>
        <div className={styles.row}>
          <label>Network</label>
          <select value={s.network} onChange={(e) => setS({ ...s, network: e.target.value as any })}>
            <option value="testnet">Testnet</option>
            <option value="mainnet">Mainnet</option>
          </select>
        </div>
      </div>

      <div className={styles.section}>
        <div className={styles.title}>DEX</div>
        <div className={styles.grid}>
          <label>Indexer URL</label>
          <input value={s.dex.deepbookIndexerUrl} onChange={(e) => setS({ ...s, dex: { ...s.dex, deepbookIndexerUrl: e.target.value } })} />

          <label>Pool Id</label>
          <input value={s.dex.poolId} onChange={(e) => setS({ ...s, dex: { ...s.dex, poolId: e.target.value } })} />

          <label>Base Type</label>
          <input value={s.dex.baseType} onChange={(e) => setS({ ...s, dex: { ...s.dex, baseType: e.target.value } })} />

          <label>Quote Type</label>
          <input value={s.dex.quoteType} onChange={(e) => setS({ ...s, dex: { ...s.dex, quoteType: e.target.value } })} />

          <label>Balance Manager Id</label>
          <input value={s.dex.balanceManagerId} onChange={(e) => setS({ ...s, dex: { ...s.dex, balanceManagerId: e.target.value } })} />

          <label>Trade Proof Id</label>
          <input value={s.dex.tradeProofId} onChange={(e) => setS({ ...s, dex: { ...s.dex, tradeProofId: e.target.value } })} />

          <label>Fee Config Id</label>
          <input value={s.dex.feeConfigId} onChange={(e) => setS({ ...s, dex: { ...s.dex, feeConfigId: e.target.value } })} />

          <label>Fee Vault Id</label>
          <input value={s.dex.feeVaultId} onChange={(e) => setS({ ...s, dex: { ...s.dex, feeVaultId: e.target.value } })} />
        </div>
      </div>

      <div className={styles.section}>
        <div className={styles.title}>Contracts</div>
        <div className={styles.grid}>
          <label>Unxversal Package Id</label>
          <input value={s.contracts.pkgUnxversal} onChange={(e) => setS({ ...s, contracts: { ...s.contracts, pkgUnxversal: e.target.value } })} />

          <label>Deepbook Package Id</label>
          <input value={s.contracts.pkgDeepbook} onChange={(e) => setS({ ...s, contracts: { ...s.contracts, pkgDeepbook: e.target.value } })} />

          <label>UNXV Staking Pool Id</label>
          <input value={s.staking?.poolId ?? ''} onChange={(e) => setS({ ...s, staking: { ...(s.staking ?? { poolId: '' }), poolId: e.target.value } })} />
        </div>
      </div>

      <div className={styles.actions}>
        <button onClick={() => { saveSettings(s); onClose?.(); }}>Close</button>
      </div>
    </div>
  );
}

