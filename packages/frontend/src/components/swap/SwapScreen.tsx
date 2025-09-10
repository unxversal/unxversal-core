import { useState, useEffect } from 'react';
import { useCurrentAccount, ConnectButton } from '@mysten/dapp-kit';
import styles from './SwapScreen.module.css';

interface Token {
  symbol: string;
  name: string;
  icon?: string;
  balance?: number;
}

// Mock token data - in a real app this would come from the blockchain
const TOKENS: Token[] = [
  { symbol: 'DEEP', name: 'DeepBook', balance: 0 },
  { symbol: 'SUI', name: 'Sui', balance: 0 },
  { symbol: 'USDC', name: 'USD Coin', balance: 0 },
  { symbol: 'USDT', name: 'Tether USD', balance: 0 },
  { symbol: 'WETH', name: 'Wrapped Ethereum', balance: 0 },
];

export function SwapScreen({ network }: { network?: string }) {
  const account = useCurrentAccount();
  
  // Swap state
  const [sellingToken, setSellingToken] = useState<Token>(TOKENS[0]); // DEEP
  const [buyingToken, setBuyingToken] = useState<Token>(TOKENS[1]); // SUI
  const [sellingAmount, setSellingAmount] = useState('');
  const [buyingAmount, setBuyingAmount] = useState('');
  const [showSellingDropdown, setShowSellingDropdown] = useState(false);
  const [showBuyingDropdown, setShowBuyingDropdown] = useState(false);
  
  // Mock exchange rate - in real app this would come from price feeds
  const [exchangeRate] = useState(0.038745); // 1 DEEP = 0.038745 SUI
  const [totalSwaps] = useState(1);

  // Update buying amount when selling amount changes
  useEffect(() => {
    if (sellingAmount && !isNaN(Number(sellingAmount))) {
      const amount = Number(sellingAmount) * exchangeRate;
      setBuyingAmount(amount.toFixed(6));
    } else {
      setBuyingAmount('');
    }
  }, [sellingAmount, exchangeRate]);

  const handleSwapTokens = () => {
    const tempToken = sellingToken;
    const tempAmount = sellingAmount;
    
    setSellingToken(buyingToken);
    setBuyingToken(tempToken);
    setSellingAmount(buyingAmount);
    setBuyingAmount(tempAmount);
  };

  const handleTokenSelect = (token: Token, isSelling: boolean) => {
    if (isSelling) {
      setSellingToken(token);
      setShowSellingDropdown(false);
    } else {
      setBuyingToken(token);
      setShowBuyingDropdown(false);
    }
  };


  const canSwap = account?.address && sellingAmount && Number(sellingAmount) > 0;

  return (
    <div className={styles.root}>
      <div className={styles.swapContainer}>

        {/* Selling Section */}
        <div className={styles.swapSection}>
          <div className={styles.sectionLabel}>Selling</div>
          <div className={styles.tokenInput}>
            <div className={styles.tokenSelector} onClick={() => setShowSellingDropdown(!showSellingDropdown)}>
              <div className={styles.tokenInfo}>
                <div className={styles.tokenIcon}>
                  {sellingToken.symbol === 'DEEP' && (
                    <div className={styles.deepIcon}>🔵</div>
                  )}
                  {sellingToken.symbol === 'SUI' && (
                    <div className={styles.suiIcon}>💧</div>
                  )}
                  {sellingToken.symbol !== 'DEEP' && sellingToken.symbol !== 'SUI' && (
                    <div className={styles.defaultIcon}>{sellingToken.symbol[0]}</div>
                  )}
                </div>
                <span className={styles.tokenSymbol}>{sellingToken.symbol}</span>
              </div>
              <svg className={styles.dropdownArrow} width="12" height="8" viewBox="0 0 12 8" fill="none">
                <path d="M1 1L6 6L11 1" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round"/>
              </svg>
            </div>
            
            <div className={styles.amountInput}>
              <input
                type="number"
                placeholder="0"
                value={sellingAmount}
                onChange={(e) => setSellingAmount(e.target.value)}
                className={styles.amountField}
              />
              <div className={styles.balanceInfo}>
                <span className={styles.balanceLabel}>{sellingToken.balance || 0} {sellingToken.symbol}</span>
              </div>
            </div>

            {showSellingDropdown && (
              <div className={styles.tokenDropdown}>
                {TOKENS.filter(token => token.symbol !== buyingToken.symbol).map((token) => (
                  <div
                    key={token.symbol}
                    className={styles.tokenOption}
                    onClick={() => handleTokenSelect(token, true)}
                  >
                    <div className={styles.tokenInfo}>
                      <div className={styles.tokenIcon}>
                        {token.symbol === 'DEEP' && <div className={styles.deepIcon}>🔵</div>}
                        {token.symbol === 'SUI' && <div className={styles.suiIcon}>💧</div>}
                        {token.symbol !== 'DEEP' && token.symbol !== 'SUI' && (
                          <div className={styles.defaultIcon}>{token.symbol[0]}</div>
                        )}
                      </div>
                      <div className={styles.tokenDetails}>
                        <span className={styles.tokenSymbol}>{token.symbol}</span>
                        <span className={styles.tokenName}>{token.name}</span>
                      </div>
                    </div>
                    <span className={styles.tokenBalance}>{token.balance || 0}</span>
                  </div>
                ))}
              </div>
            )}
          </div>
        </div>


        {/* Buying Section */}
        <div className={styles.swapSection}>
          <div className={styles.sectionLabel}>Buying</div>
          <div className={styles.tokenInput}>
            <div className={styles.tokenSelector} onClick={() => setShowBuyingDropdown(!showBuyingDropdown)}>
              <div className={styles.tokenInfo}>
                <div className={styles.tokenIcon}>
                  {buyingToken.symbol === 'DEEP' && (
                    <div className={styles.deepIcon}>🔵</div>
                  )}
                  {buyingToken.symbol === 'SUI' && (
                    <div className={styles.suiIcon}>💧</div>
                  )}
                  {buyingToken.symbol !== 'DEEP' && buyingToken.symbol !== 'SUI' && (
                    <div className={styles.defaultIcon}>{buyingToken.symbol[0]}</div>
                  )}
                </div>
                <span className={styles.tokenSymbol}>{buyingToken.symbol}</span>
              </div>
              <svg className={styles.dropdownArrow} width="12" height="8" viewBox="0 0 12 8" fill="none">
                <path d="M1 1L6 6L11 1" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round"/>
              </svg>
            </div>
            
            <div className={styles.amountInput}>
              <input
                type="number"
                placeholder="0"
                value={buyingAmount}
                onChange={(e) => setBuyingAmount(e.target.value)}
                className={styles.amountField}
                readOnly
              />
              <div className={styles.balanceInfo}>
                <span className={styles.balanceLabel}>{buyingToken.balance || 0} {buyingToken.symbol}</span>
              </div>
            </div>

            {showBuyingDropdown && (
              <div className={styles.tokenDropdown}>
                {TOKENS.filter(token => token.symbol !== sellingToken.symbol).map((token) => (
                  <div
                    key={token.symbol}
                    className={styles.tokenOption}
                    onClick={() => handleTokenSelect(token, false)}
                  >
                    <div className={styles.tokenInfo}>
                      <div className={styles.tokenIcon}>
                        {token.symbol === 'DEEP' && <div className={styles.deepIcon}>🔵</div>}
                        {token.symbol === 'SUI' && <div className={styles.suiIcon}>💧</div>}
                        {token.symbol !== 'DEEP' && token.symbol !== 'SUI' && (
                          <div className={styles.defaultIcon}>{token.symbol[0]}</div>
                        )}
                      </div>
                      <div className={styles.tokenDetails}>
                        <span className={styles.tokenSymbol}>{token.symbol}</span>
                        <span className={styles.tokenName}>{token.name}</span>
                      </div>
                    </div>
                    <span className={styles.tokenBalance}>{token.balance || 0}</span>
                  </div>
                ))}
              </div>
            )}
          </div>
        </div>

        {/* Connect Wallet or Swap Button */}
        <div className={styles.actionSection}>
          {!account?.address ? (
            <div className={styles.connectWalletContainer}>
              <ConnectButton />
            </div>
          ) : (
            <button 
              className={`${styles.swapActionButton} ${canSwap ? styles.enabled : styles.disabled}`}
              disabled={!canSwap}
            >
              {!sellingAmount || Number(sellingAmount) === 0 
                ? 'Enter an amount' 
                : `Swap ${sellingToken.symbol} for ${buyingToken.symbol}`
              }
            </button>
          )}
        </div>

        {/* Swap Info */}
        <div className={styles.swapInfo}>
          <div className={styles.swapInfoRow}>
            <span>{sellingToken.symbol} → {buyingToken.symbol}</span>
            <span>1 {sellingToken.symbol} = {exchangeRate} {buyingToken.symbol}</span>
          </div>
          <div className={styles.swapInfoRow}>
            <span>Total swaps: {totalSwaps}</span>
          </div>
        </div>
      </div>
    </div>
  );
}
