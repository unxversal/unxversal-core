#[test_only]
module unxversal::gas_futures_tests {
	use unxversal::{
		gas_futures::{Self as gasfut},
		admin,
		fees::{Self as fees},
		staking,
		unxv,
	};
	use sui::{
		clock::{Self as clock, Clock},
		coin::{Self as coin, mint_for_testing},
		sui::SUI,
		// transfer alias not needed
		test_scenario::{Scenario, begin, end, return_shared},
		test_utils::{destroy, assert_eq},
	};
	use std::debug;

	#[test]
	fun test_gas_futures_full_flow() {
		let alice = @0xA1;
		let bob = @0xB2;
		let mut s: Scenario = begin(alice);

		// Share a clock
		share_clock(&mut s);
		debug::print<vector<u8>>(&b"[start] gas_futures full-flow");
		let rgp = sui::tx_context::reference_gas_price(s.ctx());
		debug::print<vector<u8>>(&b"reference_gas_price (mist):");
		debug::print<u64>(&rgp);

		// Create AdminRegistry, FeeConfig, FeeVault, StakingPool via test-only constructors
		s.next_tx(alice);
		let admin_reg = admin::new_admin_registry_for_testing(s.ctx());
		let mut fee_cfg = fees::new_fee_config_for_testing(s.ctx());
		let mut fee_vault = fees::new_fee_vault_for_testing(s.ctx());
		let mut staking_pool = staking::new_staking_pool_for_testing(s.ctx());
		let clock_obj = s.take_shared<Clock>();
		// Mint UNXV up-front for fee payments and staking
		let mut sc = unxv::new_supply_cap_for_testing(s.ctx());
		let mut unxv_for_alice = unxv::mint_coin_for_testing(&mut sc, 1_000_000, s.ctx());
		debug::print<vector<u8>>(&b"minted UNXV for alice:");
		let unxv_total = coin::value(&unxv_for_alice);
		debug::print<u64>(&unxv_total);
		// set minimal non-zero gas futures taker/maker fees (1 bps) so fee accrual has a positive amount
		fees::set_gasfutures_trade_fees(&admin_reg, &mut fee_cfg, 1, 1, s.ctx());
		debug::print<vector<u8>>(&b"gasfut taker bps:");
		let tbps = fees::gasfut_taker_fee_bps(&fee_cfg);
		debug::print<u64>(&tbps);

		// Initialize Gas Market (use SUI as collateral) with parameters that allow liquidation without price move
		let expiry_ms = 0;             // perpetual-like
		let contract_size = 1_000_000_000; // large size to magnify margin requirements
		let im_bps = 0;                // allow opening position regardless of equity
		let mm_bps = 9000;             // 90% maintenance margin to force under-MM
		let liq_fee_bps = 50;          // 0.5%
		{
			gasfut::init_market<SUI>(&admin_reg, expiry_ms, contract_size, im_bps, mm_bps, liq_fee_bps, s.ctx());
		};
		debug::print<vector<u8>>(&b"market params [contract_size, im_bps, mm_bps, liq_fee_bps]:");
		debug::print<u64>(&contract_size);
		debug::print<u64>(&im_bps);
		debug::print<u64>(&mm_bps);
		debug::print<u64>(&liq_fee_bps);
		// Start a new tx so the shared GasMarket is available to take
		s.next_tx(alice);
		let mut market = s.take_shared<gasfut::GasMarket<SUI>>();

		// Alice deposits collateral
		s.next_tx(alice);
		let sui_deposit = mint_for_testing<SUI>(10_000_000, s.ctx());
		debug::print<vector<u8>>(&b"alice deposit SUI:");
		debug::print<u64>(&coin::value(&sui_deposit));
		gasfut::deposit_collateral<SUI>(&mut market, sui_deposit, s.ctx());

		// Open long and pay fee in UNXV (ensures non-zero fee path)
		s.next_tx(alice);
		let unxv_fee1 = coin::split(&mut unxv_for_alice, 10_000, s.ctx());
		debug::print<vector<u8>>(&b"open_long qty:");
		debug::print<u64>(&10);
		debug::print<vector<u8>>(&b"pay fee UNXV amt:");
		debug::print<u64>(&coin::value(&unxv_fee1));
		gasfut::open_long<SUI>(&mut market, &fee_cfg, &mut fee_vault, &mut staking_pool, option::some(unxv_fee1), &clock_obj, s.ctx(), 10);

		// Stake some UNXV for Alice and pay a trade fee in UNXV on a short
		s.next_tx(alice);
		staking::stake_unx(&mut staking_pool, coin::split(&mut unxv_for_alice, 200_000, s.ctx()), &clock_obj, s.ctx());
		let staked = staking::active_stake_of(&staking_pool, alice);
		debug::print<vector<u8>>(&b"alice active stake:");
		debug::print<u64>(&staked);
		s.next_tx(alice);
		let unxv_fee = coin::split(&mut unxv_for_alice, 10_000, s.ctx());
		debug::print<vector<u8>>(&b"open_short qty:");
		debug::print<u64>(&4);
		debug::print<vector<u8>>(&b"pay fee UNXV amt:");
		debug::print<u64>(&coin::value(&unxv_fee));
		gasfut::open_short<SUI>(&mut market, &fee_cfg, &mut fee_vault, &mut staking_pool, option::some(unxv_fee), &clock_obj, s.ctx(), 4);
		destroy(unxv_for_alice);

		// Bob deposits, opens a very large long so that eq < MM, then liquidate
		s.next_tx(bob);
		let sui_dep_bob = mint_for_testing<SUI>(5_000_000, s.ctx());
		debug::print<vector<u8>>(&b"bob deposit SUI:");
		debug::print<u64>(&coin::value(&sui_dep_bob));
		gasfut::deposit_collateral<SUI>(&mut market, sui_dep_bob, s.ctx());
		s.next_tx(bob);
		let unxv_fee2 = unxv::mint_coin_for_testing(&mut sc, 10_000, s.ctx());
		debug::print<vector<u8>>(&b"bob open_long qty:");
		debug::print<u64>(&50_000);
		debug::print<vector<u8>>(&b"pay fee UNXV amt:");
		debug::print<u64>(&coin::value(&unxv_fee2));
		gasfut::open_long<SUI>(&mut market, &fee_cfg, &mut fee_vault, &mut staking_pool, option::some(unxv_fee2), &clock_obj, s.ctx(), 50_000);

		// Withdraw a portion of collateral for Alice
		s.next_tx(alice);
		let c = gasfut::withdraw_collateral<SUI>(&mut market, 1_000_000, &clock_obj, s.ctx());
		// destroy coin to avoid resource leaks
		debug::print<vector<u8>>(&b"alice withdraw SUI amt:");
		let wamt = coin::value(&c);
		debug::print<u64>(&wamt);
		destroy(c);

		// Put back shared objects
		return_shared(market);
		return_shared(clock_obj);
		// consume remaining local resources
		destroy(fee_cfg);
		destroy(fee_vault);
		destroy(staking_pool);
		destroy(sc);
		destroy(admin_reg);
		end(s);
	}

	#[test]
	fun test_init_and_set_margins() {
		let alice = @0xA1;
		let mut s: Scenario = begin(alice);
		share_clock(&mut s);
		s.next_tx(alice);
		let admin_reg = admin::new_admin_registry_for_testing(s.ctx());
		let fee_cfg = fees::new_fee_config_for_testing(s.ctx());
		let fee_vault = fees::new_fee_vault_for_testing(s.ctx());
		let staking_pool = staking::new_staking_pool_for_testing(s.ctx());
		let _clk = s.take_shared<Clock>();

		let expiry_ms = 0; let cs = 123; let im = 100; let mm = 200; let lf = 33;
		{ gasfut::init_market<SUI>(&admin_reg, expiry_ms, cs, im, mm, lf, s.ctx()); };
		s.next_tx(alice);
		let mut market = s.take_shared<gasfut::GasMarket<SUI>>();
		let (e0, cs0, im0, mm0, lf0): (u64, u64, u64, u64, u64) = gasfut::view_params(&market);
		assert_eq(e0, 0);
		assert_eq(cs0, 123);
		assert_eq(im0, 100);
		assert_eq(mm0, 200);
		assert_eq(lf0, 33);
		// update margins
		gasfut::set_margins<SUI>(&admin_reg, &mut market, 5, 6, 7, s.ctx());
		let (_e1, _cs1, im1, mm1, lf1): (u64, u64, u64, u64, u64) = gasfut::view_params(&market);
		assert_eq(im1, 5);
		assert_eq(mm1, 6);
		assert_eq(lf1, 7);
		return_shared(market);
		return_shared(_clk);
		destroy(fee_cfg); destroy(fee_vault); destroy(staking_pool); destroy(admin_reg);
		end(s);
	}

	#[test, expected_failure(abort_code = 1, location = unxversal::gas_futures)]
	fun test_set_margins_unauthorized() {
		let alice = @0xA1; let bob = @0xB2; let mut s = begin(alice);
		share_clock(&mut s);
		s.next_tx(alice);
		let admin_reg = admin::new_admin_registry_for_testing(s.ctx());
		{ gasfut::init_market<SUI>(&admin_reg, 0, 1, 1, 1, 1, s.ctx()); };
		s.next_tx(alice); let mut market = s.take_shared<gasfut::GasMarket<SUI>>();
		s.next_tx(bob);
		// Bob is not in admin_reg, expect abort E_NOT_ADMIN=1
		gasfut::set_margins<SUI>(&admin_reg, &mut market, 9, 9, 9, s.ctx());
		// unreachable
		return_shared(market); destroy(admin_reg); end(s);
	}

	#[test, expected_failure(abort_code = 2, location = unxversal::gas_futures)]
	fun test_deposit_zero_aborts() {
		let alice = @0xA1; let mut s = begin(alice);
		share_clock(&mut s);
		s.next_tx(alice);
		let admin_reg = admin::new_admin_registry_for_testing(s.ctx());
		{ gasfut::init_market<SUI>(&admin_reg, 0, 1, 0, 0, 0, s.ctx()); };
		s.next_tx(alice); let mut market = s.take_shared<gasfut::GasMarket<SUI>>();
		// zero coin deposit
		let zero = coin::zero<SUI>(s.ctx());
		gasfut::deposit_collateral<SUI>(&mut market, zero, s.ctx());
		// unreachable path cleanup
		return_shared(market); destroy(admin_reg); end(s);
	}

	#[test, expected_failure(abort_code = 4, location = unxversal::gas_futures)]
	fun test_withdraw_insufficient_aborts() {
		let alice = @0xA1; let mut s = begin(alice);
		share_clock(&mut s);
		s.next_tx(alice);
		let admin_reg = admin::new_admin_registry_for_testing(s.ctx());
		let clk = s.take_shared<Clock>();
		{ gasfut::init_market<SUI>(&admin_reg, 0, 1, 0, 0, 0, s.ctx()); };
		s.next_tx(alice); let mut market = s.take_shared<gasfut::GasMarket<SUI>>();
		// No deposit yet; withdraw 1 should abort E_INSUFF=4
		let _out = gasfut::withdraw_collateral<SUI>(&mut market, 1, &clk, s.ctx());
		destroy(_out);
		// unreachable path cleanup
		return_shared(market); return_shared(clk); destroy(admin_reg); end(s);
	}

	#[test, expected_failure(abort_code = 2, location = unxversal::gas_futures)]
	fun test_open_zero_qty_aborts() {
		let alice = @0xA1; let mut s = begin(alice);
		share_clock(&mut s);
		s.next_tx(alice);
		let admin_reg = admin::new_admin_registry_for_testing(s.ctx());
		let clk = s.take_shared<Clock>();
		{ gasfut::init_market<SUI>(&admin_reg, 0, 1, 0, 0, 0, s.ctx()); };
		s.next_tx(alice); let mut market = s.take_shared<gasfut::GasMarket<SUI>>();
		let coin_in = mint_for_testing<SUI>(100, s.ctx());
		gasfut::deposit_collateral<SUI>(&mut market, coin_in, s.ctx());
		// qty=0 triggers E_ZERO=2 before fees path; must pass valid cfg/vault/pool refs
		let cfg = fees::new_fee_config_for_testing(s.ctx());
		let mut vault = fees::new_fee_vault_for_testing(s.ctx());
		let mut pool = staking::new_staking_pool_for_testing(s.ctx());
		gasfut::open_long<SUI>(&mut market, &cfg, &mut vault, &mut pool, option::none(), &clk, s.ctx(), 0);
		// unreachable path cleanup
		return_shared(market); return_shared(clk); destroy(cfg); destroy(vault); destroy(pool); destroy(admin_reg); end(s);
	}

	#[test, expected_failure(abort_code = 3, location = unxversal::gas_futures)]
	fun test_liquidate_no_account_aborts() {
		let alice = @0xA1; let bob = @0xB2; let mut s = begin(alice);
		share_clock(&mut s);
		s.next_tx(alice);
		let admin_reg = admin::new_admin_registry_for_testing(s.ctx());
		let clk = s.take_shared<Clock>();
		{ gasfut::init_market<SUI>(&admin_reg, 0, 1, 0, 0, 0, s.ctx()); };
		s.next_tx(alice); let mut market = s.take_shared<gasfut::GasMarket<SUI>>();
		// Bob has no account; expect E_NO_ACCOUNT=3
		let mut fv = fees::new_fee_vault_for_testing(s.ctx());
		gasfut::liquidate<SUI>(&mut market, bob, 1, &mut fv, &clk, s.ctx());
		// unreachable path cleanup
		return_shared(market); return_shared(clk); destroy(fv); destroy(admin_reg); end(s);
	}

	#[test]
	fun test_account_views_after_trades() {
		let alice = @0xA1; let mut s = begin(alice);
		share_clock(&mut s);
		s.next_tx(alice);
		let admin_reg = admin::new_admin_registry_for_testing(s.ctx());
		let fee_cfg = fees::new_fee_config_for_testing(s.ctx());
		let mut fee_vault = fees::new_fee_vault_for_testing(s.ctx());
		let mut staking_pool = staking::new_staking_pool_for_testing(s.ctx());
		let clk = s.take_shared<Clock>();
		{ gasfut::init_market<SUI>(&admin_reg, 0, 1_000_000, 0, 0, 0, s.ctx()); };
		s.next_tx(alice); let mut market = s.take_shared<gasfut::GasMarket<SUI>>();
		let dep = mint_for_testing<SUI>(5_000_000, s.ctx());
		gasfut::deposit_collateral<SUI>(&mut market, dep, s.ctx());
		// trades with UNXV fees to avoid zero-fee path
		let mut sc = unxv::new_supply_cap_for_testing(s.ctx());
		let mut unxv_coins = unxv::mint_coin_for_testing(&mut sc, 100_000, s.ctx());
		gasfut::open_long<SUI>(&mut market, &fee_cfg, &mut fee_vault, &mut staking_pool, option::some(coin::split(&mut unxv_coins, 10_000, s.ctx())), &clk, s.ctx(), 10);
		gasfut::open_short<SUI>(&mut market, &fee_cfg, &mut fee_vault, &mut staking_pool, option::some(coin::split(&mut unxv_coins, 10_000, s.ctx())), &clk, s.ctx(), 4);
		let coll: u64 = gasfut::account_collateral(&market, alice);
		let (lq, sq, al, avg_s): (u64, u64, u64, u64) = gasfut::account_position(&market, alice);
		assert_eq(coll, 5_000_000);
		assert_eq(lq, 6);
		assert_eq(sq, 4);
		assert_eq(al, 0);
		assert_eq(avg_s, 0);
		return_shared(market); return_shared(clk);
		destroy(unxv_coins); destroy(fee_cfg); destroy(fee_vault); destroy(staking_pool); destroy(sc); destroy(admin_reg);
		end(s);
	}

	fun share_clock(s: &mut Scenario) {
		s.next_tx(@0x1);
		clock::create_for_testing(s.ctx()).share_for_testing();
	}
}
