// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title KellyCriterion
/// @notice Library for calculating safe maximum bet sizes using Kelly Criterion
/// @dev Kelly Criterion ensures long-term bankroll growth by limiting exposure
library KellyCriterion {
    uint256 constant E18 = 1e18;

    /// @notice Calculate the maximum safe bet size
    /// @dev maxBet = (bankroll * edge) / (multiplier - 1)
    ///      where multiplier = 1 / odds
    /// @param bankroll Current house balance available for bets
    /// @param targetOddsE18 Target odds (18 decimals)
    /// @param houseEdgeE18 House edge (18 decimals)
    /// @return maxBet Maximum safe bet amount
    function calculateMaxBet(uint256 bankroll, uint64 targetOddsE18, uint256 houseEdgeE18)
        internal
        pure
        returns (uint256 maxBet)
    {
        if (bankroll == 0) return 0;

        // multiplier = 1 / odds (in E18)
        // e.g., 50% odds = 2x multiplier
        uint256 multiplierE18 = (E18 * E18) / targetOddsE18;

        // multiplier - 1 (in E18)
        // For 50% odds: 2e18 - 1e18 = 1e18
        if (multiplierE18 <= E18) return 0; // Safety check
        uint256 multiplierMinusOneE18 = multiplierE18 - E18;

        // maxBet = (bankroll * edge) / (multiplier - 1)
        // All in E18, so: (bankroll * edgeE18 / E18) / (multiplierMinusOneE18 / E18)
        // = (bankroll * edgeE18) / multiplierMinusOneE18
        maxBet = (bankroll * houseEdgeE18) / multiplierMinusOneE18;
    }

    /// @notice Calculate fractional Kelly bet (more conservative)
    /// @param bankroll Current house balance
    /// @param targetOddsE18 Target odds
    /// @param houseEdgeE18 House edge
    /// @param fractionE18 Fraction of Kelly to use (e.g., 0.5e18 = half Kelly)
    /// @return maxBet Maximum safe bet amount
    function calculateFractionalKellyMaxBet(
        uint256 bankroll,
        uint64 targetOddsE18,
        uint256 houseEdgeE18,
        uint256 fractionE18
    ) internal pure returns (uint256 maxBet) {
        uint256 fullKelly = calculateMaxBet(bankroll, targetOddsE18, houseEdgeE18);
        maxBet = (fullKelly * fractionE18) / E18;
    }

    /// @notice Check if a bet amount is within safe limits
    /// @param betAmount Proposed bet amount
    /// @param bankroll Current house balance
    /// @param targetOddsE18 Target odds
    /// @param houseEdgeE18 House edge
    /// @return safe True if bet is within Kelly limit
    function isBetSafe(uint256 betAmount, uint256 bankroll, uint64 targetOddsE18, uint256 houseEdgeE18)
        internal
        pure
        returns (bool safe)
    {
        uint256 maxBet = calculateMaxBet(bankroll, targetOddsE18, houseEdgeE18);
        safe = betAmount <= maxBet;
    }
}
