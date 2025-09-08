import { useState, useMemo } from 'react';
import styles from './StakingScreen.module.css';
import { defaultSettings, getTokenBySymbol } from '../../lib/settings.config';
import { TrendingUp, Clock, Award, Percent } from 'lucide-react';
import { ConnectButton, useCurrentAccount } from '@mysten/dapp-kit';

type StakingPool = {
  id: string;
  apy: number;
  totalStaked: number;
  userStaked: number;
  userRewards: number;
  lockPeriod: number; // in days
  minStakeAmount: number;
  poolStatus: 'active' | 'paused' | 'ended';
};

type ViewMode = 'stake' | 'rewards' | 'history';

export function StakingScreen({ started: _started, network, protocolStatus }: { 
  started?: boolean;
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
  // Suppress unused parameter warning
  _started;
  const [viewMode, setViewMode] = useState<ViewMode>('stake');
  const [selectedPool, setSelectedPool] = useState<StakingPool | null>(null);
  const [inputAmount, setInputAmount] = useState<number>(0);
  const [userBalance] = useState<number>(50000); // Mock UNXV balance
  const [submitting, setSubmitting] = useState(false);
  const account = useCurrentAccount();

  // Get UNXV token info
  const unxvToken = useMemo(() => {
    return getTokenBySymbol('UNXV', defaultSettings);
  }, []);

  // Generate staking pools with realistic mock data
  const stakingPools: StakingPool[] = useMemo(() => {
    return [
      {
        id: 'unxv-flexible',
        apy: 12.4,
        totalStaked: 125000000,
        userStaked: 15000,
        userRewards: 247.85,
        lockPeriod: 0,
        minStakeAmount: 100,
        poolStatus: 'active'
      },
      {
        id: 'unxv-30day',
        apy: 18.7,
        totalStaked: 89000000,
        userStaked: 25000,
        userRewards: 1456.23,
        lockPeriod: 30,
        minStakeAmount: 500,
        poolStatus: 'active'
      },
      {
        id: 'unxv-90day',
        apy: 24.2,
        totalStaked: 67000000,
        userStaked: 50000,
        userRewards: 3789.12,
        lockPeriod: 90,
        minStakeAmount: 1000,
        poolStatus: 'active'
      },
      {
        id: 'unxv-180day',
        apy: 31.5,
        totalStaked: 45000000,
        userStaked: 0,
        userRewards: 0,
        lockPeriod: 180,
        minStakeAmount: 2500,
        poolStatus: 'active'
      }
    ];
  }, []);

  // Calculate portfolio totals
  const portfolioStats = useMemo(() => {
    const totalStaked = stakingPools.reduce((sum, pool) => sum + pool.userStaked, 0);
    const totalRewards = stakingPools.reduce((sum, pool) => sum + pool.userRewards, 0);
    const weightedApy = stakingPools.reduce((sum, pool) => {
      if (pool.userStaked === 0) return sum;
      return sum + (pool.userStaked * pool.apy);
    }, 0) / Math.max(totalStaked, 1);
    
    return {
      totalStaked,
      totalRewards,
      averageApy: weightedApy,
      portfolioValue: totalStaked + totalRewards
    };
  }, [stakingPools]);

  const formatNumber = (num: number, decimals: number = 2) => {
    if (num >= 1_000_000) return `${(num / 1_000_000).toFixed(1)}M`;
    if (num >= 1_000) return `${(num / 1_000).toFixed(1)}K`;
    return num.toFixed(decimals);
  };

  const applyPercent = (percent: number) => {
    const amount = userBalance * percent;
    setInputAmount(amount);
  };

  const handleStake = async () => {
    if (!selectedPool || inputAmount <= 0 || !account?.address) return;
    
    setSubmitting(true);
    try {
      // TODO: Implement actual staking transaction logic
      await new Promise(resolve => setTimeout(resolve, 2000)); // Mock delay
      console.log(`Staking ${inputAmount} UNXV in pool ${selectedPool.id}`);
      
      // Reset form after successful submission
      setInputAmount(0);
    } catch (error) {
      console.error('Staking transaction failed:', error);
    } finally {
      setSubmitting(false);
    }
  };

  const handleUnstake = async (poolId: string) => {
    setSubmitting(true);
    try {
      // TODO: Implement actual unstaking transaction logic
      await new Promise(resolve => setTimeout(resolve, 2000)); // Mock delay
      console.log(`Unstaking from pool ${poolId}`);
    } catch (error) {
      console.error('Unstaking transaction failed:', error);
    } finally {
      setSubmitting(false);
    }
  };

  const handleClaimRewards = async (poolId: string) => {
    setSubmitting(true);
    try {
      // TODO: Implement actual rewards claiming transaction logic
      await new Promise(resolve => setTimeout(resolve, 2000)); // Mock delay
      console.log(`Claiming rewards from pool ${poolId}`);
    } catch (error) {
      console.error('Claim rewards transaction failed:', error);
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <div className={styles.root}>
      {/* Header */}
      <div className={styles.header}>
        <div className={styles.pairBar}>
          <div className={styles.pair}>
            <div className={styles.tokenInfo}>
              {unxvToken?.iconUrl && (
                <img src={unxvToken.iconUrl} alt="UNXV" className={styles.tokenIcon} />
              )}
              <div>
                <div className={styles.tokenSymbol}>UNXV Staking</div>
                <div className={styles.tokenName}>Unxversal Protocol Token</div>
              </div>
            </div>
          </div>
          <div className={styles.metrics}>
            <div className={styles.metricItem}>
              <div className={styles.metricValue}>${formatNumber(326000000)}</div>
              <div className={styles.metricLabel}>Total Value Locked</div>
            </div>
            <div className={styles.metricItem}>
              <div className={styles.metricValue}>8.9K</div>
              <div className={styles.metricLabel}>Active Stakers</div>
            </div>
            <div className={styles.metricItem}>
              <div className={styles.metricValue}>24.5%</div>
              <div className={styles.metricLabel}>Max APY</div>
            </div>
            <div className={styles.viewToggle}>
              <button 
                className={viewMode === 'stake' ? styles.active : ''} 
                onClick={() => setViewMode('stake')}
              >
                Stake
              </button>
              <button 
                className={viewMode === 'rewards' ? styles.active : ''} 
                onClick={() => setViewMode('rewards')}
              >
                Rewards
              </button>
              <button 
                className={viewMode === 'history' ? styles.active : ''} 
                onClick={() => setViewMode('history')}
              >
                History
              </button>
            </div>
          </div>
        </div>
      </div>

      {/* Content */}
      <div className={styles.content}>
        {/* Portfolio Summary */}
        <div className={styles.portfolioSummary}>
          <div className={styles.summaryCard}>
            <div className={styles.cardHeader}>
              <TrendingUp size={20} />
              <span>Total Staked</span>
            </div>
            <div className={styles.cardValue}>{formatNumber(portfolioStats.totalStaked)} UNXV</div>
            <div className={styles.cardSubvalue}>${formatNumber(portfolioStats.totalStaked * 0.85)}</div>
          </div>
          <div className={styles.summaryCard}>
            <div className={styles.cardHeader}>
              <Award size={20} />
              <span>Pending Rewards</span>
            </div>
            <div className={styles.cardValue}>{formatNumber(portfolioStats.totalRewards)} UNXV</div>
            <div className={styles.cardSubvalue}>${formatNumber(portfolioStats.totalRewards * 0.85)}</div>
          </div>
          <div className={styles.summaryCard}>
            <div className={styles.cardHeader}>
              <Percent size={20} />
              <span>Average APY</span>
            </div>
            <div className={`${styles.cardValue} ${styles.positive}`}>
              {portfolioStats.averageApy.toFixed(2)}%
            </div>
            <div className={styles.cardSubvalue}>Weighted by stake</div>
          </div>
          <div className={styles.summaryCard}>
            <div className={styles.cardHeader}>
              <Clock size={20} />
              <span>Portfolio Value</span>
            </div>
            <div className={styles.cardValue}>{formatNumber(portfolioStats.portfolioValue)} UNXV</div>
            <div className={styles.cardSubvalue}>${formatNumber(portfolioStats.portfolioValue * 0.85)}</div>
          </div>
        </div>

        {viewMode === 'stake' && (
          <div className={styles.stakingPools}>
            <div className={styles.poolsHeader}>
              <h3>Available Staking Pools</h3>
              <div className={styles.balanceInfo}>
                <span>Available Balance: </span>
                <span className={styles.balanceAmount}>{formatNumber(userBalance)} UNXV</span>
              </div>
            </div>
            
            <div className={styles.poolsGrid}>
              {stakingPools.map((pool) => (
                <div 
                  key={pool.id} 
                  className={`${styles.poolCard} ${selectedPool?.id === pool.id ? styles.selected : ''}`}
                  onClick={() => setSelectedPool(pool)}
                >
                  <div className={styles.poolHeader}>
                    <div className={styles.poolTitle}>
                      {pool.lockPeriod === 0 ? 'Flexible' : `${pool.lockPeriod} Day Lock`}
                    </div>
                    <div className={`${styles.poolApy} ${styles.positive}`}>
                      {pool.apy}% APY
                    </div>
                  </div>
                  
                  <div className={styles.poolStats}>
                    <div className={styles.poolStat}>
                      <span className={styles.statLabel}>Total Staked</span>
                      <span className={styles.statValue}>{formatNumber(pool.totalStaked)} UNXV</span>
                    </div>
                    <div className={styles.poolStat}>
                      <span className={styles.statLabel}>Min Stake</span>
                      <span className={styles.statValue}>{formatNumber(pool.minStakeAmount)} UNXV</span>
                    </div>
                    {pool.userStaked > 0 && (
                      <div className={styles.poolStat}>
                        <span className={styles.statLabel}>Your Stake</span>
                        <span className={`${styles.statValue} ${styles.positive}`}>{formatNumber(pool.userStaked)} UNXV</span>
                      </div>
                    )}
                    {pool.userRewards > 0 && (
                      <div className={styles.poolStat}>
                        <span className={styles.statLabel}>Rewards</span>
                        <span className={`${styles.statValue} ${styles.positive}`}>{formatNumber(pool.userRewards)} UNXV</span>
                      </div>
                    )}
                  </div>

                  {pool.userStaked > 0 && (
                    <div className={styles.poolActions}>
                      <button 
                        onClick={(e) => {
                          e.stopPropagation();
                          handleClaimRewards(pool.id);
                        }}
                        disabled={submitting || pool.userRewards === 0}
                        className={styles.claimBtn}
                      >
                        Claim Rewards
                      </button>
                      <button 
                        onClick={(e) => {
                          e.stopPropagation();
                          handleUnstake(pool.id);
                        }}
                        disabled={submitting || pool.lockPeriod > 0}
                        className={styles.unstakeBtn}
                      >
                        {pool.lockPeriod > 0 ? 'Locked' : 'Unstake'}
                      </button>
                    </div>
                  )}
                </div>
              ))}
            </div>

            {selectedPool && (
              <div className={styles.stakeForm}>
                <div className={styles.formHeader}>
                  <h4>Stake UNXV</h4>
                  <div className={styles.selectedPool}>
                    {selectedPool.lockPeriod === 0 ? 'Flexible' : `${selectedPool.lockPeriod} Day Lock`} 
                    - <span className={styles.positive}>{selectedPool.apy}% APY</span>
                  </div>
                </div>
                
                <div className={styles.inputSection}>
                  <div className={styles.inputGroup}>
                    <input
                      type="number"
                      value={inputAmount || ''}
                      onChange={(e) => setInputAmount(Number(e.target.value))}
                      placeholder="Enter stake amount"
                      className={styles.amountInput}
                      max={userBalance}
                      min={selectedPool.minStakeAmount}
                    />
                    <div className={styles.tokenSelector}>
                      <span>UNXV</span>
                    </div>
                  </div>
                  
                  <div className={styles.percentButtons}>
                    <button onClick={() => applyPercent(0.25)} className={styles.percentBtn}>25%</button>
                    <button onClick={() => applyPercent(0.5)} className={styles.percentBtn}>50%</button>
                    <button onClick={() => applyPercent(0.75)} className={styles.percentBtn}>75%</button>
                    <button onClick={() => applyPercent(1)} className={styles.percentBtn}>MAX</button>
                  </div>
                  
                  <div className={styles.stakeInfo}>
                    <div className={styles.infoRow}>
                      <span>Estimated Daily Rewards:</span>
                      <span className={styles.positive}>
                        {((inputAmount * selectedPool.apy / 100) / 365).toFixed(4)} UNXV
                      </span>
                    </div>
                    <div className={styles.infoRow}>
                      <span>Lock Period:</span>
                      <span>{selectedPool.lockPeriod === 0 ? 'Flexible' : `${selectedPool.lockPeriod} days`}</span>
                    </div>
                    <div className={styles.infoRow}>
                      <span>Minimum Stake:</span>
                      <span>{formatNumber(selectedPool.minStakeAmount)} UNXV</span>
                    </div>
                  </div>
                  
                  {!account?.address ? (
                    <div className={styles.connectWallet}>
                      <ConnectButton />
                    </div>
                  ) : (
                    <button
                      onClick={handleStake}
                      disabled={submitting || inputAmount < selectedPool.minStakeAmount || inputAmount > userBalance}
                      className={styles.stakeBtn}
                    >
                      {submitting 
                        ? 'Staking...'
                        : inputAmount < selectedPool.minStakeAmount
                          ? `Minimum ${formatNumber(selectedPool.minStakeAmount)} UNXV`
                          : inputAmount > userBalance
                            ? 'Insufficient Balance'
                            : `Stake ${inputAmount.toLocaleString()} UNXV`
                      }
                    </button>
                  )}
                </div>
              </div>
            )}
          </div>
        )}

        {viewMode === 'rewards' && (
          <div className={styles.rewardsView}>
            <div className={styles.rewardsHeader}>
              <h3>Reward Summary</h3>
              <button 
                onClick={() => {
                  // Claim all rewards
                  stakingPools.forEach(pool => {
                    if (pool.userRewards > 0) {
                      handleClaimRewards(pool.id);
                    }
                  });
                }}
                disabled={submitting || portfolioStats.totalRewards === 0}
                className={styles.claimAllBtn}
              >
                Claim All Rewards
              </button>
            </div>
            
            <div className={styles.rewardsGrid}>
              {stakingPools
                .filter(pool => pool.userStaked > 0)
                .map((pool) => (
                  <div key={pool.id} className={styles.rewardCard}>
                    <div className={styles.rewardHeader}>
                      <span className={styles.rewardPoolName}>
                        {pool.lockPeriod === 0 ? 'Flexible' : `${pool.lockPeriod} Day Lock`}
                      </span>
                      <span className={`${styles.rewardApy} ${styles.positive}`}>
                        {pool.apy}% APY
                      </span>
                    </div>
                    
                    <div className={styles.rewardStats}>
                      <div className={styles.rewardStat}>
                        <span className={styles.statLabel}>Staked Amount</span>
                        <span className={styles.statValue}>{formatNumber(pool.userStaked)} UNXV</span>
                      </div>
                      <div className={styles.rewardStat}>
                        <span className={styles.statLabel}>Pending Rewards</span>
                        <span className={`${styles.statValue} ${styles.positive}`}>
                          {formatNumber(pool.userRewards)} UNXV
                        </span>
                      </div>
                    </div>
                    
                    <button
                      onClick={() => handleClaimRewards(pool.id)}
                      disabled={submitting || pool.userRewards === 0}
                      className={styles.claimBtn}
                    >
                      Claim Rewards
                    </button>
                  </div>
                ))}
            </div>
          </div>
        )}

        {viewMode === 'history' && (
          <div className={styles.historyView}>
            <h3>Transaction History</h3>
            <div className={styles.emptyState}>
              <p>Transaction history will be displayed here once you start staking.</p>
            </div>
          </div>
        )}
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
          <span>{(network || 'testnet').toUpperCase()}</span>
        </div>
      </footer>
    </div>
  );
}
