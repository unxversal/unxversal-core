import { useMemo, useState } from 'react';
import { StakingComponent } from './StakingComponent';
import { stakingSampleData } from './stakingSampleData';
import type { StakingComponentProps } from './types';
import { ConnectButton, useCurrentAccount } from '@mysten/dapp-kit';

export function StakingWrapper({ useSampleData }: { useSampleData: boolean }) {
  const [selectedAction, setSelectedAction] = useState<StakingComponentProps['selectedAction']>('stake');
  const [inputAmount, setInputAmount] = useState('');
  const [submitting, setSubmitting] = useState(false);
  const account = useCurrentAccount();

  const base = useMemo(() => {
    if (useSampleData) return stakingSampleData;
    // For now, if not using sample data, show an empty, disabled view.
    const empty: StakingComponentProps = {
      poolId: 'unknown',
      symbol: 'UNXV',
      decimals: 9,
      currentWeek: 0,
      totalActiveStake: 0n,
      stakeVaultBalance: 0n,
      rewardVaultBalance: 0n,
      rewardThisWeek: 0n,
      weeklySnapshots: [],
      apyEstimate: 0,
      nextWeekStartMs: Date.now() + 7 * 24 * 60 * 60 * 1000,
      address: account?.address,
      walletUnxvBalance: 0n,
      staker: {
        activeStake: 0n,
        pendingStake: 0n,
        activateWeek: 0,
        pendingUnstake: 0n,
        deactivateWeek: 0,
        lastClaimedWeek: 0,
      },
      claimableRewards: 0n,
      claimedToWeek: 0,
      claimedRewardsTotal: 0n,
      tier: { tier: 0, name: 'Frost Shore', discountPct: 0 },
      selectedAction,
      submitting,
      inputAmount,
      onChangeInputAmount: setInputAmount,
      onSelectAction: setSelectedAction,
      onStake: async () => {},
      onUnstake: async () => {},
      onClaim: async () => {},
      renderConnect: <ConnectButton />,
    };
    return empty;
  }, [useSampleData, selectedAction, submitting, inputAmount, account?.address]);

  async function fakeWait() {
    return new Promise((r) => setTimeout(r, 300));
  }

  return (
    <StakingComponent
      {...base}
      address={account?.address}
      selectedAction={selectedAction}
      inputAmount={inputAmount}
      submitting={submitting}
      onChangeInputAmount={setInputAmount}
      onSelectAction={setSelectedAction}
      onStake={async () => { setSubmitting(true); try { await fakeWait(); } finally { setSubmitting(false); } }}
      onUnstake={async () => { setSubmitting(true); try { await fakeWait(); } finally { setSubmitting(false); } }}
      onClaim={async () => { setSubmitting(true); try { await fakeWait(); } finally { setSubmitting(false); } }}
    />
  );
}

export default StakingWrapper;


