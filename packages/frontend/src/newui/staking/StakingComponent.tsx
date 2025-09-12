import { useMemo } from 'react';
import styles from './StakingComponent.module.css';
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
    currentWeek,
    totalActiveStake,
    rewardThisWeek,
    nextWeekStartMs,
    walletUnxvBalance,
    staker,
    claimableRewards,
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
  } = props;

  const now = Date.now();
  const timeToNextWeekMs = Math.max(0, nextWeekStartMs - now);
  const countdown = useMemo(() => {
    const s = Math.floor(timeToNextWeekMs / 1000);
    const d = Math.floor(s / 86400);
    const h = Math.floor((s % 86400) / 3600);
    const m = Math.floor((s % 3600) / 60);
    const ss = s % 60;
    return `${d}d ${h}h ${m}m ${ss}s`;
  }, [timeToNextWeekMs]);

  const disabled = submitting;

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

  return (
    <div className={styles.root}>
      <div className={styles.titleRow}>
        <div className={styles.title}>Staking</div>
        <div className={styles.badgesRow}>
          {(['stake', 'unstake', 'claim'] as StakingAction[]).map((action) => (
            <button
              key={action || 'none'}
              className={`${styles.badge} ${selectedAction === action ? styles.badgeActive : ''}`}
              onClick={() => onSelectAction && onSelectAction(selectedAction === action ? null : action)}
            >
              {action?.slice(0, 1).toUpperCase()}{action?.slice(1)}
            </button>
          ))}
        </div>
      </div>

      <div className={styles.grid}>
        <div className={styles.card}>
          <div className={styles.cardTitle}>Total Active</div>
          <div className={styles.cardValue}>{formatUnits(totalActiveStake, decimals)} {symbol}</div>
        </div>
        <div className={styles.card}>
          <div className={styles.cardTitle}>Reward (This Week)</div>
          <div className={styles.cardValue}>{formatUnits(rewardThisWeek, decimals)} {symbol}</div>
        </div>
        <div className={styles.card}>
          <div className={styles.cardTitle}>Week / Next rollover</div>
          <div className={styles.cardValue}>#{currentWeek} / {countdown}</div>
        </div>
        <div className={styles.card}>
          <div className={styles.cardTitle}>Your Active</div>
          <div className={styles.cardValue}>{formatUnits(staker.activeStake, decimals)} {symbol}</div>
        </div>
        <div className={styles.card}>
          <div className={styles.cardTitle}>Pending Stake</div>
          <div className={styles.cardValue}>{formatUnits(staker.pendingStake, decimals)} {symbol}</div>
        </div>
        <div className={styles.card}>
          <div className={styles.cardTitle}>Claimable Rewards</div>
          <div className={styles.cardValue}>{formatUnits(claimableRewards, decimals)} {symbol}</div>
        </div>
      </div>

      <div className={styles.actionArea}>
        {renderConnect}
        {selectedAction !== 'claim' && (
          <div className={styles.inputRow}>
            <input
              className={styles.amountInput}
              value={inputAmount}
              onChange={(e) => onChangeInputAmount(e.target.value)}
              placeholder={`0.0 ${symbol}`}
              type="number"
              min="0"
            />
          </div>
        )}
        <div className={styles.hint}>
          Wallet: {formatUnits(walletUnxvBalance, decimals)} {symbol} · Tier: {tier ? `${tier.name} (${tier.discountPct}%)` : '—'}
        </div>
        {selectedAction && (
          <button className={styles.cta} disabled={disabled} onClick={handleExecute}>
            {actionCtaLabel(selectedAction)}
          </button>
        )}
      </div>
    </div>
  );
}

export default StakingComponent;


