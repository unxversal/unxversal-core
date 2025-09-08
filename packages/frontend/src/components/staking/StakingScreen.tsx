import { useState, useMemo } from 'react';
import styles from './StakingScreen.module.css';
import { defaultSettings, getTokenBySymbol } from '../../lib/settings.config';
import { TrendingUp, Clock, Award, Calendar } from 'lucide-react';
import { ConnectButton, useCurrentAccount } from '@mysten/dapp-kit';

type StakingData = {
  currentWeek: number;
  totalActiveStake: number;
  weeklyRewards: number;
  currentAPY: number;
  userActiveStake: number;
  userPendingStake: number;
  activateWeek: number;
  claimableRewards: number;
  lastClaimedWeek: number;
};

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
  const [stakeAmount, setStakeAmount] = useState<number>(0);
  const [unstakeAmount, setUnstakeAmount] = useState<number>(0);
  const [userBalance] = useState<number>(50000); // Mock UNXV balance
  const [submitting, setSubmitting] = useState(false);
  const account = useCurrentAccount();

  // Get UNXV token info
  const unxvToken = useMemo(() => {
    return getTokenBySymbol('UNXV', defaultSettings);
  }, []);

  // Mock staking data - in real implementation, this would come from the contract
  const stakingData: StakingData = useMemo(() => {
    return {
      currentWeek: 156, // Current epoch week
      totalActiveStake: 325000000, // Total UNXV staked across all users
      weeklyRewards: 45000, // UNXV rewards for current week
      currentAPY: 18.2, // Calculated APY based on recent weeks
      userActiveStake: 25000, // User's active stake (earning rewards)
      userPendingStake: 5000, // User's pending stake (activates next week)
      activateWeek: 157, // Week when pending stake activates
      claimableRewards: 347.85, // Rewards user can claim from completed weeks
      lastClaimedWeek: 154 // Last week user claimed rewards
    };
  }, []);

  const formatNumber = (num: number, decimals: number = 2) => {
    if (num >= 1_000_000) return `${(num / 1_000_000).toFixed(1)}M`;
    if (num >= 1_000) return `${(num / 1_000).toFixed(1)}K`;
    return num.toFixed(decimals);
  };

  const applyStakePercent = (percent: number) => {
    const amount = userBalance * percent;
    setStakeAmount(amount);
  };

  const applyUnstakePercent = (percent: number) => {
    const amount = stakingData.userActiveStake * percent;
    setUnstakeAmount(amount);
  };

  const handleStake = async () => {
    if (stakeAmount <= 0 || !account?.address) return;
    
    setSubmitting(true);
    try {
      // TODO: Call stake_unx() function from contract
      await new Promise(resolve => setTimeout(resolve, 2000)); // Mock delay
      console.log(`Staking ${stakeAmount} UNXV (activates week ${stakingData.currentWeek + 1})`);
      
      // Reset form after successful submission
      setStakeAmount(0);
    } catch (error) {
      console.error('Staking transaction failed:', error);
    } finally {
      setSubmitting(false);
    }
  };

  const handleUnstake = async () => {
    if (unstakeAmount <= 0 || !account?.address) return;
    
    setSubmitting(true);
    try {
      // TODO: Call unstake_unx() function from contract
      await new Promise(resolve => setTimeout(resolve, 2000)); // Mock delay
      console.log(`Unstaking ${unstakeAmount} UNXV (effective week ${stakingData.currentWeek + 1})`);
      
      // Reset form after successful submission
      setUnstakeAmount(0);
    } catch (error) {
      console.error('Unstaking transaction failed:', error);
    } finally {
      setSubmitting(false);
    }
  };

  const handleClaimRewards = async () => {
    if (stakingData.claimableRewards <= 0 || !account?.address) return;
    
    setSubmitting(true);
    try {
      // TODO: Call claim_rewards() function from contract
      await new Promise(resolve => setTimeout(resolve, 2000)); // Mock delay
      console.log(`Claiming ${stakingData.claimableRewards} UNXV rewards`);
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
                <div className={styles.tokenName}>Weekly Epochs • Pro-rata Rewards</div>
              </div>
            </div>
          </div>
          <div className={styles.metrics}>
            <div className={styles.metricItem}>
              <div className={styles.metricValue}>{formatNumber(stakingData.totalActiveStake)} UNXV</div>
              <div className={styles.metricLabel}>Total Staked</div>
            </div>
            <div className={styles.metricItem}>
              <div className={styles.metricValue}>{stakingData.currentAPY}%</div>
              <div className={styles.metricLabel}>Current APY</div>
            </div>
            <div className={styles.metricItem}>
              <div className={styles.metricValue}>Week {stakingData.currentWeek}</div>
              <div className={styles.metricLabel}>Current Epoch</div>
            </div>
          </div>
        </div>
      </div>

      {/* Content */}
      <div className={styles.content}>
        {/* Overview Cards */}
        <div className={styles.overviewCards}>
          <div className={styles.summaryCard}>
            <div className={styles.cardHeader}>
              <TrendingUp size={20} />
              <span>Your Active Stake</span>
            </div>
            <div className={styles.cardValue}>{formatNumber(stakingData.userActiveStake)} UNXV</div>
            <div className={styles.cardSubvalue}>Earning rewards</div>
          </div>

          {stakingData.userPendingStake > 0 && (
            <div className={styles.summaryCard}>
              <div className={styles.cardHeader}>
                <Clock size={20} />
                <span>Pending Stake</span>
              </div>
              <div className={styles.cardValue}>{formatNumber(stakingData.userPendingStake)} UNXV</div>
              <div className={styles.cardSubvalue}>Activates week {stakingData.activateWeek}</div>
            </div>
          )}

          <div className={styles.summaryCard}>
            <div className={styles.cardHeader}>
              <Award size={20} />
              <span>Claimable Rewards</span>
            </div>
            <div className={`${styles.cardValue} ${styles.positive}`}>
              {formatNumber(stakingData.claimableRewards)} UNXV
            </div>
            <div className={styles.cardSubvalue}>
              From weeks {stakingData.lastClaimedWeek + 1}-{stakingData.currentWeek - 1}
            </div>
          </div>

          <div className={styles.summaryCard}>
            <div className={styles.cardHeader}>
              <Calendar size={20} />
              <span>This Week's Rewards</span>
            </div>
            <div className={styles.cardValue}>{formatNumber(stakingData.weeklyRewards)} UNXV</div>
            <div className={styles.cardSubvalue}>Pool rewards for week {stakingData.currentWeek}</div>
          </div>
        </div>

        {/* Actions */}
        <div className={styles.actionsGrid}>
          {/* Stake Section */}
          <div className={styles.actionCard}>
            <div className={styles.actionHeader}>
              <h3>Stake UNXV</h3>
              <div className={styles.balanceInfo}>
                Balance: <span className={styles.balanceAmount}>{formatNumber(userBalance)} UNXV</span>
              </div>
            </div>
            
            <div className={styles.inputSection}>
              <div className={styles.inputGroup}>
                <input
                  type="number"
                  value={stakeAmount || ''}
                  onChange={(e) => setStakeAmount(Number(e.target.value))}
                  placeholder="Enter amount to stake"
                  className={styles.amountInput}
                  max={userBalance}
                  min={0}
                />
                <div className={styles.tokenSelector}>
                  <span>UNXV</span>
                </div>
              </div>
              
              <div className={styles.percentButtons}>
                <button onClick={() => applyStakePercent(0.25)} className={styles.percentBtn}>25%</button>
                <button onClick={() => applyStakePercent(0.5)} className={styles.percentBtn}>50%</button>
                <button onClick={() => applyStakePercent(0.75)} className={styles.percentBtn}>75%</button>
                <button onClick={() => applyStakePercent(1)} className={styles.percentBtn}>MAX</button>
              </div>
              
              <div className={styles.stakeInfo}>
                <div className={styles.infoRow}>
                  <span>Activation:</span>
                  <span>Week {stakingData.currentWeek + 1}</span>
                </div>
                <div className={styles.infoRow}>
                  <span>Estimated Weekly Reward:</span>
                  <span className={styles.positive}>
                    {stakeAmount > 0 
                      ? ((stakeAmount / (stakingData.totalActiveStake + stakeAmount)) * stakingData.weeklyRewards).toFixed(2)
                      : '0.00'
                    } UNXV
                  </span>
                </div>
              </div>
              
              {!account?.address ? (
                <div className={styles.connectWallet}>
                  <ConnectButton />
                </div>
              ) : (
                <button
                  onClick={handleStake}
                  disabled={submitting || stakeAmount <= 0 || stakeAmount > userBalance}
                  className={styles.stakeBtn}
                >
                  {submitting 
                    ? 'Staking...'
                    : stakeAmount <= 0
                      ? 'Enter amount to stake'
                      : stakeAmount > userBalance
                        ? 'Insufficient Balance'
                        : `Stake ${stakeAmount.toLocaleString()} UNXV`
                  }
                </button>
              )}
            </div>
          </div>

          {/* Unstake Section */}
          {stakingData.userActiveStake > 0 && (
            <div className={styles.actionCard}>
              <div className={styles.actionHeader}>
                <h3>Unstake UNXV</h3>
                <div className={styles.balanceInfo}>
                  Active Stake: <span className={styles.balanceAmount}>{formatNumber(stakingData.userActiveStake)} UNXV</span>
                </div>
              </div>
              
              <div className={styles.inputSection}>
                <div className={styles.inputGroup}>
                  <input
                    type="number"
                    value={unstakeAmount || ''}
                    onChange={(e) => setUnstakeAmount(Number(e.target.value))}
                    placeholder="Enter amount to unstake"
                    className={styles.amountInput}
                    max={stakingData.userActiveStake}
                    min={0}
                  />
                  <div className={styles.tokenSelector}>
                    <span>UNXV</span>
                  </div>
                </div>
                
                <div className={styles.percentButtons}>
                  <button onClick={() => applyUnstakePercent(0.25)} className={styles.percentBtn}>25%</button>
                  <button onClick={() => applyUnstakePercent(0.5)} className={styles.percentBtn}>50%</button>
                  <button onClick={() => applyUnstakePercent(0.75)} className={styles.percentBtn}>75%</button>
                  <button onClick={() => applyUnstakePercent(1)} className={styles.percentBtn}>MAX</button>
                </div>
                
                <div className={styles.stakeInfo}>
                  <div className={styles.infoRow}>
                    <span>Effective:</span>
                    <span>Week {stakingData.currentWeek + 1}</span>
                  </div>
                  <div className={styles.infoRow}>
                    <span>Principal returned:</span>
                    <span>Immediately</span>
                  </div>
                </div>
                
                <button
                  onClick={handleUnstake}
                  disabled={submitting || unstakeAmount <= 0 || unstakeAmount > stakingData.userActiveStake}
                  className={styles.unstakeBtn}
                >
                  {submitting 
                    ? 'Unstaking...'
                    : unstakeAmount <= 0
                      ? 'Enter amount to unstake'
                      : unstakeAmount > stakingData.userActiveStake
                        ? 'Insufficient Active Stake'
                        : `Unstake ${unstakeAmount.toLocaleString()} UNXV`
                  }
                </button>
              </div>
            </div>
          )}

          {/* Claim Rewards Section */}
          {stakingData.claimableRewards > 0 && (
            <div className={styles.actionCard}>
              <div className={styles.actionHeader}>
                <h3>Claim Rewards</h3>
                <div className={styles.balanceInfo}>
                  Available: <span className={`${styles.balanceAmount} ${styles.positive}`}>
                    {formatNumber(stakingData.claimableRewards)} UNXV
                  </span>
                </div>
              </div>
              
              <div className={styles.rewardDetails}>
                <div className={styles.infoRow}>
                  <span>Reward Period:</span>
                  <span>Weeks {stakingData.lastClaimedWeek + 1} - {stakingData.currentWeek - 1}</span>
                </div>
                <div className={styles.infoRow}>
                  <span>Amount:</span>
                  <span className={styles.positive}>{formatNumber(stakingData.claimableRewards)} UNXV</span>
                </div>
              </div>
              
              <button
                onClick={handleClaimRewards}
                disabled={submitting}
                className={styles.claimBtn}
              >
                {submitting ? 'Claiming...' : `Claim ${formatNumber(stakingData.claimableRewards)} UNXV`}
              </button>
            </div>
          )}
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
          <span>{(network || 'testnet').toUpperCase()}</span>
        </div>
      </footer>
    </div>
  );
}
