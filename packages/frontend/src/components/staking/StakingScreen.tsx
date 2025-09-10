import { useState } from 'react';
import styles from './StakingScreen.module.css';
import { ConnectButton, useCurrentAccount } from '@mysten/dapp-kit';


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
  const account = useCurrentAccount();

  // Mock data - in real implementation, this would come from the contract
  const userBalance = 50000; // UNXV balance
  const stakedAmount = 25000; // Currently staked UNXV
  const claimableRewards = 347.85; // Claimable rewards
  const currentAPY = 18.2; // Current APY

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
        {/* Stats Section */}
        <div className={styles.statsSection}>
          <div className={styles.statItem}>
            <div className={styles.statLabel}>Your Staked</div>
            <div className={styles.statValue}>{stakedAmount.toLocaleString()} UNXV</div>
          </div>
          <div className={styles.statItem}>
            <div className={styles.statLabel}>Claimable Rewards</div>
            <div className={styles.statValue}>{claimableRewards.toFixed(2)} UNXV</div>
          </div>
          <div className={styles.statItem}>
            <div className={styles.statLabel}>Current APY</div>
            <div className={styles.statValue}>{currentAPY}%</div>
          </div>
        </div>

        {/* Stake Section */}
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

        {/* Action Buttons */}
        <div className={styles.actionSection}>
          {!account?.address ? (
            <div className={styles.connectWalletContainer}>
              <ConnectButton />
            </div>
          ) : (
            <>
              <button 
                className={styles.stakeButton}
                onClick={handleStake}
                disabled={submitting || !stakeAmount || Number(stakeAmount) <= 0}
              >
                {submitting ? 'Staking...' : 'Stake UNXV'}
              </button>
              
              {claimableRewards > 0 && (
                <button 
                  className={styles.claimButton}
                  onClick={handleClaimRewards}
                  disabled={submitting}
                >
                  {submitting ? 'Claiming...' : `Claim ${claimableRewards.toFixed(2)} UNXV`}
                </button>
              )}
            </>
          )}
        </div>
      </div>
    </div>
  );
}
