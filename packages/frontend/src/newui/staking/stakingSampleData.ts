import type { StakingComponentProps } from './types';

export const stakingSampleData: StakingComponentProps = {
  // Pool summary
  poolId: '0xpool_staking_unxv',
  symbol: 'UNXV',
  decimals: 9,
  currentWeek: 1234,
  totalActiveStake: 1_234_567_890_000_000_000n,
  stakeVaultBalance: 1_500_000_000_000_000_000n,
  rewardVaultBalance: 12_345_678_900n,
  rewardThisWeek: 987_654_321n,
  weeklySnapshots: Array.from({ length: 8 }).map((_, i) => ({
    week: 1226 + i,
    active: BigInt(1_000_000_000_000_000_000 + i * 10_000_000_000_000_000),
    reward: BigInt(800_000_000 + i * 10_000_000),
  })),
  apyEstimate: 18.4,
  nextWeekStartMs: Date.now() + 3 * 24 * 60 * 60 * 1000 + 3600 * 1000,

  // User state
  address: '0xuser',
  walletUnxvBalance: 123_456_789_000n,
  staker: {
    activeStake: 25_000_000_000n,
    pendingStake: 2_500_000_000n,
    activateWeek: 1235,
    pendingUnstake: 0n,
    deactivateWeek: 0,
    lastClaimedWeek: 1232,
  },
  claimableRewards: 347_850_000n,
  claimedToWeek: 1232,
  claimedRewardsTotal: 1_234_560_000n,
  tier: { tier: 3, name: 'Teal Harbor', discountPct: 15 },

  // UI controls default
  selectedAction: 'stake',
  submitting: false,
  inputAmount: '',
  onChangeInputAmount: () => {},
  onSelectAction: () => {},
  onStake: async () => {},
  onUnstake: async () => {},
  onClaim: async () => {},
  renderConnect: null,
};


