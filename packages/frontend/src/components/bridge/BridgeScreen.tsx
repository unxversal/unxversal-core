import { useMemo } from 'react';
import styles from './BridgeScreen.module.css';
import WormholeConnect, { type config, type WormholeConnectTheme } from '@wormhole-foundation/wormhole-connect';
import { loadSettings } from '../../lib/settings.config';

export function BridgeScreen({ network, protocolStatus }: { 
  network?: string;
  protocolStatus?: {
    options: boolean;
    futures: boolean;
    perps: boolean;
    lending: boolean;
    staking: boolean;
    dex: boolean;
  }
}) {
  const settings = loadSettings();
  const currentNetwork = network || settings.network;

  const connectConfig: config.WormholeConnectConfig = useMemo(() => {
    const net = currentNetwork === 'mainnet' ? 'Mainnet' : 'Testnet';
    return {
      network: net as 'Mainnet' | 'Testnet' | 'Devnet',
      ui: {
        title: 'Unxversal Bridge',
        showHamburgerMenu: false,
        defaultInputs: {
          toChain: 'Sui',
        },
      },
    };
  }, [currentNetwork]);

  const theme: WormholeConnectTheme = useMemo(() => ({
    mode: 'dark',
    primary: '#78c4b6',
  }), []);

  return (
    <div className={styles.root}>
      <div className={styles.content}>
        <div className={styles.widgetCard}>
          <WormholeConnect config={connectConfig} theme={theme} />
        </div>
      </div>

      {/* Footer status */}
      <footer className={styles.footer}>
        <div className={styles.statusBadges}>
          <div className={`${styles.badge} ${protocolStatus?.options ? styles.connected : styles.disconnected}`}>
            <div className={`${styles.dot} ${protocolStatus?.options ? styles.dotConnected : styles.dotDisconnected}`}></div>
            <span>Options</span>
          </div>
          
          <div className={`${styles.badge} ${protocolStatus?.futures ? styles.connected : styles.disconnected}`}>
            <div className={`${styles.dot} ${protocolStatus?.futures ? styles.dotConnected : styles.dotDisconnected}`}></div>
            <span>Futures</span>
          </div>
          
          <div className={`${styles.badge} ${protocolStatus?.perps ? styles.connected : styles.disconnected}`}>
            <div className={`${styles.dot} ${protocolStatus?.perps ? styles.dotConnected : styles.dotDisconnected}`}></div>
            <span>Perps</span>
          </div>
          
          <div className={`${styles.badge} ${protocolStatus?.lending ? styles.connected : styles.disconnected}`}>
            <div className={`${styles.dot} ${protocolStatus?.lending ? styles.dotConnected : styles.dotDisconnected}`}></div>
            <span>Lending</span>
          </div>
          
          <div className={`${styles.badge} ${protocolStatus?.staking ? styles.connected : styles.disconnected}`}>
            <div className={`${styles.dot} ${protocolStatus?.staking ? styles.dotConnected : styles.dotDisconnected}`}></div>
            <span>Staking</span>
          </div>
          
          <div className={`${styles.badge} ${protocolStatus?.dex ? styles.connected : styles.disconnected}`}>
            <div className={`${styles.dot} ${protocolStatus?.dex ? styles.dotConnected : styles.dotDisconnected}`}></div>
            <span>DEX</span>
          </div>
        </div>
        
        <div className={styles.networkBadge}>
          <span>{(currentNetwork || 'testnet').toUpperCase()}</span>
        </div>
      </footer>
    </div>
  );
}

export default BridgeScreen;


