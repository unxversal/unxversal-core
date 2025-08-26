## UNXV Protocol Test Suite Overview

This document summarizes the Move unit tests across the UNXV protocols, what they validate, and their current status. All counts and names reflect the suite as of the latest successful run (Total tests: 107; all passing).

### Perpetuals

**✅ perps_record_fill_discount_and_metrics**

This test validates the complete trade fee calculation and routing system for perpetuals. It sets up a market with specific fee parameters (1% trade fee, 50% maker rebate, 50% UNXV discount), records a fill, and verifies that the math works correctly: taker fee = notional × fee_bps, maker rebate = fee × maker_rebate_bps, UNXV discount = fee × discount_bps. The test confirms that the fee after discount is properly deposited to treasury, market metrics (open_interest, volume, last_trade_price) are updated, and the event mirror captures all fee/discount/rebate fields for external verification.

**✅ perps_fill_tick_and_slippage_guards**

This test ensures that the perpetuals trading system enforces proper price controls to prevent manipulation and errors. It attempts to record a fill with a price that doesn't align to the market's tick size and verifies that the transaction aborts. Additionally, it tests slippage bounds by providing min/max price parameters and confirming that fills outside these bounds are rejected. This protects traders from execution at stale or manipulated prices.

**✅ perps_refresh_with_wrong_index_feed**

This test validates the security of the funding mechanism by ensuring that funding rate calculations can only use the authorized index price feed. It attempts to refresh market funding using an aggregator that doesn't match the whitelisted underlying feed and confirms that the operation aborts. This prevents malicious actors from manipulating funding rates using unauthorized price sources.

**✅ perps_paused_market_blocks_ops**

This test verifies that the market-level pause mechanism works correctly as a safety control. When a specific perpetual market is paused, it should block all trading operations including fills and position management. The test pauses a market and attempts to record a fill, confirming that the operation is rejected, allowing administrators to halt trading on problematic markets while keeping others operational.

**✅ perps_paused_registry_blocks_ops**

This test validates the registry-level pause functionality, which serves as a circuit breaker for the entire perpetuals system. When the registry is paused, no new markets can be listed and no operational calls should succeed. The test pauses the registry and attempts to list a new market, verifying that the operation fails, providing administrators with emergency shutdown capabilities.

**✅ perps_funding_refresh_and_points**

This test validates the funding rate calculation and points reward system for maintenance operations. It sets up a market with trading history, advances time to allow funding refresh, and calls the funding refresh function. The test verifies that the funding rate and direction are computed correctly based on the premium between mark price and index price, capped by the maximum funding rate. It also confirms that the caller receives points for performing this maintenance operation.

**✅ perps_open_close_liquidate_apply_funding**

This comprehensive test validates the complete lifecycle of perpetual positions. It creates a position with specific margin requirements, performs a partial close (verifying proportional margin refund), liquidates another position when underwater (confirming margin seizure), and applies funding to a fresh position. The test uses event mirrors to capture and verify all the emitted state changes, ensuring that position management works correctly across all scenarios.

**✅ perps_trade_bot_split_fee_routes_treasury**

This test validates the bot reward system for trading operations. It configures a trade fee with maker rebate, UNXV discount, and bot split parameters, then records a fill that should result in specific fee routing. The test verifies that after applying discount and rebate, the remaining fee is split between the bot operator and the treasury according to the configured percentages, ensuring proper incentives for bot operators while generating protocol revenue.

**✅ perps_liquidation_bot_split_routes_treasury**

This test ensures that liquidation operations properly compensate both bot operators and the protocol treasury. It creates an under-collateralized position, triggers liquidation, and verifies that the seized margin is split between the liquidating bot and the treasury according to the configured bot reward percentage. This incentivizes timely liquidation while ensuring the protocol captures appropriate revenue from risk management.

Coverage highlights:
- Trade fee stack (fee, rebate, discount, bot split)
- Market controls (tick, bounds, pause)
- Funding (rate/direction calc, accrual)
- Position lifecycle and liquidation
- Reward points integration

### Gas Futures

**✅ gas_record_fill_fee_routing_and_metrics**

This test validates the core trading functionality for gas futures contracts. It records a fill with specific price and size parameters, verifies that the trade fee is calculated correctly and routed to the treasury, and confirms that market metrics (open interest, volume, last price) are updated appropriately. The test uses both SUI and UNXV price feeds to ensure proper fee calculations in the gas futures context, where prices are denominated in micro-USD per gas unit.

**✅ gas_discount_and_maker_rebate_flow**

This test comprehensively validates the UNXV discount and maker rebate system for gas futures. It configures specific fee parameters (1% fee, 50% rebate, 50% UNXV discount), provides UNXV payment for the discount, and verifies that the discount is applied correctly with precise UNXV accounting. The test confirms that the discounted UNXV amount is deposited to epoch reserves while the remaining fee flows to the treasury, and that bot reserves properly accrue UNXV tokens.

**✅ gas_settle_rejects_wrong_aggregator**

This test ensures the integrity of gas futures settlement by validating oracle identity binding. It attempts to settle a gas futures contract using an aggregator that doesn't match the one bound to the contract during listing. The test confirms that settlement fails, preventing manipulation of settlement prices through unauthorized oracle feeds and ensuring that only the designated price source can be used for final settlement.

**✅ gas_paused_registry_blocks_ops**

This test validates the registry-level pause mechanism for gas futures. When the gas futures registry is paused, all operations including trading and settlement should be blocked. The test pauses the registry and attempts to record a fill, confirming that the operation is rejected. This provides administrators with emergency control capabilities to halt all gas futures activity during system issues.

**✅ gas_paused_contract_blocks_ops**

This test verifies contract-level pause functionality, allowing administrators to selectively halt individual gas futures contracts while keeping others operational. The test pauses a specific contract and attempts to record a fill, confirming that trading is blocked for that contract. This granular control enables targeted responses to issues with specific contracts without affecting the entire system.

**✅ gas_tick_and_slippage_guards**

This test ensures that gas futures trading enforces proper price controls similar to other derivatives. It attempts to record a fill with a price that violates tick size requirements and price bounds, confirming that such trades are rejected. This prevents execution at invalid prices and protects traders from slippage beyond their acceptable limits in the volatile gas price market.

**✅ gas_settle_and_queue_points**

This test validates the complete settlement workflow for expired gas futures contracts. It settles a contract after expiry using oracle price data, enqueues the settlement for processing, and then processes the queue. The test confirms that points are awarded to the executor for performing these maintenance operations, incentivizing timely settlement processing while ensuring contracts are properly closed at expiry.

**✅ gas_open_close_liquidate_and_settle_position**

This comprehensive test validates the complete lifecycle of gas futures positions from creation to final settlement. It creates positions, performs partial closes with margin refunds, executes liquidations for underwater positions, and settles positions at contract expiry. The test uses event mirrors to capture and verify all state changes, ensuring that position management works correctly across all scenarios in the gas futures context.

**✅ gas_settlement_bot_split_close_fee_routes**

This test validates the fee splitting mechanism during settlement operations. It configures settlement fees with bot split parameters, performs position closes during settlement, and verifies that the settlement fees are properly split between the executing bot and the protocol treasury. The test confirms exact treasury balance changes, ensuring that settlement operations provide appropriate incentives for bot operators.

Coverage highlights:
- Trade and settlement fee math
- Pause guards, tick/bounds
- Queue + points flows
- Lifecycle and liquidation logic

### Standard Futures

**✅ record_fill_discount_and_fee_routing_happy**

This test validates the complete fee calculation and routing system for standard futures contracts. It sets up a contract with UNXV discount and maker rebate parameters, records a fill with UNXV payment, and verifies that all fee components are calculated and routed correctly. The test confirms that UNXV discount is applied, maker rebate is paid, and the net fee reaches the treasury, while the event mirror captures all fee, rebate, and discount information for external verification.

**✅ clamp_edge_large_notional_routes_clamped_fee**

This test stress-tests the arithmetic safety measures in fee calculations by using extremely large notional values that would cause u128 overflow when computing fees. It verifies that the fee calculation properly clamps the result to u64::MAX to prevent arithmetic overflow, ensuring system stability even with edge-case trading scenarios. This protects against potential exploits or crashes from large position sizes.

**✅ paused_registry_blocks_settlement**

This test validates that registry-level pause controls effectively block settlement operations. When the futures registry is paused, settlement should not be allowed to proceed, providing administrators with emergency control capabilities. The test pauses the registry and attempts settlement, confirming that the operation is rejected.

**✅ paused_contract_blocks_settlement**

This test ensures that contract-level pause functionality blocks settlement for individual contracts while allowing others to operate normally. The test pauses a specific contract and attempts settlement, verifying that the operation fails. This provides granular control for administrators to handle issues with specific contracts without affecting the entire futures system.

**✅ settle_flow_and_queue_points**

This test validates the complete settlement workflow for expired futures contracts, including the points reward system. After contract expiry, it performs settlement to record the final oracle price, enqueues the settlement for processing, and processes the queue. The test verifies that points are awarded to executors for performing these maintenance operations, creating proper incentives for timely settlement processing.

**✅ settle_rejects_wrong_aggregator**

This test ensures the security of futures settlement by validating oracle identity binding. It attempts to settle a contract using an aggregator that doesn't match the one authorized for that contract's underlying asset. The test confirms that settlement fails, preventing manipulation of settlement prices through unauthorized oracle feeds and maintaining the integrity of the settlement process.

**✅ position_open_close_liquidate_settle_flows**

This comprehensive test validates the complete lifecycle of futures positions from creation through final settlement. It creates positions with specific margin requirements, performs partial closes with proportional margin refunds, executes liquidations for underwater positions, and settles positions at contract expiry. The test uses event mirrors to capture all state changes and verifies proper treasury routing throughout the lifecycle.

Coverage highlights:
- Arithmetic bounds and clamps
- Admin/pause controls
- Lifecycle and treasury routing

### Options

**✅ add_underlying_and_create_market_happy**

This test validates the fundamental setup process for options trading by adding an underlying asset and creating an option market. It adds an underlying with a bound feed hash, creates a market with specific parameters (strike, expiry, settlement type), and verifies that the creation fee is properly calculated and routed. The test confirms that UNXV discount is available during market creation, ensuring the options system integrates properly with the protocol's fee discount mechanism.

**✅ paused_registry_rejects_create_market**

This test ensures that the registry-level pause mechanism effectively blocks market creation as a safety control. When the options registry is paused, no new option markets should be creatable, preventing potentially problematic markets from being listed during system issues. The test pauses the registry and attempts to create a market, confirming that the operation is properly rejected.

**✅ wrong_feed_hash_rejected_on_exercise**

This test validates the security of option exercise by ensuring that only the exact price feed bound during market creation can be used for exercise calculations. It attempts to exercise an option using an aggregator with a different feed hash than the one registered for the underlying, confirming that the operation aborts. This prevents manipulation of exercise settlements through unauthorized price feeds.

**✅ match_offer_and_escrow_fee_and_rebate_paths**

This test validates the OTC matching system that pairs short option offers with premium escrows. It creates a short offer and premium escrow, matches them together, and verifies that the taker fee is collected, maker rebate is paid, and market totals (open interest, volume, last trade price) are updated correctly. This ensures the peer-to-peer option trading mechanism works with proper fee economics.

**✅ unxv_discount_applied_and_leftover_refunded**

This test comprehensively validates the UNXV discount system for options trading. It configures a high discount percentage, provides UNXV payment that exceeds the required amount, and verifies that the exact discount amount is applied and deposited to epoch reserves while any leftover UNXV is precisely refunded to the payer. This ensures accurate UNXV accounting in the discount mechanism.

**✅ close_by_premium_payer_short_fee_routing_and_oi_updates**

This test validates the position closing mechanism where one party pays the other to close their positions early. It sets up matched long and short positions, has the short pay the long to close a portion, and verifies that fees are properly routed and open interest is updated accordingly. This ensures the early closing mechanism works correctly with proper fee accounting.

**✅ cash_settlement_after_expiry_updates_market**

This test validates the cash settlement process for expired options. It creates a market that has already expired, triggers cash settlement using oracle price data, and verifies that the market state is updated correctly to reflect the settled status. This ensures that expired options are properly settled with oracle-derived payouts.

**✅ physical_call_escrow_and_exercise_flow**

This test validates the physical delivery mechanism for call options. It sets up a call option with underlying asset escrow, exercises the option to transfer the underlying from short to long, and then garbage collects the empty escrow. This ensures that physical delivery of call options works correctly with proper asset transfer and cleanup.

**✅ physical_put_escrow_and_exercise_flow**

This test validates the physical delivery mechanism for put options. It creates a put option where the long delivers the underlying asset to the short in exchange for the strike price, verifying that the asset transfer occurs correctly. This ensures that physical delivery of put options works properly with the long providing the underlying asset.

**✅ admin_gating_via_synth_admincap_pause_resume**

This test validates that administrative functions are properly gated through the central AdminRegistry system. It confirms that authorized admins can set maker rebate parameters and fees, while unauthorized calls are properly rejected. This ensures that only authorized parties can modify critical system parameters.

**✅ admin_gating_negative_non_admin_cannot_pause**

This test validates the negative case of admin gating by confirming that non-admin addresses cannot modify system parameters. It attempts to set fee configuration from a non-admin address and verifies that the operation is rejected, ensuring the security of administrative functions.

**✅ duplicate_market_key_rejected**

This test ensures that market keys must be unique within the options system. It attempts to create two markets with identical parameters (same underlying, type, strike, expiry) and verifies that the second creation is rejected, preventing confusion and potential issues from duplicate markets.

**✅ settle_before_expiry_rejected**

This test validates that settlement can only occur after option expiry. It attempts to settle an option market before its expiry time and confirms that the operation is rejected, ensuring that options can only be settled at the appropriate time according to their contract terms.

**✅ tick_and_contract_size_violations_rejected**

This test ensures that option trading respects tick size and contract size constraints. It attempts to create trades that violate these parameters (non-tick-aligned premiums, incorrect contract size multiples) and verifies that such trades are rejected, maintaining market integrity and preventing invalid transactions.

**✅ oi_caps_violations_rejected**

This test validates that open interest caps are properly enforced to limit risk exposure. It attempts to create positions that would exceed the configured open interest limits and confirms that such trades are rejected, protecting the system from excessive risk concentration in any single option market.

**✅ cancel_and_gc_helpers_flow**

This test validates the utility functions for canceling orders and garbage collecting empty objects. It creates premium escrows and short offers, cancels them, and then garbage collects empty escrows with zero balances. This ensures that cleanup mechanisms work properly to maintain system efficiency.

**✅ readonly_helpers_checks**

This test validates various read-only helper functions that provide information about the options system. It tests functions that list underlyings, retrieve underlying details, list market keys, and get treasury IDs, ensuring that these informational functions work correctly and provide accurate data.

**✅ american_exercise_payout_and_fee_routing**

This test validates American-style option exercise where options can be exercised before expiry. It sets up an American call option that is in-the-money, exercises it, and verifies that the payout calculation is correct and fees are properly routed to the treasury and bot rewards system.

**✅ liquidation_under_collateralized_short_routes_fee_and_bonus**

This test validates the liquidation mechanism for under-collateralized short option positions. When a short position doesn't have sufficient collateral to cover potential payouts, it can be liquidated. The test verifies that liquidation fees and bonuses are properly routed between the liquidator and the treasury.

**✅ settlement_queue_request_and_process_points**

This test validates the settlement queue system that allows for disputed settlements with a time delay. It requests settlement for an expired option, waits for the dispute window to pass, and then processes the settlement. The test confirms that points are awarded to the executor for performing this maintenance operation.

Coverage highlights:
- Admin gating, market controls, fee math, UNXV discount
- Exercise, physical delivery, settlement
- Queues and points

### Lending

**✅ supply_withdraw_scaled_and_totals**

This test validates the core scaled balance accounting system for lending operations. It performs supply and withdrawal operations and verifies that scaled balances, total supply metrics, and interest indices are updated consistently across all edge cases including rounding scenarios. This ensures that the lending system maintains accurate accounting even with complex interest calculations and multiple user interactions.

**✅ accrue_updates_indices_and_reserves**

This test validates the interest accrual mechanism that drives lending profitability. It triggers interest accrual and verifies that borrow indices increase according to the interest rate parameters, and that protocol reserves accumulate the appropriate portion of interest payments. This ensures that the lending system generates sustainable revenue while accurately tracking user obligations.

**✅ borrow_and_repay_scaled_math**

This test validates the borrowing and repayment mechanisms including their complex scaled mathematics. It performs borrow operations that adjust scaled principal correctly, executes repayments that properly reduce debt including accrued interest, and handles boundary cases such as partial repayments and full payoffs. This ensures borrowers' debt is tracked accurately throughout the loan lifecycle.

**✅ admin_set_caps_happy_path**

This test validates that authorized administrators can successfully modify lending caps and parameters. It tests setting supply caps, borrow caps, and other risk parameters, confirming that the changes take effect and are enforced in subsequent operations. This ensures that risk management controls can be adjusted as market conditions change.

**✅ admin_set_caps_rejects_non_admin**

This test validates the security of administrative functions by confirming that non-admin addresses cannot modify lending parameters. It attempts to set caps and parameters from unauthorized addresses and verifies that all such operations are rejected, protecting the system from unauthorized parameter changes.

**✅ admin_global_params_happy_and_negative**

This test validates both positive and negative cases for global parameter management. It tests successful parameter updates by authorized admins and confirms rejection of unauthorized attempts, ensuring that critical system parameters like interest rate models and fee structures are properly protected.

**✅ caps_enforced_supply_borrow_and_tx_limits**

This test ensures that various caps are properly enforced during lending operations. It tests supply caps that limit total deposits, borrow caps that limit outstanding loans, and transaction limits that prevent excessively large single operations. This protects the system from concentration risk and potential manipulation.

**✅ caps_negative_exceed_tx_caps**

This test validates that transaction size limits are enforced by attempting operations that exceed the configured transaction caps and confirming they are rejected. This prevents large single transactions that could destabilize the lending pools or create unfair advantages for large users.

**✅ borrow_exceed_tx_cap_negative**

This test specifically validates that borrowing operations respect transaction size limits. It attempts to borrow amounts exceeding the configured caps and verifies that such operations are rejected, preventing excessive single borrowing transactions that could drain liquidity.

**✅ flash_loan_fee_routed_to_treasury_epoch**

This test validates the flash loan mechanism and fee collection system. It executes flash loans and verifies that the fees are correctly calculated and routed to the treasury with proper epoch accounting, ensuring that flash loan operations generate appropriate revenue for the protocol.

**✅ liquidation_coin_routes_to_treasury_and_bot**

This test validates the liquidation mechanism that protects lenders when borrowers become undercollateralized. It triggers liquidation of an unsafe position and verifies that liquidation bonuses and fees are properly split between the liquidating bot and the protocol treasury, incentivizing timely liquidation.

**✅ paused_rejects_core_ops**

This test ensures that the lending system's pause mechanism effectively blocks all core operations during emergencies. It pauses the system and attempts various operations (supply, borrow, withdraw, repay), confirming that all are properly rejected to protect users during system maintenance or security issues.

**✅ repay_over_debt_rejected**

This test validates debt accounting accuracy by ensuring that users cannot repay more than they actually owe. It attempts to repay amounts exceeding the outstanding debt and confirms that such operations are rejected, preventing accounting errors and potential exploitation.

**✅ skim_reserves_to_treasury_routes_and_reduces_reserves**

This test validates the reserve management system that allows accumulated protocol reserves to be moved to the treasury. It skims reserves and verifies that the amounts are correctly transferred to the treasury while being deducted from the lending pool reserves, ensuring proper revenue recognition.

**✅ synth_integration_supply_withdraw_borrow_repay_accrue**

This test validates the integration between the lending system and synthetic asset protocols. It performs lending operations involving synthetic assets and verifies that all interactions work correctly, ensuring seamless integration between different protocol modules.

**✅ withdraw_ltv_guard_rejects**

This test validates loan-to-value ratio protection by preventing withdrawals that would make positions unsafe. It attempts withdrawals that would push LTV ratios beyond safe limits and confirms they are rejected, protecting both lenders and borrowers from dangerous leverage levels.

**✅ withdraw_zero_amount_rejected**

This test validates input validation by ensuring that zero-amount withdrawal attempts are properly rejected. This prevents unnecessary transaction processing and potential accounting edge cases that could arise from meaningless operations.

Coverage highlights:
- Core scaled accounting, accrual, caps, safety checks
- Treasury routing paths

### Synthetics (+ Discount & CLOB)

**✅ fee_math_u128_bounds_and_ccr_edges**

This test validates the arithmetic safety and collateral coverage ratio (CCR) edge cases in synthetic asset operations. It tests fee calculations with large amounts that approach u128 limits and verifies that CCR calculations work correctly at boundary conditions, ensuring system stability under extreme market conditions.

**✅ liquidation_executes_and_routes**

This test validates the liquidation mechanism for undercollateralized synthetic asset positions. It creates a position that becomes liquidatable due to collateral value decline, executes the liquidation, and verifies that liquidation fees and bonuses are properly routed between the liquidator and protocol treasury.

**✅ liquidation_rejects_when_not_liquidatable**

This test ensures liquidation can only occur when positions are actually undercollateralized. It attempts to liquidate a healthy position and verifies that the operation is rejected, protecting users from inappropriate liquidations that could occur due to errors or manipulation attempts.

**✅ liquidation_repay_clamps_to_outstanding**

This test validates that liquidation repayments are properly bounded by the actual outstanding debt. It attempts liquidations that would repay more than the borrower owes and verifies that the repayment amount is correctly clamped to prevent over-repayment and accounting errors.

**✅ match_orders_maker_rebate_and_fee_routing**

This test validates the order matching system for synthetic asset trading including fee economics. It matches orders between users and verifies that taker fees are collected, maker rebates are paid, and all fees are properly routed to the treasury, ensuring fair economics for synthetic asset trading.

**✅ mint_fee_deposits_to_treasury_no_unxv**

This test validates the basic minting fee collection mechanism without UNXV discount. It mints synthetic assets and verifies that minting fees are correctly calculated and deposited to the treasury, ensuring the protocol generates revenue from synthetic asset creation.

**✅ mint_then_burn_updates_debt_and_routes_fees**

This test validates the complete mint/burn cycle for synthetic assets. It mints synthetics (creating debt), burns them back (reducing debt), and verifies that total debt tracking is accurate while fees are properly routed throughout the process.

**✅ mint_with_unxv_discount_without_binding_aborts**

This test ensures that UNXV discount can only be used when properly configured. It attempts to use UNXV discount for minting when the discount system isn't properly bound/configured and verifies that the operation fails, preventing incorrect discount applications.

**✅ oracle_binding_mismatch_aborts**

This test validates oracle security by ensuring that only properly bound price feeds can be used for synthetic asset operations. It attempts operations with mismatched oracle bindings and confirms they fail, preventing price manipulation through unauthorized feeds.

**✅ reconciliation_helpers_reflect_mint_burn**

This test validates helper functions that track synthetic asset supply changes. It performs mint and burn operations and verifies that reconciliation helpers accurately reflect the changes in total supply and debt, ensuring accurate system state tracking.

**✅ stability_accrual_increments_debt**

This test validates the stability fee mechanism that generates revenue from outstanding synthetic debt. It advances time to trigger stability fee accrual and verifies that total debt increases according to the configured stability rate, ensuring sustainable protocol revenue.

**✅ stale_price_aborts**

This test ensures that synthetic asset operations cannot proceed with stale price data. It uses an oracle with outdated price information and verifies that operations are rejected, protecting users from operations based on incorrect pricing.

**✅ withdraw_collateral_multi_is_deprecated**

This test validates that deprecated withdrawal functions are properly disabled. It attempts to use old withdrawal methods and confirms they fail, ensuring users must use the current, secure withdrawal mechanisms.

**✅ withdraw_health_guard_rejects_when_ratio_drops_below_min**

This test validates collateral health checks that prevent unsafe withdrawals. It attempts to withdraw collateral that would push the health ratio below minimum requirements and verifies the operation is rejected, protecting both the user and protocol from liquidation risk.

**✅ clob_bond_cancel_and_gc_slash**

This test validates CLOB (Central Limit Order Book) integration including bond management, order cancellation, garbage collection, and slashing mechanisms. It ensures that the order book system works correctly with proper incentive structures and cleanup procedures.

**✅ clob_escrow_accrual_and_claim_cycle**

This test validates the complete lifecycle of CLOB escrow operations including fee accrual and claim processing. It ensures that escrowed funds earn appropriate returns and that claim mechanisms work correctly for all parties involved in order book operations.

**✅ mint_and_burn_event_mirror_validates_fields**

This test uses event mirrors to validate that mint and burn operations emit correct event data. It performs operations and checks that all event fields accurately reflect the transaction details, ensuring proper external system integration and monitoring.

**✅ mint_with_unxv_discount_routes_fee_and_refund_leftovers**

This test comprehensively validates the UNXV discount system for synthetic asset minting. It provides UNXV payment for discount, verifies that the discount is correctly applied and routed to epoch reserves, and confirms that any leftover UNXV is precisely refunded.

**✅ synthetics_points_variants_award_points**

This test validates the points reward system for various synthetic asset operations. It performs different types of operations and verifies that points are correctly awarded to participants, ensuring proper incentives for protocol usage and maintenance.

Coverage highlights:
- Debt accounting, stability fees, liquidation
- Discount accuracy and orderbook integration

### DEX

**✅ dex_admin_setters_and_pause_resume**

This test validates the administrative controls for the DEX system. It tests that authorized administrators can set fee parameters, maker rebate percentages, UNXV discount rates, and pause/resume functionality. The test confirms that these settings take effect immediately and are enforced during subsequent order operations, providing proper administrative control over DEX economics.

**✅ dex_match_coin_orders_with_unxv_discount_and_rebate**

This test validates the complete order matching system including fee economics. It places buy and sell orders, matches them together, and verifies that taker fees are collected, maker rebates are paid, UNXV discounts are applied when provided, and all fees are properly routed to the treasury. This ensures the DEX operates with fair and transparent fee economics.

**✅ dex_vault_mode_place_cancel_match_and_getters**

This test validates the vault-safe trading mode that allows protocol-owned liquidity to participate in the orderbook. It places vault orders, cancels some, matches others, and tests various getter functions. This ensures that institutional liquidity provision works correctly with proper risk controls and accurate state reporting.

### Vaults

**✅ vaults_stake_registry_and_vault_lifecycle**

This comprehensive test validates the complete vault management system including manager staking requirements. It demonstrates the full lifecycle: staking UNXV to meet minimum requirements, creating a vault, performing deposits and withdrawals, managing asset stores for different token types, freezing/unfreezing operations, and administrative slashing of misbehaving managers. The test ensures that the vault system properly gates access through stake requirements while providing full functionality for qualified managers.

### Treasury

**✅ epoch_reserves_and_payouts_unxv**

This test validates the epoch-based reward system for UNXV token management. It deposits UNXV to specific epochs, advances time across epoch boundaries, and verifies that epoch reserves are tracked correctly. The test also validates payout mechanisms that distribute accumulated UNXV rewards proportionally to participants.

**✅ unxv_deposit_auto_route_split**

This test validates the automatic routing system that splits UNXV deposits between immediate treasury needs and epoch-based reserves according to configured percentages. It performs deposits and verifies that the split routing works correctly, ensuring efficient UNXV token distribution.

**✅ auto_route_bps_cases_collateral_and_epoch**

This test validates various percentage-based routing scenarios for collateral deposits. It tests different basis point configurations for routing between immediate treasury use and epoch-based rewards, ensuring that the automatic routing system works correctly across different parameter settings.

**✅ auto_route_bps_cases_unxv**

This test specifically validates percentage-based routing for UNXV token deposits across different configuration scenarios. It ensures that UNXV routing percentages work correctly and that funds are distributed according to the configured parameters.

**✅ deposit_collateral_zero_amount_aborts**

This test validates input validation by ensuring that zero-amount collateral deposits are properly rejected. This prevents meaningless transactions and potential accounting edge cases.

**✅ deposit_unxv_zero_amount_aborts**

This test validates input validation by ensuring that zero-amount UNXV deposits are properly rejected, maintaining transaction integrity and preventing potential accounting issues.

### Oracle

**✅ set_feed_and_read_price_happy_path**

This test validates the complete oracle setup and reading process. It sets up oracle feeds through administrative functions, binds aggregators to symbols, and then reads prices with proper staleness and positivity checks. This ensures the oracle system works correctly for price discovery across the protocol.

**✅ direct_scaled_read_happy_path**

This test validates direct oracle reading functionality that bypasses the registry for specific use cases. It reads prices directly from aggregators with proper scaling and validation, ensuring that direct oracle access works correctly when needed.

**✅ feed_mismatch_rejected**

This test ensures oracle security by validating that price reads reject aggregators that don't match the registered feed for a symbol. It attempts to read prices using mismatched aggregators and confirms the operations fail, preventing price manipulation through unauthorized feeds.

**✅ stale_price_rejected**

This test validates staleness protection by attempting to read prices from aggregators with outdated timestamps. It confirms that stale price reads are rejected, protecting the system from operating on outdated market data.

**✅ zero_price_rejected**

This test validates price sanity checks by attempting to read zero or negative prices and confirming they are rejected. This prevents invalid price data from propagating through the system.

**✅ unregistered_symbol_rejected**

This test ensures that price reads for symbols that haven't been registered in the oracle system are properly rejected, preventing operations with unbound price feeds.

### UNXV Token

**✅ mint_burn_with_cap_happy_path**

This test validates the basic UNXV token minting and burning functionality including supply cap enforcement. It mints tokens up to the cap, burns some back, and verifies that total supply tracking remains accurate throughout the process.

**✅ mint_burn_events_and_supply_conservation**

This test validates that UNXV mint and burn operations emit proper events and maintain supply conservation. It performs various mint/burn operations and verifies that events are emitted with correct data and that the total supply always reflects the actual outstanding tokens.

**✅ cap_violation_aborts**

This test validates that attempts to mint UNXV tokens beyond the configured supply cap are properly rejected. It attempts to exceed the cap and confirms the operation fails, protecting against excessive token supply inflation.

### Bot Rewards

**✅ award_points_accumulates_and_updates_epoch**

This test validates the points award system that incentivizes protocol maintenance operations. It awards points to participants for various operations and verifies that points accumulate correctly and epoch transitions work properly.

**✅ multi_actor_pro_rata_and_idempotent_claim**

This test validates the multi-participant reward distribution system. It has multiple actors earn points, claim rewards pro-rata based on their contribution, and verifies that claims are idempotent (can't be double-claimed) while distribution is fair.

**✅ zero_weight_award_no_change**

This test validates that zero-weight point awards don't affect the system state, ensuring that meaningless operations don't create unnecessary state changes or potential exploit vectors.

---

- ✅ Total tests: 107
- ✅ Passing: 107
- ✅ Failing: 0

## Coverage Notes
- Broad coverage of fee economics (taker fee, maker rebate, UNXV discount, bot splits)
- Safety controls: pause, ticks, bounds, caps, LTV, health, staleness, identity checks
- Lifecycle across protocols: listing/creation, trade, funding/interest accrual, exercise/settlement, liquidation
- Integration points: Treasury routing, Points awards, Oracle identity and staleness, DEX and CLOB flows

For detailed assertions, refer to the corresponding `packages/unxversal/tests/*.move` files. This overview will be updated as tests evolve.


