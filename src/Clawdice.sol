// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import "./interfaces/IClawdice.sol";
import "./interfaces/IUniswapV4.sol";
import "./libraries/BetMath.sol";
import "./libraries/KellyCriterion.sol";

interface IClawdiceVault {
    function totalAssets() external view returns (uint256);
    function withdrawForPayout(uint256 amount) external;
    function collateralToken() external view returns (IERC20);
}

/// @title Clawdice
/// @notice Provably fair on-chain dice game with commit-reveal pattern
/// @dev Uses future blockhash for randomness, Kelly Criterion for bet limits
/// @dev Accepts any ERC20 token as collateral (designed for Clanker tokens on Uniswap V4)
contract Clawdice is IClawdice, ReentrancyGuard, Ownable {
    using BetMath for *;
    using KellyCriterion for *;
    using SafeERC20 for IERC20;

    uint256 public constant EXPIRY_BLOCKS = 255; // ~8.5 min on Base (2s blocks), ~51 min on mainnet (12s blocks)
    uint256 public constant BLOCKHASH_LOOKBACK = 256; // EVM limit - blockhash only available for 256 blocks

    address public immutable vault;
    IERC20 public immutable collateralToken;
    IWETH public immutable weth;
    IUniversalRouter public immutable universalRouter;
    IPermit2 public immutable permit2;

    // Uniswap V4 pool configuration
    PoolKey public poolKey;
    uint256 public houseEdgeE18 = 0.01e18; // 1% default

    uint256 public nextBetId = 1;
    mapping(uint256 => Bet) public bets;

    // Queue for expired bets that need sweeping
    uint256[] public pendingBetIds;
    mapping(uint256 => uint256) public pendingBetIndex; // betId -> index in pendingBetIds + 1 (0 means not in queue)

    event PoolKeyUpdated(PoolKey oldKey, PoolKey newKey);
    event SwapExecuted(address indexed user, uint256 ethIn, uint256 tokensOut);

    constructor(address _vault, address _weth, address _universalRouter, address _permit2, PoolKey memory _poolKey)
        Ownable(msg.sender)
    {
        require(_vault != address(0), "Invalid vault");
        vault = _vault;
        collateralToken = IClawdiceVault(_vault).collateralToken();
        weth = IWETH(_weth);
        universalRouter = IUniversalRouter(_universalRouter);
        permit2 = IPermit2(_permit2);
        poolKey = _poolKey;

        // Approve Permit2 for WETH (Universal Router uses Permit2)
        IERC20(_weth).approve(_permit2, type(uint256).max);
        // Approve Universal Router via Permit2
        IPermit2(_permit2).approve(_weth, _universalRouter, type(uint160).max, type(uint48).max);
    }

    /// @notice Update pool key for V4 swaps
    function setPoolKey(PoolKey memory _poolKey) external onlyOwner {
        PoolKey memory oldKey = poolKey;
        poolKey = _poolKey;
        emit PoolKeyUpdated(oldKey, _poolKey);
    }

    /// @notice Place a bet with collateral tokens directly
    /// @param amount Amount of tokens to bet
    /// @param targetOddsE18 Target win probability (18 decimals)
    /// @return betId The ID of the placed bet
    function placeBet(uint256 amount, uint64 targetOddsE18) external nonReentrant returns (uint256 betId) {
        // Auto-sweep up to 5 expired bets before processing new bet
        _sweepExpiredInternal(5);

        require(amount > 0, "Bet cannot be zero");
        BetMath.validateOdds(targetOddsE18);

        uint256 bankroll = _getHouseBalance();
        uint256 maxBet = KellyCriterion.calculateMaxBet(bankroll, targetOddsE18, houseEdgeE18);
        require(amount <= maxBet, "Bet exceeds max");

        // Transfer tokens from player
        collateralToken.safeTransferFrom(msg.sender, address(this), amount);

        betId = nextBetId++;

        bets[betId] = Bet({
            player: msg.sender,
            amount: uint128(amount),
            targetOddsE18: targetOddsE18,
            blockNumber: uint64(block.number),
            status: BetStatus.Pending
        });

        // Add to pending queue
        pendingBetIds.push(betId);
        pendingBetIndex[betId] = pendingBetIds.length; // 1-indexed

        emit BetPlaced(betId, msg.sender, uint128(amount), targetOddsE18, uint64(block.number));
    }

    /// @notice Place a bet using ERC20 permit (gasless approval)
    /// @param amount Amount of tokens to bet
    /// @param targetOddsE18 Target win probability (18 decimals)
    /// @param deadline Permit deadline
    /// @param v Permit signature v
    /// @param r Permit signature r
    /// @param s Permit signature s
    /// @return betId The ID of the placed bet
    function placeBetWithPermit(uint256 amount, uint64 targetOddsE18, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
        nonReentrant
        returns (uint256 betId)
    {
        // Auto-sweep up to 5 expired bets before processing new bet
        _sweepExpiredInternal(5);

        require(amount > 0, "Bet cannot be zero");
        BetMath.validateOdds(targetOddsE18);

        uint256 bankroll = _getHouseBalance();
        uint256 maxBet = KellyCriterion.calculateMaxBet(bankroll, targetOddsE18, houseEdgeE18);
        require(amount <= maxBet, "Bet exceeds max");

        // Execute permit
        IERC20Permit(address(collateralToken)).permit(msg.sender, address(this), amount, deadline, v, r, s);

        // Transfer tokens from player
        collateralToken.safeTransferFrom(msg.sender, address(this), amount);

        betId = nextBetId++;

        bets[betId] = Bet({
            player: msg.sender,
            amount: uint128(amount),
            targetOddsE18: targetOddsE18,
            blockNumber: uint64(block.number),
            status: BetStatus.Pending
        });

        // Add to pending queue
        pendingBetIds.push(betId);
        pendingBetIndex[betId] = pendingBetIds.length; // 1-indexed

        emit BetPlaced(betId, msg.sender, uint128(amount), targetOddsE18, uint64(block.number));
    }

    /// @notice Place a bet with ETH - swaps to collateral token via Uniswap V4
    /// @param targetOddsE18 Target win probability (18 decimals)
    /// @param minTokensOut Minimum tokens to receive from swap (slippage protection)
    /// @return betId The ID of the placed bet
    function placeBetWithETH(uint64 targetOddsE18, uint256 minTokensOut)
        external
        payable
        nonReentrant
        returns (uint256 betId)
    {
        // Auto-sweep up to 5 expired bets before processing new bet
        _sweepExpiredInternal(5);

        require(msg.value > 0, "No ETH sent");
        BetMath.validateOdds(targetOddsE18);

        // Execute swap via Universal Router
        uint256 tokensReceived = _swapETHForTokens(msg.value, minTokensOut);

        require(tokensReceived > 0, "Swap returned zero");

        uint256 bankroll = _getHouseBalance();
        uint256 maxBet = KellyCriterion.calculateMaxBet(bankroll, targetOddsE18, houseEdgeE18);
        require(tokensReceived <= maxBet, "Bet exceeds max");

        betId = nextBetId++;

        bets[betId] = Bet({
            player: msg.sender,
            amount: uint128(tokensReceived),
            targetOddsE18: targetOddsE18,
            blockNumber: uint64(block.number),
            status: BetStatus.Pending
        });

        // Add to pending queue
        pendingBetIds.push(betId);
        pendingBetIndex[betId] = pendingBetIds.length; // 1-indexed

        emit BetPlaced(betId, msg.sender, uint128(tokensReceived), targetOddsE18, uint64(block.number));
    }

    /// @notice Swap ETH for CLAW tokens via Uniswap V4 (no bet placed)
    /// @param minTokensOut Minimum tokens to receive from swap (slippage protection)
    /// @return tokensReceived Amount of CLAW tokens received
    function swapETHForClaw(uint256 minTokensOut) external payable nonReentrant returns (uint256 tokensReceived) {
        require(msg.value > 0, "No ETH sent");

        // Execute swap via Universal Router
        tokensReceived = _swapETHForTokens(msg.value, minTokensOut);

        // Send tokens to caller
        collateralToken.safeTransfer(msg.sender, tokensReceived);

        emit SwapExecuted(msg.sender, msg.value, tokensReceived);
    }

    /// @notice Place a new bet and claim a previous bet in one transaction
    /// @dev Useful for strategies like martingale where bets are placed sequentially
    /// @param amount Amount of tokens to bet
    /// @param targetOddsE18 Target win probability (18 decimals)
    /// @param previousBetId The bet ID to claim (must be caller's bet and ready to claim)
    /// @return betId The ID of the new bet
    /// @return previousWon Whether the previous bet won
    /// @return previousPayout Payout from the previous bet (0 if lost)
    function placeBetAndClaimPrevious(uint256 amount, uint64 targetOddsE18, uint256 previousBetId)
        external
        nonReentrant
        returns (uint256 betId, bool previousWon, uint256 previousPayout)
    {
        // First, claim the previous bet
        (previousWon, previousPayout) = _claimInternal(previousBetId);

        // Then place the new bet (inline to avoid reentrancy issues)
        _sweepExpiredInternal(5);

        require(amount > 0, "Bet cannot be zero");
        BetMath.validateOdds(targetOddsE18);

        uint256 bankroll = _getHouseBalance();
        uint256 maxBet = KellyCriterion.calculateMaxBet(bankroll, targetOddsE18, houseEdgeE18);
        require(amount <= maxBet, "Bet exceeds max");

        // Transfer tokens from player
        collateralToken.safeTransferFrom(msg.sender, address(this), amount);

        betId = nextBetId++;

        bets[betId] = Bet({
            player: msg.sender,
            amount: uint128(amount),
            targetOddsE18: targetOddsE18,
            blockNumber: uint64(block.number),
            status: BetStatus.Pending
        });

        // Add to pending queue
        pendingBetIds.push(betId);
        pendingBetIndex[betId] = pendingBetIds.length;

        emit BetPlaced(betId, msg.sender, uint128(amount), targetOddsE18, uint64(block.number));
    }

    /// @notice Internal claim function that returns result instead of just executing
    function _claimInternal(uint256 betId) internal returns (bool won, uint256 payout) {
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
        won = BetMath.isWinner(randomResult, bet.targetOddsE18, houseEdgeE18);

        if (won) {
            payout = BetMath.calculatePayout(bet.amount, bet.targetOddsE18);
            bet.status = BetStatus.Claimed;

            _removeFromPending(betId);

            // Request payout from vault
            uint256 payoutFromVault = payout > bet.amount ? payout - bet.amount : 0;
            if (payoutFromVault > 0) {
                IClawdiceVault(vault).withdrawForPayout(payoutFromVault);
            }

            // Transfer winnings to player
            collateralToken.safeTransfer(msg.sender, payout);

            emit BetResolved(betId, true, payout);
            emit BetClaimed(betId, msg.sender, payout);
        } else {
            payout = 0;
            bet.status = BetStatus.Lost;
            _removeFromPending(betId);

            // Send lost bet to vault
            _sendToVault(bet.amount);

            emit BetResolved(betId, false, 0);
        }
    }

    /// @notice Internal function to swap ETH for tokens via Uniswap V4 Universal Router
    function _swapETHForTokens(uint256 ethAmount, uint256 minTokensOut) internal returns (uint256 tokensReceived) {
        uint256 balanceBefore = collateralToken.balanceOf(address(this));

        // Wrap ETH to WETH
        weth.deposit{ value: ethAmount }();

        // Determine swap direction based on pool key
        // currency0 < currency1 by convention
        bool zeroForOne = Currency.unwrap(poolKey.currency0) == address(weth);

        // Encode V4 swap actions
        bytes memory actions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL));

        // Encode swap parameters
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: poolKey,
                zeroForOne: zeroForOne,
                amountIn: uint128(ethAmount),
                amountOutMinimum: uint128(minTokensOut),
                hookData: bytes("")
            })
        );

        // Settle input token (WETH)
        if (zeroForOne) {
            params[1] = abi.encode(poolKey.currency0, ethAmount);
            params[2] = abi.encode(poolKey.currency1, minTokensOut);
        } else {
            params[1] = abi.encode(poolKey.currency1, ethAmount);
            params[2] = abi.encode(poolKey.currency0, minTokensOut);
        }

        // Encode Universal Router command
        bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);

        // Execute swap
        universalRouter.execute(commands, inputs, block.timestamp + 60);

        // Calculate tokens received
        tokensReceived = collateralToken.balanceOf(address(this)) - balanceBefore;
        require(tokensReceived >= minTokensOut, "Insufficient output");
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

            // Request payout from vault (vault sends tokens to this contract)
            uint256 payoutFromVault = payout > bet.amount ? payout - bet.amount : 0;
            if (payoutFromVault > 0) {
                IClawdiceVault(vault).withdrawForPayout(payoutFromVault);
            }

            // Transfer winnings to player
            collateralToken.safeTransfer(msg.sender, payout);

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
        return IClawdiceVault(vault).totalAssets() + collateralToken.balanceOf(address(this));
    }

    /// @notice Send tokens to vault
    function _sendToVault(uint256 amount) internal {
        collateralToken.safeTransfer(vault, amount);
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

    /// @notice Receive ETH (for refunds if swap fails, or direct transfers)
    receive() external payable { }
}
