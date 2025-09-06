import { useEffect, useState } from 'react';
import styles from './SettingsScreen.module.css';
import { loadSettings, saveSettings, type AppSettings } from '../lib/settings.config';

export function SettingsScreen({ onClose }: { onClose?: () => void }) {
  const [s, setS] = useState<AppSettings>(loadSettings());

  useEffect(() => { saveSettings(s); }, [s]);

  return (
    <div className={styles.root}>
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
        </div>
      </div>

      <div className={styles.actions}>
        <button onClick={() => { saveSettings(s); onClose?.(); }}>Close</button>
      </div>
    </div>
  );
}

