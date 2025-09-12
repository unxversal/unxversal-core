export interface StakingPoolSummary {
  poolId: string;
  symbol: string;
  decimals: number;
  currentWeek: number;
  totalActiveStake: bigint;
  stakeVaultBalance: bigint;
  rewardVaultBalance: bigint;
  rewardThisWeek: bigint;
  weeklySnapshots?: Array<{ week: number; active: bigint; reward: bigint }>;
  apyEstimate?: number;
  nextWeekStartMs: number;
}

export interface StakingUserState {
  address?: string;
  walletUnxvBalance: bigint;
  staker: {
    activeStake: bigint;
    pendingStake: bigint;
    activateWeek: number;
    pendingUnstake: bigint;
    deactivateWeek: number;
    lastClaimedWeek: number;
  };
  claimableRewards: bigint;
  claimedToWeek?: number;
  tier?: { tier: number; name: string; discountPct: number };
}

export type StakingAction = 'stake' | 'unstake' | 'claim' | null;

export interface StakingComponentProps extends StakingPoolSummary, StakingUserState {
  // UI/controls
  selectedAction: StakingAction;
  submitting: boolean;
  inputAmount: string;
  onChangeInputAmount: (value: string) => void;
  onSelectAction?: (action: StakingAction) => void;

  // Actions
  onStake: (args: { amount: bigint; coinIds?: string[] }) => Promise<void>;
  onUnstake: (args: { amount: bigint }) => Promise<void>;
  onClaim: () => Promise<void>;

  // Optional custom connect UI render node for wrappers to inject wallet connect UI
  renderConnect?: React.ReactNode;
}


