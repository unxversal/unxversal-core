# Unxversal Protocol - Directory Structure

## Project Overview
The unxversal protocol is a comprehensive DeFi suite deployed on Peaq EVM, featuring DEX, synthetic assets, lending, perpetuals, options, and governance protocols. All contracts are production-ready and audited for deployment.

```
unxversal/
├── README.md                          # Project overview and setup instructions
├── package.json                       # Node.js dependencies and scripts
├── hardhat.config.js                  # Hardhat configuration for Peaq EVM
├── .env.example                       # Environment variables template
├── .gitignore                         # Git ignore patterns
│
├── packages/
│   └── contracts/                     # Smart contracts package
│       ├── package.json               # Contract package dependencies
│       ├── hardhat.config.js          # Contract-specific Hardhat config
│       │
│       ├── common/                    # Shared utilities and libraries
│       │   ├── interfaces/
│       │   │   ├── IOracleRelayer.sol # LayerZero oracle interface
│       │   │   ├── IPermit2.sol       # Permit2 interface for gasless approvals
│       │   │   └── IERC5805.sol       # Governance voting interface
│       │   ├── libraries/
│       │   │   ├── Math.sol           # Safe math operations
│       │   │   ├── FixedPoint.sol     # Fixed-point arithmetic
│       │   │   └── SafeDecimalMath.sol # Decimal math utilities
│       │   └── access/
│       │       └── ProtocolAdminAccess.sol # Admin role management
│       │
│       ├── dex/                       # Order-book DEX protocol
│       │   ├── OrderNFT.sol           # ERC-721 for order management
│       │   ├── DexFeeSwitch.sol       # Fee collection and distribution
│       │   ├── interfaces/
│       │   │   ├── IOrderNFT.sol      # Order NFT interface
│       │   │   └── IDexFeeSwitch.sol  # Fee switch interface
│       │   └── utils/
│       │       └── PermitHelper.sol   # ERC-2612/Permit2 integration
│       │
│       ├── synth/                     # Synthetic assets protocol
│       │   ├── USDCVault.sol          # USDC collateral vault
│       │   ├── SynthLiquidationEngine.sol # Liquidation engine
│       │   ├── interfaces/
│       │   │   └── IUSDCVault.sol     # Vault interface
│       │   └── oracles/
│       │       └── OracleRelayerDst.sol # LayerZero oracle receiver
│       │
│       ├── lend/                      # Lending/borrowing protocol
│       │   ├── CorePool.sol           # Main lending pool
│       │   ├── uToken.sol             # Interest-bearing receipt tokens
│       │   ├── LendRiskController.sol # Risk management
│       │   ├── LendLiquidationEngine.sol # Liquidation engine
│       │   ├── interfaces/
│       │   │   ├── ICorePool.sol      # Core pool interface
│       │   │   ├── ILendRiskController.sol # Risk controller interface
│       │   │   └── IFlashLoanReceiver.sol # Flash loan interface
│       │   └── interestModels/
│       │       ├── IInterestRateModel.sol # Interest rate interface
│       │       └── PiecewiseLinearInterestRateModel.sol # Rate model impl
│       │
│       ├── perps/                     # Perpetual futures protocol
│       │   ├── PerpClearingHouse.sol  # Central clearing house
│       │   ├── PerpLiquidationEngine.sol # Liquidation engine
│       │   ├── interfaces/
│       │   │   ├── IPerpClearingHouse.sol # Clearing house interface
│       │   │   ├── IPerpsFeeCollector.sol # Fee collector interface
│       │   │   └── ISpotPriceOracle.sol # Spot price oracle interface
│       │   └── libraries/
│       │       └── FundingRateLib.sol # Funding rate calculations
│       │
│       ├── options/                   # Options trading protocol
│       │   ├── OptionNFT.sol          # ERC-721 option contracts
│       │   ├── CollateralVault.sol    # Collateral management
│       │   ├── OptionFeeSwitch.sol    # Fee collection and auto-swap
│       │   ├── OptionsAdmin.sol       # Administrative functions
│       │   └── interfaces/
│       │       ├── IOptionNFT.sol     # Option NFT interface
│       │       └── ICollateralVault.sol # Collateral vault interface
│       │
│       ├── dao/                       # Governance and DAO contracts
│       │   ├── UNXV.sol               # ERC-20 governance token
│       │   ├── veUNXV.sol             # Voting escrow mechanism
│       │   ├── UnxversalGovernor.sol  # OpenZeppelin Governor
│       │   ├── Treasury.sol           # Protocol treasury
│       │   ├── GaugeController.sol    # Emissions distribution
│       │   ├── GuardianPause.sol      # Emergency pause mechanism
│       │   ├── TimelockController.sol # Governance timelock
│       │   └── interfaces/
│       │       ├── IVeUNXV.sol        # Voting escrow interface
│       │       ├── ITreasury.sol      # Treasury interface
│       │       └── IGaugeController.sol # Gauge controller interface
│       │
│       ├── ethereum/                  # Ethereum L1 contracts (oracle source)
│       │   └── OracleRelayerSrc.sol   # LayerZero oracle sender
│       │
│       └── scripts/                   # Deployment and utility scripts
│           ├── deploy/
│           │   ├── 01-deploy-common.js # Common contracts deployment
│           │   ├── 02-deploy-dex.js   # DEX protocol deployment
│           │   ├── 03-deploy-synth.js # Synth protocol deployment
│           │   ├── 04-deploy-lend.js  # Lending protocol deployment
│           │   ├── 05-deploy-perps.js # Perps protocol deployment
│           │   ├── 06-deploy-options.js # Options protocol deployment
│           │   ├── 07-deploy-dao.js   # DAO contracts deployment
│           │   └── 08-configure-all.js # Post-deployment configuration
│           ├── verify/
│           │   └── verify-contracts.js # Contract verification on block explorer
│           ├── upgrade/
│           │   └── upgrade-proxies.js # Proxy upgrade scripts (if applicable)
│           └── utils/
│               ├── network-config.js  # Network-specific configurations
│               ├── constants.js       # Protocol constants and addresses
│               └── helpers.js         # Deployment helper functions
│
├── test/                              # Test suite
│   ├── unit/                          # Unit tests for individual contracts
│   │   ├── dex/
│   │   │   ├── OrderNFT.test.js
│   │   │   └── DexFeeSwitch.test.js
│   │   ├── synth/
│   │   │   ├── USDCVault.test.js
│   │   │   └── SynthLiquidation.test.js
│   │   ├── lend/
│   │   │   ├── CorePool.test.js
│   │   │   ├── uToken.test.js
│   │   │   └── LendRiskController.test.js
│   │   ├── perps/
│   │   │   ├── PerpClearingHouse.test.js
│   │   │   └── FundingRateLib.test.js
│   │   ├── options/
│   │   │   ├── OptionNFT.test.js
│   │   │   └── CollateralVault.test.js
│   │   └── dao/
│   │       ├── UNXV.test.js
│   │       ├── veUNXV.test.js
│   │       ├── UnxversalGovernor.test.js
│   │       └── GaugeController.test.js
│   ├── integration/                   # Integration tests between protocols
│   │   ├── dex-synth-integration.test.js
│   │   ├── lend-liquidation.test.js
│   │   ├── perps-funding.test.js
│   │   ├── options-exercise.test.js
│   │   └── dao-governance.test.js
│   ├── e2e/                          # End-to-end user journey tests
│   │   ├── user-trading-journey.test.js
│   │   ├── liquidation-scenarios.test.js
│   │   └── governance-proposals.test.js
│   ├── fixtures/                     # Test fixtures and mock data
│   │   ├── tokens.js                 # Mock token contracts
│   │   ├── oracles.js                # Mock oracle data
│   │   └── scenarios.js              # Test scenario data
│   └── utils/                        # Test utilities
│       ├── helpers.js                # Test helper functions
│       ├── constants.js              # Test constants
│       └── setup.js                  # Test environment setup
│
├── docs/                             # Documentation
│   ├── protocol/
│   │   ├── unxversal-protocol.md     # Comprehensive protocol documentation
│   │   ├── dex-overview.md           # DEX protocol details
│   │   ├── synth-overview.md         # Synthetic assets documentation
│   │   ├── lend-overview.md          # Lending protocol documentation
│   │   ├── perps-overview.md         # Perpetuals documentation
│   │   ├── options-overview.md       # Options protocol documentation
│   │   └── dao-overview.md           # Governance documentation
│   ├── deployment/
│   │   ├── deployment-guide.md       # Step-by-step deployment guide
│   │   ├── network-setup.md          # Peaq EVM network setup
│   │   └── verification-guide.md     # Contract verification guide
│   ├── integration/
│   │   ├── frontend-integration.md   # Frontend integration guide
│   │   ├── api-reference.md          # API documentation
│   │   └── sdk-usage.md              # SDK usage examples
│   └── security/
│       ├── audit-reports/            # Security audit reports
│       ├── security-practices.md     # Security best practices
│       └── emergency-procedures.md   # Emergency response procedures
│
├── config/                           # Configuration files
│   ├── networks/
│   │   ├── peaq-mainnet.json         # Peaq mainnet configuration
│   │   ├── peaq-testnet.json         # Peaq testnet (agung) configuration
│   │   └── ethereum-mainnet.json     # Ethereum mainnet (for oracle source)
│   ├── deployments/
│   │   ├── peaq-mainnet/             # Mainnet deployment addresses
│   │   └── peaq-testnet/             # Testnet deployment addresses
│   └── tokens/
│       ├── peaq-tokens.json          # Peaq network token addresses
│       └── supported-assets.json     # Supported assets configuration
│
├── sdk/                              # TypeScript SDK (if included)
│   ├── src/
│   │   ├── contracts/                # Contract interfaces and ABIs
│   │   ├── dex/                      # DEX SDK functionality
│   │   ├── synth/                    # Synth SDK functionality
│   │   ├── lend/                     # Lending SDK functionality
│   │   ├── perps/                    # Perps SDK functionality
│   │   ├── options/                  # Options SDK functionality
│   │   ├── dao/                      # DAO SDK functionality
│   │   └── utils/                    # SDK utilities
│   ├── package.json                  # SDK package configuration
│   └── README.md                     # SDK documentation
│
├── artifacts/                        # Compiled contract artifacts (auto-generated)
├── cache/                            # Hardhat cache (auto-generated)
├── coverage/                         # Test coverage reports (auto-generated)
└── node_modules/                     # Dependencies (auto-generated)
```

## Key Features by Protocol

### 🔄 DEX (Decentralized Exchange)
- **Order-book**: NFT-encoded orders with off-chain discovery, on-chain settlement
- **Fee Structure**: 6 bps taker fee with volume-based tiers and UNXV discounts
- **TWAP Support**: Time-weighted average price orders with validation
- **MEV Protection**: Relayer fee sharing and batch order processing

### 🏭 Synth (Synthetic Assets)
- **USDC Collateral**: Mint synthetic assets (sBTC, sETH, sSOL) backed by USDC
- **LayerZero Oracle**: Cross-chain price feeds from Polygon to Peaq
- **Liquidation**: 12% penalty with automated liquidation bots
- **Fee Structure**: 15 bps mint, 8 bps burn fees

### 🏦 Lend (Lending Protocol)
- **Permissionless**: Any ERC-20 can be used as collateral or borrowed
- **Flash Loans**: Uncollateralized loans with 8 bps fee
- **Interest Models**: Piecewise linear interest rate curves
- **Cross-Chain**: Oracle-based asset pricing with LayerZero integration

### ⚡ Perps (Perpetual Futures)
- **Cross-Margin**: Up to 25x leverage with shared collateral
- **Funding Rates**: Hourly funding based on mark vs index price divergence
- **Order Book**: Same infrastructure as spot DEX
- **Risk Management**: Dynamic position limits and liquidation engine

### 📈 Options (Options Trading)
- **NFT-Based**: Each option is an ERC-721 token
- **European Style**: Options exercisable only at expiration
- **Auto-Settlement**: Automatic exercise for in-the-money options
- **Collateral Efficiency**: Optimal collateral requirements for writers

### 🏛️ DAO (Governance)
- **UNXV Token**: 1B fixed supply with 35% founder allocation (4-year vest)
- **veUNXV**: Voting escrow with 1-4 year lock periods
- **Gauge System**: Community-directed emissions to protocol modules
- **Treasury**: USDC-denominated with auto-swap functionality
- **Timelock**: 48-hour execution delay for security

## Development Setup

### Prerequisites
```bash
node >= 16.0.0
npm >= 8.0.0
```

### Installation
```bash
git clone https://github.com/unxversal/unxversal-protocol
cd unxversal-protocol
npm install
cd packages/contracts
npm install
```

### Environment Configuration
```bash
cp .env.example .env
# Edit .env with your configuration:
# - PEAQ_RPC_URL=https://peaq.api.onfinality.io/public
# - ETHEREUM_RPC_URL=https://mainnet.infura.io/v3/YOUR_KEY
# - PRIVATE_KEY=your_deployer_private_key
# - ETHERSCAN_API_KEY=your_etherscan_key (for verification)
```

### Network Configuration
The project is configured for Peaq EVM with the following networks:

**Peaq Mainnet:**
- Chain ID: 3338
- RPC: https://peaq.api.onfinality.io/public
- Explorer: https://peaq.subscan.io/

**Peaq Testnet (Agung):**
- Chain ID: 9990
- RPC: https://wsspc1-qa.agung.peaq.network
- Explorer: https://agung.subscan.io/

### Deployment Commands
```bash
# Deploy all contracts to Peaq testnet
npx hardhat run scripts/deploy/01-deploy-common.js --network peaq-testnet

# Deploy specific protocol
npx hardhat run scripts/deploy/02-deploy-dex.js --network peaq-testnet

# Verify contracts
npx hardhat run scripts/verify/verify-contracts.js --network peaq-testnet

# Run tests
npx hardhat test

# Run coverage
npx hardhat coverage
```

## Protocol Integration Notes

All protocols are designed to work together:
- **Fees**: All denominated in USDC with auto-swap functionality
- **Oracle**: Shared LayerZero oracle infrastructure
- **Liquidation**: Cross-protocol liquidation bots
- **Governance**: Unified DAO controls all protocol parameters
- **Treasury**: Centralized fee collection and revenue distribution 