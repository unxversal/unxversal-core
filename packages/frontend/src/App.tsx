import { useEffect, useState } from 'react'
import './App.css'
import { ConnectButton } from '@mysten/dapp-kit'
import { createSuiClient, defaultRpc } from './lib/network'
import { startTrackers } from './lib/indexer'
import { loadSettings } from './lib/settings.config'
import { allProtocolTrackers } from './protocols'
import { startPriceFeeds } from './lib/switchboard'
import { startDefaultMarketWatcher } from './lib/marketWatcher'
import { useCurrentAccount } from '@mysten/dapp-kit'
import styles from './components/AppShell.module.css'
import { Wifi, WifiOff, Activity, Pause } from 'lucide-react'
import { DexScreen } from './components/dex/DexScreen'
import { GasFuturesScreen } from './components/gas-futures/GasFuturesScreen'
import { FuturesScreen } from './components/futures/FuturesScreen'
import { PerpsScreen } from './components/perps/PerpsScreen'
import { LendingScreen } from './components/lending/LendingScreen'
import { SettingsScreen } from './components/SettingsScreen'
import { OptionsScreen } from './components/options/OptionsScreen'
import { createMockOptionsProvider } from './components/options/providers/mock'

type View = 'dex' | 'gas' | 'lending' | 'staking' | 'faucet' | 'options' | 'futures' | 'perps' | 'settings'

function App() {
  const [network] = useState<'testnet' | 'mainnet'>(loadSettings().network)
  const [started, setStarted] = useState(false)
  const [surgeReady, setSurgeReady] = useState(false)
  const [view, setView] = useState<View>('dex')
  const account = useCurrentAccount()

  useEffect(() => {
    if (started) return
    const rpc = defaultRpc(network)
    const client = createSuiClient(rpc)
    const { contracts, indexers } = loadSettings()
    if (!contracts.pkgUnxversal) return
    const trackers = allProtocolTrackers(contracts.pkgUnxversal)
      .filter(t =>
        (t.id.startsWith('dex:') && indexers.dex) ||
        (t.id.includes(':lending') && indexers.lending) ||
        (t.id.includes(':options') && indexers.options) ||
        (t.id.includes(':futures') && indexers.futures) ||
        (t.id.includes(':gas-futures') && indexers.gasFutures) ||
        (t.id.includes(':perpetuals') && indexers.perps) ||
        (t.id.includes(':staking') && indexers.staking)
      )
      .map((t) => ({ ...t, id: `${t.id}-${network}` }))
    if (trackers.length === 0) return
    setStarted(true)
    startTrackers(client, trackers).catch(() => {})
  }, [network, started])


  // Start price feeds when wallet connects
  useEffect(() => {
    const { indexers } = loadSettings()
    if (!account?.address || surgeReady || !indexers.prices) return
    startPriceFeeds().then(() => setSurgeReady(true)).catch(() => {})
  }, [account?.address, surgeReady])

  // Autostart market watchers for base pools on connect
  useEffect(() => {
    if (!account?.address) return
    const watcher = startDefaultMarketWatcher()
    return () => { watcher?.stop() }
  }, [account?.address])

  // Update document title based on current view
  useEffect(() => {
    switch (view) {
      case 'dex':
        // DEX screen handles its own title with price/pair info: PRICE | PAIR | Unxversal DEX
        break;
      case 'gas':
        // TODO: Future implementation should show: PRICE | MARKET | Unxversal MIST Futures
        // For now, show generic protocol name
        document.title = 'Unxversal MIST Futures';
        break;
      case 'lending':
        // TODO: Future implementation could show: SELECTED_POOL | STAKED_AMOUNT | Unxversal Lending
        // For now, show generic protocol name
        document.title = 'Unxversal Lending';
        break;
      case 'staking':
        // TODO: Future implementation could show: STAKED_AMOUNT | APY | Unxversal Staking
        document.title = 'Unxversal Staking';
        break;
      case 'faucet':
        document.title = 'Unxversal Faucet';
        break;
      case 'options':
        // TODO: Future implementation should show: PRICE | MARKET | Unxversal Options
        document.title = 'Unxversal Options';
        break;
      case 'futures':
        // TODO: Future implementation should show: PRICE | MARKET | Unxversal Futures
        document.title = 'Unxversal Futures';
        break;
      case 'perps':
        // TODO: Future implementation should show: PRICE | MARKET | Unxversal Perps
        document.title = 'Unxversal Perps';
        break;
      case 'settings':
        document.title = 'Unxversal Settings';
        break;
      default:
        document.title = 'Unxversal';
        break;
    }
  }, [view]);
  
  return (
    <div className={view === 'dex' || view === 'gas' || view === 'futures' || view === 'perps' ? styles.appRootDex : styles.appRoot}>
      <header className={styles.header}>
        <div className={styles.brand}>
          <img src="/whitetransparentunxvdolphin.png" alt="Unxversal" style={{ width: 32, height: 32 }} />
          <span>Unxversal</span>
        </div>
        <nav className={styles.nav}>
          <span className={view==='dex'?styles.active:''} onClick={() => setView('dex')}>DEX</span>
          <span className={view==='gas'?styles.active:''} onClick={() => setView('gas')}>MIST Futures</span>
          <span className={view==='lending'?styles.active:''} onClick={() => setView('lending')}>Lending</span>
          <span className={view==='options'?styles.active:''} onClick={() => setView('options')}>Options</span>
          <span className={view==='futures'?styles.active:''} onClick={() => setView('futures')}>Futures</span>
          <span className={view==='perps'?styles.active:''} onClick={() => setView('perps')}>Perps</span>
          <span className={view==='settings'?styles.active:''} onClick={() => setView('settings')}>Settings</span>
        </nav>
        <div className={styles.tools}>
          <ConnectButton />
        </div>
      </header>
      <main className={view === 'dex' || view === 'gas' || view === 'futures' || view === 'perps' ? styles.mainDex : styles.main}>
        {view === 'dex' && <DexScreen started={started} surgeReady={surgeReady} network={network} />}
        {view === 'gas' && <GasFuturesScreen started={started} surgeReady={surgeReady} network={network} />}
        {view === 'lending' && <LendingScreen />}
        {view === 'futures' && <FuturesScreen started={started} surgeReady={surgeReady} network={network} />}
        {view === 'perps' && <PerpsScreen started={started} surgeReady={surgeReady} network={network} />}
        {view === 'options' && (
          <OptionsScreen
            started={started}
            surgeReady={surgeReady}
            network={network}
            marketLabel={'Options'}
            symbol={'MIST'}
            quoteSymbol={'USDC'}
            dataProvider={createMockOptionsProvider()}
            panelProvider={{
              async submitOrder() {
                await new Promise(r => setTimeout(r, 300));
              }
            }}
          />
        )}
        {view === 'settings' && <SettingsScreen onClose={() => setView('dex')} />}
      </main>
      {view !== 'dex' && view !== 'gas' && view !== 'futures' && view !== 'perps' && (
        <footer className={styles.footer}>
          <div className={styles.statusBadges}>
            <div className={`${styles.badge} ${account?.address ? styles.connected : styles.disconnected}`}>
              {account?.address ? <Wifi size={10} /> : <WifiOff size={10} />}
              <span>{account?.address ? 'Online' : 'Offline'}</span>
            </div>
            
            <div className={`${styles.badge} ${started ? styles.active : styles.inactive}`}>
              {started ? <Activity size={10} /> : <Pause size={10} />}
              <span>IDX</span>
            </div>
            
            <div className={`${styles.badge} ${surgeReady ? styles.active : styles.inactive}`}>
              {surgeReady ? <Activity size={10} /> : <Pause size={10} />}
              <span>PRC</span>
            </div>
          </div>
          
          <div className={styles.networkBadge}>
            <span>{network.toUpperCase()}</span>
          </div>
        </footer>
      )}
    </div>
  )
}

export default App
