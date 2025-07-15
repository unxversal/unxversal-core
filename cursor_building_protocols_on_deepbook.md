# Building protocols on DeepBook
_Exported on 7/15/2025 at 09:42:45 PDT from Cursor (1.2.4)_

---

**User**

DeepBook Design
At a high level, the DeepBook design follows the following flow, which revolves around three shared objects:

Pool: A shared object that represents one market and is responsible for managing its order book, users, stakes, and so on. See the Pool shared object section to learn more.
PoolRegistry: Used only during pool creation, it makes sure that duplicate pools are not created and maintains package versioning.
BalanceManager: Used to source a user's funds when placing orders. A single BalanceManager can be used between all pools. See BalanceManager to learn more.
1

Pool shared object
All public facing functions take in the Pool shared object as a mutable or immutable reference. Pool is made up of three distinct components:

Book
State
Vault
Logic is isolated between components and each component builds on top of the previous one. By maintaining a book, then state, then vault relationship, DeepBook can provide data availability guarantees, improve code readability, and help make maintaining and upgrading the protocol easier.

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

DeepBook Governance Timeline

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
Every transaction that a user performs on DeepBook resets their settled and owed balances. The vault then processes these balances for the user, deducting or adding to funds to their BalanceManager.

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

To match an OrderInfo against the book, the list of Orders is iterated in the opposite side of the book. If there is an overlap in price and the existing maker order has not expired, then DeepBook matches their quantities and generates a Fill. DeepBook appends that fill to the OrderInfo fills, to use later in state. DeepBook updates the existing maker order quantities and status during each match, and removes them from the book if they are completely filled or expired.

Finally, if the OrderInfo object has any remaining quantity, DeepBook converts it into a compact Order object and injects it into the order book. Order has the minimum amount of data necessary for matching, while OrderInfo has the maximum amount of data for general processing.

Regardless of direction or order type, all DeepBook matching is processed in a single function.

State
The process_create function in State handles the processing of an order creation event within the pool's state: calculating the transaction amounts and fees for the order, and updating the account volumes accordingly.

First, the function processes the list of fills from the OrderInfo object, updating volumes tracked and settling funds for the makers involved. Next, the function retrieves the account's total trading volume and active stake. It calculates the taker's fee based on the user's account stake and volume in DEEP tokens, while the maker fee is retrieved from the governance trade parameters. To receive discounted taker fees, the account must have more than the minimum stake for the pool, and the trading volume in DEEP tokens must exceed the same threshold. If any quantity remains in the OrderInfo object, it is added to the account's list of orders as an Order and is already created in Book.

Finally, the function calculates the partial taker fills and maker order quantities, if there are any, with consideration for the taker and maker fees. It adds these to the previously settled and owed balances from the account. Trade history is updated with the total fees collected from the order and two tuples are returned to Pool, settled and owed balances, in (base, quote, DEEP) format, ensuring the correct assets are transferred in Vault.

Vault
The settle_balance_manager function in Vault is responsible for managing the transfer of any settled and owed amounts for the BalanceManager.

First, the function validates that a trader is authorized to use the BalanceManager.

Then, for each asset type the process compares balances_out against balances_in. If the balances_out total exceeds balances_in, the function splits the difference from the vault's balance and deposits it into the BalanceManager. Conversely, if the balances_in total exceeds balances_out, the function withdraws the difference from the BalanceManager and joins it to the vault's balance.

This process is repeated for base, quote, and DEEP asset balances, ensuring all asset balances are accurately reflected and settled between the vault and the BalanceManager.


BalanceManager
The BalanceManager shared object holds all balances for different assets. To perform trades, pass a combination of BalanceManager and TradeProof into a pool. TradeProofs are generated in one of two ways, either by the BalanceManager owner directly, or by any TradeCap owner. The owner can generate a TradeProof without the risk of equivocation. The TradeCap owner, because it's an owned object, risks equivocation when generating a TradeProof. Generally, a high frequency trading engine trades as the default owner.

With exception to swaps, all interactions with DeepBook require a BalanceManager as one of its inputs. When orders are matched, funds are transferred to or from the BalanceManager. You can use a single BalanceManager between all pools.

API
Following are the different public functions that the BalanceManager exposes.

Create a BalanceManager
The new() function creates a BalanceManager hot potato (a struct with no abilities). Combine it with share, or else the transaction fails. You can combine the transaction with deposit calls, allowing you to create, deposit, then share the balance manager in one transaction.

MystenLabs/deepbookv3/packages/deepbook/sources/balance_manager.move
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

MystenLabs/deepbookv3/packages/deepbook/sources/balance_manager.move
#[deprecated(note = b"This function is deprecated, use `new_with_custom_owner` instead.")]
public fun new_with_owner(_ctx: &mut TxContext, _owner: address): BalanceManager {
    abort 1337
}

Mint a TradeCap
The owner of a BalanceManager can mint a TradeCap and send it to another address. Upon receipt, that address will have the capability to place orders with this BalanceManager. The address owner cannot deposit or withdraw funds, however. The maximum total number of TradeCap, WithdrawCap, and DepositCap that can be assigned for a BalanceManager is 1000. If this limit is reached, one or more existing caps must be revoked before minting new ones. You can also use revoke_trade_cap to revoke DepositCap and WithdrawCap.

MystenLabs/deepbookv3/packages/deepbook/sources/balance_manager.move
/// Mint a `TradeCap`, only owner can mint a `TradeCap`.
public fun mint_trade_cap(balance_manager: &mut BalanceManager, ctx: &mut TxContext): TradeCap {
    balance_manager.validate_owner(ctx);
    assert!(balance_manager.allow_listed.size() < MAX_TRADE_CAPS, EMaxCapsReached);

    let id = object::new(ctx);
    balance_manager.allow_listed.insert(id.to_inner());

    TradeCap {
        id,
        balance_manager_id: object::id(balance_manager),
    }
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

MystenLabs/deepbookv3/packages/deepbook/sources/balance_manager.move
/// Mint a `DepositCap`, only owner can mint.
public fun mint_deposit_cap(balance_manager: &mut BalanceManager, ctx: &mut TxContext): DepositCap {
    balance_manager.validate_owner(ctx);
    assert!(balance_manager.allow_listed.size() < MAX_TRADE_CAPS, EMaxCapsReached);

    let id = object::new(ctx);
    balance_manager.allow_listed.insert(id.to_inner());

    DepositCap {
        id,
        balance_manager_id: object::id(balance_manager),
    }
}

/// Mint a `WithdrawCap`, only owner can mint.
public fun mint_withdraw_cap(
    balance_manager: &mut BalanceManager,
    ctx: &mut TxContext,
): WithdrawCap {
    balance_manager.validate_owner(ctx);
    assert!(balance_manager.allow_listed.size() < MAX_TRADE_CAPS, EMaxCapsReached);

    let id = object::new(ctx);
    balance_manager.allow_listed.insert(id.to_inner());

    WithdrawCap {
        id,
        balance_manager_id: object::id(balance_manager),
    }
}

Generate a TradeProof
To call any function that requires a balance check or transfer, the user must provide their BalanceManager as well as a TradeProof. There are two ways to generate a trade proof, one used by the owner and another used by a TradeCap owner.

MystenLabs/deepbookv3/packages/deepbook/sources/balance_manager.move
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

MystenLabs/deepbookv3/packages/deepbook/sources/balance_manager.move
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

MystenLabs/deepbookv3/packages/deepbook/sources/balance_manager.move
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

MystenLabs/deepbookv3/packages/deepbook/sources/balance_manager.move
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

MystenLabs/deepbookv3/packages/deepbook/sources/balance_manager.move
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
MystenLabs/deepbookv3/packages/deepbook/sources/balance_manager.move
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

Permissionless Pool Creation
The Pool shared object represents a market, such as a SUI/USDC market. That Pool is the only one representing that unique pairing (SUI/USDC) and the pairing is the only member of that particular Pool. See DeepBook Design to learn more about the structure of pools.

API
Create a Pool
The create_permissionless_pool() function creates a Pool

MystenLabs/deepbookv3/packages/deepbook/sources/pool.move
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

MystenLabs/deepbookv3/packages/deepbook/sources/pool.move
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

MystenLabs/deepbookv3/packages/deepbook/sources/pool.move
public fun update_allowed_versions<BaseAsset, QuoteAsset>(
    self: &mut Pool<BaseAsset, QuoteAsset>,
    registry: &Registry,
    _cap: &DeepbookAdminCap,
) {
    let allowed_versions = registry.allowed_versions();
    let inner: &mut PoolInner<BaseAsset, QuoteAsset> = self.inner.load_value_mut();
    inner.allowed_versions = allowed_versions;
}

Query the Pool
The Pool shared object represents a market, such as a SUI/USDC market. That Pool is the only one representing that unique pairing (SUI/USDC) and the pairing is the only member of that particular Pool. See DeepBook Design to learn more about the structure of pools.

To perform trades, you pass a BalanceManager and TradeProof into the relevant Pool. Unlike Pools, BalanceManager shared objects can contain any type of token, such that the same BalanceManager can access multiple Pools to interact with many different trade pairings. See BalanceManager to learn more.

API
DeepBook exposes a set of endpoints that can be used to query any pool.

Check whitelist status
Accessor to check whether the pool is whitelisted.

MystenLabs/deepbookv3/packages/deepbook/sources/pool.move
public fun whitelisted<BaseAsset, QuoteAsset>(self: &Pool<BaseAsset, QuoteAsset>): bool {
    self.load_inner().state.governance().whitelisted()
}

Check quote quantity against base (DEEP fees)
Dry run to determine the quote quantity out for a given base quantity. Uses DEEP as fee.

MystenLabs/deepbookv3/packages/deepbook/sources/pool.move
public fun get_quote_quantity_out<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
    base_quantity: u64,
    clock: &Clock,
): (u64, u64, u64) {
    self.get_quantity_out(base_quantity, 0, clock)
}

Check base quantity against quote (DEEP fees)
Dry run to determine the base quantity out for a given quote quantity. Uses DEEP as fee.

MystenLabs/deepbookv3/packages/deepbook/sources/pool.move
public fun get_base_quantity_out<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
    quote_quantity: u64,
    clock: &Clock,
): (u64, u64, u64) {
    self.get_quantity_out(0, quote_quantity, clock)
}

Check quote quantity against base (input token fees)
Dry run to determine the quote quantity out for a given base quantity. Uses input token as fee.

MystenLabs/deepbookv3/packages/deepbook/sources/pool.move
public fun get_quote_quantity_out_input_fee<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
    base_quantity: u64,
    clock: &Clock,
): (u64, u64, u64) {
    self.get_quantity_out_input_fee(base_quantity, 0, clock)
}

Check base quantity against quote (input token fees)
Dry run to determine the base quantity out for a given quote quantity. Uses input token as fee.

MystenLabs/deepbookv3/packages/deepbook/sources/pool.move
public fun get_base_quantity_out_input_fee<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
    quote_quantity: u64,
    clock: &Clock,
): (u64, u64, u64) {
    self.get_quantity_out_input_fee(0, quote_quantity, clock)
}

Check quote quantity against quote or base
Dry run to determine the quantity out for a given base or quote quantity. Only one out of base or quote quantity should be non-zero. Returns the (base_quantity_out, quote_quantity_out, deep_quantity_required).

MystenLabs/deepbookv3/packages/deepbook/sources/pool.move
public fun get_quantity_out<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
    base_quantity: u64,
    quote_quantity: u64,
    clock: &Clock,
): (u64, u64, u64) {
    let whitelist = self.whitelisted();
    let self = self.load_inner();
    let params = self.state.governance().trade_params();
    let (taker_fee, _) = (params.taker_fee(), params.maker_fee());
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

MystenLabs/deepbookv3/packages/deepbook/sources/pool.move
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

MystenLabs/deepbookv3/packages/deepbook/sources/pool.move
public fun mid_price<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
    clock: &Clock,
): u64 {
    self.load_inner().book.mid_price(clock.timestamp_ms())
}

Retrieve order IDs
Returns the order_id for all open orders for the balance_manager in the pool.

MystenLabs/deepbookv3/packages/deepbook/sources/pool.move
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

MystenLabs/deepbookv3/packages/deepbook/sources/pool.move
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

MystenLabs/deepbookv3/packages/deepbook/sources/pool.move
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

MystenLabs/deepbookv3/packages/deepbook/sources/pool.move
public fun vault_balances<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
): (u64, u64, u64) {
    self.load_inner().vault.balances()
}

Retrieve pool ID
Get the ID of the pool given the asset types.

MystenLabs/deepbookv3/packages/deepbook/sources/pool.move
public fun get_pool_id_by_asset<BaseAsset, QuoteAsset>(registry: &Registry): ID {
    registry.get_pool_id<BaseAsset, QuoteAsset>()
}

Retrieve order information
Returns the Order struct using the order ID.

MystenLabs/deepbookv3/packages/deepbook/sources/pool.move
public fun get_order<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
    order_id: u128,
): Order {
    self.load_inner().book.get_order(order_id)
}

Returns a vector of Order structs using a vector of order IDs.

MystenLabs/deepbookv3/packages/deepbook/sources/pool.move
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

MystenLabs/deepbookv3/packages/deepbook/sources/pool.move
public fun get_account_order_details<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
    balance_manager: &BalanceManager,
): vector<Order> {
    let acct_open_orders = self.account_open_orders(balance_manager).into_keys();

    self.get_orders(acct_open_orders)
}

Retrieve locked balance
Returns the locked balance for a BalanceManager in the pool (base_quantity, quote_quantity, deep_quantity).

MystenLabs/deepbookv3/packages/deepbook/sources/pool.move
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

MystenLabs/deepbookv3/packages/deepbook/sources/pool.move
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

MystenLabs/deepbookv3/packages/deepbook/sources/pool.move
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

MystenLabs/deepbookv3/packages/deepbook/sources/pool.move
public fun quorum<BaseAsset, QuoteAsset>(self: &Pool<BaseAsset, QuoteAsset>): u64 {
    self.load_inner().state.governance().quorum()
}

Returns the book parameters for the pool (tick_size, lot_size, min_size).

MystenLabs/deepbookv3/packages/deepbook/sources/pool.move
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

MystenLabs/deepbookv3/packages/deepbook/sources/pool.move
public fun get_order_deep_price<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
): OrderDeepPrice {
    let whitelist = self.whitelisted();
    let self = self.load_inner();

    self.deep_price.get_order_deep_price(whitelist)
}

DeepBook Orders
Users can create limit or market orders, modify orders, and cancel orders. The BalanceManager must have the necessary funds to process orders. DeepBook has four order options and three self matching options. If you set the pay_with_deep flag to true, trading fees are paid with the DEEP token. If you set the pay_with_deep flag to false, trading fees are paid with the input token.

Users can modify their existing order, reducing the size, lowering the expiration time, or both. Users cannot modify their order to increase their size or increase their expiration time. To do that, they must cancel the original order and place a new order.

Users can cancel a single order or cancel all of their orders.

API
Following are the order related endpoints that Pool exposes.

Order options
The following constants define the options available for orders.

MystenLabs/deepbookv3/packages/deepbook/sources/helper/constants.move
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

MystenLabs/deepbookv3/packages/deepbook/sources/helper/constants.move
// Self matching types.
// Self matching is allowed.
const SELF_MATCHING_ALLOWED: u8 = 0;
// Cancel the taker order.
const CANCEL_TAKER: u8 = 1;
// Cancel the maker order.
const CANCEL_MAKER: u8 = 2;

OrderInfo struct
Placing a limit order or a market order creates and returns an OrderInfo object. DeepBook automatically drops this object after the order completes or is placed in the book. Use OrderInfo to inspect the execution details of the request as it represents all order information. DeepBook does not catch any errors, so if there’s a failure of any kind, then the entire transaction fails.

MystenLabs/deepbookv3/packages/deepbook/sources/book/order_info.move
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

MystenLabs/deepbookv3/packages/deepbook/sources/vault/deep_price.move
public struct OrderDeepPrice has copy, drop, store {
    asset_is_base: bool,
    deep_per_asset: u64,
}

Fill struct
The Fill struct represents the results of a match between two orders. Use this struct to update the state.

MystenLabs/deepbookv3/packages/deepbook/sources/book/fill.move
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
DeepBook emits OrderFilled when a maker order is filled.

MystenLabs/deepbookv3/packages/deepbook/sources/book/order_info.move
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

DeepBook emits OrderCanceled when a maker order is canceled.

MystenLabs/deepbookv3/packages/deepbook/sources/book/order.move
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

DeepBook emits OrderModified on modification of a maker order.

MystenLabs/deepbookv3/packages/deepbook/sources/book/order.move
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

DeepBook emits OrderPlaced when it injects a maker order into the order book.

MystenLabs/deepbookv3/packages/deepbook/sources/book/order_info.move
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

MystenLabs/deepbookv3/packages/deepbook/sources/pool.move
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
Place a market order. Quantity is in base asset terms. Calls place_limit_order with a price of MAX_PRICE for bids and MIN_PRICE for asks. DeepBook cancels the order for any quantity not filled.

MystenLabs/deepbookv3/packages/deepbook/sources/pool.move
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

MystenLabs/deepbookv3/packages/deepbook/sources/pool.move
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

Similar to modify, cancel_order does not return anything. DeepBook emits OrderCanceled event.

MystenLabs/deepbookv3/packages/deepbook/sources/pool.move
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

MystenLabs/deepbookv3/packages/deepbook/sources/pool.move
public fun withdraw_settled_amounts<BaseAsset, QuoteAsset>(
    self: &mut Pool<BaseAsset, QuoteAsset>,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
) {
    let self = self.load_inner_mut();
    let (settled, owed) = self.state.withdraw_settled_amounts(balance_manager.id());
    self.vault.settle_balance_manager(settled, owed, balance_manager, trade_proof);
}

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

MystenLabs/deepbookv3/packages/deepbook/sources/pool.move
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

MystenLabs/deepbookv3/packages/deepbook/sources/pool.move
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

MystenLabs/deepbookv3/packages/deepbook/sources/pool.move
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


Flash Loans
Flash loans by definition are uncollaterized loans that are borrowed and repaid within the same programmable transaction block. Users can borrow flash loans in the base or quote asset from any DeepBook pool. Flash loans return a FlashLoan hot potato (struct with no abilities), which must be returned back to the pool by the end of the call. The transaction is atomic, so the entire transaction fails if the loan is not returned.

The quantity borrowed can be the maximum amount that the pool owns. Borrowing from a pool and trading in the same pool can result in failures because trading requires the movement of funds. If the funds are borrowed, then there are no funds to move.

API
Following are the endpoints that the Pool exposes for flash loans.

Borrow flash loan base
Borrow base assets from the Pool. The function returns a hot potato, forcing the borrower to return the assets within the same transaction.

MystenLabs/deepbookv3/packages/deepbook/sources/pool.move
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

MystenLabs/deepbookv3/packages/deepbook/sources/pool.move
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

MystenLabs/deepbookv3/packages/deepbook/sources/pool.move
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

MystenLabs/deepbookv3/packages/deepbook/sources/pool.move
public fun return_flashloan_quote<BaseAsset, QuoteAsset>(
    self: &mut Pool<BaseAsset, QuoteAsset>,
    coin: Coin<QuoteAsset>,
    flash_loan: FlashLoan,
) {
    let self = self.load_inner_mut();
    self.vault.return_flashloan_quote(self.pool_id, coin, flash_loan);
}


DeepBookV3 Indexer
DeepBook Indexer provides streamlined, real-time access to order book and trading data from the DeepBook protocol. It acts as a centralized service to aggregate and expose critical data points for developers, traders, and analysts who interact with DeepBook.

DeepBook Indexer simplifies data retrieval by offering endpoints that enable:

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
Public DeepBook Indexer
Mysten Labs provides a public indexer for DeepBook. You can access this indexer at the following URL:

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
You can perform the following tasks using the endpoints that the indexer API for DeepBook provides.

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

Returns a summary in JSON for all trading pairs in DeepBook.

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

Returns asset information for all coins being traded on DeepBook.

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


I want to build a few protocols on top of deepbook, docs above.

a dex protocol for swaps
an options protocol
a perpetuals protocol
a dated futures protocol
a gas futures protocol


please give me a more concise and digestible explanation of how deepbook works, how I can build these protocools on deepbook, including how flash loans and the indexer comes into play. Also, I want my own protocol token, UNXV, which will be used across all tokens as the gas token.
also note that I am making a synthetics protocol so I will alsoneed to add a permissionless listing support to the protocols too. 


How to Use Real-Time Data in Sui Contracts
This guide explains how to use real-time Pyth data in Sui applications.

Install Pyth SDK
Use the following dependency in your Move.toml file to use the latest Pyth Sui package and its dependencies:

[dependencies.Pyth]
git = "https://github.com/pyth-network/pyth-crosschain.git"
subdir = "target_chains/sui/contracts"
rev = "sui-contract-mainnet"
 
[dependencies.Wormhole]
git = "https://github.com/wormhole-foundation/wormhole.git"
subdir = "sui/wormhole"
rev = "sui/mainnet"
 
# Pyth is locked into this specific `rev` because the package depends on Wormhole and is pinned to this version.
 
[dependencies.Sui]
git = "https://github.com/MystenLabs/sui.git"
subdir = "crates/sui-framework/packages/sui-framework"
rev = "041c5f2bae2fe52079e44b70514333532d69f4e6"
 

Pyth also provides a javascript SDK to construct transaction blocks that update price feeds:

# NPM
npm install --save @pythnetwork/pyth-sui-js
 
# Yarn
yarn add @pythnetwork/pyth-sui-js
Write Contract Code
The code snippet below provides a general template for what your contract code should look like:

/// Module: oracle
module oracle::oracle;
 
use sui::clock::Clock;
use pyth::price_info;
use pyth::price_identifier;
use pyth::price;
use pyth::i64::I64;
use pyth::pyth;
use pyth::price_info::PriceInfoObject;
 
const E_INVALID_ID: u64 = 1;
 
public fun get_sui_price(
    // Other arguments
    clock: &Clock,
    price_info_object: &PriceInfoObject,
): I64 {
    let max_age = 60;
 
    // Make sure the price is not older than max_age seconds
    let price_struct = pyth::get_price_no_older_than(price_info_object, clock, max_age);
 
    // Check the price feed ID
    let price_info = price_info::get_price_info_from_price_info_object(price_info_object);
    let price_id = price_identifier::get_bytes(&price_info::get_price_identifier(&price_info));
 
    // SUI/USD price feed ID
    // The complete list of feed IDs is available at https://pyth.network/developers/price-feed-ids
    // Note: Sui uses the Pyth price feed ID without the `0x` prefix.
    let testnet_sui_price_id = x"50c67b3fd225db8912a424dd4baed60ffdde625ed2feaaf283724f9608fea266";
    assert!(price_id == testnet_sui_price_id, E_INVALID_ID);
 
    // Extract the price, decimal, and timestamp from the price struct and use them.
    let _decimal_i64 = price::get_expo(&price_struct);
    let price_i64 = price::get_price(&price_struct);
    let _timestamp_sec = price::get_timestamp(&price_struct);
 
    price_i64
}

One can consume the price by calling pyth::get_price abovementioned or other utility functions on the PriceInfoObject in the Move module

The code snippet below provides an example of how to update the Pyth price feeds:

import {
  SuiPythClient,
  SuiPriceServiceConnection,
} from "@pythnetwork/pyth-sui-js";
import { SuiClient } from "@mysten/sui/client";
import { Transaction } from "@mysten/sui/transactions";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
 
/// Step 1: Get the off-chain data.
const connection = new SuiPriceServiceConnection(
  "https://hermes-beta.pyth.network", // [!] Only for Sui Testnet
  // "https://hermes.pyth.network/", // Use this for Mainnet
  {
    // Provide this option to retrieve signed price updates for on-chain contracts!
    priceFeedRequestConfig: {
      binary: true,
    },
  }
);
const priceIDs = [
  // You can find the IDs of prices at:
  // - https://pyth.network/developers/price-feed-ids for Mainnet
  // - https://www.pyth.network/developers/price-feed-ids#beta for Testnet
  "0x50c67b3fd225db8912a424dd4baed60ffdde625ed2feaaf283724f9608fea266", // SUI/USD price ID
];
const priceUpdateData = await connection.getPriceFeedsUpdateData(priceIDs);
 
/// Step 2: Submit the new price on-chain and verify it using the contract.
const suiClient = new SuiClient({ url: "https://fullnode.testnet.sui.io:443" });
 
// Fixed the StateIds using the CLI example extracting them from
// here: https://docs.pyth.network/price-feeds/contract-addresses/sui
const pythTestnetStateId =
  "0x243759059f4c3111179da5878c12f68d612c21a8d54d85edc86164bb18be1c7c"; // Testnet
const wormholeTestnetStateId =
  "0x31358d198147da50db32eda2562951d53973a0c0ad5ed738e9b17d88b213d790"; // Testnet
 
const pythClient = new SuiPythClient(
  suiClient,
  pythTestnetStateId,
  wormholeTestnetStateId
);
 
const transaction = new Transaction();
 
/// By calling the updatePriceFeeds function, the SuiPythClient adds the necessary
/// transactions to the transaction block to update the price feeds.
const priceInfoObjectIds = await pythClient.updatePriceFeeds(
  transaction,
  priceUpdateData,
  priceIDs
);
 
let suiPriceObjectId = priceInfoObjectIds[0];
if (!suiPriceObjectId) {
  throw new Error("suiPriceObjectId is undefined");
}
 
/// This is the package id that we receive after publishing `oracle` contract from the previous step.
let testnetExampleContractPackageId =
  "0x42d05111a160febe4144338647e0b7a80daea459c765c1e29a7a6198b235f67c";
const CLOCK =
  "0x0000000000000000000000000000000000000000000000000000000000000006";
transaction.moveCall({
  target: `${testnetExampleContractPackageId}::oracle::get_sui_price`,
  arguments: [transaction.object(CLOCK), transaction.object(suiPriceObjectId)],
});
transaction.setGasBudget(1000000000);
 
const keypair = Ed25519Keypair.fromSecretKey(
  process.env.ADMIN_SECRET_KEY!.toLowerCase()
);
const result = await suiClient.signAndExecuteTransaction({
  transaction,
  signer: keypair,
  options: {
    showEffects: true,
    showEvents: true,
  },
});

By calling the updatePriceFeeds function, the SuiPythClient adds the necessary transactions to the transaction block to update the price feeds.

Your Sui Move module should NOT have a hard-coded call to pyth::update_single_price_feed. In other words, a contract should never call the Sui Pyth pyth::update_single_price_feed entry point. Instead, it should be called directly from client code (e.g., Typescript or Rust).

When Sui contracts are upgraded, the address changes, which makes the old address no longer valid. If your module has a hard-coded call to pyth::update_single_price_feed living at a fixed call-site, it may eventually get bricked due to how Pyth upgrades are implemented. (Pyth only allow users to interact with the most recent package version for security reasons).

Therefore, you should build a Sui programmable transaction that first updates the price by calling pyth::update_single_price_feed at the latest call-site from the client-side and then call a function in your contract that invokes pyth::get_price on the PriceInfoObject to get the recently updated price. You can use SuiPythClient to build such transactions and handle all the complexity of updating the price feeds.

Consult Fetch Price Updates for more information on how to fetch the pyth_price_update.

Coin Standard
The Coin standard is the technical standard used for smart contracts on Sui for creating coins on the Sui blockchain. The standardization of coin creation on Sui means that wallets, exchanges, and other smart contracts can manage coins created on Sui the same as they manage SUI, without any additional processing logic.

See Sui Tokenomics to learn more about the SUI native coin and its use on the Sui network.

Although coins on Sui follow the Coin standard, they can offer specialized abilities. For example, you can create a regulated token that allows its creator to add specific addresses to a deny list, so that the identified addresses cannot use the token as inputs to transactions.

See the coin module documentation for all available options when creating a coin-type token on Sui.

Fungible tokens
In the Sui blockchain ecosystem, the Coin<T> type represents open-loop fungible tokens (see Token<T> for closed-loop tokens). Coins are denominated by their type parameter, T, which is also associated with metadata (like name, symbol, decimal precision, and so on) that applies to all instances of Coin<T>. The sui::coin module exposes an interface over Coin<T> that treats it as fungible, meaning that a unit of T held in one instance of Coin<T> is interchangeable with any other unit of T, much like how traditional fiat currencies operate.

info
The documentation refers to fungible tokens created on Sui using the Coin standard as "coins". For fungible tokens created on Sui using the Closed-Loop Token standard, the documentation uses the term "tokens". In practice, the terms for both these objects are often interchangeable.

Treasury capability
When you create a coin using the coin::create_currency function, the publisher of the smart contract that creates the coin receives a TreasuryCap object. The TreasuryCap object is required to mint new coins or to burn current ones. Consequently, only addresses that have access to this object are able to maintain the coin supply on the Sui network.

The TreasuryCap object is transferable, so a third party can take over the management of a coin that you create if you transfer the TreasuryCap. After transferring the capability, however, you are no longer able to mint and burn tokens yourself.

Regulated coins
The Coin standard includes the ability to create regulated coins. To create a regulated coin, you use the coin::create_regulated_currency_v2 function (which uses the coin::create_currency function itself), but which also returns a DenyCap capability. The DenyCap capability allows the bearer to maintain a list of addresses that aren't allowed to use the token.

tip
The regulated-coin-sample repository provides an example of regulated coin creation.

DenyList object
The list of addresses that aren't able to use a particular regulated coin is held within a system-created DenyList shared object. If you have access to the DenyCap, then you can use the coin::deny_list_v2_add and coin::deny_list_v2_remove functions to add and remove addresses.

Global pause switch
Regulated coin objects include an allow_global_pause Boolean field. When set to true, the bearer of the DenyCapV2 object for the coin type can use the coin::deny_list_v2_enable_global_pause function to pause coin activity indefinitely. Immediately upon the bearer initiating the pause, the network disallows the coin type as input for any transactions. At the start of the next epoch (epochs last ~24 hours), the network additionally disallows all addresses from receiving the coin type.

When the bearer of the DenyCapV2 object for the coin type removes the pause using coin::deny_list_v2_disable_global_pause, the coins are immediately available to use again as transaction inputs. Addresses cannot receive the coin type, however, until the following epoch.

The global pause functionality does not affect the deny list for the coin. After clearing the pause for the coin, any addresses included in the deny list are still unable to interact with the coin.

Coin metadata
Each coin you create includes metadata that describes it. Typically, smart contracts freeze this object upon creation using the transfer::public_freeze_object function because the metadata for coins should almost never change. Regulated coins freeze the metadata they create automatically.

Regular coins using the Coin standard include a CoinMetadata object. As mentioned previously, regulated coins build on top of the same procedure that creates regular coins, so they receive the same metadata object in addition to a RegulatedCoinMetadata object that includes deny list information.

The fields of the metadata objects include the following:

CoinMetadata
Name	Description
id	The object ID of the metadata for the token.
decimals	The number of decimals the token uses. If you set this field to 3, then a token of value 1000 would display as 1.000.
name	Name of the coin.
symbol	Symbol for the coin. This might be the same as name, but is typically fewer than five all capital letters. For example, SUI is the symbol for the native coin on Sui but its name is also SUI.
description	A short description to describe the token.
icon_url	The URL for the token's icon, used for display in wallets, explorers, and other apps.
RegulatedCoinMetadata
Name	Description
id	The ID of the metadata object for the regulated token.
coin_metadata_object	The ID of the underlying metadata object (CoinMetadata) for the regulated token.
deny_cap_object	The ID of the token's DenyCapV2 object, which is necessary to maintain the deny list entries that controls who can and cannot use the token.
Minting and burning coins
The coin module provides the logic for creating and destroying coins on the Sui network (as long as you own the associated TreasuryCap). These functions are the same for all coins and each requires the TreasuryCap as an input.

Mint
Use the coin::mint function to create new tokens.

crates/sui-framework/packages/sui-framework/sources/coin.move
public fun mint<T>(cap: &mut TreasuryCap<T>, value: u64, ctx: &mut TxContext): Coin<T> {
    Coin {
        id: object::new(ctx),
        balance: cap.total_supply.increase_supply(value),
    }
}

The signature shows that a Coin<T> results from calling the function with a TreasuryCap, value for the coin created, and the transaction context. The function updates the total supply in TreasuryCap automatically. Upon display, the coin value respects the decimals value in the metadata. So, if you supply 1000000 as the coin value that has a decimal value of 6, the coin's value displays as 1.000000.

Burn
Use the coin::burn function to destroy current tokens.

crates/sui-framework/packages/sui-framework/sources/coin.move
public entry fun burn<T>(cap: &mut TreasuryCap<T>, c: Coin<T>): u64 {
    let Coin { id, balance } = c;
    id.delete();
    cap.total_supply.decrease_supply(balance)
}

The signature shows that only the TreasuryCap and coin object you want to burn are necessary inputs, returning the amount by which the supply was decreased (value of the coin). The function does not allow you to burn more coins than are available in the supply.

Adding and removing addresses to and from the deny list
The deny list is only applicable to regulated coins. As mentioned previously, when you create a regulated coin you receive a DenyCapV2 that authorizes the bearer to add and remove addresses from the system-created DenyList object. Any address on the list for your coin is unable to use the coin as an input to transactions starting immediately upon being added. At the epoch that follows address addition to the deny list, the addresses additionally cannot receive the coin type. In other words, an address that gets added to the deny list for a coin type is immediately unable to send the coin. At the start of the following epoch, the address is still unable to send the coin but is also unable to receive it. From that point, the address cannot interact with the coin until expressly removed from the deny list by the DenyCapV2 bearer.

Add address to deny list
Use the coin::deny_list_v2_add function to add the provided address to the deny list for your coin. The signature for the function is:

crates/sui-framework/packages/sui-framework/sources/coin.move
public fun deny_list_v2_add<T>(
    deny_list: &mut DenyList,
    _deny_cap: &mut DenyCapV2<T>,
    addr: address,
    ctx: &mut TxContext,
) {
    let ty = type_name::get_with_original_ids<T>().into_string().into_bytes();
    deny_list.v2_add(DENY_LIST_COIN_INDEX, ty, addr, ctx)
}

When using this function, you provide the DenyList object (0x403), the DenyCap you receive on coin creation, the address to add to the list, and the transaction context. After using this function, the address you provide is unable to use your coin by the next epoch.

Remove address from deny list
Use the coin::deny_list_v2_remove function to remove addresses from the deny list for your coin.

crates/sui-framework/packages/sui-framework/sources/coin.move
public fun deny_list_v2_remove<T>(
    deny_list: &mut DenyList,
    _deny_cap: &mut DenyCapV2<T>,
    addr: address,
    ctx: &mut TxContext,
) {
    let ty = type_name::get_with_original_ids<T>().into_string().into_bytes();
    deny_list.v2_remove(DENY_LIST_COIN_INDEX, ty, addr, ctx)
}

When using this function, you provide the DenyList object (0x403), the DenyCapV2 you receive on coin creation, the address to remove from the list, and the transaction context. If you try to remove an address that isn't on the list, you receive an ENotFrozen error and the function aborts. After calling this function, the address you provide is able to use your coin by the next epoch.

Using an SDK
You can use either the TypeScript or Rust SDK to manipulate the addresses held in the DenyList for your coin. The following examples are based on the regulated coin sample.

TypeScript
Rust
const tx = new Transaction();

tx.moveCall({
    target: `0x2::coin::deny_list_v2_add`,
    arguments: [
        tx.object(<SUI-DENY-LIST-OBJECT-ID>),
        tx.object(<DENY-CAP-ID>),
        tx.pure.address(options.address),
    ],
    typeArguments: [<COIN-TYPE>],
});

<SUI-DENY-LIST-OBJECT-ID> is "0x403"
<DENY-CAP-ID> is the object of type DenyCapV2<REGULATED_COIN> you receive from publishing the contract
options.address is the address to ban
<COIN-TYPE> is ${PACKAGE-ID}::${MODULE-NAME}::${COIN-NAME}, which is ${PACKAGE-ID}::regulated_coin::REGULATED_COIN based on the example.
Globally pausing and unpausing regulated coin activity
Globally pausing coin activity is only applicable to regulated coin types.

Pause coin activity
To pause activity across the network for a regulated coin type with the allow_global_pause field set to true, use coin::deny_list_v2_enable_global_pause. You must provide the DenyCapV2 object for the coin type to initiate the pause. Transaction activity is paused immediately, and no addresses can receive the coin in the epoch that follows the call to pause.

crates/sui-framework/packages/sui-framework/sources/coin.move
#[allow(unused_mut_parameter)]
public fun deny_list_v2_enable_global_pause<T>(
    deny_list: &mut DenyList,
    deny_cap: &mut DenyCapV2<T>,
    ctx: &mut TxContext,
) {
    assert!(deny_cap.allow_global_pause, EGlobalPauseNotAllowed);
    let ty = type_name::get_with_original_ids<T>().into_string().into_bytes();
    deny_list.v2_enable_global_pause(DENY_LIST_COIN_INDEX, ty, ctx)
}

Unpause coin activity
To restart network activity for a paused regulated coin, use the coin::deny_list_v2_disable_global_pause function. As with pausing, you must provide the DenyCapV2 object for the coin type. Transaction activity resumes immediately, and addresses can begin receiving the coin in the epoch that follows the call to remove the pause.

crates/sui-framework/packages/sui-framework/sources/coin.move
#[allow(unused_mut_parameter)]
public fun deny_list_v2_disable_global_pause<T>(
    deny_list: &mut DenyList,
    deny_cap: &mut DenyCapV2<T>,
    ctx: &mut TxContext,
) {
    assert!(deny_cap.allow_global_pause, EGlobalPauseNotAllowed);
    let ty = type_name::get_with_original_ids<T>().into_string().into_bytes();
    deny_list.v2_disable_global_pause(DENY_LIST_COIN_INDEX, ty, ctx)
}

Query coin data
You can use the following functions to retrieve data from coins.

Metadata
Use the following functions to get the values for the respective fields on the metadata object for coins.

Function	Signature
get_decimals	public fun get_decimals<T>(metadata: &coin::CoinMetadata<T>): u8
get_name	public fun get_name<T>(metadata: &coin::CoinMetadata<T>): string::String
get_symbol	public fun get_symbol<T>(metadata: &coin::CoinMetadata<T>): ascii::String
get_description	public fun get_description<T>(metadata: &coin::CoinMetadata<T>): string::String
get_icon_url	public fun get_icon_url<T>(metadata: &coin::CoinMetadata<T>): option::Option<url::Url>
Supply
Use the coin::supply function to get the current supply of a given coin.

Update coin metadata
If the CoinMetadata object was not frozen upon creation, you can use the following functions to update its values.

Each function signature is similar. Replace <FUNCTION-NAME> and <ATTRIBUTE-TYPE> with the values defined in the table to get the signature of each function:

public entry fun <FUNCTION-NAME><T>(
  _treasury: &coin::TreasuryCap<T>,
  metadata: &mut coin::CoinMetadata<T>,
  <ATTRIBUTE-TYPE>
)

<FUNCTION-NAME>	<ATTRIBUTE-TYPE>
update_name	name: string::String
update_symbol	symbol: ascii::String
update_description	description: string::String
update_icon_url	url: ascii::String
info
RegulatedCoinMetadata is frozen upon creation, so there are no functions to update its data.

Related links
Check out the following content for more information about coins and tokens on Sui:

Create a Coin: Guide for creating coins and regulated coins in your smart contracts.
Closed-Loop Token Standard: Details the Token standard on Sui.
coin module rustdoc documentation: Automated documentation output for the Sui framework coin module.
token module rustdoc documentation: Automated documentation output for the Sui framework token module.
Tokenomics: Discover the Sui ecosystem and where SUI coins fit within it.
Edit this page

Closed-Loop Token
Using the Closed-Loop Token standard, you can limit the applications that can use the token and set up custom policies for transfers, spends, and conversions. The sui::token module in the Sui framework defines the standard.

Background and use cases
The Coin standard on Sui is an example of an open-loop system - coins are free-flowing, wrappable, freely transferable and you can store them in any application. The best real world analogy would be cash - hardly regulated and can be freely used and passed.

Some applications, however, require constraining the scope of the token to a specific purpose. For example, some applications might need a token that you can only use for a specific service, or that an authorized account can only use, or a token that you can block certain accounts from using. A real-world analogy would be a bank account - regulated, bank-controlled, and compliant with certain rules and policies.

Difference with Coin
  Token has key { Balance }  
  Coin has key, store { Balance }  
  Balance has store { u64 }  
to_balance
to_coin
Token<T>
TreasuryCap<T>
Coin<T>
TreasuryCap<T>
Balance<T>
Supply<T>
  Token has key { Balance }  
  Coin has key, store { Balance }  
  Balance has store { u64 }  
from_balance
from_coin
Token<T>
TreasuryCap<T>
Coin<T>
TreasuryCap<T>
Balance<T>
Supply<T>
Unlike Coin, which has key + store abilities and thus supports wrapping and public transfers, Token has only the key ability and cannot be wrapped, stored as a dynamic field, or freely transferred (unless there's a custom policy for that). Due to this restriction, Token can only be owned by an account and can't be stored in an application (however, it can be "spent" - see Spending section section).

// defined in `sui::coin`
struct Coin<phantom T> has key, store { id: UID, balance: Balance<T> }

// defined in `sui::token`
struct Token<phantom T> has key { id: UID, balance: Balance<T> }

Compliance and rules
You can set up any rules for transfers, spends, and conversions for the tokens you create. You specify these rules per action in the TokenPolicy. Rules are custom programmable restrictions that you can use to implement any request authorization or validation logic.

For example, a policy can set a limit on a transfer - X tokens per operation; or require user verification before spending tokens; or allow spending tokens only on a specific service.

You can reuse rules across different policies and applications; and you can freely combine rules to create complex policies.

Public actions
Tokens have a set of public and protected actions that you can use to manage the token. Public actions are available to everyone and don't require any authorization. They have similar APIs to coins, but operate on the Token type:

token::keep - send a token to the transaction sender
token::join - join two tokens
token::split - split a token into two, specify the amount to split
token::zero - create an empty (zero balance) token
token::destroy_zero - destroy a token with zero balance
See Coin Token Comparison for coin and token methods comparison.

Protected actions
Protected actions are ones that issue an ActionRequest - a hot-potato struct that must be resolved for the transaction to succeed. There are three main ways to resolve an ActionRequest, most common of which is via the TokenPolicy.

token::transfer - transfer a token to a specified address
token::to_coin - convert a token to a coin
token::from_coin - convert a coin to a token
token::spend - spend a token on a specified address
The previous methods are included in the base implementation, however it is possible to create ActionRequests for custom actions.

Token policy and rules
Protected actions are disabled by default but you can enable them in a TokenPolicy. Additionally, you can set custom restrictions called rules that a specific action must satisfy for it to succeed.

Coin/Token API comparison
Use this appendix as a quick reference to compare the API of the coin and token modules.

Function	Coin	Token	Note
mint	+	+	Requires TreasuryCap
burn	+	+	Requires TreasuryCap
join	+	+	Public
split	+	+	Public
zero	+	+	Public
destroy_zero	+	+	Public
keep	-	+	Send token to sender, not required for coin due to lack of transfer restrictions
transfer	+	[protected]	Coin is transferable by default, token requires authorization
to_balance/to_coin	+	[protected]	Token can be converted to_coin, requires authorization
from_balance/from_coin	+	[protected]	Token can be created from_coin, requires authorization
spend	-	[protected]	Token can be spent, requires authorization

Building Programmable Transaction Blocks
This guide explores creating a programmable transaction block (PTB) on Sui using the TypeScript SDK. For an overview of what a PTB is, see Programmable Transaction Blocks in the Concepts section. If you don't already have the Sui TypeScript SDK, follow the install instructions on the Sui TypeScript SDK site.

This example starts by constructing a PTB to send Sui. If you are familiar with the legacy Sui transaction types, this is similar to a paySui transaction. To construct transactions, import the Transaction class, and construct it:

import { Transaction } from '@mysten/sui/transactions';

const tx = new Transaction();

Using this, you can then add transactions to this PTB.

// Create a new coin with balance 100, based on the coins used as gas payment.
// You can define any balance here.
const [coin] = tx.splitCoins(tx.gas, [tx.pure('u64', 100)]);

// Transfer the split coin to a specific address.
tx.transferObjects([coin], tx.pure('address', '0xSomeSuiAddress'));

You can attach multiple transaction commands of the same type to a PTB as well. For example, to get a list of transfers, and iterate over them to transfer coins to each of them:

interface Transfer {
	to: string;
	amount: number;
}

// Procure a list of some Sui transfers to make:
const transfers: Transfer[] = getTransfers();

const tx = new Transaction();

// First, split the gas coin into multiple coins:
const coins = tx.splitCoins(
	tx.gas,
	transfers.map((transfer) => tx.pure('u64', transfer.amount)),
);

// Next, create a transfer transaction for each coin:
transfers.forEach((transfer, index) => {
	tx.transferObjects([coins[index]], tx.pure('address', transfer.to));
});

After you have the Transaction defined, you can directly execute it with a SuiClient and KeyPair using client.signAndExecuteTransaction.

client.signAndExecuteTransaction({ signer: keypair, transaction: tx });

Constructing inputs
Inputs are how you provide external values to PTBs. For example, defining an amount of Sui to transfer, or which object to pass into a Move call, or a shared object.

There are currently two ways to define inputs:

For objects: the tx.object(objectId) function is used to construct an input that contains an object reference.
For pure values: the tx.pure(type, value) function is used to construct an input for a non-object input.
If value is a Uint8Array, then the value is assumed to be raw bytes and is used directly: tx.pure(SomeUint8Array).
Otherwise, it's used to generate the BCS serialization layout for the value.
In the new version, a more intuitive way of writing is provided, for example: tx.pure.u64(100), tx.pure.string('SomeString'), tx.pure.address('0xSomeSuiAddress'), tx.pure.vector('bool', [true, false])...
Available transactions
Sui supports following transaction commands:

tx.splitCoins(coin, amounts): Creates new coins with the defined amounts, split from the provided coin. Returns the coins so that it can be used in subsequent transactions.
Example: tx.splitCoins(tx.gas, [tx.pure.u64(100), tx.pure.u64(200)])
tx.mergeCoins(destinationCoin, sourceCoins): Merges the sourceCoins into the destinationCoin.
Example: tx.mergeCoins(tx.object(coin1), [tx.object(coin2), tx.object(coin3)])
tx.transferObjects(objects, address): Transfers a list of objects to the specified address.
Example: tx.transferObjects([tx.object(thing1), tx.object(thing2)], tx.pure.address(myAddress))
tx.moveCall({ target, arguments, typeArguments }): Executes a Move call. Returns whatever the Sui Move call returns.
Example: tx.moveCall({ target: '0x2::devnet_nft::mint', arguments: [tx.pure.string(name), tx.pure.string(description), tx.pure.string(image)] })
tx.makeMoveVec({ type, elements }): Constructs a vector of objects that can be passed into a moveCall. This is required as there's no other way to define a vector as an input.
Example: tx.makeMoveVec({ elements: [tx.object(id1), tx.object(id2)] })
tx.publish(modules, dependencies): Publishes a Move package. Returns the upgrade capability object.
Passing transaction results as arguments
You can use the result of a transaction command as an argument in subsequent transaction commands. Each transaction command method on the transaction builder returns a reference to the transaction result.

// Split a coin object off of the gas object:
const [coin] = tx.splitCoins(tx.gas, [tx.pure.u64(100)]);
// Transfer the resulting coin object:
tx.transferObjects([coin], tx.pure.address(address));

When a transaction command returns multiple results, you can access the result at a specific index either using destructuring, or array indexes.

// Destructuring (preferred, as it gives you logical local names):
const [nft1, nft2] = tx.moveCall({ target: '0x2::nft::mint_many' });
tx.transferObjects([nft1, nft2], tx.pure.address(address));

// Array indexes:
const mintMany = tx.moveCall({ target: '0x2::nft::mint_many' });
tx.transferObjects([mintMany[0], mintMany[1]], tx.pure.address(address));

Use the gas coin
With PTBs, you can use the gas payment coin to construct coins with a set balance using splitCoin. This is useful for Sui payments, and avoids the need for up-front coin selection. You can use tx.gas to access the gas coin in a PTB, and it is valid as input for any arguments; with the exception of transferObjects, tx.gas must be used by-reference. Practically speaking, this means you can also add to the gas coin with mergeCoins or borrow it for Move functions with moveCall.

You can also transfer the gas coin using transferObjects, in the event that you want to transfer all of your coin balance to another address.

Of course, you can also transfer other coins in your wallet using their Object ID. For example,

const otherCoin = tx.object('0xCoinObjectId');
const coin = tx.splitCoins(otherCoin, [tx.pure.u64(100)]);
tx.transferObjects([coin], tx.pure.address(address));

Get PTB bytes
If you need the PTB bytes, instead of signing or executing the PTB, you can use the build method on the transaction builder itself.

tip
You might need to explicitly call setSender() on the PTB to ensure that the sender field is populated. This is normally done by the signer before signing the transaction, but will not be done automatically if you're building the PTB bytes yourself.

const tx = new Transaction();

// ... add some transactions...

await tx.build({ provider });

In most cases, building requires your JSON RPC provider to fully resolve input values.

If you have PTB bytes, you can also convert them back into a Transaction class:

const bytes = getTransactionBytesFromSomewhere();
const tx = Transaction.from(bytes);

Building offline
In the event that you want to build a PTB offline (as in with no provider required), you need to fully define all of your input values, and gas configuration (see the following example). For pure values, you can provide a Uint8Array which is used directly in the transaction. For objects, you can use the Inputs helper to construct an object reference.

import { Inputs } from '@mysten/sui/transactions';

// For pure values:
tx.pure(pureValueAsBytes);

// For owned or immutable objects:
tx.object(Inputs.ObjectRef({ digest, objectId, version }));

// For shared objects:
tx.object(Inputs.SharedObjectRef({ objectId, initialSharedVersion, mutable }));

You can then omit the provider object when calling build on the transaction. If there is any required data that is missing, this will throw an error.

Gas configuration
The new transaction builder comes with default behavior for all gas logic, including automatically setting the gas price, budget, and selecting coins to be used as gas. This behavior can be customized.

Gas price
By default, the gas price is set to the reference gas price of the network. You can also explicitly set the gas price of the PTB by calling setGasPrice on the transaction builder.

tx.setGasPrice(gasPrice);

Budget
By default, the gas budget is automatically derived by executing a dry-run of the PTB beforehand. The dry run gas consumption is then used to determine a balance for the transaction. You can override this behavior by explicitly setting a gas budget for the transaction, by calling setGasBudget on the transaction builder.

info
The gas budget is represented in Sui, and should take the gas price of the PTB into account.

tx.setGasBudget(gasBudgetAmount);

Gas payment
By default, the gas payment is automatically determined by the SDK. The SDK selects all coins at the provided address that are not used as inputs in the PTB.

The list of coins used as gas payment will be merged down into a single gas coin before executing the PTB, and all but one of the gas objects will be deleted. The gas coin at the 0-index will be the coin that all others are merged into.

// NOTE: You need to ensure that the coins do not overlap with any
// of the input objects for the PTB.
tx.setGasPayment([coin1, coin2]);

Gas coins should be objects containing the coins objectId, version, and digest (ie { objectId: string, version: string | number, digest: string }).

dApp / Wallet integration
The Wallet Standard interface has been updated to support the Transaction kind directly. All signTransaction and signAndExecuteTransaction calls from dApps into wallets is expected to provide a Transaction class. This PTB class can then be serialized and sent to your wallet for execution.

To serialize a PTB for sending to a wallet, Sui recommends using the tx.serialize() function, which returns an opaque string representation of the PTB that can be passed from the wallet standard dApp context to your wallet. This can then be converted back into a Transaction using Transaction.from().

tip
You should not build the PTB from bytes in the dApp code. Using serialize instead of build allows you to build the PTB bytes within the wallet itself. This allows the wallet to perform gas logic and coin selection as needed.

// Within a dApp
const tx = new Transaction();
wallet.signTransaction({ transaction: tx });

// Your wallet standard code:
function handleSignTransaction(input) {
	sendToWalletContext({ transaction: input.transaction.serialize() });
}

// Within your wallet context:
function handleSignRequest(input) {
	const userTx = Transaction.from(input.transaction);
}

Sponsored PTBs
The PTB builder can support sponsored PTBs by using the onlyTransactionKind flag when building the PTB.

const tx = new Transaction();
// ... add some transactions...

const kindBytes = await tx.build({ provider, onlyTransactionKind: true });

// Construct a sponsored transaction from the kind bytes:
const sponsoredTx = Transaction.fromKind(kindBytes);

// You can now set the sponsored transaction data that is required:
sponsoredTx.setSender(sender);
sponsoredTx.setGasOwner(sponsor);
sponsoredTx.setGasPayment(sponsorCoins);

Sponsored Transactions
A transaction on Sui takes a payment to execute. The payment, also known as gas, is a list of 0x2::coin::Coin<0x2::sui::Sui> objects. Although gas is a critical piece in Sui tokenomics, it sometimes adds challenges when new Web3 users start to navigate on Sui.

Sponsored transactions are a primitive on the Sui blockchain that enable the execution of a transaction without a user paying the gas. Sponsored transactions can reduce the onboarding friction for users because the feature streamlines the process for end users. Using sponsored transactions, you can execute a transaction without requiring the user to pay it themselves. Instead, you can act as a sponsor of the transaction, offering your own payment gas objects for the transaction.

Roles in sponsored transactions
In a sponsored transaction there are three roles: the user, the gas station, and the sponsor.

The user is the entity who wants to execute a transaction.
The gas station is the entity that fulfills the sponsorship request for the user's transaction by providing the gas payment they own.
The sponsor is entity that funds the gas station for its operations.
It's not uncommon for the gas station and the sponsor to be the same entity. For example, a web3 gaming studio could run its own gas station to sponsor users with real free-to-play gaming experiences at its user acquisition stage. Because it's not always trivial to maintain a gas station for teams of any size, that gaming studio could also leverage third-party gas stations to sponsor transactions they want to promote.

The remainder of this guide assumes the sponsor uses their own gas station.

Use cases
The following sections describe some common scenarios where sponsored transactions offer an improved user experience.

App-specific sponsorship
In this scenario, the sponsor has a specific set of applications they want to sponsor.

If the transaction is initialized by the user, the sponsor examines the transaction to make sure it's within the set of approved applications before agreeing to provide the gas payment.
If the transaction is proposed by the sponsor, the user must examine the transaction and decide if they want to execute it. Examples of this type of transaction might include a rewards claim transaction of a campaign or a "try it out" advertisement transaction.
Wildcard sponsorship
In this scenario, the sponsor has few restrictions on the type of transactions the gas payment can be used for.

If the sponsor is a gasless wallet, it may agree to sponsor any valid transactions proposed by its users.
In the form of a reward or discount, the sponsor could offer the user a wildcard gas payment, expressly promising to execute any transactions with that gas payment.
A sponsored transaction is not restricted to these use cases. Essentially, a sponsored transaction is any transaction jointly made by the user and the sponsor. As long as the stakeholders can agree on the transaction details, then the number of possible ways to provide sponsored transactions is limited only by the imagination. Because at least two stakeholders are involved in a sponsored transaction, however, there are some additional risks that you should take steps to mitigate.

Sponsored transaction flow
This section is mostly for developers who are interested in building a gas station or integrating with one.

The data structure of a transaction resembles the following:


pub struct SenderSignedTransaction {
    pub intent_message: IntentMessage<TransactionData>,
    /// A list of signatures signed by all transaction participants.
    /// 1. non participant signature must not be present.
    /// 2. signature order does not matter.
    pub tx_signatures: Vec<GenericSignature>,
}

pub struct TransactionDataV1 {  // <-- A variant of `TransactionData`
    pub kind: TransactionKind,  // <-- This is the actual transaction details
    pub sender: SuiAddress,
    pub gas_data: GasData,
    pub expiration: TransactionExpiration,
}

pub struct GasData {
    pub payment: Vec<ObjectRef>,
    pub owner: SuiAddress,
    pub price: u64,
    pub budget: u64,
}


A few details of note for the preceding code:

sender in TransactionDataV1 (a variant of TransactionData) is the user address.
gas_data in TransactionDataV1 is the gas payment.
GasData allows a list of gas objects, but the same address must own them, namely the owner in GasData (the sponsor). When owner is equal to sender, then it is a regular/non-sponsored transaction.
tx_signatures in SenderSignedTransaction is a list of signatures. For a sponsored transaction, the list needs to contain both signatures of the user and the sponsor in some order. The signatures are signed over the entire TransactionData, including GasData.
So, to construct a correct sponsored transaction, you must first build a TransactionData object. If you are neither the user or the sponsor, you would then pass the transaction to both parties to sign. If you're the sponsor, you would sign the transaction and then pass it and the signature to the other party (in the form of SenderSignedTransaction) for them to sign. In practice, the latter is the more common scenario.

There are three flows of sponsored transaction.

User proposed transaction

(swimlane link)



Sponsor proposed transaction

(swimlane link)



Wildcard gas payment

(swimlane link)



Risk considerations
Because at least two stakeholders are involved in a sponsored transaction, you should take steps to mitigate risk.

Client equivocation risk
Client equivocation happens when more than one legit transaction that shares at least one owned object (such as a gas coin object) at a certain version are submitted to the network simultaneously. On Sui, before a transaction is executed, owned objects in this transaction are locked on validators at specific versions. An honest validator only accepts one transaction and rejects others. Depending on the order validators receive these transactions, validators might accept different transactions. In the event of no single transaction getting accepted by at least 2/3rds of validators, the owned object is locked until end of the epoch.

Practically speaking, client equivocation is rare, mostly caused by buggy client software. After all, no one has incentives to lock their own objects. However, sponsored transactions come with counterparty risks. For example, a malicious user could equivocate the gas station's gas coin object by submitting another transaction that uses one owned object in the gas station signed transaction at the same version. Similarly, a Byzantine gas station could do the same to the user owned objects.

Although this risk might seem trivial, it is helpful to be aware of it. Your gas station should actively monitor user behavior and alert on anything abnormal. Whether you're a user taking advantage of sponsored transactions or a developer integrating with a gas station, consider your reputation to minimize the risk of client equivocation.

Both the user and the sponsor need to sign over the entire TransactionData, including GasData because otherwise a third party (such as a malicious Full node) could snip the partially signed data and cause client equivocation and locking of owned objects.

Censorship risk
If you chooses to submit the dual-signed transaction to the sponsor or gas station rather than a Full node, the transaction might be subject to sponsor or gas station censorship. Namely, the sponsor might choose not to submit the transaction to the network, or delay the submission.

You can mitigate this risk by submitting the transaction directly to a Full node.

Create a Non-Fungible Token
On Sui, everything is an object. Moreover, everything is a non-fungible token (NFT) as its objects are unique, non-fungible, and owned.

Creating NFTs on Sui differs from other blockchains that are not object based. Those blockchains require a dedicated standard to handle the properties that define NFTs because they are based on a mapping between smart contracts and the token's ID. For instance, the ERC-721 standard on Ethereum was necessary to pair a globally unique ID with the relevant smart contract address to create a unique token instance on the network.

On Sui, every object already has a unique ID, so whether you're dealing with a million fungible tokens, like coins, or thousands of NFTs with individual characteristics, like SuiFrens, your smart contracts on Sui always interact with individual objects.

Imagine you create an Excitable Chimp NFT collection on Sui and another blockchain that isn't object based. To get an attribute like the Chimp's name on the other blockchain, you would need to interact with the smart contract that created the NFT to get that information (typically from off-chain storage) using the NFT ID. On Sui, the name attribute can be a field on the object that defines the NFT itself. This construct provides a much more straightforward process for accessing metadata for the NFT as the smart contract that wants the information can just return the name from the object itself.

Example
The following example creates a basic NFT on Sui. The TestnetNFT struct defines the NFT with an id, name, description, and url fields.

examples/move/nft/sources/testnet_nft.move
public struct TestnetNFT has key, store {
    id: UID,
    name: string::String,
    description: string::String,
    url: Url,
}

In this example, anyone can mint the NFT by calling the mint_to_sender function. As the name suggests, the function creates a new TestnetNFT and transfers it to the address that makes the call.

examples/move/nft/sources/testnet_nft.move
#[allow(lint(self_transfer))]
public fun mint_to_sender(
    name: vector<u8>,
    description: vector<u8>,
    url: vector<u8>,
    ctx: &mut TxContext,
) {
    let sender = ctx.sender();
    let nft = TestnetNFT {
        id: object::new(ctx),
        name: string::utf8(name),
        description: string::utf8(description),
        url: url::new_unsafe_from_bytes(url),
    };

    event::emit(NFTMinted {
        object_id: object::id(&nft),
        creator: sender,
        name: nft.name,
    });

    transfer::public_transfer(nft, sender);
}

The module includes functions to return NFT metadata, too. Referencing the hypothetical used previously, you can call the name function to get that value. As you can see, the function simply returns the name field value of the NFT itself.

examples/move/nft/sources/testnet_nft.move
public fun name(nft: &TestnetNFT): &string::String {
    &nft.name
}

Click to open
testnet_nft.move



above is some more docs and information

now, I want to go protocol by potocol and pseudocode it up. basically I want to get a solid foundation of what the objectson chain will look like, what the events emitted would look like, so that we know what events the indexer we run will be listening for (including using indexer/apis already provided by deepbook/sui). and what I need to code into the CLI/frontend. basically there are three components. the on-chain code, the cli/server, and the frontend. traders /users run the cli and frontend on their computers to interact with the network. Any off-chain thing that needs to run must run in the cli/server. I'd like to keep as much as possible on chain without sacrificing performance. sui isnice because it's unique object architecture allows us to do much more than a normal EVM. 

So let's refresh, and go from the ground up

unx token	base token for everything. fees are allowed to be paid by either the input asset, USDC, or UNXV. using UNXV gives you a discount, and all fees are autoswapped to unxv. Then the deepbook amount is autoswapped to DEEP, and then the remaining unxv is burned. Naturally, this means the fees for UNXV are higher than that for just deepbook. If deepbook offers rebates/etc in DEEP, these must be autoswapped back into UNXV before they reach the user. (so all fees and rewards etc are in UNXV)
unxversal synthetics	
unxversal spot dex	
unxversal lending protocol	robust permissionless lending protocol
unxversal options	
unxversal dated futures	
unxversal perpetuals	
unxversal exotic derivatives	
unxversal liquid staking	"Supported pay-offs (launch set)
Code	Description	Pay-off formula	Typical use-case
KO_CALL	Knock-out call	max(0, S_T – K) if S_t < B ∀ t	Cheap trend bet—but dies if price crashes
KI_PUT	Knock-in put	Activates only if barrier hit, then vanilla put	Hedge only if support breaks
RANGE_ACC	Range accrual	Pays coupon c per epoch while L ≤ S ≤ U	Earn yield in chop
PWR_PERP_n	Power perp (n=2,3)	PnL ∝ S^n funding-adjusted	Leveraged beta or variance trading"
unxversal liquidity provisioning pools	"people can make vaults, where the vault manager cna trade with the assets. manager is required to have at least a minimum of 5% stake in the pool. Trader gets 10% of profits by default, but this is configurable by the trader. basically a vault manager can specify their minimum stake (>=5%), and profit share, and people can deposit in different pools). Vault managers can manually trade with the funds or deploy on-chain strategies. Inspired by the grant rfp below (would like to also fulfil the grant requirements too). Liquidity Provisioning
Request for Proposal Program
DeepBook
Overview
Build a user-facing application enabling token holders to deploy capital to market making strategies or operate custom strategies without writing code on DeepBook. This should provide a range of liquidity provisioning strategies, from simple to more complex and increasing in risk. The application should let the user tweak key parameters and keep track of their P&L.

Desirable Features
Vault-based architecture allowing capital deployment using major Sui assets (e.g., SUI, stablecoins, DEEP)
Predefined and configurable strategies, ranging from passive (e.g., AMM overlays) to active market making
User-controlled parameters such as tick range, rebalancing frequency, and deposit limits
Performance tracking, including individual and strategy-level P&L, drawdowns, and DeepBook liquidity contributions
Risk management tools, including timelocks, circuit breakers, drawdown limits, and real-time monitoring
Modular smart contract design separating vault logic, strategy execution, risk controls, and user accounting for auditability and upgradeability
Deliverables
Open-source Move smart contracts for strategy vaults, execution logic, and safety controls
A web-based front end for strategy selection, interaction, and performance monitoring
Comprehensive technical documentation, including architecture, usage, and deployment guides
A full testing suite for backend and frontend components
Audit-ready modular design with internal checks and safety mechanisms
"
unxversal gas futures	"inspired by this grant rfp: Project Name
Gas Futures Functionality
Request for Proposal Program
Sui
Overview
Gas prices on public blockchains, including the Sui blockchain, are inherently volatile due to short-term fluctuations in the value of the SUI token. This volatility poses challenges for businesses and users who require predictable costs to plan their operations efficiently. The Sui Foundation seeks proposals to design and implement a Gas Futures Functionality mechanism that allows users to hedge gas price volatility by purchasing gas credits at a predefined price for future use.



This feature will enable businesses and users to secure predictable costs for gas fees, similar to commodity futures markets like oil, providing stability and cost-efficiency for using the Sui blockchain. The gas futures functionality itself will incorporate an appropriate risk and hedging model to ensure its long-term viability and ability to meet its future gas obligations.

Desirable Features
Gas Futures Mechanism:

- Allow users to pre-purchase gas credits redeemable for future transaction fees, inclusive of both computation and storage fees.

- Support contract expiry dates and seamless redemption.



Modular architecture:

Allow flexibility in designing gas fee derivatives. For instance:

- A smart contract-based clearinghouse.

- Automated market makers (AMMs) for trading gas futures.

- Incentive systems for liquidity providers.

- Pooled risk models to minimize exposure to a single volatility event.



Pricing Model:

- Propose a fair, transparent pricing mechanism (e.g., fixed, dynamic, or auction-based). Consider exploring mechanisms like ""predictive AMMs"" or bonding curves tailored to gas pricing dynamics.

- Ensure resistance to manipulation and alignment with market demand.

- Design a robust risk management framework to ensure the product remains financially sustainable and responsive to changes in the RGP, storage gas price, or instruction gas costs.



Smart Contract Infrastructure:

- Design secure smart contracts to manage issuance, tracking, and redemption of gas futures.



User Tools & User Experience:

- Develop intuitive tools (web/app interfaces, dashboards, or APIs) for purchasing, monitoring, and redeeming gas credits.

- Prioritize low-friction integration with existing DeFi infrastructure/ DeepBook

- Encourage innovative designs that go beyond replicating traditional derivatives (e.g., pooled risk or community staking for fee hedging).



Security and Governance:

- Ensure robust security with audits.

- Propose incentives for liquidity providers and governance mechanisms for updates.

Deliverables
1. Technical Design Document: Architecture, pricing and risk model, and security approach.

2. Functional Prototype (MVP): Demonstrate purchasing, tracking, and redeeming gas futures.

3. Smart Contract Codebase: Audited and tested smart contracts.

4. User Tools: Interfaces or APIs for gas credit management.

5. Testing and Audits: Results of functional, performance, and security testing.

6. Final Report and Documentation: Detailed summary, technical documentation, and user guides."
unxversal autoswap contracts	when you send asset a to the contract, you get sent asset b.there will be two of these contracts. one autoswaps arbitrary asset A for UNXV. the other autoswaps arbitrary asset A for USDC.


note that there is nodao: unxv tokenomics:
1b max supply
30% founding team, vested over two years 6 month cliff
30% initial comunity airdrop
30% future community airdrop
10% lending liquidity

lmk your thoughts on the tokenomics if you think it should be changed
there will be no dao. v1 will be immutable once deployed

ok, forgetting the previous approaches, now let's start with unxversal synthetics

write your response to unxvsynthetics.md

---

**Cursor**

I'll help you design the UnXversal ecosystem starting with the synthetics protocol. Let me create a comprehensive overview and then dive into the synthetics protocol specifically.

```markdown
# UnXversal Synthetics Protocol Design

## Overview

UnXversal Synthetics enables permissionless creation and trading of synthetic assets backed by collateral, built on top of DeepBook's order book infrastructure. Users can mint synthetic assets by depositing collateral and trade them on DeepBook pools with automatic price feeds from Pyth Network.

## DeepBook Integration Summary

**How DeepBook Works:**
- **Pool**: Central limit order book for each trading pair (e.g., synth/USDC)
- **BalanceManager**: Holds user funds across all pools, requires TradeProof for operations
- **Order Matching**: Automatic matching of buy/sell orders with maker/taker fees
- **Flash Loans**: Uncollateralized borrowing within single transaction
- **Indexer**: Real-time data feeds for order books, trades, and volumes

**Our Integration:**
- Create DeepBook pools for each synthetic asset vs collateral pairs
- Use flash loans for atomic liquidations and arbitrage
- Leverage indexer for real-time pricing and risk management
- Integrate with existing fee structure while adding UNXV discounts

## Core Architecture

### On-Chain Objects

#### 1. SynthRegistry (Shared Object)
```move
struct SynthRegistry has key {
    id: UID,
    synthetics: Table<String, SyntheticAsset>,
    collateral_types: VecSet<TypeName>,
    oracle_feeds: Table<String, vector<u8>>, // Pyth price feed IDs
    global_params: GlobalParams,
    admin_cap: Option<AdminCap>,
}

struct GlobalParams has store {
    min_collateral_ratio: u64,     // 150% = 1500 basis points
    liquidation_threshold: u64,    // 120% = 1200 basis points
    liquidation_penalty: u64,      // 5% = 500 basis points
    max_synthetics: u64,           // Max synthetic types
    stability_fee: u64,            // Annual percentage
}
```

#### 2. SyntheticAsset (Stored in Registry)
```move
struct SyntheticAsset has store {
    name: String,
    symbol: String,
    decimals: u8,
    pyth_feed_id: vector<u8>,
    min_collateral_ratio: u64,
    total_supply: u64,
    deepbook_pool_id: Option<ID>,
    is_active: bool,
    created_at: u64,
}
```

#### 3. CollateralVault (Owned Object)
```move
struct CollateralVault<phantom T> has key {
    id: UID,
    owner: address,
    collateral_balance: Balance<T>,
    synthetic_debt: Table<String, u64>, // synth_symbol -> amount
    last_update: u64,
    liquidation_price: Table<String, u64>, // cached liquidation prices
}
```

#### 4. SyntheticCoin (Transferable Asset)
```move
struct SyntheticCoin<phantom T> has key, store {
    id: UID,
    balance: Balance<T>,
    synthetic_type: String,
}
```

#### 5. LiquidationBot (Service Object)
```move
struct LiquidationBot has key {
    id: UID,
    operator: address,
    min_profit_threshold: u64,
    max_liquidation_amount: u64,
    whitelisted_assets: VecSet<String>,
}
```

### Events

#### 1. Synthetic Asset Events
```move
// When new synthetic asset is created
struct SyntheticAssetCreated has copy, drop {
    asset_name: String,
    asset_symbol: String,
    pyth_feed_id: vector<u8>,
    creator: address,
    deepbook_pool_id: ID,
    timestamp: u64,
}

// When synthetic is minted
struct SyntheticMinted has copy, drop {
    vault_id: ID,
    synthetic_type: String,
    amount_minted: u64,
    collateral_deposited: u64,
    collateral_type: String,
    minter: address,
    new_collateral_ratio: u64,
    timestamp: u64,
}

// When synthetic is burned
struct SyntheticBurned has copy, drop {
    vault_id: ID,
    synthetic_type: String,
    amount_burned: u64,
    collateral_withdrawn: u64,
    collateral_type: String,
    burner: address,
    new_collateral_ratio: u64,
    timestamp: u64,
}
```

#### 2. Liquidation Events
```move
struct LiquidationExecuted has copy, drop {
    vault_id: ID,
    liquidator: address,
    liquidated_amount: u64,
    collateral_seized: u64,
    liquidation_penalty: u64,
    synthetic_type: String,
    collateral_type: String,
    timestamp: u64,
}

struct LiquidationBotRegistered has copy, drop {
    bot_id: ID,
    operator: address,
    min_profit_threshold: u64,
    timestamp: u64,
}
```

#### 3. Fee Events
```move
struct FeeCollected has copy, drop {
    fee_type: String, // "mint", "burn", "stability"
    amount: u64,
    asset_type: String,
    user: address,
    unxv_discount_applied: bool,
    timestamp: u64,
}

struct UnxvBurned has copy, drop {
    amount_burned: u64,
    fee_source: String,
    timestamp: u64,
}
```

## Core Functions

### 1. Synthetic Asset Creation
```move
public fun create_synthetic_asset(
    registry: &mut SynthRegistry,
    asset_name: String,
    asset_symbol: String,
    pyth_feed_id: vector<u8>,
    min_collateral_ratio: u64,
    deepbook_registry: &mut Registry,
    ctx: &mut TxContext,
): ID // Returns DeepBook pool ID
```

### 2. Collateral Management
```move
public fun deposit_collateral<T>(
    vault: &mut CollateralVault<T>,
    collateral: Coin<T>,
    ctx: &mut TxContext,
)

public fun withdraw_collateral<T>(
    vault: &mut CollateralVault<T>,
    amount: u64,
    registry: &SynthRegistry,
    price_info: &PriceInfoObject,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<T>
```

### 3. Synthetic Minting/Burning
```move
public fun mint_synthetic<T>(
    vault: &mut CollateralVault<T>,
    synthetic_type: String,
    amount: u64,
    registry: &SynthRegistry,
    price_info: &PriceInfoObject,
    clock: &Clock,
    ctx: &mut TxContext,
): SyntheticCoin<T>

public fun burn_synthetic<T>(
    vault: &mut CollateralVault<T>,
    synthetic_coin: SyntheticCoin<T>,
    registry: &SynthRegistry,
    price_info: &PriceInfoObject,
    clock: &Clock,
    ctx: &mut TxContext,
): Option<Coin<T>> // Returns collateral if any
```

### 4. Liquidation
```move
public fun liquidate_vault<T>(
    vault: &mut CollateralVault<T>,
    synthetic_type: String,
    liquidation_amount: u64,
    registry: &SynthRegistry,
    price_info: &PriceInfoObject,
    clock: &Clock,
    ctx: &mut TxContext,
): (SyntheticCoin<T>, Coin<T>) // Returns debt repaid, collateral seized
```

### 5. Flash Loan Integration
```move
public fun flash_mint_arbitrage<BaseAsset, QuoteAsset>(
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    vault: &mut CollateralVault<BaseAsset>,
    synthetic_type: String,
    arbitrage_amount: u64,
    registry: &SynthRegistry,
    price_info: &PriceInfoObject,
    clock: &Clock,
    ctx: &mut TxContext,
): FlashLoan // Hot potato for atomic arbitrage
```

## Fee Structure with UNXV Integration

### Fee Types
1. **Minting Fee**: 0.5% of minted value
2. **Burning Fee**: 0.3% of burned value  
3. **Stability Fee**: 2% annually on outstanding debt
4. **Liquidation Fee**: 5% penalty on liquidated collateral

### UNXV Discount Mechanism
```move
struct FeeCalculation has drop {
    base_fee: u64,
    unxv_discount: u64,    // 20% discount
    final_fee: u64,
    payment_asset: String,  // "UNXV", "USDC", or "input_asset"
}

public fun calculate_fee_with_discount(
    base_fee: u64,
    payment_asset: String,
    unxv_balance: u64,
): FeeCalculation
```

### Auto-swap Integration
```move
public fun process_fee_payment(
    fee_amount: u64,
    payment_asset: String,
    user_balance_manager: &mut BalanceManager,
    autoswap_contract: &mut AutoSwapContract,
    ctx: &mut TxContext,
)
```

## Risk Management

### 1. Collateral Ratio Monitoring
```move
public fun check_vault_health<T>(
    vault: &CollateralVault<T>,
    synthetic_type: String,
    registry: &SynthRegistry,
    price_info: &PriceInfoObject,
    clock: &Clock,
): (u64, bool) // Returns (collateral_ratio, is_liquidatable)
```

### 2. Oracle Price Validation
```move
public fun validate_price_feed(
    price_info: &PriceInfoObject,
    expected_feed_id: vector<u8>,
    max_age: u64,
    clock: &Clock,
): I64
```

### 3. System Stability Checks
```move
public fun check_system_stability(
    registry: &SynthRegistry,
    price_feeds: vector<PriceInfoObject>,
    clock: &Clock,
): SystemHealth

struct SystemHealth has drop {
    total_collateral_value: u64,
    total_synthetic_value: u64,
    global_collateral_ratio: u64,
    at_risk_vaults: u64,
    system_solvent: bool,
}
```

## DeepBook Pool Management

### 1. Automatic Pool Creation
```move
public fun create_deepbook_pool_for_synthetic(
    synthetic_type: String,
    collateral_type: String,
    registry: &mut SynthRegistry,
    deepbook_registry: &mut Registry,
    creation_fee: Coin<DEEP>,
    ctx: &mut TxContext,
): ID
```

### 2. Liquidity Incentives
```move
public fun provide_initial_liquidity<BaseAsset, QuoteAsset>(
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    synthetic_amount: u64,
    collateral_amount: u64,
    price_range: PriceRange,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
    ctx: &mut TxContext,
)
```

## Indexer Integration

### Events to Index
1. **SyntheticAssetCreated** - Track new synthetic assets
2. **SyntheticMinted/Burned** - Monitor supply changes
3. **LiquidationExecuted** - Risk monitoring
4. **FeeCollected** - Revenue tracking
5. **UnxvBurned** - Tokenomics tracking

### API Endpoints Needed
```typescript
// Custom indexer endpoints
/api/v1/synthetics/assets          // List all synthetic assets
/api/v1/synthetics/vaults/{owner}  // User's vaults
/api/v1/synthetics/health          // System health metrics
/api/v1/synthetics/liquidations    // Liquidation opportunities
/api/v1/synthetics/fees            // Fee analytics
/api/v1/synthetics/prices          // Price feeds with oracle data

// DeepBook integration
/api/v1/deepbook/pools/synthetic   // Synthetic asset pools
/api/v1/deepbook/volume/synthetic  // Trading volumes
/api/v1/deepbook/liquidity/synthetic // Liquidity metrics
```

## CLI/Server Components

### 1. Price Feed Manager
```typescript
class PriceFeedManager {
    private pythClient: SuiPythClient;
    private feedIds: Map<string, string>;
    
    async updatePriceFeeds(synthetics: string[]): Promise<void>;
    async validatePrices(synthetic: string): Promise<boolean>;
    async getPriceWithConfidence(synthetic: string): Promise<PriceData>;
}
```

### 2. Liquidation Bot
```typescript
class LiquidationBot {
    private suiClient: SuiClient;
    private vaultMonitor: VaultMonitor;
    
    async scanForLiquidations(): Promise<LiquidationOpportunity[]>;
    async executeLiquidation(opportunity: LiquidationOpportunity): Promise<void>;
    async calculateProfitability(vault: VaultData): Promise<number>;
}
```

### 3. Vault Manager
```typescript
class VaultManager {
    async createVault(collateralType: string): Promise<string>;
    async mintSynthetic(vaultId: string, amount: number): Promise<void>;
    async burnSynthetic(vaultId: string, amount: number): Promise<void>;
    async monitorHealth(vaultId: string): Promise<VaultHealth>;
}
```

## Frontend Integration

### 1. Vault Dashboard
- Real-time collateral ratios
- Liquidation warnings
- Minting/burning interface
- Fee calculator with UNXV discounts

### 2. Trading Interface
- DeepBook order book integration
- Price charts with oracle feeds
- Liquidity provision tools
- Arbitrage opportunities

### 3. Risk Management
- System health monitoring
- Price feed status
- Liquidation queue
- Fee analytics

## Security Considerations

1. **Oracle Failures**: Multiple price feed validation
2. **Flash Loan Attacks**: Atomic operation constraints
3. **Collateral Volatility**: Dynamic liquidation thresholds
4. **Smart Contract Risks**: Formal verification and audits
5. **Economic Attacks**: Incentive alignment and circuit breakers

## Deployment Strategy

### Phase 1: Core Infrastructure
- Deploy SynthRegistry and core contracts
- Create initial synthetic assets (sUSD, sBTC, sETH)
- Set up price feeds and DeepBook pools

### Phase 2: Advanced Features  
- Liquidation bots and flash loan integration
- Advanced synthetic assets (commodities, indices)
- Cross-collateral support

### Phase 3: Ecosystem Integration
- Integration with other UnXversal protocols
- Synthetic derivatives and structured products
- Institutional features

## UNXV Tokenomics Integration

### Fee Revenue Distribution
- 50% burned (deflationary pressure)
- 30% protocol treasury
- 20% liquidity incentives

### Discount Mechanism
- 20% fee discount for UNXV payments
- Auto-swap non-UNXV fees to UNXV
- Gradual burn of collected fees

This creates a sustainable flywheel where protocol usage drives UNXV demand and supply reduction, while providing clear utility and value accrual to token holders.
```

I've created a comprehensive design document for the UnXversal Synthetics protocol. Here are my thoughts on the overall approach and tokenomics:

## DeepBook Integration Strategy

Your approach to build on DeepBook is excellent because:

1. **Liquidity Aggregation**: All synthetic assets automatically get access to DeepBook's order book liquidity
2. **Flash Loan Synergy**: Perfect for atomic liquidations, arbitrage, and rebalancing
3. **Real-time Data**: DeepBook's indexer provides crucial pricing and volume data
4. **Proven Infrastructure**: Leverages battle-tested order matching and settlement

## UNXV Tokenomics Assessment

Your proposed tokenomics structure is solid:

**✅ Strong Points:**
- **Deflationary Mechanism**: Fee burning creates sustainable demand
- **Utility-First**: Real fee discounts provide immediate value
- **No Governance Complexity**: Immutable contracts reduce attack vectors
- **Reasonable Distribution**: 60% to community is generous

**🔄 Suggestions for Consideration:**
- **Team Vesting**: 6-month cliff might be short - consider 12 months
- **Community Split**: Consider making initial airdrop smaller (20%) and future airdrop larger (40%) to reward early adopters over time
- **Fee Discount**: 20% might be optimal, but consider making it dynamic based on protocol maturity

## Next Steps for Protocol Development

Would you like me to design the next protocol? I'd suggest we tackle them in this order:

1. **✅ Synthetics** (Complete)
2. **Spot DEX** - Aggregation layer over DeepBook with advanced order types
3. **Lending** - Collateral integration with synthetics
4. **Options** - Build on synthetic infrastructure
5. **Perpetuals** - Leverage synthetic pricing
6. **Dated Futures** - Extension of perps
7. **Gas Futures** - Specialized SUI gas hedging
8. **Exotic Derivatives** - Advanced payoff structures
9. **Liquid Staking** - Yield-bearing collateral
10. **Liquidity Provisioning** - Vault strategies

Each protocol can build on the previous ones, creating a integrated ecosystem where:
- Synthetics provide price exposure
- Lending provides leveraged positions
- Options/perps provide hedging
- Liquidity vaults provide automated strategies

Should I proceed with the **Spot DEX** design next, or would you prefer to dive deeper into any specific aspect of the synthetics protocol?

---

**User**

only usdc collateral. also, what is the admincap?

---

**Cursor**

Good points! Let me update the design for USDC-only collateral and explain the AdminCap.

```markdown
#### 1. SynthRegistry (Shared Object)
```move
struct SynthRegistry has key {
    id: UID,
    synthetics: Table<String, SyntheticAsset>,
    collateral_types: VecSet<TypeName>,
    oracle_feeds: Table<String, vector<u8>>, // Pyth price feed IDs
    global_params: GlobalParams,
    admin_cap: Option<AdminCap>,
}

struct GlobalParams has store {
    min_collateral_ratio: u64,     // 150% = 1500 basis points
    liquidation_threshold: u64,    // 120% = 1200 basis points
    liquidation_penalty: u64,      // 5% = 500 basis points
    max_synthetics: u64,           // Max synthetic types
    stability_fee: u64,            // Annual percentage
}
```

->

#### 1. SynthRegistry (Shared Object)
```move
struct SynthRegistry has key {
    id: UID,
    synthetics: Table<String, SyntheticAsset>,
    oracle_feeds: Table<String, vector<u8>>, // Pyth price feed IDs
    global_params: GlobalParams,
    admin_cap: Option<AdminCap>,
}

struct GlobalParams has store {
    min_collateral_ratio: u64,     // 150% = 1500 basis points
    liquidation_threshold: u64,    // 120% = 1200 basis points
    liquidation_penalty: u64,      // 5% = 500 basis points
    max_synthetics: u64,           // Max synthetic types
    stability_fee: u64,            // Annual percentage
}

/// AdminCap grants privileged access for initial setup and emergency functions
/// Will be destroyed after deployment to make protocol immutable
struct AdminCap has key, store {
    id: UID,
}
```
```

```markdown
#### 3. CollateralVault (Owned Object)
```move
struct CollateralVault<phantom T> has key {
    id: UID,
    owner: address,
    collateral_balance: Balance<T>,
    synthetic_debt: Table<String, u64>, // synth_symbol -> amount
    last_update: u64,
    liquidation_price: Table<String, u64>, // cached liquidation prices
}
```

->

#### 3. CollateralVault (Owned Object)
```move
struct CollateralVault has key {
    id: UID,
    owner: address,
    collateral_balance: Balance<USDC>,    // USDC-only collateral
    synthetic_debt: Table<String, u64>,  // synth_symbol -> amount owed
    last_update: u64,
    liquidation_price: Table<String, u64>, // cached liquidation prices per synthetic
}
```
```

```markdown
#### 4. SyntheticCoin (Transferable Asset)
```move
struct SyntheticCoin<phantom T> has key, store {
    id: UID,
    balance: Balance<T>,
    synthetic_type: String,
}
```

->

#### 4. SyntheticCoin (Transferable Asset)
```move
struct SyntheticCoin<phantom T> has key, store {
    id: UID,
    balance: Balance<T>,
    synthetic_type: String,
}
```
```

```markdown
// When synthetic is minted
struct SyntheticMinted has copy, drop {
    vault_id: ID,
    synthetic_type: String,
    amount_minted: u64,
    collateral_deposited: u64,
    collateral_type: String,
    minter: address,
    new_collateral_ratio: u64,
    timestamp: u64,
}

// When synthetic is burned
struct SyntheticBurned has copy, drop {
    vault_id: ID,
    synthetic_type: String,
    amount_burned: u64,
    collateral_withdrawn: u64,
    collateral_type: String,
    burner: address,
    new_collateral_ratio: u64,
    timestamp: u64,
}

->

// When synthetic is minted
struct SyntheticMinted has copy, drop {
    vault_id: ID,
    synthetic_type: String,
    amount_minted: u64,
    usdc_collateral_deposited: u64,
    minter: address,
    new_collateral_ratio: u64,
    timestamp: u64,
}

// When synthetic is burned
struct SyntheticBurned has copy, drop {
    vault_id: ID,
    synthetic_type: String,
    amount_burned: u64,
    usdc_collateral_withdrawn: u64,
    burner: address,
    new_collateral_ratio: u64,
    timestamp: u64,
}
```

```markdown
struct LiquidationExecuted has copy, drop {
    vault_id: ID,
    liquidator: address,
    liquidated_amount: u64,
    collateral_seized: u64,
    liquidation_penalty: u64,
    synthetic_type: String,
    collateral_type: String,
    timestamp: u64,
}

->

struct LiquidationExecuted has copy, drop {
    vault_id: ID,
    liquidator: address,
    liquidated_amount: u64,
    usdc_collateral_seized: u64,
    liquidation_penalty: u64,
    synthetic_type: String,
    timestamp: u64,
}
```

```markdown
### 2. Collateral Management
```move
public fun deposit_collateral<T>(
    vault: &mut CollateralVault<T>,
    collateral: Coin<T>,
    ctx: &mut TxContext,
)

public fun withdraw_collateral<T>(
    vault: &mut CollateralVault<T>,
    amount: u64,
    registry: &SynthRegistry,
    price_info: &PriceInfoObject,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<T>
```

->

### 2. Collateral Management
```move
public fun deposit_collateral(
    vault: &mut CollateralVault,
    usdc_collateral: Coin<USDC>,
    ctx: &mut TxContext,
)

public fun withdraw_collateral(
    vault: &mut CollateralVault,
    amount: u64,
    registry: &SynthRegistry,
    price_info: &PriceInfoObject,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<USDC>
```
```

```markdown
### 3. Synthetic Minting/Burning
```move
public fun mint_synthetic<T>(
    vault: &mut CollateralVault<T>,
    synthetic_type: String,
    amount: u64,
    registry: &SynthRegistry,
    price_info: &PriceInfoObject,
    clock: &Clock,
    ctx: &mut TxContext,
): SyntheticCoin<T>

public fun burn_synthetic<T>(
    vault: &mut CollateralVault<T>,
    synthetic_coin: SyntheticCoin<T>,
    registry: &SynthRegistry,
    price_info: &PriceInfoObject,
    clock: &Clock,
    ctx: &mut TxContext,
): Option<Coin<T>> // Returns collateral if any
```

->

### 3. Synthetic Minting/Burning
```move
public fun mint_synthetic<T>(
    vault: &mut CollateralVault,
    synthetic_type: String,
    amount: u64,
    registry: &SynthRegistry,
    price_info: &PriceInfoObject,
    clock: &Clock,
    ctx: &mut TxContext,
): SyntheticCoin<T>

public fun burn_synthetic<T>(
    vault: &mut CollateralVault,
    synthetic_coin: SyntheticCoin<T>,
    registry: &SynthRegistry,
    price_info: &PriceInfoObject,
    clock: &Clock,
    ctx: &mut TxContext,
): Option<Coin<USDC>> // Returns USDC collateral if any
```
```

```markdown
### 4. Liquidation
```move
public fun liquidate_vault<T>(
    vault: &mut CollateralVault<T>,
    synthetic_type: String,
    liquidation_amount: u64,
    registry: &SynthRegistry,
    price_info: &PriceInfoObject,
    clock: &Clock,
    ctx: &mut TxContext,
): (SyntheticCoin<T>, Coin<T>) // Returns debt repaid, collateral seized
```

->

### 4. Liquidation
```move
public fun liquidate_vault<T>(
    vault: &mut CollateralVault,
    synthetic_type: String,
    liquidation_amount: u64,
    registry: &SynthRegistry,
    price_info: &PriceInfoObject,
    clock: &Clock,
    ctx: &mut TxContext,
): (SyntheticCoin<T>, Coin<USDC>) // Returns debt repaid, USDC collateral seized
```
```

```markdown
### 5. Flash Loan Integration
```move
public fun flash_mint_arbitrage<BaseAsset, QuoteAsset>(
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    vault: &mut CollateralVault<BaseAsset>,
    synthetic_type: String,
    arbitrage_amount: u64,
    registry: &SynthRegistry,
    price_info: &PriceInfoObject,
    clock: &Clock,
    ctx: &mut TxContext,
): FlashLoan // Hot potato for atomic arbitrage
```

->

### 5. Flash Loan Integration
```move
public fun flash_mint_arbitrage<BaseAsset, QuoteAsset>(
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    vault: &mut CollateralVault,
    synthetic_type: String,
    arbitrage_amount: u64,
    registry: &SynthRegistry,
    price_info: &PriceInfoObject,
    clock: &Clock,
    ctx: &mut TxContext,
): FlashLoan // Hot potato for atomic arbitrage
```
```

```markdown
### 1. Collateral Ratio Monitoring
```move
public fun check_vault_health<T>(
    vault: &CollateralVault<T>,
    synthetic_type: String,
    registry: &SynthRegistry,
    price_info: &PriceInfoObject,
    clock: &Clock,
): (u64, bool) // Returns (collateral_ratio, is_liquidatable)
```

->

### 1. Collateral Ratio Monitoring
```move
public fun check_vault_health(
    vault: &CollateralVault,
    synthetic_type: String,
    registry: &SynthRegistry,
    price_info: &PriceInfoObject,
    clock: &Clock,
): (u64, bool) // Returns (collateral_ratio, is_liquidatable)
```
```

```markdown
### 1. Automatic Pool Creation
```move
public fun create_deepbook_pool_for_synthetic(
    synthetic_type: String,
    collateral_type: String,
    registry: &mut SynthRegistry,
    deepbook_registry: &mut Registry,
    creation_fee: Coin<DEEP>,
    ctx: &mut TxContext,
): ID
```

->

### 1. Automatic Pool Creation
```move
public fun create_deepbook_pool_for_synthetic(
    synthetic_type: String,
    registry: &mut SynthRegistry,
    deepbook_registry: &mut Registry,
    creation_fee: Coin<DEEP>,
    ctx: &mut TxContext,
): ID // Returns pool ID for synthetic/USDC pair
```
```

```markdown
### 3. Vault Manager
```typescript
class VaultManager {
    async createVault(collateralType: string): Promise<string>;
    async mintSynthetic(vaultId: string, amount: number): Promise<void>;
    async burnSynthetic(vaultId: string, amount: number): Promise<void>;
    async monitorHealth(vaultId: string): Promise<VaultHealth>;
}
```

->

### 3. Vault Manager
```typescript
class VaultManager {
    async createVault(): Promise<string>; // USDC-only collateral
    async depositCollateral(vaultId: string, usdcAmount: number): Promise<void>;
    async withdrawCollateral(vaultId: string, usdcAmount: number): Promise<void>;
    async mintSynthetic(vaultId: string, syntheticType: string, amount: number): Promise<void>;
    async burnSynthetic(vaultId: string, syntheticType: string, amount: number): Promise<void>;
    async monitorHealth(vaultId: string): Promise<VaultHealth>;
}
```
```

```markdown
## Security Considerations

1. **Oracle Failures**: Multiple price feed validation
2. **Flash Loan Attacks**: Atomic operation constraints
3. **Collateral Volatility**: Dynamic liquidation thresholds
4. **Smart Contract Risks**: Formal verification and audits
5. **Economic Attacks**: Incentive alignment and circuit breakers

->

## AdminCap Explanation

The `AdminCap` is a capability object that grants administrative privileges during the initial protocol setup. It allows the deployer to:

### Initial Setup Functions (Requires AdminCap)
```move
public fun initialize_synthetic_asset(
    registry: &mut SynthRegistry,
    _admin_cap: &AdminCap,
    asset_name: String,
    asset_symbol: String,
    pyth_feed_id: vector<u8>,
    min_collateral_ratio: u64,
    ctx: &mut TxContext,
)

public fun update_global_params(
    registry: &mut SynthRegistry,
    _admin_cap: &AdminCap,
    new_params: GlobalParams,
    ctx: &mut TxContext,
)

public fun emergency_pause(
    registry: &mut SynthRegistry,
    _admin_cap: &AdminCap,
    ctx: &mut TxContext,
)
```

### Making Protocol Immutable
```move
public fun destroy_admin_cap(admin_cap: AdminCap) {
    let AdminCap { id } = admin_cap;
    object::delete(id);
}

// Or transfer to burn address
public fun transfer_admin_to_burn(admin_cap: AdminCap, ctx: &mut TxContext) {
    transfer::public_transfer(admin_cap, @0x0);
}
```

Once the AdminCap is destroyed or transferred to a burn address, the protocol becomes truly immutable and decentralized.

## Security Considerations

1. **Oracle Failures**: Multiple price feed validation
2. **Flash Loan Attacks**: Atomic operation constraints
3. **Collateral Volatility**: Dynamic liquidation thresholds (USDC stability mitigates this)
4. **Smart Contract Risks**: Formal verification and audits
5. **Economic Attacks**: Incentive alignment and circuit breakers
6. **AdminCap Security**: Must be destroyed after deployment to ensure immutability
```

```markdown
## Overview

UnXversal Synthetics enables permissionless creation and trading of synthetic assets backed by collateral, built on top of DeepBook's order book infrastructure. Users can mint synthetic assets by depositing collateral and trade them on DeepBook pools with automatic price feeds from Pyth Network.

->

## Overview

UnXversal Synthetics enables permissionless creation and trading of synthetic assets backed by USDC collateral, built on top of DeepBook's order book infrastructure. Users can mint synthetic assets by depositing USDC and trade them on DeepBook pools with automatic price feeds from Pyth Network.

### Benefits of USDC-Only Collateral

1. **Simplified Risk Management**: No need to manage multiple collateral types with different volatility profiles
2. **Stable Collateral**: USDC's price stability reduces liquidation risk and provides predictable collateral ratios
3. **Reduced Complexity**: Single collateral type simplifies vault management, liquidation logic, and user experience
4. **Better Capital Efficiency**: Users don't need to manage multiple collateral balances
5. **Unified Liquidity**: All synthetic assets trade against USDC, creating deeper liquidity pools
6. **Easier Oracle Integration**: Only need USDC price feeds for collateral valuation (typically $1.00)
```

## Updated Design Summary

I've updated the UnXversal Synthetics design to use **USDC-only collateral** and explained the **AdminCap**. Here are the key changes:

### USDC-Only Collateral Benefits:

1. **Simplified Architecture**: Removed all generic type parameters for collateral types
2. **Reduced Risk**: USDC's stability eliminates collateral volatility concerns
3. **Better UX**: Users only need to manage one collateral type
4. **Unified Liquidity**: All synthetics trade against USDC, creating deeper pools
5. **Easier Implementation**: Single collateral type reduces complexity across the entire system

### AdminCap Explanation:

The `AdminCap` is a **capability object** that grants administrative privileges during initial protocol setup. It allows the deployer to:

- **Initialize synthetic assets** with their Pyth price feeds
- **Update global parameters** like collateral ratios and fees
- **Emergency pause** the protocol if needed during early stages

**Critical for Immutability**: Once the protocol is deployed and tested, the AdminCap must be **destroyed** or **transferred to a burn address** to make the protocol truly immutable and decentralized, as you specified for v1.

### Key Architecture Improvements:

- **Single CollateralVault type**: No more generic parameters
- **Simplified Events**: All events reference USDC directly
- **Cleaner Functions**: Removed complexity around multiple collateral types
- **Better Risk Management**: Focused on synthetic asset price volatility, not collateral volatility

This design is much cleaner and easier to implement while maintaining all the core functionality. The USDC-only approach is actually used by many successful synthetic asset protocols because it provides the right balance of simplicity and functionality.

Ready to move on to the **Spot DEX** design next, or would you like me to refine any aspect of the synthetics protocol?

---

**User**

what is a stability_fee?

---

**Cursor**

A **stability fee** is an annual interest rate charged on outstanding synthetic debt to maintain the protocol's stability and peg. Here's how it works in our UnXversal Synthetics protocol:

## What is a Stability Fee?

The stability fee is a **continuous interest rate** applied to the synthetic debt in a user's vault. It serves multiple purposes:

### 1. **Peg Maintenance**
- When synthetic assets trade below their target price, the stability fee can be increased to make borrowing more expensive
- This reduces supply of new synthetics and encourages burning existing ones
- Helps maintain the peg to the underlying asset price

### 2. **Protocol Revenue**
- Generates ongoing revenue for the protocol
- Fees collected are used for UNXV buyback and burn
- Funds protocol operations and development

### 3. **Risk Management**
- Compensates the protocol for the risk of providing synthetic exposure
- Acts as a buffer against oracle failures or market volatility
- Encourages active vault management

## How It Works in Practice

```move
struct GlobalParams has store {
    stability_fee: u64,            // Annual percentage in basis points (200 = 2%)
    // ... other params
}
```

### Example Calculation:
- User mints 1000 sBTC worth $50,000 USD
- Stability fee: 2% annually (200 basis points)
- **Daily accrual**: $50,000 × 0.02 ÷ 365 = ~$2.74 per day
- **Monthly accrual**: ~$83.33 per month

### Implementation:
```move
// Calculate accrued stability fee
public fun calculate_stability_fee(
    vault: &CollateralVault,
    synthetic_type: String,
    registry: &SynthRegistry,
    clock: &Clock,
): u64 {
    let debt_amount = vault.synthetic_debt[synthetic_type];
    let time_elapsed = clock.timestamp_ms() - vault.last_update;
    let annual_rate = registry.global_params.stability_fee;
    
    // Calculate compounded interest
    let fee_owed = debt_amount * annual_rate * time_elapsed / (365 * 24 * 3600 * 1000 * 10000);
    fee_owed
}
```

## When Stability Fees Are Charged

1. **On Vault Updates**: Any time a user interacts with their vault (mint, burn, withdraw)
2. **On Liquidation**: Accrued fees are added to the debt before liquidation
3. **Periodic Settlements**: Background processes can trigger fee updates

## Payment and Collection

```move
public fun settle_stability_fee(
    vault: &mut CollateralVault,
    synthetic_type: String,
    registry: &SynthRegistry,
    clock: &Clock,
) {
    let fee_owed = calculate_stability_fee(vault, synthetic_type, registry, clock);
    
    // Add fee to synthetic debt (compounds the position)
    vault.synthetic_debt[synthetic_type] = vault.synthetic_debt[synthetic_type] + fee_owed;
    vault.last_update = clock.timestamp_ms();
    
    // Emit fee collection event
    event::emit(StabilityFeeAccrued {
        vault_id: object::id(vault),
        synthetic_type,
        fee_amount: fee_owed,
        timestamp: clock.timestamp_ms(),
    });
}
```

## Dynamic Fee Adjustment

The stability fee can be adjusted based on market conditions:

```move
public fun update_stability_fee(
    registry: &mut SynthRegistry,
    _admin_cap: &AdminCap,  // Only admin can adjust (before AdminCap destruction)
    new_stability_fee: u64,
    ctx: &mut TxContext,
) {
    registry.global_params.stability_fee = new_stability_fee;
    
    event::emit(StabilityFeeUpdated {
        old_fee: registry.global_params.stability_fee,
        new_fee: new_stability_fee,
        timestamp: ctx.timestamp(),
    });
}
```

## Comparison to Other Protocols

- **MakerDAO**: Uses stability fees on DAI (ranges from 0.5% to 8%+ depending on collateral type)
- **Synthetix**: Uses different mechanisms but similar concept with debt decay
- **Liquity**: Uses one-time borrowing fees instead of ongoing stability fees

## Benefits for UnXversal Protocol

1. **Sustainable Revenue**: Provides ongoing income stream for UNXV burns
2. **Market Balancing**: Helps maintain synthetic asset pegs
3. **Risk Premium**: Compensates for oracle and market risks
4. **User Incentives**: Encourages efficient capital use and debt management

The 2% annual stability fee is competitive with other DeFi protocols and provides a steady revenue stream while not being prohibitively expensive for users.

```plaintext
struct GlobalParams has store {
    stability_fee: u64,            // Annual percentage in basis points (200 = 2%)
    // ... other params
}
```

```plaintext
// Calculate accrued stability fee
public fun calculate_stability_fee(
    vault: &CollateralVault,
    synthetic_type: String,
    registry: &SynthRegistry,
    clock: &Clock,
): u64 {
    let debt_amount = vault.synthetic_debt[synthetic_type];
    let time_elapsed = clock.timestamp_ms() - vault.last_update;
    let annual_rate = registry.global_params.stability_fee;
    
    // Calculate compounded interest
    let fee_owed = debt_amount * annual_rate * time_elapsed / (365 * 24 * 3600 * 1000 * 10000);
    fee_owed
}
```

```plaintext
public fun settle_stability_fee(
    vault: &mut CollateralVault,
    synthetic_type: String,
    registry: &SynthRegistry,
    clock: &Clock,
) {
    let fee_owed = calculate_stability_fee(vault, synthetic_type, registry, clock);
    
    // Add fee to synthetic debt (compounds the position)
    vault.synthetic_debt[synthetic_type] = vault.synthetic_debt[synthetic_type] + fee_owed;
    vault.last_update = clock.timestamp_ms();
    
    // Emit fee collection event
    event::emit(StabilityFeeAccrued {
        vault_id: object::id(vault),
        synthetic_type,
        fee_amount: fee_owed,
        timestamp: clock.timestamp_ms(),
    });
}
```

```plaintext
public fun update_stability_fee(
    registry: &mut SynthRegistry,
    _admin_cap: &AdminCap,  // Only admin can adjust (before AdminCap destruction)
    new_stability_fee: u64,
    ctx: &mut TxContext,
) {
    registry.global_params.stability_fee = new_stability_fee;
    
    event::emit(StabilityFeeUpdated {
        old_fee: registry.global_params.stability_fee,
        new_fee: new_stability_fee,
        timestamp: ctx.timestamp(),
    });
}
```

