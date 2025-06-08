# unxversal DAO Contracts

This directory contains the smart contracts that power the unxversal DAO governance system.

## Contracts

### UNXV.sol
- ERC20 governance token with EIP-2612 permit functionality
- Fixed supply of 1 billion tokens
- Minting can be permanently disabled by owner

### VeUNXV.sol
- Voting escrow contract for UNXV tokens
- Users can lock UNXV for 1-4 years to get veUNXV (voting power)
- Voting power decays linearly over time
- Supports delegation to other addresses

### GaugeController.sol
- Manages emission weights for different protocol components
- veUNXV holders can vote on gauge weights
- Supports multiple gauge types (DEX, LEND, SYNTH, PERPS)
- Weekly emission schedule with decay

### UnxversalGovernor.sol
- Main governance contract based on OpenZeppelin Governor
- Proposal threshold: 1% of circulating veUNXV
- Quorum: 4% of total supply
- Voting period: ~1 week
- Timelock: 48 hours

### Treasury.sol
- Manages protocol fees and assets
- USDC-denominated fee collection
- Controlled by governance through timelock
- Supports whitelisted tokens

### GuardianPause.sol
- Emergency pause mechanism for critical contracts
- 3-of-5 multisig guardian system
- 7-day maximum pause duration
- Revocable by DAO after Year 1

## Deployment

The contracts should be deployed in the following order:

1. Deploy UNXV token
2. Deploy VeUNXV with UNXV address
3. Deploy TimelockController with 48h delay
4. Deploy UnxversalGovernor with UNXV and Timelock addresses
5. Deploy GaugeController with UNXV and VeUNXV addresses
6. Deploy Treasury
7. Deploy GuardianPause with initial guardians
8. Setup phase:
   - Transfer Treasury ownership to Timelock
   - Finish UNXV minting
   - Set initial gauge types and weights

Use the deployment script at `scripts/deploy-dao.ts`:

```bash
npx hardhat run scripts/deploy-dao.ts --network peaq
```

## Configuration

Create a `.env` file with:

```
PRIVATE_KEY=your_deployer_private_key
PEAQ_RPC_URL=your_peaq_rpc_url
REPORT_GAS=true
```

## Testing

```bash
npx hardhat test
```

## Security

- All contracts are non-upgradeable for maximum security
- Critical parameter changes go through timelock
- Emergency pause available through guardian multisig
- Extensive test coverage required before mainnet deployment

## License

MIT 