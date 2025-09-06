import { useEffect, useState } from 'react';
import './App.css';
import { useSuiClientContext } from '@mysten/dapp-kit';
import { createSuiClient, defaultRpc } from './lib/network';
import { startTrackers } from './lib/indexer';
import { db } from './lib/storage';
import { getContracts } from './lib/env';
import { allProtocolTrackers } from './protocols';
import { KeeperManager } from './strategies/keeperManager.ts';
import { buildKeeperFromStrategy } from './strategies/factory.ts';
import { SuiClient } from '@mysten/sui/client';
import { Transaction } from '@mysten/sui/transactions';
import { startPriceFeeds } from './lib/switchboard';
import { useCurrentAccount, useSignAndExecuteTransaction } from '@mysten/dapp-kit';
import { Layout } from './components/Layout/Layout';
import { DEX } from './components/DEX/DEX';
import { GasFutures } from './components/GasFutures/GasFutures';
import { Lending } from './components/Lending/Lending';

function App() {
  const [network, setNetwork] = useState<'testnet' | 'mainnet'>('testnet');
  const [started, setStarted] = useState(false);
  const [surgeReady, setSurgeReady] = useState(false);
  const [currentPage, setCurrentPage] = useState('dex');
  const account = useCurrentAccount();
  const { mutateAsync: signAndExecute } = useSignAndExecuteTransaction();
  const { selectNetwork } = useSuiClientContext();

  useEffect(() => {
    if (started) return;
    const rpc = defaultRpc(network);
    const client = createSuiClient(rpc);
    const { pkgUnxversal } = getContracts();
    if (!pkgUnxversal) return;
    const trackers = allProtocolTrackers(pkgUnxversal).map((t) => ({ ...t, id: `${t.id}-${network}` }));
    setStarted(true);
    startTrackers(client, trackers).catch(() => {});
  }, [network, started]);

  // Auto-resume ephemeral keepers in this tab (leader) after wallet connects
  useEffect(() => {
    // crude leader election using BroadcastChannel
    const bc = new BroadcastChannel('uxv-keepers');
    let isLeader = true;
    let pong = false;
    bc.onmessage = (ev) => { if (ev.data === 'pong') pong = true; };
    bc.postMessage('ping');
    setTimeout(async () => {
      if (pong) { isLeader = false; }
      if (!isLeader || !account?.address) return;
      const rpc = defaultRpc(network);
      const sui = createSuiClient(rpc);
      const exec = async (tx: Transaction) => { await signAndExecute({ transaction: tx }); };
      const sender = account.address;
      const km = new KeeperManager();
      await km.autoResume((cfg) => buildKeeperFromStrategy(sui as unknown as SuiClient, sender, exec, cfg)!);
    }, 300);
    return () => { bc.close(); };
  }, [network, account?.address, signAndExecute]);

  // Start price feeds when wallet connects
  useEffect(() => {
    if (!account?.address || surgeReady) return;
    startPriceFeeds().then(() => setSurgeReady(true)).catch(() => {});
  }, [account?.address, surgeReady]);

  const handleNetworkChange = (newNetwork: 'testnet' | 'mainnet') => {
    setNetwork(newNetwork);
    selectNetwork(newNetwork);
    setStarted(false); // Reset started state to reinitialize trackers
  };

  const renderCurrentPage = () => {
    switch (currentPage) {
      case 'dex':
        return <DEX />;
      case 'gas-futures':
        return <GasFutures />;
      case 'lending':
        return <Lending />;
      case 'options':
        return (
          <div style={{ padding: '2rem', textAlign: 'center', color: '#888' }}>
            <h2>Options Trading</h2>
            <p>Options trading interface coming soon...</p>
            <div style={{ marginTop: '2rem' }}>
              <button 
                onClick={async () => {
                  const latest = await db.events.orderBy('tsMs').reverse().limit(5).toArray();
                  console.log('Latest events', latest);
                  alert(`Indexed rows: ${latest.length}`);
                }}
                style={{ 
                  background: '#00d4aa', 
                  color: 'white', 
                  border: 'none', 
                  padding: '0.5rem 1rem', 
                  borderRadius: '0.5rem',
                  marginRight: '1rem'
                }}
              >
                Peek Events
              </button>
              <select 
                value={network} 
                onChange={(e) => handleNetworkChange(e.target.value as 'testnet' | 'mainnet')}
                style={{ 
                  background: '#1a1a1a', 
                  color: 'white', 
                  border: '1px solid #333', 
                  padding: '0.5rem', 
                  borderRadius: '0.5rem' 
                }}
              >
                <option value="testnet">Testnet</option>
                <option value="mainnet">Mainnet</option>
              </select>
            </div>
          </div>
        );
      case 'futures':
        return (
          <div style={{ padding: '2rem', textAlign: 'center', color: '#888' }}>
            <h2>Futures Trading</h2>
            <p>Futures trading interface coming soon...</p>
          </div>
        );
      case 'perpetuals':
        return (
          <div style={{ padding: '2rem', textAlign: 'center', color: '#888' }}>
            <h2>Perpetuals Trading</h2>
            <p>Perpetuals trading interface coming soon...</p>
          </div>
        );
      case 'staking':
        return (
          <div style={{ padding: '2rem', textAlign: 'center', color: '#888' }}>
            <h2>UNXV Staking</h2>
            <p>Staking interface coming soon...</p>
          </div>
        );
      case 'usdu-faucet':
        return (
          <div style={{ padding: '2rem', textAlign: 'center', color: '#888' }}>
            <h2>USDU Testnet Faucet</h2>
            <p>Faucet interface coming soon...</p>
          </div>
        );
      case 'strategy-builder':
        return (
          <div style={{ padding: '2rem', textAlign: 'center', color: '#888' }}>
            <h2>Strategy Builder</h2>
            <p>Visual strategy builder coming soon...</p>
          </div>
        );
      default:
        return <DEX />;
    }
  };

  return (
    <Layout currentPage={currentPage} onPageChange={setCurrentPage}>
      {renderCurrentPage()}
    </Layout>
  );
}

export default App;