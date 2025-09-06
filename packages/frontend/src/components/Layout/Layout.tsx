import React from 'react';
import { Activity, Wallet } from 'lucide-react';
import styles from './Layout.module.css';

interface LayoutProps {
  children: React.ReactNode;
  currentPage: string;
  onPageChange: (page: string) => void;
}

const navItems = [
  { id: 'dex', label: 'DEX' },
  { id: 'lending', label: 'Lending' },
  { id: 'options', label: 'Options' },
  { id: 'futures', label: 'Futures' },
  { id: 'gas-futures', label: 'Gas Futures' },
  { id: 'perpetuals', label: 'Perpetuals' },
  { id: 'staking', label: 'Staking' },
  { id: 'usdu-faucet', label: 'USDU Faucet' },
  { id: 'strategy-builder', label: 'Strategy Builder' },
];

export function Layout({ children, currentPage, onPageChange }: LayoutProps) {
  return (
    <div className={styles.layout}>
      <nav className={styles.navbar}>
        <div className={styles.logo}>
          <Activity size={24} />
          UNXVERSAL
        </div>
        
        <ul className={styles.navItems}>
          {navItems.map((item) => (
            <li
              key={item.id}
              className={`${styles.navItem} ${currentPage === item.id ? styles.active : ''}`}
              onClick={() => onPageChange(item.id)}
            >
              {item.label}
            </li>
          ))}
        </ul>
        
        <button className={styles.connectButton}>
          <Wallet size={16} style={{ marginRight: '0.5rem' }} />
          Connect Wallet
        </button>
      </nav>
      
      <main className={styles.main}>
        {children}
      </main>
    </div>
  );
}
