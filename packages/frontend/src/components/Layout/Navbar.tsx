import { ConnectButton } from '@mysten/dapp-kit'
import styles from '../AppShell.module.css'

export function Navbar({
  view,
  setView,
  useNewUi,
  setUseNewUi,
  useSampleData,
  setUseSampleData,
}: {
  view: string;
  setView: (v: any) => void;
  useNewUi: boolean;
  setUseNewUi: (v: boolean) => void;
  useSampleData: boolean;
  setUseSampleData: (v: boolean) => void;
}) {
  return (
    <header className={styles.header}>
      <div className={styles.brand}>
        <img src="/whitetransparentunxvdolphin.png" alt="Unxversal" style={{ width: 32, height: 32 }} />
        <span>Unxversal</span>
      </div>
      <nav className={styles.nav}>
        <span className={view==='options'?styles.active:''} onClick={() => setView('options')}>Options</span>
        <span className={view==='gas'?styles.active:''} onClick={() => setView('gas')}>MIST Futures</span>
        <span className={view==='futures'?styles.active:''} onClick={() => setView('futures')}>Futures</span>
        <span className={view==='perps'?styles.active:''} onClick={() => setView('perps')}>Perps</span>
        <span className={view==='lending'?styles.active:''} onClick={() => setView('lending')}>Lending</span>
        <span className={view==='dex'?styles.active:''} onClick={() => setView('dex')}>DEX</span>
        <span className={view==='swap'?styles.active:''} onClick={() => setView('swap')}>Swap</span>
        <span className={view==='bridge'?styles.active:''} onClick={() => setView('bridge')}>Bridge</span>
        <span className={view==='staking'?styles.active:''} onClick={() => setView('staking')}>Staking</span>
        <span className={view==='settings'?styles.active:''} onClick={() => setView('settings')}>Settings</span>
      </nav>
      <div className={styles.tools}>
        <label style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
          <input type="checkbox" checked={useNewUi} onChange={(e) => setUseNewUi(e.target.checked)} />
          <span>Use new UI</span>
        </label>
        <label style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
          <input type="checkbox" checked={useSampleData} onChange={(e) => setUseSampleData(e.target.checked)} />
          <span>Use sample data</span>
        </label>
        <ConnectButton />
      </div>
    </header>
  )
}

export default Navbar


