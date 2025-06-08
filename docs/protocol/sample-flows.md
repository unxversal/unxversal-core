# Unxversal Protocol - Sample Interaction Flows

## Introduction

This document demonstrates real-world scenarios showing how the different Unxversal protocols interact with each other on-chain. Each flow shows the complete transaction sequence, contract interactions, and cross-protocol integrations.

## Flow 1: Cross-Protocol Arbitrage

**Scenario**: Price discrepancy between synthetic assets and spot prices creates arbitrage opportunity

A user spots that sBTC is trading at $49,000 on the DEX while the oracle price is $50,000. They can profit by:

1. **Flash loan** $100,000 USDC from Lend protocol
2. **Buy sBTC** on DEX at discounted price ($98,000 for 2 sBTC)
3. **Burn sBTC** in Synth protocol at oracle price ($100,000 USDC)
4. **Repay flash loan** and keep profit (~$1,920 after fees)

This demonstrates:
- Flash loan integration between protocols
- Price arbitrage opportunities
- Automatic oracle-based settlement
- Fee-efficient execution

## Flow 2: Leveraged Yield Farming

**Scenario**: User leverages ETH position across multiple protocols

A user with 10 ETH wants enhanced yield:

1. **Supply ETH** to Lend protocol (receive uETH)
2. **Borrow USDC** against ETH collateral  
3. **Mint sETH** using USDC as collateral
4. **Short ETH perps** to hedge synthetic exposure
5. **Net result**: Leveraged ETH exposure with yield from all protocols

## Flow 3: Options Market Making

**Scenario**: Market maker creates option series and hedges with perpetuals

1. **Write call options** at multiple strikes
2. **List options** on DEX for trading
3. **Hedge delta exposure** using perps
4. **Collect premiums** and manage risk
5. **Rebalance hedges** as market moves

## Flow 4: Flash Liquidation

**Scenario**: Bot liquidates underwater positions across protocols

1. **Detect liquidation** opportunity after price movement
2. **Flash loan capital** for liquidation
3. **Execute liquidations** across Synth, Lend, and Perps
4. **Convert seized collateral** to USDC via DEX
5. **Repay loan and profit** from liquidation bonuses

## Flow 5: DAO Governance

**Scenario**: Community reduces DEX fees through governance

1. **Propose parameter change** (reduce taker fee 6→5 bps)
2. **Vote with veUNXV** during 5-day voting period
3. **Queue execution** in 48-hour timelock
4. **Execute change** after timelock expires
5. **Fee update** becomes active across protocol

## Flow 6: Cross-Chain Oracle Updates

**Scenario**: Price update flows from Ethereum to Peaq

1. **Chainlink price change** triggers update threshold
2. **LayerZero message** sends price to Peaq
3. **Oracle update** received and validated
4. **All protocols** use new price for calculations
5. **Risk management** responds to price changes

These flows demonstrate the deep integration and capital efficiency possible when protocols share infrastructure and work together as a unified ecosystem. 