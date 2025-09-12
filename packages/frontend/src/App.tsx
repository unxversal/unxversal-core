import { useEffect, useState } from 'react'
import './App.css'
import { createSuiClient, defaultRpc } from './lib/network'
import { startTrackers } from './lib/indexer'
import { loadSettings } from './lib/settings.config'
import { allProtocolTrackers } from './protocols'
import { startPriceFeeds } from './lib/switchboard'
import { startDefaultMarketWatcher } from './lib/marketWatcher'
import { useCurrentAccount } from '@mysten/dapp-kit'
import styles from './components/AppShell.module.css'
import Navbar from './components/Layout/Navbar'
import { StakingWrapper } from './newui/staking'
import { DexScreen } from './components/dex/DexScreen'
import { GasFuturesScreen } from './components/gas-futures/GasFuturesScreen'
import { FuturesScreen } from './components/futures/FuturesScreen'
import { PerpsScreen } from './components/perps/PerpsScreen'
import { LendingScreen } from './components/lending/LendingScreen'
import { StakingScreen } from './components/staking/StakingScreen'
import { SettingsScreen } from './components/SettingsScreen'
import { OptionsScreen } from './components/options/OptionsScreen'
import { BridgeScreen } from './components/bridge/BridgeScreen'
import { SwapScreen } from './components/swap'
import { createMockOptionsProvider } from './components/options/providers/mock'

type View = 'dex' | 'gas' | 'lending' | 'staking' | 'faucet' | 'options' | 'futures' | 'perps' | 'bridge' | 'swap' | 'settings'

function App() {
  const [network] = useState<'testnet' | 'mainnet'>(loadSettings().network)
  const [started, setStarted] = useState(false)
  const [surgeReady, setSurgeReady] = useState(false)
  const [view, setView] = useState<View>('options')
  const account = useCurrentAccount()
  const [useNewUi, setUseNewUi] = useState(false)
  const [useSampleData, setUseSampleData] = useState(true)

  // Protocol status tracking
  const [protocolStatus, setProtocolStatus] = useState({
    options: false,
    futures: false,
    perps: false,
    lending: false,
    staking: false,
    dex: false
  })

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
    
    // Update protocol status based on available trackers
    const newStatus = {
      options: indexers.options && trackers.some(t => t.id.includes(':options')),
      futures: indexers.futures && trackers.some(t => t.id.includes(':futures')),
      perps: indexers.perps && trackers.some(t => t.id.includes(':perpetuals')),
      lending: indexers.lending && trackers.some(t => t.id.includes(':lending')),
      staking: indexers.staking && trackers.some(t => t.id.includes(':staking')),
      dex: indexers.dex && trackers.some(t => t.id.startsWith('dex:'))
    }
    setProtocolStatus(newStatus)
    
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
      case 'bridge':
        document.title = 'Unxversal Bridge';
        break;
      case 'swap':
        document.title = 'Unxversal Swap';
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
    <div className={view === 'dex' || view === 'gas' || view === 'futures' || view === 'perps' || view === 'bridge' || view === 'swap' ? styles.appRootDex : styles.appRoot}>
      <Navbar
        view={view}
        setView={setView}
        useNewUi={useNewUi}
        setUseNewUi={setUseNewUi}
        useSampleData={useSampleData}
        setUseSampleData={setUseSampleData}
      />
      <main className={view === 'dex' || view === 'gas' || view === 'futures' || view === 'perps' || view === 'lending' || view === 'staking' || view === 'swap' ? styles.mainDex : styles.main}>
        {view === 'dex' && <DexScreen started={started} surgeReady={surgeReady} network={network} protocolStatus={protocolStatus} />}
        {view === 'gas' && <GasFuturesScreen started={started} surgeReady={surgeReady} network={network} protocolStatus={protocolStatus} />}
        {view === 'lending' && <LendingScreen started={started} network={network} protocolStatus={protocolStatus} />}
        {view === 'staking' && (
          useNewUi
            ? <StakingWrapper useSampleData={useSampleData} />
            : <StakingScreen started={started} network={network} protocolStatus={protocolStatus} />
        )}
        {view === 'futures' && <FuturesScreen started={started} surgeReady={surgeReady} network={network} protocolStatus={protocolStatus} />}
        {view === 'perps' && <PerpsScreen started={started} surgeReady={surgeReady} network={network} protocolStatus={protocolStatus} />}
        {view === 'bridge' && <BridgeScreen network={network} protocolStatus={protocolStatus} />}
        {view === 'swap' && <SwapScreen network={network} />}
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
      {!(view === 'dex' || view === 'gas' || view === 'futures' || view === 'lending' || view === 'staking' || view === 'perps' || view === 'bridge' || view === 'swap') && (
        <footer className={styles.footer}>
          <div className={styles.statusBadges}>
            <div className={`${styles.badge} ${protocolStatus.options ? styles.connected : styles.disconnected}`}>
              <div className={`${styles.dot} ${protocolStatus.options ? styles.dotConnected : styles.dotDisconnected}`}></div>
              <span>Options</span>
            </div>
            
            <div className={`${styles.badge} ${protocolStatus.futures ? styles.connected : styles.disconnected}`}>
              <div className={`${styles.dot} ${protocolStatus.futures ? styles.dotConnected : styles.dotDisconnected}`}></div>
              <span>Futures</span>
            </div>
            
            <div className={`${styles.badge} ${protocolStatus.perps ? styles.connected : styles.disconnected}`}>
              <div className={`${styles.dot} ${protocolStatus.perps ? styles.dotConnected : styles.dotDisconnected}`}></div>
              <span>Perps</span>
            </div>
            
            <div className={`${styles.badge} ${protocolStatus.lending ? styles.connected : styles.disconnected}`}>
              <div className={`${styles.dot} ${protocolStatus.lending ? styles.dotConnected : styles.dotDisconnected}`}></div>
              <span>Lending</span>
            </div>
            
            <div className={`${styles.badge} ${protocolStatus.staking ? styles.connected : styles.disconnected}`}>
              <div className={`${styles.dot} ${protocolStatus.staking ? styles.dotConnected : styles.dotDisconnected}`}></div>
              <span>Staking</span>
            </div>
            
            <div className={`${styles.badge} ${protocolStatus.dex ? styles.connected : styles.disconnected}`}>
              <div className={`${styles.dot} ${protocolStatus.dex ? styles.dotConnected : styles.dotDisconnected}`}></div>
              <span>DEX</span>
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
