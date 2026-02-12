#!/bin/bash
# Martingale strategy runner for Clawdice on Base Sepolia

set -e

PRIVATE_KEY=${PRIVATE_KEY:?'Set PRIVATE_KEY env var'}
CLAWDICE="0xd64135C2AeFA49f75421D07d5bb15e8A5DADfC35"
RPC="https://sepolia.base.org"
CAST=~/.foundry/bin/cast

# Martingale params
INITIAL_BET="1000000000000000000"  # 1 CLAW (18 decimals)
ODDS="500000000000000000"  # 50% (0.5e18)
MAX_ROUNDS=${1:-10}

current_bet=$INITIAL_BET
total_wagered=0
total_won=0
wins=0
losses=0
streak=0

echo "=== Clawdice Martingale Strategy ==="
echo "Initial bet: 1 CLAW"
echo "Odds: 50% (2x payout)"
echo "Max rounds: $MAX_ROUNDS"
echo ""

for ((round=1; round<=MAX_ROUNDS; round++)); do
    echo "--- Round $round ---"
    echo "Bet amount: $(echo "scale=2; $current_bet / 1000000000000000000" | bc) CLAW"

    # Place bet
    echo "Placing bet..."
    result=$($CAST send $CLAWDICE "placeBet(uint256,uint64)" $current_bet $ODDS \
        --rpc-url $RPC \
        --private-key $PRIVATE_KEY \
        --json 2>&1)

    tx_hash=$(echo $result | jq -r '.transactionHash')
    echo "TX: $tx_hash"

    # Get bet ID from logs
    bet_id=$($CAST receipt $tx_hash --rpc-url $RPC --json | jq -r '.logs[1].topics[1]' | $CAST to-dec)
    echo "Bet ID: $bet_id"

    # Wait for next block
    echo "Waiting for next block..."
    sleep 4

    # Compute result (view function)
    result=$($CAST call $CLAWDICE "computeResult(uint256)(bool,uint256)" $bet_id --rpc-url $RPC 2>&1)
    won=$(echo $result | awk '{print $1}')
    payout=$(echo $result | awk '{print $2}')

    echo "Result: won=$won, payout=$payout"

    # Claim the bet
    echo "Claiming..."
    $CAST send $CLAWDICE "claim(uint256)" $bet_id \
        --rpc-url $RPC \
        --private-key $PRIVATE_KEY \
        --json > /dev/null 2>&1

    total_wagered=$((total_wagered + current_bet))

    if [ "$won" = "true" ]; then
        echo "WIN!"
        wins=$((wins + 1))
        total_won=$((total_won + payout))
        streak=$((streak > 0 ? streak + 1 : 1))
        # Reset to initial bet after win
        current_bet=$INITIAL_BET
    else
        echo "LOSS"
        losses=$((losses + 1))
        streak=$((streak < 0 ? streak - 1 : -1))
        # Double the bet after loss (martingale)
        current_bet=$((current_bet * 2))
    fi

    echo "Streak: $streak"
    echo ""
done

echo "=== Final Results ==="
echo "Rounds: $MAX_ROUNDS"
echo "Wins: $wins"
echo "Losses: $losses"
echo "Total wagered: $(echo "scale=2; $total_wagered / 1000000000000000000" | bc) CLAW"
echo "Total won: $(echo "scale=2; $total_won / 1000000000000000000" | bc) CLAW"
profit=$((total_won - total_wagered))
echo "Net P&L: $(echo "scale=2; $profit / 1000000000000000000" | bc) CLAW"
