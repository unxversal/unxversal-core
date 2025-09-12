import { useMemo, useState } from 'react';
import { StakingComponent } from './StakingComponent';
import { stakingSampleData } from './stakingSampleData';
import type { StakingComponentProps } from './types';
import { ConnectButton, useCurrentAccount } from '@mysten/dapp-kit';
import { useStakingData } from './useStakingData';

export function StakingWrapper({ useSampleData }: { useSampleData: boolean }) {
  const [selectedAction, setSelectedAction] = useState<StakingComponentProps['selectedAction']>('stake');
  const [inputAmount, setInputAmount] = useState('');
  const [submitting, setSubmitting] = useState(false);
  const account = useCurrentAccount();
  const { data, loading: _loading, refresh, submitStake, submitUnstake, submitClaim } = useStakingData(account?.address);

  const base = useMemo(() => {
    if (useSampleData) return stakingSampleData;
    // For now, if not using sample data, show an empty, disabled view.
    const empty: StakingComponentProps = {
      poolId: 'unknown',
      symbol: 'UNXV',
      decimals: 9,
      currentWeek: data?.currentWeek ?? 0,
      totalActiveStake: data?.totalActiveStake ?? 0n,
      stakeVaultBalance: data?.stakeVaultBalance ?? 0n,
      rewardVaultBalance: data?.rewardVaultBalance ?? 0n,
      rewardThisWeek: data?.rewardThisWeek ?? 0n,
      weeklySnapshots: data?.weeklySnapshots ?? [],
      apyEstimate: data?.apyEstimate ?? 0,
      nextWeekStartMs: data?.nextWeekStartMs ?? (Date.now() + 7 * 24 * 60 * 60 * 1000),
      address: data?.address ?? account?.address,
      walletUnxvBalance: data?.walletUnxvBalance ?? 0n,
      staker: data?.staker ?? {
        activeStake: 0n,
        pendingStake: 0n,
        activateWeek: 0,
        pendingUnstake: 0n,
        deactivateWeek: 0,
        lastClaimedWeek: 0,
      },
      claimableRewards: data?.claimableRewards ?? 0n,
      claimedToWeek: data?.claimedToWeek ?? 0,
      claimedRewardsTotal: data?.claimedRewardsTotal ?? 0n,
      tier: data?.tier ?? { tier: 0, name: 'Frost Shore', discountPct: 0 },
      selectedAction,
      submitting,
      inputAmount,
      onChangeInputAmount: setInputAmount,
      onSelectAction: setSelectedAction,
      onStake: async ({ amount }) => { await submitStake(amount); },
      onUnstake: async ({ amount }) => { await submitUnstake(amount); },
      onClaim: async () => { await submitClaim(); },
      renderConnect: <ConnectButton />,
    };
    return empty;
  }, [useSampleData, selectedAction, submitting, inputAmount, account?.address, data, refresh]);

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


