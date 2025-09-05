import { useEffect, useState } from 'react'
import './App.css'
import { SuiClientProvider, WalletProvider, makeDappNetworks } from './lib/wallet'
import { ConnectButton } from '@mysten/dapp-kit'
import { createSuiClient, defaultRpc } from './lib/network'
import { startTrackers } from './lib/indexer'
import { db } from './lib/storage'
import { getContracts } from './lib/env'
import { allProtocolTrackers } from './protocols'
import { KeeperManager } from './strategies/keeperManager.ts'
import { buildKeeperFromStrategy } from './strategies/factory.ts'
import { SuiClient } from '@mysten/sui/client'
import { Transaction } from '@mysten/sui/transactions'
import { initSurgeFromSettings } from './lib/switchboard'
import { useCurrentAccount, useSignAndExecuteTransaction } from '@mysten/dapp-kit'

function App() {
  const [network, setNetwork] = useState<'testnet' | 'mainnet'>('testnet')
  const [started, setStarted] = useState(false)
  const [surgeReady, setSurgeReady] = useState(false)
  const { networkConfig } = makeDappNetworks()
  const account = useCurrentAccount()
  const { mutateAsync: signAndExecute } = useSignAndExecuteTransaction()

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

  // Switchboard init from stored settings
  useEffect(() => {
    if (surgeReady) return
    initSurgeFromSettings().then(() => setSurgeReady(true)).catch(() => {})
  }, [surgeReady])

  return (
    <SuiClientProvider networks={networkConfig} network={network} onNetworkChange={(n) => setNetwork(n as 'testnet' | 'mainnet')}>
      <WalletProvider>
        <div style={{ padding: 16 }}>
          <h2>Unxversal</h2>
          <div style={{ display: 'flex', gap: 8 }}>
            <button onClick={() => setNetwork('testnet')}>Testnet</button>
            <button onClick={() => setNetwork('mainnet')}>Mainnet</button>
            <ConnectButton />
            <button onClick={async () => {
              const latest = await db.events.orderBy('tsMs').reverse().limit(5).toArray()
              console.log('Latest events', latest)
              alert(`Indexed rows: ${latest.length}`)
            }}>Peek events</button>
          </div>
          <p style={{ opacity: 0.7 }}>Polling on {network}. Set VITE_UNXV_PKG in .env for indexing filters.</p>
        </div>
      </WalletProvider>
    </SuiClientProvider>
  )
}

export default App
