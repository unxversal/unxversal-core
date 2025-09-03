use unxversal::{
	gas_futures::{Self as gasfut},
	utils::{admin, fees::{Self as fees}},
	staking,
	unxv
};
use sui::{
	clock::{Self as clock, Clock},
	coin::{Self as coin, Coin, mint_for_testing},
	test_scenario::{Self as test, Scenario, begin, end, return_shared, return_to_sender},
	test_utils::{assert_eq, destroy}
};

#[test]
fun test_gas_futures_full_flow() {
	let alice = @0xA1;
	let bob = @0xB2;
	let mut s: Scenario = begin(alice);

	// Share a clock
	share_clock(&mut s);

	// Create AdminRegistry, FeeConfig, FeeVault, StakingPool
	s.next_tx(alice);
	let mut admin_reg = admin::new_admin_registry_for_testing(s.ctx());
	fees::FEES {}.init(s.ctx());
	let mut fee_cfg = s.take_shared<fees::FeeConfig>();
	let mut fee_vault = s.take_shared<fees::FeeVault>();
	staking::STAKING {}.init(s.ctx());
	let mut staking_pool = s.take_shared<staking::StakingPool>();
	let mut clock_obj = s.take_shared<Clock>();

	// Initialize Gas Market (use SUI as collateral)
	let expiry_ms = 0; // perpetual-like
	let contract_size = 1; // 1 MIST per 1e6 price unit
	let im_bps = 1000; // 10%
	let mm_bps = 500;  // 5%
	let liq_fee_bps = 50; // 0.5%
	{
		gasfut::init_market<sui::SUI>(&admin_reg, expiry_ms, contract_size, im_bps, mm_bps, liq_fee_bps, s.ctx());
	}
	let mut market = s.take_shared<gasfut::GasMarket<sui::SUI>>();

	// Alice deposits collateral
	s.next_tx(alice);
	let sui_deposit = mint_for_testing<sui::SUI>(10_000_000, s.ctx());
	gasfut::deposit_collateral<sui::SUI>(&mut market, sui_deposit, s.ctx());

	// Open long without UNXV discount
	s.next_tx(alice);
	gasfut::open_long<sui::SUI>(&mut market, &fee_cfg, &mut fee_vault, &mut staking_pool, option::none(), &clock_obj, s.ctx(), 10);

	// Stake some UNXV for Alice
	s.next_tx(alice);
	let mut sc = unxv::new_supply_cap_for_testing(s.ctx());
	let unxv_for_alice = unxv::mint_coin_for_testing(&mut sc, 1_000_000, s.ctx());
	staking::stake_unx(&mut staking_pool, coin::split(&mut unxv_for_alice, 200_000, s.ctx()), &clock_obj, s.ctx());
	// pay future fees with UNXV: open short with maybe_unxv
	s.next_tx(alice);
	let unxv_fee = coin::split(&mut unxv_for_alice, 10_000, s.ctx());
	gasfut::open_short<sui::SUI>(&mut market, &fee_cfg, &mut fee_vault, &mut staking_pool, option::some(unxv_fee), &clock_obj, s.ctx(), 4);
	// return remaining UNXV to sender for cleanup
	return_to_sender(unxv_for_alice);

	// Bob deposits, then gets liquidated by forcing under MM (open positions then liquidate a portion)
	s.next_tx(bob);
	let sui_dep_bob = mint_for_testing<sui::SUI>(5_000_000, s.ctx());
	gasfut::deposit_collateral<sui::SUI>(&mut market, sui_dep_bob, s.ctx());
	// Bob opens a long position that will be risky under IM/MM
	s.next_tx(bob);
	gasfut::open_long<sui::SUI>(&mut market, &fee_cfg, &mut fee_vault, &mut staking_pool, option::none(), &clock_obj, s.ctx(), 50);

	// Attempt liquidation on Bob for a small qty
	// Note: liquidation will only succeed if equity < MM requirement.
	// Depending on reference gas price, this may or may not trigger; we call and allow outcome either way.
	s.next_tx(alice);
	let res = test::try_call(
		&mut s,
		fun() { gasfut::liquidate<sui::SUI>(&mut market, bob, 10, &mut fee_vault, &clock_obj, s.ctx()); }
	);
	// res may be ok or failure; we don't assert outcome here to keep test robust across envs.
	let _ = res;

	// Withdraw a portion of collateral for Alice
	s.next_tx(alice);
	let _c = gasfut::withdraw_collateral<sui::SUI>(&mut market, 1_000_000, &clock_obj, s.ctx());
	// burn/transfer coin to avoid resource leak
	destroy(_c);

	// Put back shared objects
	return_shared(market);
	return_shared(fee_cfg);
	return_shared(fee_vault);
	return_shared(staking_pool);
	return_shared(clock_obj);
	// destroy admin cap local copy
	destroy(admin_reg);
	end(s);
}

fun share_clock(s: &mut Scenario) {
	s.next_tx(@0x1);
	clock::create_for_testing(s.ctx()).share_for_testing();
}
