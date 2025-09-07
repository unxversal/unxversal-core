import { useEffect, useState } from 'react'
import './App.css'
import { ConnectButton, useSuiClientContext } from '@mysten/dapp-kit'
import { createSuiClient, defaultRpc } from './lib/network'
import { startTrackers } from './lib/indexer'
import { loadSettings, saveSettings } from './lib/settings.config'
import { allProtocolTrackers } from './protocols'
import { KeeperManager } from './strategies/keeperManager.ts'
import { buildKeeperFromStrategy } from './strategies/factory.ts'
import { SuiClient } from '@mysten/sui/client'
import { Transaction } from '@mysten/sui/transactions'
import { startPriceFeeds } from './lib/switchboard'
import { startDefaultMarketWatcher } from './lib/marketWatcher'
import { useCurrentAccount, useSignAndExecuteTransaction } from '@mysten/dapp-kit'
import styles from './components/AppShell.module.css'
import { BarChart3, Factory, Fuel, Gauge, Home, Landmark, Settings, Wifi, WifiOff, Activity, Pause } from 'lucide-react'
import { DexScreen } from './components/dex/DexScreen'
import { GasFuturesScreen } from './components/gas/GasFuturesScreen'
import { LendingScreen } from './components/lending/LendingScreen'
import { SettingsScreen } from './components/SettingsScreen'

type View = 'dex' | 'gas' | 'lending' | 'staking' | 'faucet' | 'options' | 'futures' | 'perps' | 'builder' | 'settings'

function App() {
  const [network, setNetwork] = useState<'testnet' | 'mainnet'>(loadSettings().network)
  const [started, setStarted] = useState(false)
  const [surgeReady, setSurgeReady] = useState(false)
  const [view, setView] = useState<View>('dex')
  const account = useCurrentAccount()
  const { mutateAsync: signAndExecute } = useSignAndExecuteTransaction()
  const { selectNetwork } = useSuiClientContext()

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

  // Auto-resume ephemeral keepers in this tab (leader) after wallet connects
  useEffect(() => {
    const { keepers } = loadSettings()
    if (!keepers.autoResume) return
    
    // crude leader election using BroadcastChannel
    const bc = new BroadcastChannel('uxv-keepers')
    let isLeader = true
    let pong = false
    bc.onmessage = (ev) => { if (ev.data === 'pong') pong = true }
    bc.postMessage('ping')
    setTimeout(async () => {
      if (pong) { isLeader = false }
      if (!isLeader || !account?.address) return
      const rpc = defaultRpc(network)
      const sui = createSuiClient(rpc)
      const exec = async (tx: Transaction) => { await signAndExecute({ transaction: tx }) }
      const sender = account.address
      const km = new KeeperManager()
      await km.autoResume((cfg) => buildKeeperFromStrategy(sui as unknown as SuiClient, sender, exec, cfg)!)
    }, 300)
    return () => { bc.close() }
  }, [network, account?.address, signAndExecute])

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

  const handleNetworkChange = (newNetwork: 'testnet' | 'mainnet') => {
    setNetwork(newNetwork)
    selectNetwork(newNetwork)
    setStarted(false) // Reset started state to reinitialize trackers
    const s = loadSettings();
    saveSettings({ ...s, network: newNetwork })
    }

  // Update document title based on current view
  useEffect(() => {
    switch (view) {
      case 'dex':
        // DEX screen handles its own title with price/pair info: PRICE | PAIR | Unxversal DEX
        break;
      case 'gas':
        // TODO: Future implementation should show: PRICE | MARKET | Unxversal Gas Futures
        // For now, show generic protocol name
        document.title = 'Unxversal Gas Futures';
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
      case 'builder':
        document.title = 'Unxversal Builder';
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
    <div className={view === 'dex' ? styles.appRootDex : styles.appRoot}>
      <header className={styles.header}>
        <div className={styles.brand}>
        <img src="/whitetransparentunxvdolphin.png" alt="Unxversal" style={{ width: 24, height: 24 }} />
        {/* <img src="/unxvdolphintarget.png" alt="Unxversal" style={{ width: 24, height: 24 }} /> */}
        <span>Unxversal</span>
        </div>
        <nav className={styles.nav}>
          <button className={view==='dex'?styles.active:''} onClick={() => setView('dex')}><Home size={16}/> DEX</button>
          <button className={view==='gas'?styles.active:''} onClick={() => setView('gas')}><Fuel size={16}/> Gas Futures</button>
          <button className={view==='lending'?styles.active:''} onClick={() => setView('lending')}><Landmark size={16}/> Lending</button>
          <button disabled title="Coming soon"><BarChart3 size={16}/> Options</button>
          <button disabled title="Coming soon"><Gauge size={16}/> Perps</button>
          <button disabled title="Coming soon"><Factory size={16}/> Builder</button>
          <button className={view==='settings'?styles.active:''} onClick={() => setView('settings')}><Settings size={16}/> Settings</button>
        </nav>
        <div className={styles.tools}>
          <div className={styles.netToggle}>
            <button className={network==='testnet'?styles.active:''} onClick={() => handleNetworkChange('testnet')}>Testnet</button>
            <button className={network==='mainnet'?styles.active:''} onClick={() => handleNetworkChange('mainnet')}>Mainnet</button>
          </div>
          <ConnectButton />
        </div>
      </header>
      <main className={view === 'dex' ? styles.mainDex : styles.main}>
        {view === 'dex' && <DexScreen started={started} surgeReady={surgeReady} network={network} />}
        {view === 'gas' && <GasFuturesScreen />}
        {view === 'lending' && <LendingScreen />}
        {view === 'settings' && <SettingsScreen onClose={() => setView('dex')} />}
      </main>
      {view !== 'dex' && (
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
