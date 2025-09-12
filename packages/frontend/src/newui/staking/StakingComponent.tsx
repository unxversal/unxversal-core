import { useEffect, useRef, useState } from 'react';
import styles from '../../components/staking/StakingScreen.module.css';
import { HelpCircle } from 'lucide-react';
import type { StakingAction, StakingComponentProps } from './types';

function formatUnits(amount: bigint, decimals: number, maxFrac = 4): string {
  const negative = amount < 0n;
  const abs = negative ? -amount : amount;
  const base = 10n ** BigInt(decimals);
  const whole = abs / base;
  const frac = abs % base;
  const fracStr = frac.toString().padStart(decimals, '0').slice(0, maxFrac).replace(/0+$/, '');
  return `${negative ? '-' : ''}${whole.toLocaleString()}${fracStr ? '.' + fracStr : ''}`;
}

export function StakingComponent(props: StakingComponentProps) {
  const {
    symbol,
    decimals,
    walletUnxvBalance,
    staker,
    claimableRewards,
    claimedRewardsTotal,
    tier,
    selectedAction,
    submitting,
    inputAmount,
    onChangeInputAmount,
    onSelectAction,
    onStake,
    onUnstake,
    onClaim,
    renderConnect,
    address,
  } = props;

  const [showTierTooltip, setShowTierTooltip] = useState(false);
  const tooltipRef = useRef<HTMLDivElement>(null);
  // no-op: preserve semantic parity with old screen's disabled logic handled inline

  useEffect(() => {
    function handleClickOutside(event: MouseEvent) {
      if (tooltipRef.current && !tooltipRef.current.contains(event.target as Node)) {
        setShowTierTooltip(false);
      }
    }
    if (showTierTooltip) {
      document.addEventListener('mousedown', handleClickOutside);
      return () => { document.removeEventListener('mousedown', handleClickOutside); };
    }
  }, [showTierTooltip]);

  async function handleExecute() {
    if (selectedAction === 'claim') {
      await onClaim();
      return;
    }
    const asBigInt = (() => {
      const trimmed = (inputAmount || '').trim();
      if (!trimmed) return 0n;
      // parse decimal string to bigint in base units
      const [w, f = ''] = trimmed.split('.');
      const fracPadded = (f + '0'.repeat(decimals)).slice(0, decimals);
      const s = (w || '0') + fracPadded;
      try { return BigInt(s); } catch { return 0n; }
    })();
    if (asBigInt <= 0n) return;
    if (selectedAction === 'stake') {
      await onStake({ amount: asBigInt });
      return;
    }
    if (selectedAction === 'unstake') {
      await onUnstake({ amount: asBigInt });
      return;
    }
  }

  function actionCtaLabel(action: StakingAction): string {
    if (action === 'stake') return submitting ? 'Staking…' : 'Execute Stake';
    if (action === 'unstake') return submitting ? 'Unstaking…' : 'Execute Unstake';
    if (action === 'claim') return submitting ? 'Claiming…' : 'Execute Claim';
    return 'Execute';
  }

  const badgeCls = (base: string, action: StakingAction) => `${styles.actionBadge} ${base} ${selectedAction === action ? styles.active : ''}`;

  const stakedAmountDisplay = `${formatUnits(staker.activeStake, decimals)} ${symbol}`;
  const claimableDisplay = `${formatUnits(claimableRewards, decimals, 2)} ${symbol}`;
  const claimedDisplay = `${formatUnits(claimedRewardsTotal ?? 0n, decimals, 2)} ${symbol}`;
  const tierName = tier ? tier.name : 'Frost Shore';
  const tierDiscount = tier ? `${tier.discountPct}%` : '0%';

  return (
    <div className={styles.root}>
      <div className={styles.stakingContainer}>
        <div className={styles.title}>Staking</div>

        <div className={styles.actionBadgesRow}>
          <div className={styles.actionBadges}>
            <button className={badgeCls(styles.stakeBadge, 'stake')} onClick={() => onSelectAction && onSelectAction(selectedAction === 'stake' ? null : 'stake')}>Stake</button>
            <button className={badgeCls(styles.unstakeBadge, 'unstake')} onClick={() => onSelectAction && onSelectAction(selectedAction === 'unstake' ? null : 'unstake')}>Unstake</button>
            <button className={badgeCls(styles.claimBadge, 'claim')} onClick={() => onSelectAction && onSelectAction(selectedAction === 'claim' ? null : 'claim')}>Claim</button>
          </div>
        </div>

        <div className={styles.description}>
          Stake your UNXV to get fee discounts across all protocols and earn a share of protocol fees.
        </div>

        <div className={styles.statsSection}>
          <div className={styles.statItem}>
            <div className={styles.statLabel}>Your Staked</div>
            <div className={styles.statValue}>{stakedAmountDisplay}</div>
          </div>
          <div className={styles.statItem}>
            <div className={styles.statLabel}>Claimable Rewards</div>
            <div className={`${styles.statValue} ${styles.claimableRewardsValue}`}>{claimableDisplay}</div>
          </div>
          <div className={styles.statItem}>
            <div className={styles.tierSection}>
              <div className={styles.statLabel}>
                Current Tier
                <button
                  type="button"
                  className={styles.helpButton}
                  onClick={(e) => { e.preventDefault(); e.stopPropagation(); setShowTierTooltip(!showTierTooltip); }}
                >
                  <HelpCircle size={14} />
                </button>
              </div>
              <div className={styles.tierValue}>{tierName} ({tierDiscount} discount)</div>
              {showTierTooltip && (
                <div ref={tooltipRef} className={styles.tooltip}>
                  <div className={styles.tooltipContent}>
                    <div className={styles.tooltipTitle}>Staking Tiers</div>
                    <div className={styles.tierList}>
                      <div className={styles.tierItem}><span className={styles.tierName}>Midnight Ocean</span><span className={styles.tierRequirement}>500K+ UNXV: 40% discount</span></div>
                      <div className={styles.tierItem}><span className={styles.tierName}>Cobalt Trench</span><span className={styles.tierRequirement}>100K+ UNXV: 30% discount</span></div>
                      <div className={styles.tierItem}><span className={styles.tierName}>Indigo Waves</span><span className={styles.tierRequirement}>10K+ UNXV: 20% discount</span></div>
                      <div className={styles.tierItem}><span className={styles.tierName}>Teal Harbor</span><span className={styles.tierRequirement}>1K+ UNXV: 15% discount</span></div>
                      <div className={styles.tierItem}><span className={styles.tierName}>Silver Stream</span><span className={styles.tierRequirement}>100+ UNXV: 10% discount</span></div>
                      <div className={styles.tierItem}><span className={styles.tierName}>Crystal Pool</span><span className={styles.tierRequirement}>10+ UNXV: 5% discount</span></div>
                      <div className={styles.tierItem}><span className={styles.tierName}>Frost Shore</span><span className={styles.tierRequirement}>0 UNXV: No discount</span></div>
                    </div>
                  </div>
                </div>
              )}
            </div>
          </div>
          <div className={styles.statItem}>
            <div className={styles.statLabel}>Claimed Rewards</div>
            <div className={`${styles.statValue} ${styles.rewardsValue}`}>{claimedDisplay}</div>
          </div>
        </div>

        {selectedAction === 'stake' && (
          <div className={styles.actionContent}>
            <div className={styles.stakeSection}>
              <div className={styles.sectionLabel}>Stake UNXV</div>
              <div className={styles.inputContainer}>
                <input
                  type="number"
                  placeholder="0"
                  value={inputAmount}
                  onChange={(e) => onChangeInputAmount(e.target.value)}
                  className={styles.amountInput}
                />
                <div className={styles.balanceLabel}>Balance: {formatUnits(walletUnxvBalance, decimals)} {symbol}</div>
              </div>
            </div>
            {address ? (
              <button className={styles.executeButton} onClick={handleExecute} disabled={submitting || !inputAmount || Number(inputAmount) <= 0}>
                {actionCtaLabel('stake')}
              </button>
            ) : (
              <div className={styles.connectWalletContainer}>{renderConnect}</div>
            )}
          </div>
        )}

        {selectedAction === 'unstake' && (
          <div className={styles.actionContent}>
            <div className={styles.unstakeSection}>
              <div className={styles.sectionLabel}>Unstake UNXV</div>
              <div className={styles.inputContainer}>
                <input
                  type="number"
                  placeholder="0"
                  value={inputAmount}
                  onChange={(e) => onChangeInputAmount(e.target.value)}
                  className={styles.amountInput}
                />
                <div className={styles.balanceLabel}>Staked: {formatUnits(staker.activeStake, decimals)} {symbol}</div>
              </div>
            </div>
            {address ? (
              <button className={styles.executeButton} onClick={handleExecute} disabled={submitting || !inputAmount || Number(inputAmount) <= 0}>
                {actionCtaLabel('unstake')}
              </button>
            ) : (
              <div className={styles.connectWalletContainer}>{renderConnect}</div>
            )}
          </div>
        )}

        {selectedAction === 'claim' && (
          <div className={styles.actionContent}>
            <div className={styles.claimSection}>
              <div className={styles.sectionLabel}>Claim Rewards</div>
              <div className={styles.claimInfo}>
                <div className={styles.claimAmount}>{claimableDisplay}</div>
                <div className={styles.claimLabel}>Available to claim</div>
              </div>
            </div>
            {address ? (
              <button className={styles.executeButton} onClick={handleExecute} disabled={submitting || claimableRewards <= 0n}>
                {actionCtaLabel('claim')}
              </button>
            ) : (
              <div className={styles.connectWalletContainer}>{renderConnect}</div>
            )}
          </div>
        )}
      </div>
    </div>
  );
}

export default StakingComponent;


