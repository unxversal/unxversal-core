import { useState, useEffect, useRef } from 'react';
import styles from './StakingScreen.module.css';
import { ConnectButton, useCurrentAccount } from '@mysten/dapp-kit';
import { HelpCircle } from 'lucide-react';


export function StakingScreen({ network }: { 
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
  const [stakeAmount, setStakeAmount] = useState('');
  const [submitting, setSubmitting] = useState(false);
  const [activeAction, setActiveAction] = useState<'stake' | 'unstake' | 'claim' | null>(null);
  const [showTierTooltip, setShowTierTooltip] = useState(false);
  const tooltipRef = useRef<HTMLDivElement>(null);
  const account = useCurrentAccount();

  // Mock data - in real implementation, this would come from the contract
  const userBalance = 50000; // UNXV balance
  const stakedAmount = 25000; // Currently staked UNXV
  const claimableRewards = 347.85; // Claimable rewards
  
  // Calculate user's tier based on staked amount (from fees.move tiers)
  const getUserTier = (amount: number): { tier: number; name: string; discount: string } => {
    if (amount >= 500000) return { tier: 6, name: "Midnight Ocean", discount: "40%" };
    if (amount >= 100000) return { tier: 5, name: "Cobalt Trench", discount: "30%" };
    if (amount >= 10000) return { tier: 4, name: "Indigo Waves", discount: "20%" };
    if (amount >= 1000) return { tier: 3, name: "Teal Harbor", discount: "15%" };
    if (amount >= 100) return { tier: 2, name: "Silver Stream", discount: "10%" };
    if (amount >= 10) return { tier: 1, name: "Crystal Pool", discount: "5%" };
    return { tier: 0, name: "Frost Shore", discount: "0%" };
  };

  const userTier = getUserTier(stakedAmount);

  // Close tooltip when clicking outside
  useEffect(() => {
    function handleClickOutside(event: MouseEvent) {
      if (tooltipRef.current && !tooltipRef.current.contains(event.target as Node)) {
        setShowTierTooltip(false);
      }
    }

    if (showTierTooltip) {
      document.addEventListener('mousedown', handleClickOutside);
      return () => {
        document.removeEventListener('mousedown', handleClickOutside);
      };
    }
  }, [showTierTooltip]);

  const handleStake = async () => {
    if (!stakeAmount || Number(stakeAmount) <= 0 || !account?.address) return;
    
    setSubmitting(true);
    try {
      // TODO: Call stake_unx() function from contract
      await new Promise(resolve => setTimeout(resolve, 2000)); // Mock delay
      console.log(`Staking ${stakeAmount} UNXV`);
      setStakeAmount('');
    } catch (error) {
      console.error('Staking transaction failed:', error);
    } finally {
      setSubmitting(false);
    }
  };

  const handleClaimRewards = async () => {
    if (claimableRewards <= 0 || !account?.address) return;
    
    setSubmitting(true);
    try {
      // TODO: Call claim_rewards() function from contract
      await new Promise(resolve => setTimeout(resolve, 2000)); // Mock delay
      console.log(`Claiming ${claimableRewards} UNXV rewards`);
    } catch (error) {
      console.error('Claim rewards transaction failed:', error);
    } finally {
      setSubmitting(false);
    }
  };

    return (
      <div className={styles.root}>
        <div className={styles.stakingContainer}>
          {/* Title */}
          <div className={styles.title}>Staking</div>
          
          {/* Action Badges Row */}
          <div className={styles.actionBadgesRow}>
            <div className={styles.actionBadges}>
              <button
                className={`${styles.actionBadge} ${styles.stakeBadge} ${activeAction === 'stake' ? styles.active : ''}`}
                onClick={() => setActiveAction(activeAction === 'stake' ? null : 'stake')}
              >
                Stake
              </button>
              <button
                className={`${styles.actionBadge} ${styles.unstakeBadge} ${activeAction === 'unstake' ? styles.active : ''}`}
                onClick={() => setActiveAction(activeAction === 'unstake' ? null : 'unstake')}
              >
                Unstake
              </button>
              <button
                className={`${styles.actionBadge} ${styles.claimBadge} ${activeAction === 'claim' ? styles.active : ''}`}
                onClick={() => setActiveAction(activeAction === 'claim' ? null : 'claim')}
              >
                Claim
              </button>
            </div>
          </div>
        
        {/* Description */}
        <div className={styles.description}>
          Stake your UNXV to get fee discounts across all protocols and earn a share of protocol fees.
        </div>

        {/* Stats Section */}
        <div className={styles.statsSection}>
          <div className={styles.statItem}>
            <div className={styles.statLabel}>Your Staked</div>
            <div className={styles.statValue}>{stakedAmount.toLocaleString()} UNXV</div>
          </div>
          <div className={styles.statItem}>
            <div className={styles.statLabel}>Claimable Rewards</div>
            <div className={`${styles.statValue} ${styles.claimableRewardsValue}`}>
              {claimableRewards.toFixed(2)} UNXV
            </div>
          </div>
          <div className={styles.statItem}>
            <div className={styles.tierSection}>
              <div className={styles.statLabel}>
                Current Tier
                <button
                  type="button"
                  className={styles.helpButton}
                  onClick={(e) => {
                    e.preventDefault();
                    e.stopPropagation();
                    setShowTierTooltip(!showTierTooltip);
                  }}
                >
                  <HelpCircle size={14} />
                </button>
              </div>
              <div className={styles.tierValue}>
                {userTier.name} ({userTier.discount} discount)
              </div>
              {showTierTooltip && (
                <div ref={tooltipRef} className={styles.tooltip}>
                  <div className={styles.tooltipContent}>
                    <div className={styles.tooltipTitle}>Staking Tiers</div>
                    <div className={styles.tierList}>
                      <div className={styles.tierItem}>
                        <span className={styles.tierName}>Midnight Ocean</span>
                        <span className={styles.tierRequirement}>500K+ UNXV: 40% discount</span>
                      </div>
                      <div className={styles.tierItem}>
                        <span className={styles.tierName}>Cobalt Trench</span>
                        <span className={styles.tierRequirement}>100K+ UNXV: 30% discount</span>
                      </div>
                      <div className={styles.tierItem}>
                        <span className={styles.tierName}>Indigo Waves</span>
                        <span className={styles.tierRequirement}>10K+ UNXV: 20% discount</span>
                      </div>
                      <div className={styles.tierItem}>
                        <span className={styles.tierName}>Teal Harbor</span>
                        <span className={styles.tierRequirement}>1K+ UNXV: 15% discount</span>
                      </div>
                      <div className={styles.tierItem}>
                        <span className={styles.tierName}>Silver Stream</span>
                        <span className={styles.tierRequirement}>100+ UNXV: 10% discount</span>
                      </div>
                      <div className={styles.tierItem}>
                        <span className={styles.tierName}>Crystal Pool</span>
                        <span className={styles.tierRequirement}>10+ UNXV: 5% discount</span>
                      </div>
                      <div className={styles.tierItem}>
                        <span className={styles.tierName}>Frost Shore</span>
                        <span className={styles.tierRequirement}>0 UNXV: No discount</span>
                      </div>
                    </div>
                  </div>
                </div>
              )}
            </div>
          </div>
          <div className={styles.statItem}>
            <div className={styles.statLabel}>Claimed Rewards</div>
            <div className={`${styles.statValue} ${styles.rewardsValue}`}>
              1,234.56 UNXV
            </div>
          </div>
        </div>

        {/* Action Content Based on Selection */}
        {activeAction === 'stake' && (
          <div className={styles.actionContent}>
            <div className={styles.stakeSection}>
              <div className={styles.sectionLabel}>Stake UNXV</div>
              <div className={styles.inputContainer}>
                <input
                  type="number"
                  placeholder="0"
                  value={stakeAmount}
                  onChange={(e) => setStakeAmount(e.target.value)}
                  className={styles.amountInput}
                />
                <div className={styles.balanceLabel}>
                  Balance: {userBalance.toLocaleString()} UNXV
                </div>
              </div>
            </div>
            {/* Action Button Below Card */}
            {account?.address ? (
              <button
                className={styles.executeButton}
                onClick={handleStake}
                disabled={submitting || !stakeAmount || Number(stakeAmount) <= 0}
              >
                {submitting ? 'Staking...' : 'Execute Stake'}
              </button>
            ) : (
              <div className={styles.connectWalletContainer}>
                <ConnectButton />
              </div>
            )}
          </div>
        )}

        {activeAction === 'unstake' && (
          <div className={styles.actionContent}>
            <div className={styles.unstakeSection}>
              <div className={styles.sectionLabel}>Unstake UNXV</div>
              <div className={styles.inputContainer}>
                <input
                  type="number"
                  placeholder="0"
                  value={stakeAmount}
                  onChange={(e) => setStakeAmount(e.target.value)}
                  className={styles.amountInput}
                />
                <div className={styles.balanceLabel}>
                  Staked: {stakedAmount.toLocaleString()} UNXV
                </div>
              </div>
            </div>
            {/* Action Button Below Card */}
            {account?.address ? (
              <button
                className={styles.executeButton}
                onClick={() => console.log('Unstake')} // TODO: Implement unstake
                disabled={submitting || !stakeAmount || Number(stakeAmount) <= 0}
              >
                {submitting ? 'Unstaking...' : 'Execute Unstake'}
              </button>
            ) : (
              <div className={styles.connectWalletContainer}>
                <ConnectButton />
              </div>
            )}
          </div>
        )}

        {activeAction === 'claim' && (
          <div className={styles.actionContent}>
            <div className={styles.claimSection}>
              <div className={styles.sectionLabel}>Claim Rewards</div>
              <div className={styles.claimInfo}>
                <div className={styles.claimAmount}>
                  {claimableRewards.toFixed(2)} UNXV
                </div>
                <div className={styles.claimLabel}>Available to claim</div>
              </div>
            </div>
            {/* Action Button Below Card */}
            {account?.address ? (
              <button
                className={styles.executeButton}
                onClick={handleClaimRewards}
                disabled={submitting || claimableRewards <= 0}
              >
                {submitting ? 'Claiming...' : 'Execute Claim'}
              </button>
            ) : (
              <div className={styles.connectWalletContainer}>
                <ConnectButton />
              </div>
            )}
          </div>
        )}
      </div>
    </div>
  );
}
