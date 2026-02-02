# Clawsino

Provably fair on-chain dice game with ERC-4626 staking vault.

## Overview

Clawsino is a Satoshi Dice-style betting protocol where:
- Players bet ETH with customizable odds (1% to 99%)
- Randomness derived from future block hash (commit-reveal pattern)
- House bank powered by LP stakers via ERC-4626 vault
- Kelly Criterion ensures safe maximum bet sizes
- 1% house edge (configurable)

## How It Works

### Betting

1. **Place Bet**: Player calls `placeBet(odds)` with ETH
   - Bet recorded at block N
   - Funds held in contract

2. **Result**: Determined by block N+1 hash (unknown at bet time)
   - Block N+1 gets mined after the bet
   - On claim: `random = keccak256(betId, blockhash(N+1))`
   - betId acts as nonce ensuring unique results per bet
   - If `random < adjustedOdds` → WIN

3. **Claim**: Winner calls `claim(betId)` within 256 blocks
   - Payout = betAmount / targetOdds
   - e.g., 1 ETH at 50% odds = 2 ETH payout

4. **Expiry**: Unclaimed bets after ~1 hour are swept
   - Funds go to house pool

### Odds & Payouts

| Target Odds | Win Chance* | Payout | Max Bet (10 ETH pool) |
|-------------|-------------|--------|----------------------|
| 50% | 49.5% | 2x | 0.1 ETH |
| 25% | 24.75% | 4x | 0.033 ETH |
| 10% | 9.9% | 10x | 0.011 ETH |

*Adjusted for 1% house edge

### Kelly Criterion

Max bet is calculated to prevent house ruin:
```
maxBet = (houseBalance × houseEdge) / (multiplier - 1)
```

This ensures the house has positive expected value even with variance.

## Staking (ERC-4626)

### What is ERC-4626?

ERC-4626 is the "Tokenized Vault Standard" - an extension of ERC-20 that represents shares in an underlying asset pool. Unlike plain ERC-20 tokens where 1 token always equals 1 token, ERC-4626 shares represent a proportional claim on a changing pool of assets.

### How clawETH Works

```
Alice stakes 10 ETH when pool = 100 ETH
→ Gets 10 clawETH shares (10% of pool)

House wins 10 ETH from bets
→ Pool now 110 ETH, still 100 shares
→ Each share worth 1.1 ETH

Alice unstakes her 10 shares
→ Receives 11 ETH (10% of 110 ETH)
```

### Why ERC-4626?

1. **Automatic accounting** - Share price adjusts with house P&L
2. **Composability** - Works with any DeFi protocol that supports ERC-4626
3. **Standardized interface** - `deposit()`, `withdraw()`, `convertToShares()`, `convertToAssets()`

### Uniswap & DeFi Integration

clawETH is a standard ERC-20 token, so it works with:
- **Uniswap**: Create clawETH/ETH or clawETH/USDC pools
- **Aave/Compound**: Could be used as collateral (if listed)
- **Yield aggregators**: Auto-compound strategies

**Note for LPs**: clawETH's underlying value changes with house performance. In a clawETH/ETH pool:
- House wins → clawETH appreciates vs ETH → arbitrage buys clawETH
- House loses → clawETH depreciates → arbitrage sells clawETH

This creates interesting dynamics for AMM liquidity providers.

## Contracts

| Contract | Description |
|----------|-------------|
| `Clawsino.sol` | Main game logic, betting, claims |
| `ClawsinoVault.sol` | ERC-4626 staking vault (clawETH) |
| `BetMath.sol` | Payout calculations, randomness |
| `KellyCriterion.sol` | Max bet calculations |

## Installation

```bash
# Clone
git clone https://github.com/trifle-labs/clawsino
cd clawsino

# Install dependencies
forge install

# Build
forge build

# Test
forge test
```

## SDK

```bash
npm install @trifle-labs/clawsino
```

```typescript
import { Clawsino } from '@trifle-labs/clawsino';

const clawsino = new Clawsino({
  chain: mainnet,
  clawsinoAddress: '0x...',
  vaultAddress: '0x...',
  account: privateKeyToAccount(key),
});

// Place bet (0.1 ETH at 50% odds)
const { betId } = await clawsino.placeBet({
  amount: parseEther('0.1'),
  odds: 0.5
});

// Check result after next block
const result = await clawsino.computeResult(betId);
if (result.won) {
  await clawsino.claim(betId);
}

// Stake in vault
await clawsino.vault.stake('1'); // 1 ETH
```

## CLI

```bash
# Install
npm install -g @trifle-labs/clawsino-cli

# Place bet
clawsino bet 0.1 0.5  # 0.1 ETH at 50% odds

# Check status
clawsino status 123

# Claim winnings
clawsino claim 123

# Stake
clawsino stake 1.0

# Check balance
clawsino balance

# Contract info
clawsino info
```

## Security

- **Reentrancy**: Protected via OpenZeppelin ReentrancyGuard
- **Randomness**: Future blockhash (can't be predicted or manipulated cheaply)
- **Bet limits**: Kelly Criterion prevents house ruin
- **Expiry**: Unclaimed bets swept after 1 hour

### Known Limitations

- Block proposers could theoretically manipulate results, but the economic cost exceeds reasonable bet sizes
- Blockhash only available for 256 blocks - must claim within ~1 hour

## Deployments

| Network | Clawsino | ClawsinoVault |
|---------|----------|---------------|
| Mainnet | TBD | TBD |
| Sepolia | TBD | TBD |
| Base | TBD | TBD |

## License

MIT

## Links

- [Specification](./SPEC.md)
- [Agent Skill](./skills/clawsino/SKILL.md)
- [ERC-4626 Standard](https://eips.ethereum.org/EIPS/eip-4626)
