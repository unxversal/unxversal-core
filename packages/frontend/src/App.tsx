import { useEffect, useState } from 'react'
import './App.css'
import { ConnectButton, useSuiClientContext } from '@mysten/dapp-kit'
import { createSuiClient, defaultRpc } from './lib/network'
import { startTrackers } from './lib/indexer'
import { db } from './lib/storage'
import { getContracts } from './lib/env'
import { allProtocolTrackers } from './protocols'
import { KeeperManager } from './strategies/keeperManager.ts'
import { buildKeeperFromStrategy } from './strategies/factory.ts'
import { SuiClient } from '@mysten/sui/client'
import { Transaction } from '@mysten/sui/transactions'
import { startPriceFeeds } from './lib/switchboard'
import { useCurrentAccount, useSignAndExecuteTransaction } from '@mysten/dapp-kit'

function App() {
  const [network, setNetwork] = useState<'testnet' | 'mainnet'>('testnet')
  const [started, setStarted] = useState(false)
  const [surgeReady, setSurgeReady] = useState(false)
  const account = useCurrentAccount()
  const { mutateAsync: signAndExecute } = useSignAndExecuteTransaction()
  const { selectNetwork } = useSuiClientContext()

  useEffect(() => {
    if (started) return
    const rpc = defaultRpc(network)
    const client = createSuiClient(rpc)
    const { pkgUnxversal } = getContracts()
    if (!pkgUnxversal) return
    const trackers = allProtocolTrackers(pkgUnxversal).map((t) => ({ ...t, id: `${t.id}-${network}` }))
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
  }

  return (
    <div style={{ padding: 16 }}>
      <h2>Unxversal</h2>
      <div style={{ display: 'flex', gap: 8 }}>
        <button 
          onClick={() => handleNetworkChange('testnet')}
          style={{ backgroundColor: network === 'testnet' ? '#007bff' : undefined, color: network === 'testnet' ? 'white' : undefined }}
        >
          Testnet
        </button>
        <button 
          onClick={() => handleNetworkChange('mainnet')}
          style={{ backgroundColor: network === 'mainnet' ? '#007bff' : undefined, color: network === 'mainnet' ? 'white' : undefined }}
        >
          Mainnet
        </button>
        <ConnectButton />
        <button onClick={async () => {
          const latest = await db.events.orderBy('tsMs').reverse().limit(5).toArray()
          console.log('Latest events', latest)
          alert(`Indexed rows: ${latest.length}`)
        }}>Peek events</button>
      </div>
      <p style={{ opacity: 0.7 }}>Polling on {network}. Set VITE_UNXV_PKG in .env for indexing filters.</p>
    </div>
  )
}

export default App
