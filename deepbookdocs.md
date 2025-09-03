DeepBookV3
DeepBookV3 is a next-generation decentralized central limit order book (CLOB) built on Sui. DeepBookV3 leverages Sui's parallel execution and low transaction fees to bring a highly performant, low-latency exchange on chain.

The latest version delivers new features including flash loans, governance, improved account abstraction, and enhancements to the existing matching engine. This version also introduces its own tokenomics with the DEEP token, which you can stake for additional benefits.

DeepBookV3 does not include an end-user interface for token trading. Rather, it offers built-in trading functionality that can support token trades from decentralized exchanges, wallets, or other apps. The available SDK abstracts away a lot of the complexities of interacting with the chain and building programmable transaction blocks, lowering the barrier of entry for active market making.

info
The documentation refers to the DeepBook standard as "DeepBookV3" to avoid confusion with the recently deprecated version of DeepBook (DeepBookV2).

DeepBookV3 tokenomics
The DEEP token pays for trading fees on the exchange. Users can pay trading fees using DEEP tokens or input tokens, but owning, using, and staking DEEP continues to provide the most benefits to active DeepBookV3 traders on the Sui network.

As an example, governance determines the fee for paying in DEEP tokens, which is 20% lower than the fee for using input tokens.

Users that stake DEEP can enjoy taker and maker incentives. Taker incentives can reduce trading fees by half, dropping them to as low as 0.25 basis points (bps) on stable pairs and 2.5 bps on volatile pairs. Maker incentives are rebates earned based on maker volume generated.

Liquidity support
Similar to order books for other market places, DeepBookV3's CLOB architecture enables you to enter market and limit orders. You can sell SUI tokens, referred to as an ask, can set your price, referred to as a limit order, or sell at the market's going rate. If you are seeking to buy SUI, referred to as a bid, you can pay the current market price or set a limit price. Limit orders only get fulfilled if the CLOB finds a match between a buyer and seller.

If you put in a limit order for 1,000 SUI, and no single seller is currently offering that quantity of tokens, DeepBookV3 automatically pools the current asks to meet the quantity of your bid.

Transparency and privacy
As a CLOB, DeepBookV3 works like a digital ledger, logging bids and asks in chronological order and automatically finding matches between the two sides. It takes into account user parameters on trades such as prices.

The digital ledger is open so people can view the trades and prices, giving clear proof of fairness. You can use this transparency to create metrics and dashboards to monitor trading activity.

Documentation
This documentation outlines the design of DeepBookV3, its public endpoints, and provides guidance for integrations. The SDK abstracts away a lot of the complexities of interacting with the chain and building programmable transaction blocks, lowering the barrier of entry for active market making.

Open source
DeepBookV3 is open for community development. You can use the Sui Improvement Proposals (SIPs) process to suggest changes to make DeepBookV3 better.

Related links
DeepBookV3 repository: The DeepBookV3 repository on GitHub.

Design
At a high level, the DeepBookV3 design follows the following flow, which revolves around three shared objects:

Pool: A shared object that represents one market and is responsible for managing its order book, users, stakes, and so on. See the Pool shared object section to learn more.
PoolRegistry: Used only during pool creation, it makes sure that duplicate pools are not created and maintains package versioning.
BalanceManager: Used to source a user's funds when placing orders. A single BalanceManager can be used between all pools. See BalanceManager to learn more.
1

Pool shared object
All public facing functions take in the Pool shared object as a mutable or immutable reference. Pool is made up of three distinct components:

Book
State
Vault
Logic is isolated between components and each component builds on top of the previous one. By maintaining a book, then state, then vault relationship, DeepBookV3 can provide data availability guarantees, improve code readability, and help make maintaining and upgrading the protocol easier.

Pool Modules

Book
This component is made up of the main Book module along with Fill, OrderInfo, and Order modules. The Book struct maintains two BigVector<Order> objects for bids and asks, as well as some metadata. It is responsible for storing, matching, modifying, and removing Orders.

When placing an order, an OrderInfo is first created. If applicable, it is first matched against existing maker orders, accumulating Fills in the process. Any remaining quantity will be used to create an Order object and injected into the book. By the end of book processing, the OrderInfo object has enough information to update all relevant users and the overall state.

State
State stores Governance, History, and Account. It processes all requests, updating at least one of these stored structs.

Governance
The Governance module stores data related to the pool's trading params. These parameters are the taker fee, maker fee, and the stake required. Stake required represents the amount of DEEP tokens that a user must have staked in this specific pool to be eligible for taker and maker incentives.

Every epoch, users with non zero stake can submit a proposal to change these parameters. The proposed fees are bounded.

min_value (bps)	max_value (bps)	Pool type	Taker or maker
1	10	Volatile	Taker
0	5	Volatile	Maker
0.1	1	Stable	Taker
0	0.5	Stable	Maker
0	0	Whitelisted	Taker and maker
 
Users can also vote on live proposals. When a proposal exceeds the quorum, the new trade parameters are queued to go live from the following epoch and onwards. Proposals and votes are reset every epoch. Users can start submitting and voting on proposals the epoch following their stake. Quorum is equivalent to half of the total voting power. A user's voting power is calculated with the following formula where 
V
V is the voting power, 
S
S is the amount staked, and 
V
c
V 
c
​
  is the voting power cutoff. 
V
c
V 
c
​
  is currently set to 100,000 DEEP.

V
=
min
⁡
(
S
,
V
c
)
+
max
⁡
(
S
−
V
c
,
0
)
V=min(S,V 
c
​
 )+max( 
S
​
 − 
V 
c
​
 
​
 ,0)

The following diagram helps visualize the governance lifecycle.

DeepBookV3 Governance Timeline

History
The History module stores aggregated volumes, trading params, fees collected and fees to burn for the current epoch and previous epochs. During order processing, fills are used to calculate and update the total volume. Additionally, if the maker of the trade has enough stake, the total staked volume is also updated.

The first operation of every epoch will trigger an update, moving the current epoch data into historic data, and resetting the current epoch data.

User rebate calculations are done in this module. During every epoch, a maker is eligible for rebates as long as their DEEP staked is over the stake required and have contributed in maker volume. The following formula is used to calculate maker fees, quoted from the Whitepaper: DeepBook Token document. Details on maker incentives can be found in section 2.2 of the whitepaper.

The computation of incentives – which happens after an epoch ends and is only given to makers who have staked the required number of DEEP tokens in advance – is calculated in Equation (3) for a given maker 
i
i. Equation (3) introduces several new variables. First, 
M
M refers to the set of makers who stake a sufficient number of DEEP tokens, and 
M
ˉ
M
ˉ
  refers to the set of makers who do not fulfill this condition. Second, 
F
F refers to total fees (collected both from takers and the maker) that a maker’s volume has generated in a given epoch. Third, 
L
L refers to the total liquidity provided by a maker – and specifically the liquidity traded, not just the liquidity quoted. Finally, the critical point 
p
p is the “phaseout” point, at which – if total liquidity provided by other makers’ crosses this point – incentives are zero for the maker in that epoch. This point 
p
p is constant for all makers in a pool and epoch.

Incentives
 
for
 
Maker
 
i
=
max
⁡
[
F
i
(
1
+
∑
j
∈
M
ˉ
F
j
∑
j
∈
M
F
j
)
(
1
−
∑
j
∈
M
∪
M
ˉ
L
j
−
L
i
p
)
,
0
]
Incentives for Maker i=max[F 
i
​
 (1+ 
∑ 
j∈M
​
 F 
j
​
 
∑ 
j∈ 
M
ˉ
 
​
 F 
j
​
 
​
 )(1− 
p
∑ 
j∈M∪ 
M
ˉ
 
​
 L 
j
​
 −L 
i
​
 
​
 ),0]
(3)

In essence, if the total volume during an epoch is greater than the median volume from the last 28 days, then there are no rebates. The lower the volume compared to the median, the more rebates are available. The maximum amount of rebates for an epoch is equivalent to the total amount of DEEP collected during that epoch. Remaining DEEP is burned.

Account
Account represents a single user and their relevant data. Everything related to volumes, stake, voted proposal, unclaimed rebates, and balances to be transferred. There is a one to one relationship between a BalanceManager and an Account.

Every epoch, the first action that a user performs will update their account, triggering a calculation of any potential rebates from the previous epoch, as well as resetting their volumes for the current epoch. Any new stakes from the previous epoch become active.

Each account has settled and owed balances. Settled balances are what the pool owes to the user, and owed balances are what the user owes to the pool. For example, when placing an order, the user's owed balances increase, representing the funds that the user has to pay to place that order. Then, if a maker order is taken by another user, the maker's settled balances increase, representing the funds that the maker is owed.

Vault
Every transaction that a user performs on DeepBookV3 resets their settled and owed balances. The vault then processes these balances for the user, deducting or adding to funds to their BalanceManager.

The vault also stores the DeepPrice struct. This object holds up to 100 data points representing the conversion rate between the pool's base or quote asset and DEEP. These data points are sourced from a whitelisted pool, DEEP/USDC or DEEP/SUI. This conversion rate is used to determine the quantity of DEEP tokens required to pay for trading fees.

BigVector
BigVector is an arbitrary sized vector-like data structure, implemented using an on-chain B+ Tree to support almost constant time (log base max_fan_out) random access, insertion and removal.

Iteration is supported by exposing access to leaf nodes (slices). Finding the initial slice can be done in almost constant time, and subsequently finding the previous or next slice can also be done in constant time.

Nodes in the B+ Tree are stored as individual dynamic fields hanging off the BigVector.

Place limit order flow
The following diagram of the lifecycle of an order placement action helps visualize the book, then state, then vault flow.

Place limit order flow

Pool
In the Pool module, place_order_int is called with the user's input parameters. In this function, four things happen in order:

An OrderInfo is created.
The Book function create_order is called.
The State function process_create is called.
The Vault function settle_balance_manager is called.
Book
The order creation within the book involves three primary tasks:

Validate inputs.
Match against existing orders.
Inject any remaining quantity into the order book as a limit order.
Validation of inputs ensures that quantity, price, timestamp, and order type are within expected ranges.

To match an OrderInfo against the book, the list of Orders is iterated in the opposite side of the book. If there is an overlap in price and the existing maker order has not expired, then DeepBookV3 matches their quantities and generates a Fill. DeepBookV3 appends that fill to the OrderInfo fills, to use later in state. DeepBookV3 updates the existing maker order quantities and status during each match, and removes them from the book if they are completely filled or expired.

Finally, if the OrderInfo object has any remaining quantity, DeepBookV3 converts it into a compact Order object and injects it into the order book. Order has the minimum amount of data necessary for matching, while OrderInfo has the maximum amount of data for general processing.

Regardless of direction or order type, all DeepBookV3 matching is processed in a single function.

State
The process_create function in State handles the processing of an order creation event within the pool's state: calculating the transaction amounts and fees for the order, and updating the account volumes accordingly.

First, the function processes the list of fills from the OrderInfo object, updating volumes tracked and settling funds for the makers involved. Next, the function retrieves the account's total trading volume and active stake. It calculates the taker's fee based on the user's account stake and volume in DEEP tokens, while the maker fee is retrieved from the governance trade parameters. To receive discounted taker fees, the account must have more than the minimum stake for the pool, and the trading volume in DEEP tokens must exceed the same threshold. If any quantity remains in the OrderInfo object, it is added to the account's list of orders as an Order and is already created in Book.

Finally, the function calculates the partial taker fills and maker order quantities, if there are any, with consideration for the taker and maker fees. It adds these to the previously settled and owed balances from the account. Trade history is updated with the total fees collected from the order and two tuples are returned to Pool, settled and owed balances, in (base, quote, DEEP) format, ensuring the correct assets are transferred in Vault.

Vault
The settle_balance_manager function in Vault is responsible for managing the transfer of any settled and owed amounts for the BalanceManager.

First, the function validates that a trader is authorized to use the BalanceManager.

Then, for each asset type the process compares balances_out against balances_in. If the balances_out total exceeds balances_in, the function splits the difference from the vault's balance and deposits it into the BalanceManager. Conversely, if the balances_in total exceeds balances_out, the function withdraws the difference from the BalanceManager and joins it to the vault's balance.

This process is repeated for base, quote, and DEEP asset balances, ensuring all asset balances are accurately reflected and settled between the vault and the BalanceManager.

Related links
DeepBookV3 repository: The DeepBookV3 repository on GitHub.

BalanceManager
The BalanceManager shared object holds all balances for different assets. To perform trades, pass a combination of BalanceManager and TradeProof into a pool. TradeProofs are generated in one of two ways, either by the BalanceManager owner directly, or by any TradeCap owner. The owner can generate a TradeProof without the risk of equivocation. The TradeCap owner, because it's an owned object, risks equivocation when generating a TradeProof. Generally, a high frequency trading engine trades as the default owner.

With exception to swaps, all interactions with DeepBookV3 require a BalanceManager as one of its inputs. When orders are matched, funds are transferred to or from the BalanceManager. You can use a single BalanceManager between all pools.

API
Following are the different public functions that the BalanceManager exposes.

Create a BalanceManager
The new() function creates a BalanceManager hot potato (a struct with no abilities). Combine it with share, or else the transaction fails. You can combine the transaction with deposit calls, allowing you to create, deposit, then share the balance manager in one transaction.

public fun new(ctx: &mut TxContext): BalanceManager {
    let id = object::new(ctx);
    event::emit(BalanceManagerEvent {
        balance_manager_id: id.to_inner(),
        owner: ctx.sender(),
    });

    BalanceManager {
        id,
        owner: ctx.sender(),
        balances: bag::new(ctx),
        allow_listed: vec_set::empty(),
    }
}

Create a BalanceManager with custom owner
The new_with_owner() function creates a BalanceManager hot potato (a struct with no abilities) with a custom owner. Combine it with share, or else the transaction fails. You can combine the transaction with deposit calls, allowing you to create, deposit, then share the balance manager in one transaction.

#[deprecated(note = b"This function is deprecated, use `new_with_custom_owner` instead.")]
public fun new_with_owner(_ctx: &mut TxContext, _owner: address): BalanceManager {
    abort 1337
}

Mint a TradeCap
The owner of a BalanceManager can mint a TradeCap and send it to another address. Upon receipt, that address will have the capability to place orders with this BalanceManager. The address owner cannot deposit or withdraw funds, however. The maximum total number of TradeCap, WithdrawCap, and DepositCap that can be assigned for a BalanceManager is 1000. If this limit is reached, one or more existing caps must be revoked before minting new ones. You can also use revoke_trade_cap to revoke DepositCap and WithdrawCap.

/// Mint a `TradeCap`, only owner can mint a `TradeCap`.
public fun mint_trade_cap(balance_manager: &mut BalanceManager, ctx: &mut TxContext): TradeCap {
    balance_manager.validate_owner(ctx);
    balance_manager.mint_trade_cap_internal(ctx)
}

/// Revoke a `TradeCap`. Only the owner can revoke a `TradeCap`.
/// Can also be used to revoke `DepositCap` and `WithdrawCap`.
public fun revoke_trade_cap(
    balance_manager: &mut BalanceManager,
    trade_cap_id: &ID,
    ctx: &TxContext,
) {
    balance_manager.validate_owner(ctx);

    assert!(balance_manager.allow_listed.contains(trade_cap_id), ECapNotInList);
    balance_manager.allow_listed.remove(trade_cap_id);
}

Mint a DepositCap or WithdrawCap
The owner of a BalanceManager can mint a DepositCap or WithdrawCap and send it to another address. Upon receipt, that address will have the capability to deposit in or withdraw from BalanceManager. The address owner cannot execute trades, however. The maximum total number of TradeCap, WithdrawCap, and DepositCap that can be assigned for a BalanceManager is 1000. If this limit is reached, one or more existing caps must be revoked before minting new ones.

/// Mint a `DepositCap`, only owner can mint.
public fun mint_deposit_cap(balance_manager: &mut BalanceManager, ctx: &mut TxContext): DepositCap {
    balance_manager.validate_owner(ctx);
    balance_manager.mint_deposit_cap_internal(ctx)
}

/// Mint a `WithdrawCap`, only owner can mint.
public fun mint_withdraw_cap(
    balance_manager: &mut BalanceManager,
    ctx: &mut TxContext,
): WithdrawCap {
    balance_manager.validate_owner(ctx);
    balance_manager.mint_withdraw_cap_internal(ctx)
}

Generate a TradeProof
To call any function that requires a balance check or transfer, the user must provide their BalanceManager as well as a TradeProof. There are two ways to generate a trade proof, one used by the owner and another used by a TradeCap owner.

/// Generate a `TradeProof` by the owner. The owner does not require a capability
/// and can generate TradeProofs without the risk of equivocation.
public fun generate_proof_as_owner(
    balance_manager: &mut BalanceManager,
    ctx: &TxContext,
): TradeProof {
    balance_manager.validate_owner(ctx);

    TradeProof {
        balance_manager_id: object::id(balance_manager),
        trader: ctx.sender(),
    }
}

/// Generate a `TradeProof` with a `TradeCap`.
/// Risk of equivocation since `TradeCap` is an owned object.
public fun generate_proof_as_trader(
    balance_manager: &mut BalanceManager,
    trade_cap: &TradeCap,
    ctx: &TxContext,
): TradeProof {
    balance_manager.validate_trader(trade_cap);

    TradeProof {
        balance_manager_id: object::id(balance_manager),
        trader: ctx.sender(),
    }
}

Deposit funds
Only the owner can call this function to deposit funds into the BalanceManager.

/// Deposit funds to a balance manager. Only owner can call this directly.
public fun deposit<T>(balance_manager: &mut BalanceManager, coin: Coin<T>, ctx: &mut TxContext) {
    balance_manager.emit_balance_event(
        type_name::get<T>(),
        coin.value(),
        true,
    );

    let proof = balance_manager.generate_proof_as_owner(ctx);
    balance_manager.deposit_with_proof(&proof, coin.into_balance());
}

Withdraw funds
Only the owner can call this function to withdraw funds from the BalanceManager.

/// Withdraw funds from a balance_manager. Only owner can call this directly.
/// If withdraw_all is true, amount is ignored and full balance withdrawn.
/// If withdraw_all is false, withdraw_amount will be withdrawn.
public fun withdraw<T>(
    balance_manager: &mut BalanceManager,
    withdraw_amount: u64,
    ctx: &mut TxContext,
): Coin<T> {
    let proof = generate_proof_as_owner(balance_manager, ctx);
    let coin = balance_manager.withdraw_with_proof(&proof, withdraw_amount, false).into_coin(ctx);
    balance_manager.emit_balance_event(
        type_name::get<T>(),
        coin.value(),
        false,
    );

    coin
}

public fun withdraw_all<T>(balance_manager: &mut BalanceManager, ctx: &mut TxContext): Coin<T> {
    let proof = generate_proof_as_owner(balance_manager, ctx);
    let coin = balance_manager.withdraw_with_proof(&proof, 0, true).into_coin(ctx);
    balance_manager.emit_balance_event(
        type_name::get<T>(),
        coin.value(),
        false,
    );

    coin
}

Deposit funds using DepositCap
Only holders of a DepositCap for the BalanceManager can call this function to deposit funds into the BalanceManager.

/// Deposit funds into a balance manager by a `DepositCap` owner.
public fun deposit_with_cap<T>(
    balance_manager: &mut BalanceManager,
    deposit_cap: &DepositCap,
    coin: Coin<T>,
    ctx: &TxContext,
) {
    balance_manager.emit_balance_event(
        type_name::get<T>(),
        coin.value(),
        true,
    );

    let proof = balance_manager.generate_proof_as_depositor(deposit_cap, ctx);
    balance_manager.deposit_with_proof(&proof, coin.into_balance());
}

Withdraw funds using WithdrawCap
Only holders of a WithdrawCap for the BalanceManager can call this function to withdraw funds from the BalanceManager.

/// Withdraw funds from a balance manager by a `WithdrawCap` owner.
public fun withdraw_with_cap<T>(
    balance_manager: &mut BalanceManager,
    withdraw_cap: &WithdrawCap,
    withdraw_amount: u64,
    ctx: &mut TxContext,
): Coin<T> {
    let proof = balance_manager.generate_proof_as_withdrawer(
        withdraw_cap,
        ctx,
    );
    let coin = balance_manager.withdraw_with_proof(&proof, withdraw_amount, false).into_coin(ctx);
    balance_manager.emit_balance_event(
        type_name::get<T>(),
        coin.value(),
        false,
    );

    coin
}

Read endpoints
public fun validate_proof(balance_manager: &BalanceManager, proof: &TradeProof) {
    assert!(object::id(balance_manager) == proof.balance_manager_id, EInvalidProof);
}

/// Returns the balance of a Coin in a balance manager.
public fun balance<T>(balance_manager: &BalanceManager): u64 {
    let key = BalanceKey<T> {};
    if (!balance_manager.balances.contains(key)) {
        0
    } else {
        let acc_balance: &Balance<T> = &balance_manager.balances[key];
        acc_balance.value()
    }
}

/// Returns the owner of the balance_manager.
public fun owner(balance_manager: &BalanceManager): address {
    balance_manager.owner
}

/// Returns the owner of the balance_manager.
public fun id(balance_manager: &BalanceManager): ID {
    balance_manager.id.to_inner()
}

Related links
DeepBookV3 repository: The DeepBookV3 repository on GitHub.

Permissionless Pool Creation
The Pool shared object represents a market, such as a SUI/USDC market. That Pool is the only one representing that unique pairing (SUI/USDC) and the pairing is the only member of that particular Pool. See DeepBookV3 Design to learn more about the structure of pools.

API
Create a Pool
The create_permissionless_pool() function creates a Pool

public fun create_permissionless_pool<BaseAsset, QuoteAsset>(
    registry: &mut Registry,
    tick_size: u64,
    lot_size: u64,
    min_size: u64,
    creation_fee: Coin<DEEP>,
    ctx: &mut TxContext,
): ID {
    assert!(creation_fee.value() == constants::pool_creation_fee(), EInvalidFee);
    let base_type = type_name::get<BaseAsset>();
    let quote_type = type_name::get<QuoteAsset>();
    let whitelisted_pool = false;
    let stable_pool = registry.is_stablecoin(base_type) && registry.is_stablecoin(quote_type);

    create_pool<BaseAsset, QuoteAsset>(
        registry,
        tick_size,
        lot_size,
        min_size,
        creation_fee,
        whitelisted_pool,
        stable_pool,
        ctx,
    )
}

Tick size should be 10^(9 - base_decimals + quote_decimals - decimal_desired). For example, if creating a SUI(9 decimals)/USDC(6 decimals) pool, with a desired decimal of 3 for tick size (0.001), tick size should be 10^(9 - 9 + 6 - 3) = 10^(3) = 1000.

Decimal desired should be at most 1bps, or 0.01%, of the price between base and quote asset. For example, if 3 decimals is the target, 0.001 (three decimals) / price should be less than or equal to 0.0001. Consider a lower tick size for pools where both base and quote assets are stablecoins.

Lot size is in MIST of the base asset, and should be approximately $0.01 to $0.10 nominal of the base asset. Lot size must be a power of 10, and less than or equal to min size. Lot size should also be greater than or equal to 1,000.

Min size is in MIST of the base asset, and should be approximately $0.10 to $1.00 nominal of the base asset. Min size must be a power of 10, and larger than or equal to lot size.

Creation fee is 500 DEEP tokens.

info
Pools can only be created if the asset pair has not already been created before.

Add DEEP price point
The add_deep_price_point() function allows for the calculation of DEEP price and correct collection of fees in DEEP.

public fun add_deep_price_point<BaseAsset, QuoteAsset, ReferenceBaseAsset, ReferenceQuoteAsset>(
    target_pool: &mut Pool<BaseAsset, QuoteAsset>,
    reference_pool: &Pool<ReferenceBaseAsset, ReferenceQuoteAsset>,
    clock: &Clock,
) {
    assert!(
        reference_pool.whitelisted() && reference_pool.registered_pool(),
        EIneligibleReferencePool,
    );
    let reference_pool_price = reference_pool.mid_price(clock);

    let target_pool = target_pool.load_inner_mut();
    let reference_base_type = type_name::get<ReferenceBaseAsset>();
    let reference_quote_type = type_name::get<ReferenceQuoteAsset>();
    let target_base_type = type_name::get<BaseAsset>();
    let target_quote_type = type_name::get<QuoteAsset>();
    let deep_type = type_name::get<DEEP>();
    let timestamp = clock.timestamp_ms();

    assert!(
        reference_base_type == deep_type || reference_quote_type == deep_type,
        EIneligibleTargetPool,
    );

    let reference_deep_is_base = reference_base_type == deep_type;
    let reference_other_type = if (reference_deep_is_base) {
        reference_quote_type
    } else {
        reference_base_type
    };
    let reference_other_is_target_base = reference_other_type == target_base_type;
    let reference_other_is_target_quote = reference_other_type == target_quote_type;
    assert!(
        reference_other_is_target_base || reference_other_is_target_quote,
        EIneligibleTargetPool,
    );

    let deep_per_reference_other_price = if (reference_deep_is_base) {
        math::div(1_000_000_000, reference_pool_price)
    } else {
        reference_pool_price
    };

    target_pool
        .deep_price
        .add_price_point(
            deep_per_reference_other_price,
            timestamp,
            reference_other_is_target_base,
        );
    emit_deep_price_added(
        deep_per_reference_other_price,
        timestamp,
        reference_other_is_target_base,
        reference_pool.load_inner().pool_id,
        target_pool.pool_id,
    );
}

All pools support input token fees. To allow a permissionless pool to pay fees in DEEP, which has a 20% discount compared to input token fees, two conditions must be met:

Either the base or quote asset must be USDC or SUI.
To calculate DEEP fees accurately, you must set up a cron job to call the add_deep_price_point() function on the pool every 1-10 minutes.
For a pool with USDC as an asset, use the DEEP/USDC pool at 0xf948981b806057580f91622417534f491da5f61aeaf33d0ed8e69fd5691c95ce as the reference pool.

For a pool with SUI as an asset, use the DEEP/SUI pool at 0xb663828d6217467c8a1838a03793da896cbe745b150ebd57d82f814ca579fc22 as the reference pool.

Update allowed versions
The update_allowed_versions() function takes a pool and the registry, and updates the allowed contract versions within the pool. This is very important after contract upgrades to ensure the newest contract can be used on the pool.

public fun update_allowed_versions<BaseAsset, QuoteAsset>(
    self: &mut Pool<BaseAsset, QuoteAsset>,
    registry: &Registry,
    _cap: &DeepbookAdminCap,
) {
    let allowed_versions = registry.allowed_versions();
    let inner: &mut PoolInner<BaseAsset, QuoteAsset> = self.inner.load_value_mut();
    inner.allowed_versions = allowed_versions;
}

Related links
DeepBookV3 repository: The DeepBookV3 repository on GitHub.

Query the Pool
The Pool shared object represents a market, such as a SUI/USDC market. That Pool is the only one representing that unique pairing (SUI/USDC) and the pairing is the only member of that particular Pool. See DeepBookV3 Design to learn more about the structure of pools.

To perform trades, you pass a BalanceManager and TradeProof into the relevant Pool. Unlike Pools, BalanceManager shared objects can contain any type of token, such that the same BalanceManager can access multiple Pools to interact with many different trade pairings. See BalanceManager to learn more.

API
DeepBookV3 exposes a set of endpoints that can be used to query any pool.

Check whitelist status
Accessor to check whether the pool is whitelisted.

public fun whitelisted<BaseAsset, QuoteAsset>(self: &Pool<BaseAsset, QuoteAsset>): bool {
    self.load_inner().state.governance().whitelisted()
}

Check quote quantity against base (DEEP fees)
Dry run to determine the quote quantity out for a given base quantity. Uses DEEP as fee.

public fun get_quote_quantity_out<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
    base_quantity: u64,
    clock: &Clock,
): (u64, u64, u64) {
    self.get_quantity_out(base_quantity, 0, clock)
}

Check base quantity against quote (DEEP fees)
Dry run to determine the base quantity out for a given quote quantity. Uses DEEP as fee.

public fun get_base_quantity_out<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
    quote_quantity: u64,
    clock: &Clock,
): (u64, u64, u64) {
    self.get_quantity_out(0, quote_quantity, clock)
}

Check quote quantity against base (input token fees)
Dry run to determine the quote quantity out for a given base quantity. Uses input token as fee.

public fun get_quote_quantity_out_input_fee<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
    base_quantity: u64,
    clock: &Clock,
): (u64, u64, u64) {
    self.get_quantity_out_input_fee(base_quantity, 0, clock)
}

Check base quantity against quote (input token fees)
Dry run to determine the base quantity out for a given quote quantity. Uses input token as fee.

public fun get_base_quantity_out_input_fee<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
    quote_quantity: u64,
    clock: &Clock,
): (u64, u64, u64) {
    self.get_quantity_out_input_fee(0, quote_quantity, clock)
}

Check quote quantity against quote or base
Dry run to determine the quantity out for a given base or quote quantity. Only one out of base or quote quantity should be non-zero. Returns the (base_quantity_out, quote_quantity_out, deep_quantity_required).

public fun get_quantity_out<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
    base_quantity: u64,
    quote_quantity: u64,
    clock: &Clock,
): (u64, u64, u64) {
    let whitelist = self.whitelisted();
    let self = self.load_inner();
    let params = self.state.governance().trade_params();
    let taker_fee = params.taker_fee();
    let deep_price = self.deep_price.get_order_deep_price(whitelist);
    self
        .book
        .get_quantity_out(
            base_quantity,
            quote_quantity,
            taker_fee,
            deep_price,
            self.book.lot_size(),
            true,
            clock.timestamp_ms(),
        )
}

Check fee required
Returns the DEEP required for an order if it's a taker or maker given quantity and price (deep_required_taker, deep_required_maker).

public fun get_order_deep_required<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
    base_quantity: u64,
    price: u64,
): (u64, u64) {
    let order_deep_price = self.get_order_deep_price();
    let self = self.load_inner();
    let maker_fee = self.state.governance().trade_params().maker_fee();
    let taker_fee = self.state.governance().trade_params().taker_fee();
    let deep_quantity = order_deep_price
        .fee_quantity(
            base_quantity,
            math::mul(base_quantity, price),
            true,
        )
        .deep();

    (math::mul(taker_fee, deep_quantity), math::mul(maker_fee, deep_quantity))
}

Retrieve mid price for a pool
Returns the mid price of the pool.

public fun mid_price<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
    clock: &Clock,
): u64 {
    self.load_inner().book.mid_price(clock.timestamp_ms())
}

Retrieve order IDs
Returns the order_id for all open orders for the balance_manager in the pool.

public fun account_open_orders<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
    balance_manager: &BalanceManager,
): VecSet<u128> {
    let self = self.load_inner();

    if (!self.state.account_exists(balance_manager.id())) {
        return vec_set::empty()
    };

    self.state.account(balance_manager.id()).open_orders()
}

Retrieve prices and quantities for an order book
Returns vectors holding the prices (price_vec) and quantities (quantity_vec) for the level2 order book. The price_low and price_high are inclusive, all orders within the range are returned. is_bid is true for bids and false for asks.

public fun get_level2_range<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
    price_low: u64,
    price_high: u64,
    is_bid: bool,
    clock: &Clock,
): (vector<u64>, vector<u64>) {
    self
        .load_inner()
        .book
        .get_level2_range_and_ticks(
            price_low,
            price_high,
            constants::max_u64(),
            is_bid,
            clock.timestamp_ms(),
        )
}

Returns vectors holding the prices (price_vec) and quantities (quantity_vec) for the level2 order book. ticks are the maximum number of ticks to return starting from best bid and best ask. (bid_price, bid_quantity, ask_price, ask_quantity) are returned as four vectors. The price vectors are sorted in descending order for bids and ascending order for asks.

public fun get_level2_ticks_from_mid<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
    ticks: u64,
    clock: &Clock,
): (vector<u64>, vector<u64>, vector<u64>, vector<u64>) {
    let self = self.load_inner();
    let (bid_price, bid_quantity) = self
        .book
        .get_level2_range_and_ticks(
            constants::min_price(),
            constants::max_price(),
            ticks,
            true,
            clock.timestamp_ms(),
        );
    let (ask_price, ask_quantity) = self
        .book
        .get_level2_range_and_ticks(
            constants::min_price(),
            constants::max_price(),
            ticks,
            false,
            clock.timestamp_ms(),
        );

    (bid_price, bid_quantity, ask_price, ask_quantity)
}

Retrieve balances
Get all balances held in this pool.

public fun vault_balances<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
): (u64, u64, u64) {
    self.load_inner().vault.balances()
}

Retrieve pool ID
Get the ID of the pool given the asset types.

public fun get_pool_id_by_asset<BaseAsset, QuoteAsset>(registry: &Registry): ID {
    registry.get_pool_id<BaseAsset, QuoteAsset>()
}

Retrieve order information
Returns the Order struct using the order ID.

public fun get_order<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
    order_id: u128,
): Order {
    self.load_inner().book.get_order(order_id)
}

Returns a vector of Order structs using a vector of order IDs.

public fun get_orders<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
    order_ids: vector<u128>,
): vector<Order> {
    let mut orders = vector[];
    let mut i = 0;
    let num_orders = order_ids.length();
    while (i < num_orders) {
        let order_id = order_ids[i];
        orders.push_back(self.get_order(order_id));
        i = i + 1;
    };

    orders
}

Returns a vector of Order structs for all orders that belong to a BalanceManager in the pool.

public fun get_account_order_details<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
    balance_manager: &BalanceManager,
): vector<Order> {
    let acct_open_orders = self.account_open_orders(balance_manager).into_keys();

    self.get_orders(acct_open_orders)
}

Retrieve locked balance
Returns the locked balance for a BalanceManager in the pool (base_quantity, quote_quantity, deep_quantity).

public fun locked_balance<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
    balance_manager: &BalanceManager,
): (u64, u64, u64) {
    let account_orders = self.get_account_order_details(balance_manager);
    let self = self.load_inner();
    if (!self.state.account_exists(balance_manager.id())) {
        return (0, 0, 0)
    };

    let mut base_quantity = 0;
    let mut quote_quantity = 0;
    let mut deep_quantity = 0;

    account_orders.do_ref!(|order| {
        let maker_fee = self.state.history().historic_maker_fee(order.epoch());
        let locked_balance = order.locked_balance(maker_fee);
        base_quantity = base_quantity + locked_balance.base();
        quote_quantity = quote_quantity + locked_balance.quote();
        deep_quantity = deep_quantity + locked_balance.deep();
    });

    let settled_balances = self.state.account(balance_manager.id()).settled_balances();
    base_quantity = base_quantity + settled_balances.base();
    quote_quantity = quote_quantity + settled_balances.quote();
    deep_quantity = deep_quantity + settled_balances.deep();

    (base_quantity, quote_quantity, deep_quantity)
}

Retrieve pool parameters
Returns the trade parameters for the pool (taker_fee, maker_fee, stake_required).

public fun pool_trade_params<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
): (u64, u64, u64) {
    let self = self.load_inner();
    let trade_params = self.state.governance().trade_params();
    let taker_fee = trade_params.taker_fee();
    let maker_fee = trade_params.maker_fee();
    let stake_required = trade_params.stake_required();

    (taker_fee, maker_fee, stake_required)
}

Returns the trade parameters for the next epoch for the currently leading proposal of the pool (taker_fee, maker_fee, stake_required).

public fun pool_trade_params_next<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
): (u64, u64, u64) {
    let self = self.load_inner();
    let trade_params = self.state.governance().next_trade_params();
    let taker_fee = trade_params.taker_fee();
    let maker_fee = trade_params.maker_fee();
    let stake_required = trade_params.stake_required();

    (taker_fee, maker_fee, stake_required)
}

Returns the quorum needed to pass proposal in the current epoch.

public fun quorum<BaseAsset, QuoteAsset>(self: &Pool<BaseAsset, QuoteAsset>): u64 {
    self.load_inner().state.governance().quorum()
}

Returns the book parameters for the pool (tick_size, lot_size, min_size).

public fun pool_book_params<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
): (u64, u64, u64) {
    let self = self.load_inner();
    let tick_size = self.book.tick_size();
    let lot_size = self.book.lot_size();
    let min_size = self.book.min_size();

    (tick_size, lot_size, min_size)
}

Returns the OrderDeepPrice struct for the pool, which determines the conversion for DEEP fees.

public fun get_order_deep_price<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
): OrderDeepPrice {
    let whitelist = self.whitelisted();
    let self = self.load_inner();

    self.deep_price.get_order_deep_price(whitelist)
}

Related links
DeepBookV3 repository: The DeepBookV3 repository on GitHub.

Orders
Users can create limit or market orders, modify orders, and cancel orders. The BalanceManager must have the necessary funds to process orders. DeepBookV3 has four order options and three self matching options. If you set the pay_with_deep flag to true, trading fees are paid with the DEEP token. If you set the pay_with_deep flag to false, trading fees are paid with the input token.

Users can modify their existing order, reducing the size, lowering the expiration time, or both. Users cannot modify their order to increase their size or increase their expiration time. To do that, they must cancel the original order and place a new order.

Users can cancel a single order or cancel all of their orders.

API
Following are the order related endpoints that Pool exposes.

Order options
The following constants define the options available for orders.

// Restrictions on limit orders.
// No restriction on the order.
const NO_RESTRICTION: u8 = 0;
// Mandates that whatever amount of an order that can be executed in the current
// transaction, be filled and then the rest of the order canceled.
const IMMEDIATE_OR_CANCEL: u8 = 1;
// Mandates that the entire order size be filled in the current transaction.
// Otherwise, the order is canceled.
const FILL_OR_KILL: u8 = 2;
// Mandates that the entire order be passive. Otherwise, cancel the order.
const POST_ONLY: u8 = 3;

Self-matching options
The following constants define the options available for self-matching orders.

// Self matching types.
// Self matching is allowed.
const SELF_MATCHING_ALLOWED: u8 = 0;
// Cancel the taker order.
const CANCEL_TAKER: u8 = 1;
// Cancel the maker order.
const CANCEL_MAKER: u8 = 2;

OrderInfo struct
Placing a limit order or a market order creates and returns an OrderInfo object. DeepBookV3 automatically drops this object after the order completes or is placed in the book. Use OrderInfo to inspect the execution details of the request as it represents all order information. DeepBookV3 does not catch any errors, so if there’s a failure of any kind, then the entire transaction fails.

// === Structs ===
/// OrderInfo struct represents all order information.
/// This objects gets created at the beginning of the order lifecycle and
/// gets updated until it is completed or placed in the book.
/// It is returned at the end of the order lifecycle.
public struct OrderInfo has copy, drop, store {
    // ID of the pool
    pool_id: ID,
    // ID of the order within the pool
    order_id: u128,
    // ID of the account the order uses
    balance_manager_id: ID,
    // ID of the order defined by client
    client_order_id: u64,
    // Trader of the order
    trader: address,
    // Order type, NO_RESTRICTION, IMMEDIATE_OR_CANCEL, FILL_OR_KILL, POST_ONLY
    order_type: u8,
    // Self matching option,
    self_matching_option: u8,
    // Price, only used for limit orders
    price: u64,
    // Whether the order is a buy or a sell
    is_bid: bool,
    // Quantity (in base asset terms) when the order is placed
    original_quantity: u64,
    // Deep conversion used by the order
    order_deep_price: OrderDeepPrice,
    // Expiration timestamp in ms
    expire_timestamp: u64,
    // Quantity executed so far
    executed_quantity: u64,
    // Cumulative quote quantity executed so far
    cumulative_quote_quantity: u64,
    // Any partial fills
    fills: vector<Fill>,
    // Whether the fee is in DEEP terms
    fee_is_deep: bool,
    // Fees paid so far in base/quote/DEEP terms for taker orders
    paid_fees: u64,
    // Fees transferred to pool vault but not yet paid for maker order
    maker_fees: u64,
    // Epoch this order was placed
    epoch: u64,
    // Status of the order
    status: u8,
    // Is a market_order
    market_order: bool,
    // Executed in one transaction
    fill_limit_reached: bool,
    // Whether order is inserted
    order_inserted: bool,
    // Order Timestamp
    timestamp: u64,
}

OrderDeepPrice struct
The OrderDeepPrice struct represents the conversion rate of DEEP at the time the order was placed.

public struct OrderDeepPrice has copy, drop, store {
    asset_is_base: bool,
    deep_per_asset: u64,
}

Fill struct
The Fill struct represents the results of a match between two orders. Use this struct to update the state.

// === Structs ===
/// Fill struct represents the results of a match between two orders.
/// It is used to update the state.
public struct Fill has copy, drop, store {
    // ID of the maker order
    maker_order_id: u128,
    // Client Order ID of the maker order
    maker_client_order_id: u64,
    // Execution price
    execution_price: u64,
    // account_id of the maker order
    balance_manager_id: ID,
    // Whether the maker order is expired
    expired: bool,
    // Whether the maker order is fully filled
    completed: bool,
    // Original maker quantity
    original_maker_quantity: u64,
    // Quantity filled
    base_quantity: u64,
    // Quantity of quote currency filled
    quote_quantity: u64,
    // Whether the taker is bid
    taker_is_bid: bool,
    // Maker epoch
    maker_epoch: u64,
    // Maker deep price
    maker_deep_price: OrderDeepPrice,
    // Taker fee paid for fill
    taker_fee: u64,
    // Whether taker_fee is DEEP
    taker_fee_is_deep: bool,
    // Maker fee paid for fill
    maker_fee: u64,
    // Whether maker_fee is DEEP
    maker_fee_is_deep: bool,
}

Events
DeepBookV3 emits OrderFilled when a maker order is filled.

/// Emitted when a maker order is filled.
public struct OrderFilled has copy, drop, store {
    pool_id: ID,
    maker_order_id: u128,
    taker_order_id: u128,
    maker_client_order_id: u64,
    taker_client_order_id: u64,
    price: u64,
    taker_is_bid: bool,
    taker_fee: u64,
    taker_fee_is_deep: bool,
    maker_fee: u64,
    maker_fee_is_deep: bool,
    base_quantity: u64,
    quote_quantity: u64,
    maker_balance_manager_id: ID,
    taker_balance_manager_id: ID,
    timestamp: u64,
}

DeepBookV3 emits OrderCanceled when a maker order is canceled.

/// Emitted when a maker order is canceled.
public struct OrderCanceled has copy, drop, store {
    balance_manager_id: ID,
    pool_id: ID,
    order_id: u128,
    client_order_id: u64,
    trader: address,
    price: u64,
    is_bid: bool,
    original_quantity: u64,
    base_asset_quantity_canceled: u64,
    timestamp: u64,
}

DeepBookV3 emits OrderModified on modification of a maker order.

/// Emitted when a maker order is modified.
public struct OrderModified has copy, drop, store {
    balance_manager_id: ID,
    pool_id: ID,
    order_id: u128,
    client_order_id: u64,
    trader: address,
    price: u64,
    is_bid: bool,
    previous_quantity: u64,
    filled_quantity: u64,
    new_quantity: u64,
    timestamp: u64,
}

DeepBookV3 emits OrderPlaced when it injects a maker order into the order book.

/// Emitted when a maker order is injected into the order book.
public struct OrderPlaced has copy, drop, store {
    balance_manager_id: ID,
    pool_id: ID,
    order_id: u128,
    client_order_id: u64,
    trader: address,
    price: u64,
    is_bid: bool,
    placed_quantity: u64,
    expire_timestamp: u64,
    timestamp: u64,
}

Place limit order
Place a limit order. Quantity is in base asset terms. For current version pay_with_deep must be true, so the fee is paid with DEEP tokens.

You must combine a BalanceManager call of generating a TradeProof before placing orders.

public fun place_limit_order<BaseAsset, QuoteAsset>(
    self: &mut Pool<BaseAsset, QuoteAsset>,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
    client_order_id: u64,
    order_type: u8,
    self_matching_option: u8,
    price: u64,
    quantity: u64,
    is_bid: bool,
    pay_with_deep: bool,
    expire_timestamp: u64,
    clock: &Clock,
    ctx: &TxContext,
): OrderInfo {
    self.place_order_int(
        balance_manager,
        trade_proof,
        client_order_id,
        order_type,
        self_matching_option,
        price,
        quantity,
        is_bid,
        pay_with_deep,
        expire_timestamp,
        clock,
        false,
        ctx,
    )
}

Place market order
Place a market order. Quantity is in base asset terms. Calls place_limit_order with a price of MAX_PRICE for bids and MIN_PRICE for asks. DeepBookV3 cancels the order for any quantity not filled.

public fun place_market_order<BaseAsset, QuoteAsset>(
    self: &mut Pool<BaseAsset, QuoteAsset>,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
    client_order_id: u64,
    self_matching_option: u8,
    quantity: u64,
    is_bid: bool,
    pay_with_deep: bool,
    clock: &Clock,
    ctx: &TxContext,
): OrderInfo {
    self.place_order_int(
        balance_manager,
        trade_proof,
        client_order_id,
        constants::immediate_or_cancel(),
        self_matching_option,
        if (is_bid) constants::max_price() else constants::min_price(),
        quantity,
        is_bid,
        pay_with_deep,
        clock.timestamp_ms(),
        clock,
        true,
        ctx,
    )
}

Modify order
Modifies an order given order_id and new_quantity. New quantity must be less than the original quantity and more than the filled quantity. Order must not have already expired.

The modify_order function does not return anything. If the transaction is successful, then assume the modification was successful.

public fun modify_order<BaseAsset, QuoteAsset>(
    self: &mut Pool<BaseAsset, QuoteAsset>,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
    order_id: u128,
    new_quantity: u64,
    clock: &Clock,
    ctx: &TxContext,
) {
    let previous_quantity = self.get_order(order_id).quantity();

    let self = self.load_inner_mut();
    let (cancel_quantity, order) = self
        .book
        .modify_order(order_id, new_quantity, clock.timestamp_ms());
    assert!(order.balance_manager_id() == balance_manager.id(), EInvalidOrderBalanceManager);
    let (settled, owed) = self
        .state
        .process_modify(
            balance_manager.id(),
            cancel_quantity,
            order,
            self.pool_id,
            ctx,
        );
    self.vault.settle_balance_manager(settled, owed, balance_manager, trade_proof);

    order.emit_order_modified(
        self.pool_id,
        previous_quantity,
        ctx.sender(),
        clock.timestamp_ms(),
    );
}

Cancel order
Cancel an order. The order must be owned by the balance_manager. The order is removed from the book and the balance_manager open orders. The balance_manager balance is updated with the order's remaining quantity.

Similar to modify, cancel_order does not return anything. DeepBookV3 emits OrderCanceled event.

public fun cancel_order<BaseAsset, QuoteAsset>(
    self: &mut Pool<BaseAsset, QuoteAsset>,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
    order_id: u128,
    clock: &Clock,
    ctx: &TxContext,
) {
    let self = self.load_inner_mut();
    let mut order = self.book.cancel_order(order_id);
    assert!(order.balance_manager_id() == balance_manager.id(), EInvalidOrderBalanceManager);
    let (settled, owed) = self
        .state
        .process_cancel(&mut order, balance_manager.id(), self.pool_id, ctx);
    self.vault.settle_balance_manager(settled, owed, balance_manager, trade_proof);

    order.emit_order_canceled(
        self.pool_id,
        ctx.sender(),
        clock.timestamp_ms(),
    );
}

Withdraw settled amounts
Withdraw settled amounts to the balance_manager. All orders automatically withdraw settled amounts. This can be called explicitly to withdraw all settled funds from the pool.

public fun withdraw_settled_amounts<BaseAsset, QuoteAsset>(
    self: &mut Pool<BaseAsset, QuoteAsset>,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
) {
    let self = self.load_inner_mut();
    let (settled, owed) = self.state.withdraw_settled_amounts(balance_manager.id());
    self.vault.settle_balance_manager(settled, owed, balance_manager, trade_proof);
}

Related links
DeepBookV3 repository: The DeepBookV3 repository on GitHub.

Swaps
DeepBook provides a swap-like interface commonly seen in automatic market makers (AMMs). Unlike the order functions, you can call swap_exact_amount without a BalanceManager. You call it directly with Coin objects instead. When swapping from base to quote, base_in must have a positive value while quote_in must be zero. When swapping from quote to base, quote_in must be positive and base_in zero. Some deep_in amount is required to pay for trading fees. You can overestimate this amount, as the unused DEEP tokens are returned at the end of the call.

You can use the get_amount_out endpoint to simulate a swap. The function returns the exact amount of DEEP tokens that the swap requires.

API
Following are the endpoints that the Pool exposes for swaps.

Swap exact base for quote
Swap exact base quantity without needing a balance_manager. DEEP quantity can be overestimated. Returns three Coin objects:

BaseAsset
QuoteAsset
DEEP
Some base quantity may be left over, if the input quantity is not divisible by lot size.

You can overestimate the amount of DEEP required. The remaining balance is returned.

public fun swap_exact_base_for_quote<BaseAsset, QuoteAsset>(
    self: &mut Pool<BaseAsset, QuoteAsset>,
    base_in: Coin<BaseAsset>,
    deep_in: Coin<DEEP>,
    min_quote_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<BaseAsset>, Coin<QuoteAsset>, Coin<DEEP>) {
    let quote_in = coin::zero(ctx);

    self.swap_exact_quantity(
        base_in,
        quote_in,
        deep_in,
        min_quote_out,
        clock,
        ctx,
    )
}

Swap exact quote for base
Swap exact quote quantity without needing a balance_manager. You can overestimate DEEP quantity. Returns three Coin objects:

BaseAsset
QuoteAsset
DEEP
Some quote quantity might be left over if the input quantity is not divisible by lot size.

public fun swap_exact_quote_for_base<BaseAsset, QuoteAsset>(
    self: &mut Pool<BaseAsset, QuoteAsset>,
    quote_in: Coin<QuoteAsset>,
    deep_in: Coin<DEEP>,
    min_base_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<BaseAsset>, Coin<QuoteAsset>, Coin<DEEP>) {
    let base_in = coin::zero(ctx);

    self.swap_exact_quantity(
        base_in,
        quote_in,
        deep_in,
        min_base_out,
        clock,
        ctx,
    )
}

Swap exact quantity
This function is what the previous two functions call with coin::zero() set for the third coin. Users can call this directly for base → quote or quote → base as long as base or quote have a zero value.

public fun swap_exact_quantity<BaseAsset, QuoteAsset>(
    self: &mut Pool<BaseAsset, QuoteAsset>,
    base_in: Coin<BaseAsset>,
    quote_in: Coin<QuoteAsset>,
    deep_in: Coin<DEEP>,
    min_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<BaseAsset>, Coin<QuoteAsset>, Coin<DEEP>) {
    let mut base_quantity = base_in.value();
    let quote_quantity = quote_in.value();
    let taker_fee = self.load_inner().state.governance().trade_params().taker_fee();
    let input_fee_rate = math::mul(
        taker_fee,
        constants::fee_penalty_multiplier(),
    );
    assert!((base_quantity > 0) != (quote_quantity > 0), EInvalidQuantityIn);

    let pay_with_deep = deep_in.value() > 0;
    let is_bid = quote_quantity > 0;
    if (is_bid) {
        (base_quantity, _, _) = if (pay_with_deep) {
            self.get_quantity_out(0, quote_quantity, clock)
        } else {
            self.get_quantity_out_input_fee(0, quote_quantity, clock)
        }
    } else {
        if (!pay_with_deep) {
            base_quantity =
                math::div(
                    base_quantity,
                    constants::float_scaling() + input_fee_rate,
                );
        }
    };
    base_quantity = base_quantity - base_quantity % self.load_inner().book.lot_size();
    if (base_quantity < self.load_inner().book.min_size()) {
        return (base_in, quote_in, deep_in)
    };

    let mut temp_balance_manager = balance_manager::new(ctx);
    let trade_proof = temp_balance_manager.generate_proof_as_owner(ctx);
    temp_balance_manager.deposit(base_in, ctx);
    temp_balance_manager.deposit(quote_in, ctx);
    temp_balance_manager.deposit(deep_in, ctx);

    self.place_market_order(
        &mut temp_balance_manager,
        &trade_proof,
        0,
        constants::self_matching_allowed(),
        base_quantity,
        is_bid,
        pay_with_deep,
        clock,
        ctx,
    );

    let base_out = temp_balance_manager.withdraw_all<BaseAsset>(ctx);
    let quote_out = temp_balance_manager.withdraw_all<QuoteAsset>(ctx);
    let deep_out = temp_balance_manager.withdraw_all<DEEP>(ctx);

    if (is_bid) {
        assert!(base_out.value() >= min_out, EMinimumQuantityOutNotMet);
    } else {
        assert!(quote_out.value() >= min_out, EMinimumQuantityOutNotMet);
    };

    temp_balance_manager.delete();

    (base_out, quote_out, deep_out)
}

Related links
DeepBookV3 repository: The DeepBookV3 repository on GitHub.

https://github.com/MystenLabs/deepbookv3

Flash Loans
Flash loans by definition are uncollateralized loans that are borrowed and repaid within the same programmable transaction block. Users can borrow flash loans in the base or quote asset from any DeepBookV3 pool. Flash loans return a FlashLoan hot potato (struct with no abilities), which must be returned back to the pool by the end of the call. The transaction is atomic, so the entire transaction fails if the loan is not returned.

The quantity borrowed can be the maximum amount that the pool owns. Borrowing from a pool and trading in the same pool can result in failures because trading requires the movement of funds. If the funds are borrowed, then there are no funds to move.

API
Following are the endpoints that the Pool exposes for flash loans.

Borrow flash loan base
Borrow base assets from the Pool. The function returns a hot potato, forcing the borrower to return the assets within the same transaction.

public fun borrow_flashloan_base<BaseAsset, QuoteAsset>(
    self: &mut Pool<BaseAsset, QuoteAsset>,
    base_amount: u64,
    ctx: &mut TxContext,
): (Coin<BaseAsset>, FlashLoan) {
    let self = self.load_inner_mut();
    self.vault.borrow_flashloan_base(self.pool_id, base_amount, ctx)
}

Borrow flash loan quote
Borrow quote assets from the Pool. The function returns a hot potato, forcing the borrower to return the assets within the same transaction.

public fun borrow_flashloan_quote<BaseAsset, QuoteAsset>(
    self: &mut Pool<BaseAsset, QuoteAsset>,
    quote_amount: u64,
    ctx: &mut TxContext,
): (Coin<QuoteAsset>, FlashLoan) {
    let self = self.load_inner_mut();
    self.vault.borrow_flashloan_quote(self.pool_id, quote_amount, ctx)
}

Retrieve flash loan base
Return the flash loaned base assets to the Pool. FlashLoan object is unwrapped only if the assets are returned, otherwise the transaction fails.

public fun return_flashloan_base<BaseAsset, QuoteAsset>(
    self: &mut Pool<BaseAsset, QuoteAsset>,
    coin: Coin<BaseAsset>,
    flash_loan: FlashLoan,
) {
    let self = self.load_inner_mut();
    self.vault.return_flashloan_base(self.pool_id, coin, flash_loan);
}

Retrieve flash loan quote
Return the flash loaned quote assets to the Pool. FlashLoan object is unwrapped only if the assets are returned, otherwise the transaction fails.

public fun return_flashloan_quote<BaseAsset, QuoteAsset>(
    self: &mut Pool<BaseAsset, QuoteAsset>,
    coin: Coin<QuoteAsset>,
    flash_loan: FlashLoan,
) {
    let self = self.load_inner_mut();
    self.vault.return_flashloan_quote(self.pool_id, coin, flash_loan);
}

DeepBookV3 Indexer
DeepBookV3 Indexer provides streamlined, real-time access to order book and trading data from the DeepBookV3 protocol. It acts as a centralized service to aggregate and expose critical data points for developers, traders, and analysts who interact with DeepBookV3.

DeepBookV3 Indexer simplifies data retrieval by offering endpoints that enable:

Viewing pool information: Retrieve detailed metadata about all available trading pools, including base and quote assets, tick sizes, and lot sizes.
Historical volume analysis: Fetch volume metrics for specific pools or balance managers over custom time ranges, with support for interval-based breakdowns.
User-specific volume tracking: Provide insights into individual trader activities by querying their balance manager-specific volumes.
You can either use a publicly available indexer or spin up your own service. The choice you make depends on a few factors.

Use the public service if:

You have standard data needs.
Latency and availability provided by the public endpoint meet your requirements.
You want to avoid the operational overhead of running your own service.
Run your own indexer if:

You require guaranteed uptime and low latency.
You have specific customization needs.
Your application depends on proprietary features or extended data sets.
Public DeepBookV3 Indexer
Mysten Labs provides a public indexer for DeepBookV3. You can access this indexer at the following URL:

https://deepbook-indexer.mainnet.mystenlabs.com/

Asset conversions
Volumes returned by the following endpoints are expressed in the smallest unit of the corresponding asset.

/all_historical_volume
/historical_volume
/historical_volume_by_balance_manager_id
/historical_volume_by_balance_manager_id_with_interval
Following are the decimal places (scalars) used to determine the base unit for each asset.

Asset	Scalar
AUSD	6
Bridged Eth (bETH)	8
Deepbook Token (DEEP)	6
Native USDC	6
SUI	9
SuiNS Token (NS)	6
TYPUS	9
Wrapped USDC (wUSDC)	6
Wrapped USDT (wUSDT)	6
To convert the returned volume to the standard asset unit, divide the value by 10^SCALAR. For example:

If the volume returned in the base asset for the SUI/USDC pool is 1,000,000,000 SUI UNIT, the correct volume in SUI is 1,000,000,000 / 10^(SUI_SCALAR) = 1 SUI. Similarly, if the volume returned in the quote asset for the SUI/USDC pool is 1,000,000,000 USDC UNIT, the correct volume is 1,000,000,000 / 10^(USDC_SCALAR) = 1,000 USDC.

Use these conversions to interpret the volumes correctly across all pools and assets.

API endpoints
You can perform the following tasks using the endpoints that the indexer API for DeepBookV3 provides.

Get all pool information
/get_pools

Returns a list of all available pools, each containing detailed information about the base and quote assets, as well as pool parameters like minimum size, lot size, and tick size.

Response
[
	{
	  "pool_id": "string",
	  "pool_name": "string",
	  "base_asset_id": "string",
	  "base_asset_decimals": integer,
	  "base_asset_symbol": "string",
	  "base_asset_name": "string",
	  "quote_asset_id": "string",
	  "quote_asset_decimals": integer,
	  "quote_asset_symbol": "string",
	  "quote_asset_name": "string",
	  "min_size": integer,
	  "lot_size": integer,
	  "tick_size": integer
	},
	...
]

Each pool object in the response includes the following fields:

pool_id: ID for the pool.
pool_name: Name of the pool.
base_asset_id: ID for the base asset.
base_asset_decimals: Number of decimals for the base asset.
base_asset_symbol: Symbol for the base asset.
base_asset_name: Name of the base asset.
quote_asset_id: ID for the quote asset.
quote_asset_decimals: Number of decimals for the quote asset.
quote_asset_symbol: Symbol for the quote asset.
quote_asset_name: Name of the quote asset.
min_size: Minimum trade size for the pool, in smallest units of the base asset.
lot_size: Minimum increment for trades in this pool, in smallest units of the base asset.
tick_size: Minimum price increment for trades in this pool.
Example
A successful request to the following endpoint

/get_pools

produces a response similar to

[
	{
		"pool_id": "0xb663828d6217467c8a1838a03793da896cbe745b150ebd57d82f814ca579fc22",
		"pool_name": "DEEP_SUI",
		"base_asset_id": "0xdeeb7a4662eec9f2f3def03fb937a663dddaa2e215b8078a284d026b7946c270::deep::DEEP",
		"base_asset_decimals": 6,
		"base_asset_symbol": "DEEP",
		"base_asset_name": "DeepBook Token",
		"quote_asset_id": "0x0000000000000000000000000000000000000000000000000000000000000002::sui::SUI",
		"quote_asset_decimals": 9,
		"quote_asset_symbol": "SUI",
		"quote_asset_name": "Sui",
		"min_size": 100000000,
		"lot_size": 10000000,
		"tick_size": 10000000
	},
	{
		"pool_id": "0xf948981b806057580f91622417534f491da5f61aeaf33d0ed8e69fd5691c95ce",
		"pool_name": "DEEP_USDC",
		"base_asset_id": "0xdeeb7a4662eec9f2f3def03fb937a663dddaa2e215b8078a284d026b7946c270::deep::DEEP",
		"base_asset_decimals": 6,
		"base_asset_symbol": "DEEP",
		"base_asset_name": "DeepBook Token",
		"quote_asset_id": "0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC",
		"quote_asset_decimals": 6,
		"quote_asset_symbol": "USDC",
		"quote_asset_name": "USDC",
		"min_size": 100000000,
		"lot_size": 10000000,
		"tick_size": 10000
	}
]

Get historical volume for pool in a specific time range
/historical_volume/:pool_names?start_time=<UNIX_TIMESTAMP_SECONDS>&end_time=<UNIX_TIMESTAMP_SECONDS>&volume_in_base=<BOOLEAN>


Use this endpoint to get historical volume for pools for a specific time range. Delimit the pool_names with commas, and use Unix timestamp seconds for start_time and end_time values.

By default, this endpoint retrieves the last 24-hour trading volume in the quote asset for specified pools. If you want to query the base asset instead, set volume_in_base to true.

Response
Returns the historical volume for each specified pool within the given time range.

{
	"pool_name_1": total_pool1_volume,
	"pool_name_2": total_pool2_volume,
	...
}

Example
A successful request to the following endpoint

/historical_volume/DEEP_SUI,SUI_USDC?start_time=1731260703&end_time=1731692703&volume_in_base=true

produces a response similar to

{
	"DEEP_SUI": 22557460000000,
	"SUI_USDC": 19430171000000000
}

Get historical volume for all pools
/all_historical_volume?start_time=<UNIX_TIMESTAMP_SECONDS>&end_time=<UNIX_TIMESTAMP_SECONDS>&volume_in_base=<BOOLEAN>


Use this endpoint to get historical volume for all pools. Include the optional start_time and end_time values as Unix timestamp seconds to retrieve the volume within that time range.

By default, this endpoint retrieves the last 24-hour trading volume in the quote asset. If you want to query the base asset instead, set volume_in_base to true.

Response
Returns the historical volume for all available pools within the time range (if provided).

{
	"pool_name_1": total_pool1_volume,
	"pool_name_2": total_pool2_volume
}

Example
A successful request to the following endpoint

/all_historical_volume?start_time=<UNIX_TIMESTAMP_SECONDS>&end_time=<UNIX_TIMESTAMP_SECONDS>&volume_in_base=<BOOLEAN>


produces a response similar to

{
	"DEEP_SUI": 22557460000000,
	"WUSDT_USDC": 10265000000,
	"NS_USDC": 4399650900000,
	"NS_SUI": 6975475200000,
	"SUI_USDC": 19430171000000000,
	"WUSDC_USDC": 23349574900000,
	"DEEP_USDC": 130000590000000
}

Get historical volume by balance manager
/historical_volume_by_balance_manager_id/:pool_names/:balance_manager_id?start_time=<UNIX_TIMESTAMP_SECONDS>&end_time=<UNIX_TIMESTAMP_SECONDS>&volume_in_base=<BOOLEAN>


Get historical volume by balance manager for a specific time range. Delimit the pool_names with commas, and use Unix timestamp seconds for the optional start_time and end_time values.

By default, this endpoint retrieves the last 24-hour trading volume for the balance manager in the quote asset for specified pools. If you want to query the base asset instead, set volume_in_base to true.

Response
{
	"pool_name_1": [maker_volume, taker_volume],
	"pool_name_2": …
}

Example
A successful request to the following endpoint

/historical_volume_by_balance_manager_id/SUI_USDC,DEEP_SUI/0x344c2734b1d211bd15212bfb7847c66a3b18803f3f5ab00f5ff6f87b6fe6d27d?start_time=1731260703&end_time=1731692703&volume_in_base=true


produces a response similar to

{
	"DEEP_SUI": [
		14207960000000,
		3690000000
	],
	"SUI_USDC": [
		2089300100000000,
		17349400000000
	]
}

Get historical volume by balance manager within a specific time range and intervals
/historical_volume_by_balance_manager_id_with_interval/:pool_names/:balance_manager_id?start_time=<UNIX_TIMESTAMP_SECONDS>&end_time=<UNIX_TIMESTAMP_SECONDS>&interval=<UNIX_TIMESTAMP_SECONDS>&volume_in_base=<BOOLEAN>


Get historical volume by BalanceManager for a specific time range with intervals. Delimit pool_names with commas and use Unix timestamp seconds for the optional start_time and end_time values. Use number of seconds for the interval value. As a simplified interval example, if start_time is 5, end_time is 10, and interval is 2, then the response includes volume from 5 to 7 and 7 to 9, with start time of the periods as keys.

By default, this endpoint retrieves the last 24-hour trading volume for the balance manager in the quote asset for specified pools. If you want to query the base asset instead, set volume_in_base to true.

Response
{
	"[time_1_start, time_1_end]": {
		"pool_name_1": [maker_volume, taker_volume],
		"pool_name_2": …
	},
	"[time_2_start, time_2_end]": {
		"pool_name_1": [maker_volume, taker_volume],
		"pool_name_2": …
	}
}

Example
A successful request to the following endpoint with an interval of 24 hours

/historical_volume_by_balance_manager_id_with_interval/USDC_DEEP,SUI_USDC/0x344c2734b1d211bd15212bfb7847c66a3b18803f3f5ab00f5ff6f87b6fe6d27d?start_time=1731460703&end_time=1731692703&interval=86400&volume_in_base=true


produces a response similar to

{
	"[1731460703, 1731547103]": {
		"SUI_USDC": [
			505887400000000,
			2051300000000
		]
	},
	"[1731547103, 1731633503]": {
		"SUI_USDC": [
			336777500000000,
			470600000000
		]
	}
}

Get summary
/summary

Returns a summary in JSON for all trading pairs in DeepBookV3.

Response
Each summary object has the following form. The order of fields in the JSON object is not guaranteed.

{
	"trading_pairs": "string",
	"quote_currency": "string",
	"last_price": float,
	"lowest_price_24h": float,
	"highest_bid": float,
	"base_volume": float,
	"price_change_percent_24h": float,
	"quote_volume": float,
	"lowest_ask": float,
	"highest_price_24h": float,
	"base_currency": "string"
}

Example
A successful request to

/summary

produces a response similar to

[
	{
    "trading_pairs": "AUSD_USDC",
    "quote_currency": "USDC",
    "last_price": 1.0006,
    "lowest_price_24h": 0.99905,
    "highest_bid": 1.0006,
    "base_volume": 1169.2,
    "price_change_percent_24h": 0.07501125168773992,
    "quote_volume": 1168.961637,
    "lowest_ask": 1.0007,
    "highest_price_24h": 1.00145,
    "base_currency": "AUSD"
  },
  {
    "quote_volume": 4063809.55231,
    "lowest_price_24h": 0.9999,
    "highest_price_24h": 1.009,
    "base_volume": 4063883.6,
    "quote_currency": "USDC",
    "price_change_percent_24h": 0.0,
    "base_currency": "WUSDC",
    "trading_pairs": "WUSDC_USDC",
    "last_price": 1.0,
    "highest_bid": 1.0,
    "lowest_ask": 1.0001
  },
  {
		"price_change_percent_24h": 0.0,
		"quote_currency": "USDC",
		"lowest_price_24h": 0.0,
		"quote_volume": 0.0,
		"base_volume": 0.0,
		"highest_price_24h": 0.0,
		"lowest_ask": 1.04,
		"last_price": 1.04,
		"base_currency": "WUSDT",
		"highest_bid": 0.90002,
		"trading_pairs": "WUSDT_USDC"
	},
	...
]

Get ticker information
/ticker

Returns all trading pairs volume (already scaled), last price, and isFrozen value. Possible values for isFrozen is either:

0: Pool is active
1: Pool is inactive
Response
{
  "TRADING_PAIR": {
    "base_volume": float,
    "quote_volume": float,
    "last_price": float,
    "isFrozen": integer (0 | 1)
  }
}

Example
A successful request to

/ticker

produces a response similar to

{
	"DEEP_USDC": {
		"last_price": 0.07055,
		"base_volume": 43760440.0,
		"quote_volume": 3096546.9161,
		"isFrozen": 0
	},
	"NS_SUI": {
		"last_price": 0.08323,
		"base_volume": 280820.8,
		"quote_volume": 23636.83837,
		"isFrozen": 0
	},
	...
}

Get trades
/trades/:pool_name?limit=<INTEGER>&start_time=<UNIX_TIMESTAMP_SECONDS>&end_time=<UNIX_TIMESTAMP_SECONDS>&maker_balance_manager_id=<ID>&taker_balance_manager_id=<ID>


Returns the most recent trade in the pool.

Response
[
    {
        "trade_id": "string",
        "base_volume": integer,
        "quote_volume": integer,
        "price": integer,
        "type": "string",
        "timestamp": integer,
        "maker_order_id": "string",
        "taker_order_id": "string",
        "maker_balance_manager_id": "string",
        "taker_balance_manager_id": "string"
    }
]

The timestamp value is in Unix milliseconds.

Example
A successful request to

trades/SUI_USDC?limit=2&start_time=1738093405&end_time=1738096485&maker_balance_manager_id=0x344c2734b1d211bd15212bfb7847c66a3b18803f3f5ab00f5ff6f87b6fe6d27d&taker_balance_manager_id=0x47dcbbc8561fe3d52198336855f0983878152a12524749e054357ac2e3573d58


produces a response similar to

[
    {
        "trade_id": "136321457151457660152049680",
        "base_volume": 405,
        "quote_volume": 1499,
        "price": 3695,
        "type": "sell",
        "timestamp": 1738096392913,
        "maker_order_id": "68160737799100866923792791",
        "taker_order_id": "170141183460537392451039660509112362617",
        "maker_balance_manager_id": "0x344c2734b1d211bd15212bfb7847c66a3b18803f3f5ab00f5ff6f87b6fe6d27d",
        "taker_balance_manager_id": "0x47dcbbc8561fe3d52198336855f0983878152a12524749e054357ac2e3573d58"
    },
	...
]

Get order updates
/order_updates/:pool_name?limit=<INTEGER>&start_time=<UNIX_TIMESTAMP_SECONDS>&end_time=<UNIX_TIMESTAMP_SECONDS>&status=<"Placed" or "Canceled">&balance_manager_id=<ID>


Returns the orders that were recently placed or canceled in the pool

Response
[
    {
        "order_id": "string",
        "balance_manager_id": "string",
        "timestamp": integer,
        "original_quantity": integer,
        "remaining_quantity": integer,
        "filled_quantity": integer,
        "price": integer,
        "status": "string",
        "type": "string"
    }
]

The timestamp value is in Unix milliseconds.

Example
A successful request to

/order_updates/DEEP_USDC?start_time=1738703053&end_time=1738704080&limit=2&status=Placed&balance_manager_id=0xd335e8aa19d6dc04273d77e364c936bad69db4905a4ab3b2733d644dd2b31e0a


produces a response similar to

[
    {
        "order_id": "170141183464610341308794360958165054983",
        "balance_manager_id": "0xd335e8aa19d6dc04273d77e364c936bad69db4905a4ab3b2733d644dd2b31e0a",
        "timestamp": 1738704071994,
        "original_quantity": 8910,
        "remaining_quantity": 8910,
        "filled_quantity": 0,
        "price": 22449,
        "status": "Placed",
        "type": "sell"
    },
	...
]

Get order book information
/orderbook/:pool_name?level={1|2}&depth={integer}

Returns the bids and asks for the relevant pool. The bids and asks returned are each sorted from best to worst. There are two optional query parameters in the endpoint:

level: The level value can be either 1 or 2.
1: Only the best bid and ask.
2: Arranged by best bids and asks. This is the default value.
depth: The depth value can be 0 or greater than 1. A value of 0 returns the entire order book, and a value greater than 1 returns the specified number of both bids and asks. In other words, if you provide depth=100, then your response includes 50 bids and 50 asks. If the depth value is odd, it's treated as the next lowest even value. Consequently, depth=101 also returns 50 bids and 50 asks. If you do not provide a depth parameter, the response defaults to all orders in the order book.
Response
{
	"timestamp": "string",
	"bids": [
		[
			"string",
			"string"
		],
		[
			"string",
			"string"
		]
	],
	"asks": [
		[
			"string",
			"string"
		],
		[
			"string",
			"string"
		]
	]
}

The timestamp returned is a string that represents a Unix timestamp in milliseconds.

Example
A successful request to

/orderbook/SUI_USDC?level=2&depth=4

produces a response similar to

{
	"timestamp": "1733874965431",
	"bids": [
		[
			"3.715",
			"2.7"
		],
		[
			"3.713",
			"2294.8"
		]
	],
	"asks": [
		[
			"3.717",
			"0.9"
		],
		[
			"3.718",
			"1000"
		]
	]
}

Get asset information
/assets

Returns asset information for all coins being traded on DeepBookV3.

Response
Each asset object has the following form:

"ASSET_NAME": {
	"unified_cryptoasset_id": "string",
	"name": "string",
	"contractAddress": "string",
	"contractAddressUrl": "string",
	"can_deposit": "string (true | false)",
	"can_withdraw": "string (true | false)"
}

Example
A successful request to

/assets

produces a response similar to

{
  "NS": {
    "unified_cryptoasset_id": "32942",
    "name": "Sui Name Service",
    "contractAddress": "0x5145494a5f5100e645e4b0aa950fa6b68f614e8c59e17bc5ded3495123a79178",
    "contractAddressUrl": "https://suiscan.xyz/mainnet/object/0x5145494a5f5100e645e4b0aa950fa6b68f614e8c59e17bc5ded3495123a79178",
    "can_deposit": "true",
    "can_withdraw": "true"
  },
  "AUSD": {
    "unified_cryptoasset_id": "32864",
    "name": "AUSD",
    "contractAddress": "0x2053d08c1e2bd02791056171aab0fd12bd7cd7efad2ab8f6b9c8902f14df2ff2",
    "contractAddressUrl": "https://suiscan.xyz/mainnet/object/0x2053d08c1e2bd02791056171aab0fd12bd7cd7efad2ab8f6b9c8902f14df2ff2",
    "can_deposit": "true",
    "can_withdraw": "true"
  },
	...
}


Related links
DeepBookV3 repository: The DeepBookV3 repository on GitHub.


DeepBook V3 Mainnet Integration
We will maintain this technical document with the latest information for all mainnet integrations. The FAQ section may be filled in over time with questions that we receive. The current latest deployment uses the mainnet branch.

Note: All references to USDC refer to native USDC
Note: This is for mainnet integration. For testnet, please use this doc. 

Point of contact:
Aslan Tashtanov TG: @aslantash
Tony Lee TG: @tonylee08
Material
Last contract deployment: Deployment at Oct-10-2024 1400 UTC
VERSION: 1 (ORIGINAL_DEEPBOOK_PACKAGE_ID = 0x2c8d603bc51326b8c13cef9dd07031a408a48dddb541963357661df5d3204809)

Contract upgrade: Apr-16 2025, 1620 UTC
VERSION: 2
Package ID: 0xcaf6ba059d539a97646d47f0b9ddf843e138d215e2a12ca1f4585d386f7aec3a
Key changes: Input token fees, permissionless pool creation, gas improvements

Contract upgrade: Jun-11 2025
VERSION: 3
Package ID: 0xb29d83c26cdd2a64959263abbcfc4a6937f0c9fccaf98580ca56faded65be244
Key changes: Small bug fix for creating balance manager

Redeployment means DEEPBOOK_PACKAGE_ID, REGISTRY_ID, and all pool IDs need to be updated
Upgrade means only DEEPBOOK_PACKAGE_ID needs to be updated, previous versions will still be compatible unless noted here

DEEPBOOK_PACKAGE_ID = 0xb29d83c26cdd2a64959263abbcfc4a6937f0c9fccaf98580ca56faded65be244
REGISTRY_ID = 0xaf16199a2dff736e9f07a845f23c5da6df6f756eddb631aed9d24a93efc4549d

// Coins
// Deepbook Token
DEEP_ID = 0xdeeb7a4662eec9f2f3def03fb937a663dddaa2e215b8078a284d026b7946c270
DEEP_TYPE = 0xdeeb7a4662eec9f2f3def03fb937a663dddaa2e215b8078a284d026b7946c270::deep::DEEP
DEEP_DECIMALS = 6

// SUI Token
SUI_ID = 0x0000000000000000000000000000000000000000000000000000000000000002
SUI_TYPE = 0x0000000000000000000000000000000000000000000000000000000000000002::sui::SUI
SUI_DECIMALS = 9

// Native USDC Token
USDC_ID = 0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7
USDC_TYPE = 0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC
USDC_DECIMALS = 6

// Native bridged ETH
BETH_ID = 0xd0e89b2af5e4910726fbcd8b8dd37bb79b29e5f83f7491bca830e94f7f226d29
BETH_TYPE = 0xd0e89b2af5e4910726fbcd8b8dd37bb79b29e5f83f7491bca830e94f7f226d29::eth::ETH
BETH_DECIMALS = 8

// Wormhole USDT
WUSDT_ID = 0xc060006111016b8a020ad5b33834984a437aaa7d3c74c18e09a95d48aceab08c
WUSDT_TYPE = 0xc060006111016b8a020ad5b33834984a437aaa7d3c74c18e09a95d48aceab08c::coin::COIN
WUSDT_DECIMALS = 6

// Wormhole USDC
WUSDC_ID = 0x5d4b302506645c37ff133b98c4b50a5ae14841659738d6d733d59d0d217a93bf
WUSDC_TYPE = 0x5d4b302506645c37ff133b98c4b50a5ae14841659738d6d733d59d0d217a93bf::coin::COIN
WUSDC_DECIMALS = 6

// NS Token
NS_ID = 0x5145494a5f5100e645e4b0aa950fa6b68f614e8c59e17bc5ded3495123a79178
NS_TYPE = 0x5145494a5f5100e645e4b0aa950fa6b68f614e8c59e17bc5ded3495123a79178::ns::NS
NS_DECIMALS = 6

// TYPUS Token
TYPUS_ID = 0xf82dc05634970553615eef6112a1ac4fb7bf10272bf6cbe0f80ef44a6c489385
TYPUS_TYPE = 0xf82dc05634970553615eef6112a1ac4fb7bf10272bf6cbe0f80ef44a6c489385::typus::TYPUS
TYPUS_DECIMALS = 9

// AUSD Token
AUSD_ID = 0x2053d08c1e2bd02791056171aab0fd12bd7cd7efad2ab8f6b9c8902f14df2ff2
AUSD_TYPE = 0x2053d08c1e2bd02791056171aab0fd12bd7cd7efad2ab8f6b9c8902f14df2ff2::ausd::AUSD
AUSD_DECIMALS = 6

// DRF Token
DRF_ID = 0x294de7579d55c110a00a7c4946e09a1b5cbeca2592fbb83fd7bfacba3cfeaf0e
DRF_TYPE = 0x294de7579d55c110a00a7c4946e09a1b5cbeca2592fbb83fd7bfacba3cfeaf0e::drf::DRF
DRF_DECIMALS = 6

// SEND Token
SEND_ID = 0xb45fcfcc2cc07ce0702cc2d229621e046c906ef14d9b25e8e4d25f6e8763fef7
SEND_TYPE = 0xb45fcfcc2cc07ce0702cc2d229621e046c906ef14d9b25e8e4d25f6e8763fef7::send::SEND
SEND_DECIMALS = 6

// xBTC Token
XBTC_ID = 0x876a4b7bce8aeaef60464c11f4026903e9afacab79b9b142686158aa86560b50
XBTC_TYPE = 0x876a4b7bce8aeaef60464c11f4026903e9afacab79b9b142686158aa86560b50::xbtc::XBTC
XBTC_DECIMALS = 8

// WAL Token
WAL_ID = 0x356a26eb9e012a68958082340d4c4116e7f55615cf27affcff209cf0ae544f59
WAL_TYPE = 0x356a26eb9e012a68958082340d4c4116e7f55615cf27affcff209cf0ae544f59::wal::WAL
WAL_DECIMALS = 9

// IKA Token
IKA_ID = 0x7262fb2f7a3a14c888c438a3cd9b912469a58cf60f367352c46584262e8299aa
IKA_TYPE = 0x7262fb2f7a3a14c888c438a3cd9b912469a58cf60f367352c46584262e8299aa::ika::IKA
IKA_DECIMALS = 9

// Pools
DEEP_SUI = 
0xb663828d6217467c8a1838a03793da896cbe745b150ebd57d82f814ca579fc22
INITIAL_VERSION = 389750321
TICK_SIZE = 10000000 = 0.00001
LOT_SIZE = 10000000 = 10 DEEP
MIN_SIZE = 100000000 = 100 DEEP
INITIAL_TAKER_FEE = 0 bps
INITIAL_MAKER_FEE = 0 bps

DEEP_USDC = 0xf948981b806057580f91622417534f491da5f61aeaf33d0ed8e69fd5691c95ce
INITIAL_VERSION = 389750321
TICK_SIZE = 10000 = 0.00001
LOT_SIZE = 10000000 = 10 DEEP
MIN_SIZE = 100000000 = 100 DEEP
INITIAL_TAKER_FEE = 0 bps
INITIAL_MAKER_FEE = 0 bps

SUI_USDC = 0xe05dafb5133bcffb8d59f4e12465dc0e9faeaa05e3e342a08fe135800e3e4407
INITIAL_VERSION = 389750322
TICK_SIZE = 1000 = 0.001
LOT_SIZE = 100000000 = 0.1 SUI
MIN_SIZE = 1000000000 = 1 SUI
INITIAL_TAKER_FEE = 10 bps
INITIAL_MAKER_FEE = 5 bps

BWETH_USDC = 0x1109352b9112717bd2a7c3eb9a416fff1ba6951760f5bdd5424cf5e4e5b3e65c
INITIAL_VERSION = 389750322
TICK_SIZE = 10000 = 0.001
LOT_SIZE = 10000 = 0.0001 BETH
MIN_SIZE = 100000 = 0.001 BETH
INITIAL_TAKER_FEE = 10 bps
INITIAL_MAKER_FEE = 5 bps

WUSDC_USDC = 0xa0b9ebefb38c963fd115f52d71fa64501b79d1adcb5270563f92ce0442376545 (Updated)
INITIAL_VERSION = 400279088
TICK_SIZE = 10000 = 0.00001
LOT_SIZE = 100000 = 0.1 WUSDC
MIN_SIZE = 1000000 = 1 WUSDC
INITIAL_TAKER_FEE = 0 bps
INITIAL_MAKER_FEE = 0 bps

WUSDT_USDC = 0x4e2ca3988246e1d50b9bf209abb9c1cbfec65bd95afdacc620a36c67bdb8452f (Updated)
INITIAL_VERSION = 400279088
TICK_SIZE = 10000 = 0.00001
LOT_SIZE = 100000 = 0.1 WUSDT
MIN_SIZE = 1000000 = 1 WUSDT
INITIAL_TAKER_FEE = 1 bps
INITIAL_MAKER_FEE = 0.5 bps

NS_SUI = 0x27c4fdb3b846aa3ae4a65ef5127a309aa3c1f466671471a806d8912a18b253e8
INITIAL_VERSION = 414947421
TICK_SIZE = 10000000 = 0.00001
LOT_SIZE = 100000 = 0.1 NS
MIN_SIZE = 1000000 = 1 NS
INITIAL_TAKER_FEE = 10 bps
INITIAL_MAKER_FEE = 5 bps

NS_USDC = 0x0c0fdd4008740d81a8a7d4281322aee71a1b62c449eb5b142656753d89ebc060
INITIAL_VERSION = 414947421
TICK_SIZE = 10000 = 0.00001
LOT_SIZE = 100000 = 0.1 NS
MIN_SIZE = 1000000 = 1 NS
INITIAL_TAKER_FEE = 10 bps
INITIAL_MAKER_FEE = 5 bps

TYPUS_SUI = 0xe8e56f377ab5a261449b92ac42c8ddaacd5671e9fec2179d7933dd1a91200eec
INITIAL_VERSION = 414947422
TICK_SIZE = 10000 = 0.00001
LOT_SIZE = 100000000 = 0.1 TYPUS
MIN_SIZE = 1000000000 = 1 TYPUS
INITIAL_TAKER_FEE = 10 bps
INITIAL_MAKER_FEE = 5 bps

SUI_AUSD = 0x183df694ebc852a5f90a959f0f563b82ac9691e42357e9a9fe961d71a1b809c8
INITIAL_VERSION = 414947423
TICK_SIZE = 100 = 0.0001
LOT_SIZE = 100000000 = 0.1 SUI
MIN_SIZE = 1000000000 = 1 SUI
INITIAL_TAKER_FEE = 10 bps
INITIAL_MAKER_FEE = 5 bps

AUSD_USDC = 0x5661fc7f88fbeb8cb881150a810758cf13700bb4e1f31274a244581b37c303c3
INITIAL_VERSION = 414947423
TICK_SIZE = 10000 = 0.00001
LOT_SIZE = 100000 = 0.1 AUSD
MIN_SIZE = 1000000 = 1 AUSD
INITIAL_TAKER_FEE = 1 bps
INITIAL_MAKER_FEE = 0.5 bps

DRF_SUI = 0x126865a0197d6ab44bfd15fd052da6db92fd2eb831ff9663451bbfa1219e2af2
INITIAL_VERSION = 414947424
TICK_SIZE = 1000000 = 0.000001
LOT_SIZE = 1000000 = 1 DRF
MIN_SIZE = 10000000 = 10 DRF
INITIAL_TAKER_FEE = 10 bps
INITIAL_MAKER_FEE = 5 bps

SEND_USDC = 0x1fe7b99c28ded39774f37327b509d58e2be7fff94899c06d22b407496a6fa990
INITIAL_VERSION = 414947426
TICK_SIZE = 1000 = 0.000001
LOT_SIZE = 100000 = 0.1 SEND
MIN_SIZE = 1000000 = 1 SEND
INITIAL_TAKER_FEE = 10 bps
INITIAL_MAKER_FEE = 5 bps

WAL_USDC = 0x56a1c985c1f1123181d6b881714793689321ba24301b3585eec427436eb1c76d
INITIAL_VERSION = 414947427
TICK_SIZE = 1 = 0.000001
LOT_SIZE = 100000000 = 0.1 WAL
MIN_SIZE = 1000000000 = 1 WAL
INITIAL_TAKER_FEE = 10 bps
INITIAL_MAKER_FEE = 5 bps

WAL_SUI = 0x81f5339934c83ea19dd6bcc75c52e83509629a5f71d3257428c2ce47cc94d08b
INITIAL_VERSION = 414947427
TICK_SIZE = 1000 = 0.000001
LOT_SIZE = 100000000 = 0.1 WAL
MIN_SIZE = 1000000000 = 1 WAL
INITIAL_TAKER_FEE = 10 bps
INITIAL_MAKER_FEE = 5 bps

XBTC_USDC = 0x20b9a3ec7a02d4f344aa1ebc5774b7b0ccafa9a5d76230662fdc0300bb215307
INITIAL_VERSION = 556438674
TICK_SIZE = 10000000 = 1
LOT_SIZE = 1000 = 0.00001 XBTC
MIN_SIZE = 1000 = 0.00001 XBTC
INITIAL_TAKER_FEE = 10 bps
INITIAL_MAKER_FEE = 5 bps

IKA_USDC = 0xfa732993af2b60d04d7049511f801e79426b2b6a5103e22769c0cead982b0f47
INITIAL_VERSION = 589011838
TICK_SIZE = 1 = 0.000001
LOT_SIZE = 10000000000 = 10 IKA
MIN_SIZE = 10000000000 = 10 IKA
INITIAL_TAKER_FEE = 10 bps
INITIAL_MAKER_FEE = 5 bps

Whitepaper
Repository 
Documentation
Typescript SDK - published, latest version seen here https://www.npmjs.com/package/@mysten/deepbook-v3 
Typescript SDK Docs
Mainnet RPC URL - https://fullnode.mainnet.sui.io:443
