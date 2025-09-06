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
import { useCurrentAccount, useSignAndExecuteTransaction } from '@mysten/dapp-kit'
import styles from './components/AppShell.module.css'
import { BarChart3, CandlestickChart, Factory, Fuel, Gauge, Home, Landmark, Settings } from 'lucide-react'
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
    const { contracts } = loadSettings()
    if (!contracts.pkgUnxversal) return
    const trackers = allProtocolTrackers(contracts.pkgUnxversal).map((t) => ({ ...t, id: `${t.id}-${network}` }))
    setStarted(true)
    startTrackers(client, trackers).catch(() => {})
  }, [network, started])

  // Auto-resume ephemeral keepers in this tab (leader) after wallet connects
  useEffect(() => {
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
    if (!account?.address || surgeReady) return
    startPriceFeeds().then(() => setSurgeReady(true)).catch(() => {})
  }, [account?.address, surgeReady])

  const handleNetworkChange = (newNetwork: 'testnet' | 'mainnet') => {
    setNetwork(newNetwork)
    selectNetwork(newNetwork)
    setStarted(false) // Reset started state to reinitialize trackers
    const s = loadSettings();
    saveSettings({ ...s, network: newNetwork })
  }

  return (
    <div className={styles.appRoot}>
      <header className={styles.header}>
        <div className={styles.brand}>
          <CandlestickChart size={18} />
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
      <main className={styles.main}>
        {view === 'dex' && <DexScreen />}
        {view === 'gas' && <GasFuturesScreen />}
        {view === 'lending' && <LendingScreen />}
        {view === 'settings' && <SettingsScreen onClose={() => setView('dex')} />}
      </main>
      <footer className={styles.footer}>
        <span>Polling on {network}. Set VITE_UNXV_PKG in .env for indexing filters.</span>
      </footer>
    </div>
  )
}

export default App
