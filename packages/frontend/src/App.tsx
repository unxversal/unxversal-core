import { useEffect, useState } from 'react'
import './App.css'
import { SuiClientProvider, WalletProvider, makeDappNetworks } from './lib/wallet'
import { ConnectButton } from '@mysten/dapp-kit'
import { createSuiClient, defaultRpc } from './lib/network'
import { startTrackers } from './lib/indexer'
import { db } from './lib/storage'
import { getContracts } from './lib/env'
import { allProtocolTrackers } from './protocols'

function App() {
  const [network, setNetwork] = useState<'testnet' | 'mainnet'>('testnet')
  const [started, setStarted] = useState(false)
  const { networkConfig } = makeDappNetworks()

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
