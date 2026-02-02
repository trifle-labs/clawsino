// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IClawsino.sol";
import "./libraries/BetMath.sol";
import "./libraries/KellyCriterion.sol";

interface IClawsinoVault {
    function totalAssets() external view returns (uint256);
    function withdrawForPayout(uint256 amount) external;
}

/// @title Clawsino
/// @notice Provably fair on-chain dice game with commit-reveal pattern
/// @dev Uses future blockhash for randomness, Kelly Criterion for bet limits
contract Clawsino is IClawsino, ReentrancyGuard, Ownable {
    using BetMath for *;
    using KellyCriterion for *;

    uint256 public constant MIN_BET = 0.001 ether;
    uint256 public constant EXPIRY_BLOCKS = 300; // ~1 hour on mainnet
    uint256 public constant BLOCKHASH_LOOKBACK = 256;

    address public immutable vault;
    uint256 public houseEdgeE18 = 0.01e18; // 1% default

    uint256 public nextBetId = 1;
    mapping(uint256 => Bet) public bets;

    // Queue for expired bets that need sweeping
    uint256[] public pendingBetIds;
    mapping(uint256 => uint256) public pendingBetIndex; // betId -> index in pendingBetIds + 1 (0 means not in queue)

    constructor(address _vault) Ownable(msg.sender) {
        require(_vault != address(0), "Invalid vault");
        vault = _vault;
    }

    /// @notice Place a bet with specified odds
    /// @param targetOddsE18 Target win probability (18 decimals)
    /// @return betId The ID of the placed bet
    function placeBet(uint64 targetOddsE18) external payable nonReentrant returns (uint256 betId) {
        // Auto-sweep up to 5 expired bets before processing new bet
        _sweepExpiredInternal(5);

        require(msg.value >= MIN_BET, "Bet too small");
        BetMath.validateOdds(targetOddsE18);

        uint256 bankroll = _getHouseBalance();
        uint256 maxBet = KellyCriterion.calculateMaxBet(bankroll, targetOddsE18, houseEdgeE18);
        require(msg.value <= maxBet, "Bet exceeds max");

        betId = nextBetId++;

        bets[betId] = Bet({
            player: msg.sender,
            amount: uint128(msg.value),
            targetOddsE18: targetOddsE18,
            blockNumber: uint64(block.number),
            status: BetStatus.Pending
        });

        // Add to pending queue
        pendingBetIds.push(betId);
        pendingBetIndex[betId] = pendingBetIds.length; // 1-indexed

        emit BetPlaced(betId, msg.sender, uint128(msg.value), targetOddsE18, uint64(block.number));
    }

    /// @notice Claim winnings from a winning bet
    /// @param betId The bet ID to claim
    function claim(uint256 betId) external nonReentrant {
        Bet storage bet = bets[betId];
        require(bet.player == msg.sender, "Not your bet");
        require(bet.status == BetStatus.Pending, "Bet not pending");

        // Check blockhash availability
        uint64 resultBlock = bet.blockNumber + 1;
        require(block.number > resultBlock, "Wait for next block");
        require(block.number <= resultBlock + BLOCKHASH_LOOKBACK, "Blockhash expired");

        bytes32 futureBlockHash = blockhash(resultBlock);
        require(futureBlockHash != bytes32(0), "Blockhash unavailable");

        uint256 randomResult = BetMath.computeRandomResult(betId, futureBlockHash);
        bool won = BetMath.isWinner(randomResult, bet.targetOddsE18, houseEdgeE18);

        if (won) {
            uint256 payout = BetMath.calculatePayout(bet.amount, bet.targetOddsE18);
            bet.status = BetStatus.Claimed;

            _removeFromPending(betId);

            // Request payout from vault (vault sends ETH to this contract)
            uint256 payoutFromVault = payout > bet.amount ? payout - bet.amount : 0;
            if (payoutFromVault > 0) {
                IClawsinoVault(vault).withdrawForPayout(payoutFromVault);
            }

            // Transfer winnings to player (original bet + profit from vault)
            (bool success,) = msg.sender.call{ value: payout }("");
            require(success, "Transfer failed");

            emit BetResolved(betId, true, payout);
            emit BetClaimed(betId, msg.sender, payout);
        } else {
            bet.status = BetStatus.Lost;
            _removeFromPending(betId);

            // Send lost bet to vault
            _sendToVault(bet.amount);

            emit BetResolved(betId, false, 0);
        }
    }

    /// @notice Sweep expired bets (callable by anyone)
    /// @param maxCount Maximum number of bets to sweep
    /// @return swept Number of bets swept
    function sweepExpired(uint256 maxCount) external nonReentrant returns (uint256 swept) {
        return _sweepExpiredInternal(maxCount);
    }

    /// @notice Internal sweep function
    function _sweepExpiredInternal(uint256 maxCount) internal returns (uint256 swept) {
        uint256 len = pendingBetIds.length;
        if (len == 0) return 0;

        uint256 i = 0;
        while (i < len && swept < maxCount) {
            uint256 betId = pendingBetIds[i];
            Bet storage bet = bets[betId];

            // Check if expired (more than EXPIRY_BLOCKS since bet)
            if (block.number > bet.blockNumber + EXPIRY_BLOCKS) {
                bet.status = BetStatus.Expired;

                // Send to vault
                _sendToVault(bet.amount);

                emit BetExpired(betId);
                emit BetResolved(betId, false, 0);

                // Remove from pending (swap and pop)
                _removeFromPendingByIndex(i);
                len--;
                swept++;
                // Don't increment i, check the swapped element
            } else {
                i++;
            }
        }
    }

    /// @notice Get bet details
    function getBet(uint256 betId) external view returns (Bet memory) {
        return bets[betId];
    }

    /// @notice Get maximum bet for given odds
    function getMaxBet(uint64 targetOddsE18) external view returns (uint256) {
        uint256 bankroll = _getHouseBalance();
        return KellyCriterion.calculateMaxBet(bankroll, targetOddsE18, houseEdgeE18);
    }

    /// @notice Compute result for a bet (view function for UI)
    /// @param betId The bet ID
    /// @return won Whether the bet won
    /// @return payout The payout amount if won
    function computeResult(uint256 betId) external view returns (bool won, uint256 payout) {
        Bet storage bet = bets[betId];
        require(bet.status == BetStatus.Pending, "Bet not pending");

        uint64 resultBlock = bet.blockNumber + 1;
        require(block.number > resultBlock, "Wait for next block");

        bytes32 futureBlockHash = blockhash(resultBlock);
        if (futureBlockHash == bytes32(0)) {
            // Blockhash expired, bet is a loss
            return (false, 0);
        }

        uint256 randomResult = BetMath.computeRandomResult(betId, futureBlockHash);
        won = BetMath.isWinner(randomResult, bet.targetOddsE18, houseEdgeE18);

        if (won) {
            payout = BetMath.calculatePayout(bet.amount, bet.targetOddsE18);
        }
    }

    /// @notice Update house edge (owner only)
    function setHouseEdge(uint256 newEdgeE18) external onlyOwner {
        require(newEdgeE18 <= 0.1e18, "Edge too high"); // Max 10%
        uint256 oldEdge = houseEdgeE18;
        houseEdgeE18 = newEdgeE18;
        emit HouseEdgeUpdated(oldEdge, newEdgeE18);
    }

    /// @notice Get current pending bet count
    function getPendingBetCount() external view returns (uint256) {
        return pendingBetIds.length;
    }

    /// @notice Get house balance from vault
    function _getHouseBalance() internal view returns (uint256) {
        return IClawsinoVault(vault).totalAssets() + address(this).balance;
    }

    /// @notice Send ETH to vault
    function _sendToVault(uint256 amount) internal {
        (bool success,) = vault.call{ value: amount }("");
        require(success, "Vault transfer failed");
    }

    /// @notice Remove bet from pending queue by betId
    function _removeFromPending(uint256 betId) internal {
        uint256 index = pendingBetIndex[betId];
        if (index == 0) return; // Not in queue

        _removeFromPendingByIndex(index - 1);
    }

    /// @notice Remove bet from pending queue by index
    function _removeFromPendingByIndex(uint256 index) internal {
        uint256 len = pendingBetIds.length;
        if (index >= len) return;

        uint256 betIdToRemove = pendingBetIds[index];

        // Swap with last element
        if (index < len - 1) {
            uint256 lastBetId = pendingBetIds[len - 1];
            pendingBetIds[index] = lastBetId;
            pendingBetIndex[lastBetId] = index + 1;
        }

        pendingBetIds.pop();
        pendingBetIndex[betIdToRemove] = 0;
    }

    /// @notice Receive ETH (for payouts from vault)
    receive() external payable { }
}
