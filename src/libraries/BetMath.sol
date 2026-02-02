// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title BetMath
/// @notice Library for bet calculations including payouts and randomness
library BetMath {
    uint256 constant E18 = 1e18;
    uint256 constant MIN_ODDS = 0.01e18; // 1%
    uint256 constant MAX_ODDS = 0.99e18; // 99%

    /// @notice Calculate payout for a winning bet
    /// @param amount Bet amount
    /// @param targetOddsE18 Target odds (18 decimals)
    /// @return payout The amount to pay out on a win
    function calculatePayout(uint128 amount, uint64 targetOddsE18) internal pure returns (uint256 payout) {
        // payout = amount / odds
        // e.g., 1 ETH at 50% odds = 2 ETH payout
        payout = (uint256(amount) * E18) / targetOddsE18;
    }

    /// @notice Calculate profit for house on a losing bet
    /// @param amount Bet amount
    /// @return profit The profit (same as bet amount for a loss)
    function calculateProfit(uint128 amount) internal pure returns (uint256 profit) {
        return amount;
    }

    /// @notice Calculate the loss to house on a winning bet
    /// @param amount Bet amount
    /// @param targetOddsE18 Target odds (18 decimals)
    /// @return loss The loss amount (payout - original bet)
    function calculateLoss(uint128 amount, uint64 targetOddsE18) internal pure returns (uint256 loss) {
        uint256 payout = calculatePayout(amount, targetOddsE18);
        loss = payout - amount;
    }

    /// @notice Compute random result from blockhash and nonce
    /// @param betId Unique bet identifier (nonce)
    /// @param futureBlockHash The hash of block betBlockNumber + 1
    /// @return result A uniformly distributed uint256
    function computeRandomResult(uint256 betId, bytes32 futureBlockHash) internal pure returns (uint256 result) {
        result = uint256(keccak256(abi.encodePacked(betId, futureBlockHash)));
    }

    /// @notice Check if a result is a winner
    /// @param result The random result from computeRandomResult
    /// @param targetOddsE18 Target odds (18 decimals)
    /// @param houseEdgeE18 House edge (18 decimals), e.g., 0.01e18 = 1%
    /// @return won True if the bet won
    function isWinner(
        uint256 result,
        uint64 targetOddsE18,
        uint256 houseEdgeE18
    ) internal pure returns (bool won) {
        // Adjusted odds = targetOdds * (1 - houseEdge)
        uint256 adjustedOddsE18 = (uint256(targetOddsE18) * (E18 - houseEdgeE18)) / E18;

        // Scale result to E18 range for comparison
        // result / MAX = resultE18 / E18
        // So: resultE18 = result * E18 / MAX
        // But this loses precision. Instead, compare:
        // result < threshold where threshold = adjustedOdds * MAX / E18
        // To avoid overflow: result / (MAX / E18) < adjustedOdds
        // MAX / E18 = 115792089237316195423570985008687907853269984665640564039457
        uint256 scaleFactor = type(uint256).max / E18;
        uint256 scaledResult = result / scaleFactor;

        won = scaledResult < adjustedOddsE18;
    }

    /// @notice Validate odds are within acceptable range
    /// @param targetOddsE18 Target odds to validate
    function validateOdds(uint64 targetOddsE18) internal pure {
        require(targetOddsE18 >= MIN_ODDS, "Odds too low");
        require(targetOddsE18 <= MAX_ODDS, "Odds too high");
    }
}
