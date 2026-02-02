// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IClawsino {
    enum BetStatus {
        Pending,
        Won,
        Lost,
        Claimed,
        Expired
    }

    struct Bet {
        address player;
        uint128 amount;
        uint64 targetOddsE18; // 18 decimals, e.g., 0.5e18 = 50%
        uint64 blockNumber;
        BetStatus status;
    }

    event BetPlaced(uint256 indexed betId, address indexed player, uint128 amount, uint64 targetOddsE18, uint64 blockNumber);
    event BetResolved(uint256 indexed betId, bool won, uint256 payout);
    event BetClaimed(uint256 indexed betId, address indexed player, uint256 payout);
    event BetExpired(uint256 indexed betId);
    event HouseEdgeUpdated(uint256 oldEdge, uint256 newEdge);

    function placeBet(uint64 targetOddsE18) external payable returns (uint256 betId);
    function claim(uint256 betId) external;
    function sweepExpired(uint256 maxCount) external returns (uint256 swept);

    function getBet(uint256 betId) external view returns (Bet memory);
    function getMaxBet(uint64 targetOddsE18) external view returns (uint256);
    function computeResult(uint256 betId) external view returns (bool won, uint256 payout);
    function houseEdgeE18() external view returns (uint256);
    function vault() external view returns (address);
}
