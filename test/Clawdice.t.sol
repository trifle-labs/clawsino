// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/Clawdice.sol";
import "../src/ClawdiceVault.sol";
import "../src/interfaces/IUniswapV4.sol";
import "../src/libraries/BetMath.sol";
import "../src/libraries/KellyCriterion.sol";

// Mock ERC20 token (simulates Clanker token)
contract MockToken {
    string public name = "Mock Clanker Token";
    string public symbol = "MCLAW";
    uint8 public decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function mint(address to, uint256 amount) public {
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) public returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) public returns (bool) {
        return transferFrom(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public returns (bool) {
        require(balanceOf[from] >= amount, "Insufficient balance");

        if (from != msg.sender && allowance[from][msg.sender] != type(uint256).max) {
            require(allowance[from][msg.sender] >= amount, "Insufficient allowance");
            allowance[from][msg.sender] -= amount;
        }

        balanceOf[from] -= amount;
        balanceOf[to] += amount;

        emit Transfer(from, to, amount);
        return true;
    }
}

// Mock WETH for testing
contract MockWETH {
    string public name = "Wrapped Ether";
    string public symbol = "WETH";
    uint8 public decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Deposit(address indexed dst, uint256 wad);
    event Withdrawal(address indexed src, uint256 wad);

    function deposit() public payable {
        balanceOf[msg.sender] += msg.value;
        emit Deposit(msg.sender, msg.value);
    }

    function withdraw(uint256 wad) public {
        require(balanceOf[msg.sender] >= wad, "Insufficient balance");
        balanceOf[msg.sender] -= wad;
        payable(msg.sender).transfer(wad);
        emit Withdrawal(msg.sender, wad);
    }

    function totalSupply() public view returns (uint256) {
        return address(this).balance;
    }

    function approve(address guy, uint256 wad) public returns (bool) {
        allowance[msg.sender][guy] = wad;
        emit Approval(msg.sender, guy, wad);
        return true;
    }

    function transfer(address dst, uint256 wad) public returns (bool) {
        return transferFrom(msg.sender, dst, wad);
    }

    function transferFrom(address src, address dst, uint256 wad) public returns (bool) {
        require(balanceOf[src] >= wad, "Insufficient balance");

        if (src != msg.sender && allowance[src][msg.sender] != type(uint256).max) {
            require(allowance[src][msg.sender] >= wad, "Insufficient allowance");
            allowance[src][msg.sender] -= wad;
        }

        balanceOf[src] -= wad;
        balanceOf[dst] += wad;

        emit Transfer(src, dst, wad);
        return true;
    }

    receive() external payable {
        deposit();
    }
}

// Mock Permit2 for testing
contract MockPermit2 is IPermit2 {
    // Simplified: just track approvals
    mapping(address => mapping(address => mapping(address => uint160))) public approvals;

    function approve(
        address token,
        address spender,
        uint160 amount,
        uint48 /* expiration */
    )
        external
    {
        approvals[msg.sender][token][spender] = amount;
    }

    function allowance(address owner, address token, address spender)
        external
        view
        returns (uint160 amount, uint48 expiration, uint48 nonce)
    {
        return (approvals[owner][token][spender], type(uint48).max, 0);
    }
}

// Mock Universal Router for testing V4 swaps
contract MockUniversalRouter is IUniversalRouter {
    MockWETH public weth;
    MockToken public token;
    uint256 public rate = 1000; // 1 ETH = 1000 tokens

    constructor(address _weth, address _token) {
        weth = MockWETH(payable(_weth));
        token = MockToken(_token);

        // Pre-approve max so the router can always pull tokens
        // In real scenario, Permit2 handles this
    }

    function setRate(uint256 _rate) external {
        rate = _rate;
    }

    function execute(
        bytes calldata commands,
        bytes[] calldata inputs,
        uint256 /* deadline */
    )
        external
        payable
    {
        // Simple mock: just look for V4_SWAP command and execute
        if (commands.length > 0 && uint8(commands[0]) == Commands.V4_SWAP) {
            // Decode the V4 swap input
            (bytes memory actions, bytes[] memory params) = abi.decode(inputs[0], (bytes, bytes[]));

            // First action should be SWAP_EXACT_IN_SINGLE
            if (actions.length > 0 && uint8(actions[0]) == Actions.SWAP_EXACT_IN_SINGLE) {
                IV4Router.ExactInputSingleParams memory swapParams =
                    abi.decode(params[0], (IV4Router.ExactInputSingleParams));

                // In the real Universal Router, it would pull from msg.sender via Permit2.
                // For testing, we check if msg.sender has the WETH balance and "pull" it.
                // The contracts approve WETH to Permit2, and Permit2 approves to Universal Router.
                // We simulate this by just checking the balance exists and transferring.
                uint256 senderBalance = weth.balanceOf(msg.sender);
                require(senderBalance >= swapParams.amountIn, "Insufficient WETH balance");

                // Transfer WETH from sender (simulating Permit2 pull)
                // The contract has already approved Permit2 which approves Universal Router
                bool success = weth.transferFrom(msg.sender, address(this), swapParams.amountIn);
                require(success, "WETH transfer failed");

                // Calculate output (simple fixed rate for testing)
                uint256 amountOut = swapParams.amountIn * rate;
                require(amountOut >= swapParams.amountOutMinimum, "Insufficient output");

                // Mint tokens to sender (the contract that called execute)
                token.mint(msg.sender, amountOut);
            }
        }
    }

    function execute(bytes calldata commands, bytes[] calldata inputs) external payable {
        this.execute(commands, inputs, block.timestamp + 60);
    }
}

contract ClawdiceTest is Test {
    Clawdice public clawdice;
    ClawdiceVault public vault;
    MockWETH public weth;
    MockToken public token;
    MockUniversalRouter public router;
    MockPermit2 public permit2;

    address public owner = address(this);
    address public player1 = address(0x1);
    address public player2 = address(0x2);

    uint64 constant FIFTY_PERCENT = 0.5e18;
    uint64 constant TWENTY_FIVE_PERCENT = 0.25e18;

    function setUp() public {
        // Deploy mocks
        weth = new MockWETH();
        token = new MockToken();
        router = new MockUniversalRouter(address(weth), address(token));
        permit2 = new MockPermit2();

        // Create pool key (WETH as currency0 since address is lower)
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(weth)),
            currency1: Currency.wrap(address(token)),
            fee: 10000, // 1%
            tickSpacing: 200,
            hooks: address(0)
        });

        // Deploy vault
        vault = new ClawdiceVault(
            address(token),
            address(weth),
            address(router),
            address(permit2),
            poolKey,
            "Clawdice Staked Token",
            "clawTOKEN"
        );

        // Deploy Clawdice
        clawdice = new Clawdice(address(vault), address(weth), address(router), address(permit2), poolKey);

        // Set Clawdice in vault
        vault.setClawdice(address(clawdice));

        // For testing: grant router direct approval on WETH from the contracts
        // In production, Permit2 handles this, but our mock doesn't fully implement Permit2
        vm.prank(address(clawdice));
        weth.approve(address(router), type(uint256).max);
        vm.prank(address(vault));
        weth.approve(address(router), type(uint256).max);

        // Mint tokens to owner and seed liquidity
        token.mint(address(this), 10000 ether);
        token.approve(address(vault), type(uint256).max);
        vault.seedLiquidity(10000 ether);

        // Fund players with tokens
        token.mint(player1, 10000 ether);
        token.mint(player2, 10000 ether);

        // Fund players with ETH
        vm.deal(player1, 100 ether);
        vm.deal(player2, 100 ether);

        // Approve clawdice for players
        vm.prank(player1);
        token.approve(address(clawdice), type(uint256).max);
        vm.prank(player2);
        token.approve(address(clawdice), type(uint256).max);
    }

    function test_InitialSetup() public view {
        assertEq(clawdice.vault(), address(vault));
        assertEq(clawdice.houseEdgeE18(), 0.01e18);
        assertEq(vault.clawdice(), address(clawdice));
        assertEq(token.balanceOf(address(vault)), 10000 ether);
    }

    function test_PlaceBet() public {
        vm.prank(player1);
        uint256 betId = clawdice.placeBet(100 ether, FIFTY_PERCENT);

        assertEq(betId, 1);

        IClawdice.Bet memory bet = clawdice.getBet(betId);
        assertEq(bet.player, player1);
        assertEq(bet.amount, 100 ether);
        assertEq(bet.targetOddsE18, FIFTY_PERCENT);
        assertEq(uint8(bet.status), uint8(IClawdice.BetStatus.Pending));
    }

    function test_PlaceBetWithETH() public {
        vm.prank(player1);
        uint256 betId = clawdice.placeBetWithETH{ value: 0.1 ether }(FIFTY_PERCENT, 0);

        assertEq(betId, 1);

        IClawdice.Bet memory bet = clawdice.getBet(betId);
        assertEq(bet.player, player1);
        // 0.1 ETH * 1000 rate = 100 tokens
        assertEq(bet.amount, 100 ether);
        assertEq(bet.targetOddsE18, FIFTY_PERCENT);
        assertEq(uint8(bet.status), uint8(IClawdice.BetStatus.Pending));
    }

    function test_PlaceBetWithETH_SlippageProtection() public {
        vm.prank(player1);
        // Require at least 200 tokens but will only get 100
        vm.expectRevert("Insufficient output");
        clawdice.placeBetWithETH{ value: 0.1 ether }(FIFTY_PERCENT, 200 ether);
    }

    function test_PlaceBet_TooSmall() public {
        vm.prank(player1);
        vm.expectRevert("Bet too small");
        clawdice.placeBet(0.0001 ether, FIFTY_PERCENT);
    }

    function test_PlaceBet_OddsTooLow() public {
        vm.prank(player1);
        vm.expectRevert("Odds too low");
        clawdice.placeBet(100 ether, 0.001e18);
    }

    function test_PlaceBet_OddsTooHigh() public {
        vm.prank(player1);
        vm.expectRevert("Odds too high");
        clawdice.placeBet(100 ether, 0.999e18);
    }

    function test_MaxBet_FiftyPercent() public view {
        // maxBet = (bankroll * edge) / (multiplier - 1)
        // = (10000 tokens * 0.01) / (2 - 1) = 100 tokens
        uint256 maxBet = clawdice.getMaxBet(FIFTY_PERCENT);
        assertEq(maxBet, 100 ether);
    }

    function test_MaxBet_TwentyFivePercent() public view {
        // maxBet = (10000 tokens * 0.01) / (4 - 1) = 33.33... tokens
        uint256 maxBet = clawdice.getMaxBet(TWENTY_FIVE_PERCENT);
        assertApproxEqRel(maxBet, 33.33 ether, 0.01e18);
    }

    function test_PlaceBet_ExceedsMax() public {
        vm.prank(player1);
        vm.expectRevert("Bet exceeds max");
        clawdice.placeBet(200 ether, FIFTY_PERCENT);
    }

    function test_Claim_Win() public {
        // Place bet
        vm.prank(player1);
        uint256 betId = clawdice.placeBet(100 ether, FIFTY_PERCENT);

        // Mine blocks to get blockhash (need block > betBlock + 1)
        vm.roll(block.number + 2);

        // Check result
        (bool won, uint256 payout) = clawdice.computeResult(betId);

        if (won) {
            uint256 balanceBefore = token.balanceOf(player1);
            vm.prank(player1);
            clawdice.claim(betId);

            assertEq(token.balanceOf(player1), balanceBefore + payout);

            IClawdice.Bet memory bet = clawdice.getBet(betId);
            assertEq(uint8(bet.status), uint8(IClawdice.BetStatus.Claimed));
        }
    }

    function test_Claim_Loss() public {
        // Place bet
        vm.prank(player1);
        uint256 betId = clawdice.placeBet(100 ether, FIFTY_PERCENT);

        // Mine blocks (need block > betBlock + 1)
        vm.roll(block.number + 2);

        // Check result
        (bool won,) = clawdice.computeResult(betId);

        if (!won) {
            uint256 vaultBalanceBefore = token.balanceOf(address(vault));

            vm.prank(player1);
            clawdice.claim(betId);

            // Lost bet goes to vault
            assertEq(token.balanceOf(address(vault)), vaultBalanceBefore + 100 ether);

            IClawdice.Bet memory bet = clawdice.getBet(betId);
            assertEq(uint8(bet.status), uint8(IClawdice.BetStatus.Lost));
        }
    }

    function test_Claim_NotYourBet() public {
        vm.prank(player1);
        uint256 betId = clawdice.placeBet(100 ether, FIFTY_PERCENT);

        vm.roll(block.number + 1);

        vm.prank(player2);
        vm.expectRevert("Not your bet");
        clawdice.claim(betId);
    }

    function test_Claim_TooEarly() public {
        vm.prank(player1);
        uint256 betId = clawdice.placeBet(100 ether, FIFTY_PERCENT);

        // Don't mine any blocks
        vm.prank(player1);
        vm.expectRevert("Wait for next block");
        clawdice.claim(betId);
    }

    function test_SweepExpired() public {
        // Place bet
        vm.prank(player1);
        uint256 betId = clawdice.placeBet(100 ether, FIFTY_PERCENT);

        // Fast forward past expiry (255 blocks)
        vm.roll(block.number + 256);

        uint256 vaultBalanceBefore = token.balanceOf(address(vault));

        // Sweep
        uint256 swept = clawdice.sweepExpired(10);
        assertEq(swept, 1);

        // Bet amount should be in vault
        assertEq(token.balanceOf(address(vault)), vaultBalanceBefore + 100 ether);

        // Check bet status
        IClawdice.Bet memory bet = clawdice.getBet(betId);
        assertEq(uint8(bet.status), uint8(IClawdice.BetStatus.Expired));
    }

    function test_SetHouseEdge() public {
        clawdice.setHouseEdge(0.02e18);
        assertEq(clawdice.houseEdgeE18(), 0.02e18);
    }

    function test_SetHouseEdge_TooHigh() public {
        vm.expectRevert("Edge too high");
        clawdice.setHouseEdge(0.15e18);
    }

    function test_SetHouseEdge_NotOwner() public {
        vm.prank(player1);
        vm.expectRevert();
        clawdice.setHouseEdge(0.02e18);
    }

    function test_SetPoolKey() public {
        PoolKey memory newPoolKey = PoolKey({
            currency0: Currency.wrap(address(weth)),
            currency1: Currency.wrap(address(token)),
            fee: 3000, // 0.3%
            tickSpacing: 60,
            hooks: address(0)
        });
        clawdice.setPoolKey(newPoolKey);
        (Currency c0, Currency c1, uint24 fee, int24 tickSpacing, address hooks) = clawdice.poolKey();
        assertEq(fee, 3000);
        assertEq(tickSpacing, 60);
    }

    function test_PlaceBetAndClaimPrevious_Win() public {
        // Place initial bet
        vm.prank(player1);
        uint256 betId1 = clawdice.placeBet(50 ether, FIFTY_PERCENT);

        // Mine blocks to resolve bet
        vm.roll(block.number + 2);

        // Check if bet won
        (bool won,) = clawdice.computeResult(betId1);

        // Place second bet and claim first
        uint256 player1BalanceBefore = token.balanceOf(player1);

        vm.prank(player1);
        (uint256 betId2, bool previousWon, uint256 previousPayout) =
            clawdice.placeBetAndClaimPrevious(50 ether, FIFTY_PERCENT, betId1);

        assertEq(previousWon, won);
        assertEq(betId2, 2);

        // Check first bet status
        IClawdice.Bet memory bet1 = clawdice.getBet(betId1);
        if (won) {
            assertEq(uint8(bet1.status), uint8(IClawdice.BetStatus.Claimed));
            // Player receives payout minus new bet
            assertEq(token.balanceOf(player1), player1BalanceBefore + previousPayout - 50 ether);
        } else {
            assertEq(uint8(bet1.status), uint8(IClawdice.BetStatus.Lost));
            assertEq(previousPayout, 0);
        }

        // Check second bet is pending
        IClawdice.Bet memory bet2 = clawdice.getBet(betId2);
        assertEq(bet2.player, player1);
        assertEq(bet2.amount, 50 ether);
        assertEq(uint8(bet2.status), uint8(IClawdice.BetStatus.Pending));
    }

    function test_PlaceBetAndClaimPrevious_Loss() public {
        // Place initial bet with low odds (less likely to win for testing)
        vm.prank(player1);
        uint256 betId1 = clawdice.placeBet(10 ether, 0.1e18); // 10% odds

        // Mine blocks to resolve bet
        vm.roll(block.number + 2);

        uint256 player1BalanceBefore = token.balanceOf(player1);
        uint256 vaultBalanceBefore = token.balanceOf(address(vault));

        // Place second bet and claim first
        vm.prank(player1);
        (uint256 betId2, bool previousWon, uint256 previousPayout) =
            clawdice.placeBetAndClaimPrevious(10 ether, 0.1e18, betId1);

        assertEq(betId2, 2);

        // Check first bet status
        IClawdice.Bet memory bet1 = clawdice.getBet(betId1);
        if (!previousWon) {
            assertEq(uint8(bet1.status), uint8(IClawdice.BetStatus.Lost));
            assertEq(previousPayout, 0);
            // Lost bet goes to vault
            assertEq(token.balanceOf(address(vault)), vaultBalanceBefore + 10 ether);
        }
    }

    function test_PlaceBetAndClaimPrevious_NotYourBet() public {
        // Place initial bet as player1
        vm.prank(player1);
        uint256 betId1 = clawdice.placeBet(50 ether, FIFTY_PERCENT);

        // Mine blocks
        vm.roll(block.number + 2);

        // Player2 tries to claim player1's bet while placing their own
        vm.prank(player2);
        vm.expectRevert("Not your bet");
        clawdice.placeBetAndClaimPrevious(50 ether, FIFTY_PERCENT, betId1);
    }

    function test_PlaceBetAndClaimPrevious_TooEarly() public {
        // Place initial bet
        vm.prank(player1);
        uint256 betId1 = clawdice.placeBet(50 ether, FIFTY_PERCENT);

        // Don't mine blocks - try to claim too early
        vm.prank(player1);
        vm.expectRevert("Wait for next block");
        clawdice.placeBetAndClaimPrevious(50 ether, FIFTY_PERCENT, betId1);
    }

    function test_PlaceBetAndClaimPrevious_AlreadyClaimed() public {
        // Place initial bet
        vm.prank(player1);
        uint256 betId1 = clawdice.placeBet(50 ether, FIFTY_PERCENT);

        // Mine blocks
        vm.roll(block.number + 2);

        // Claim the bet normally
        vm.prank(player1);
        clawdice.claim(betId1);

        // Try to claim again via placeBetAndClaimPrevious
        vm.prank(player1);
        vm.expectRevert("Bet not pending");
        clawdice.placeBetAndClaimPrevious(50 ether, FIFTY_PERCENT, betId1);
    }

    function test_PlaceBetAndClaimPrevious_ChainedBets() public {
        // Simulate martingale-like chained betting
        vm.startPrank(player1);

        // Bet 1
        uint256 betId1 = clawdice.placeBet(10 ether, FIFTY_PERCENT);
        vm.roll(block.number + 2);

        // Bet 2 and claim bet 1
        (uint256 betId2,,) = clawdice.placeBetAndClaimPrevious(10 ether, FIFTY_PERCENT, betId1);
        vm.roll(block.number + 2);

        // Bet 3 and claim bet 2
        (uint256 betId3,,) = clawdice.placeBetAndClaimPrevious(10 ether, FIFTY_PERCENT, betId2);
        vm.roll(block.number + 2);

        // Final claim
        clawdice.claim(betId3);

        vm.stopPrank();

        // All bets should be resolved
        assertNotEq(uint8(clawdice.getBet(betId1).status), uint8(IClawdice.BetStatus.Pending));
        assertNotEq(uint8(clawdice.getBet(betId2).status), uint8(IClawdice.BetStatus.Pending));
        assertNotEq(uint8(clawdice.getBet(betId3).status), uint8(IClawdice.BetStatus.Pending));
    }
}

contract BetMathTest is Test {
    function test_CalculatePayout_FiftyPercent() public pure {
        uint256 payout = BetMath.calculatePayout(1 ether, 0.5e18);
        assertEq(payout, 2 ether);
    }

    function test_CalculatePayout_TwentyFivePercent() public pure {
        uint256 payout = BetMath.calculatePayout(1 ether, 0.25e18);
        assertEq(payout, 4 ether);
    }

    function test_CalculatePayout_TenPercent() public pure {
        uint256 payout = BetMath.calculatePayout(1 ether, 0.1e18);
        assertEq(payout, 10 ether);
    }

    function test_IsWinner_ZeroResult() public pure {
        // Zero should always win (below any threshold > 0)
        bool won = BetMath.isWinner(0, 0.5e18, 0.01e18);
        assertTrue(won);
    }

    function test_IsWinner_MaxResult() public pure {
        // Max result should never win
        bool won = BetMath.isWinner(type(uint256).max, 0.99e18, 0.01e18);
        assertFalse(won);
    }
}

contract KellyCriterionTest is Test {
    function test_CalculateMaxBet_FiftyPercent() public pure {
        // maxBet = (10 ETH * 0.01) / (2 - 1) = 0.1 ETH
        uint256 maxBet = KellyCriterion.calculateMaxBet(10 ether, 0.5e18, 0.01e18);
        assertEq(maxBet, 0.1 ether);
    }

    function test_CalculateMaxBet_TwentyFivePercent() public pure {
        // maxBet = (10 ETH * 0.01) / (4 - 1) = 0.0333... ETH
        uint256 maxBet = KellyCriterion.calculateMaxBet(10 ether, 0.25e18, 0.01e18);
        assertApproxEqRel(maxBet, 0.0333 ether, 0.01e18);
    }

    function test_CalculateMaxBet_TenPercent() public pure {
        // maxBet = (10 ETH * 0.01) / (10 - 1) = 0.0111... ETH
        uint256 maxBet = KellyCriterion.calculateMaxBet(10 ether, 0.1e18, 0.01e18);
        assertApproxEqRel(maxBet, 0.0111 ether, 0.01e18);
    }

    function test_CalculateMaxBet_ZeroBankroll() public pure {
        uint256 maxBet = KellyCriterion.calculateMaxBet(0, 0.5e18, 0.01e18);
        assertEq(maxBet, 0);
    }

    function test_IsBetSafe() public pure {
        assertTrue(KellyCriterion.isBetSafe(0.05 ether, 10 ether, 0.5e18, 0.01e18));
        assertTrue(KellyCriterion.isBetSafe(0.1 ether, 10 ether, 0.5e18, 0.01e18));
        assertFalse(KellyCriterion.isBetSafe(0.2 ether, 10 ether, 0.5e18, 0.01e18));
    }
}

contract ClawdiceVaultTest is Test {
    ClawdiceVault public vault;
    Clawdice public clawdice;
    MockWETH public weth;
    MockToken public token;
    MockUniversalRouter public router;
    MockPermit2 public permit2;

    address public staker1 = address(0x1);
    address public staker2 = address(0x2);

    function setUp() public {
        weth = new MockWETH();
        token = new MockToken();
        router = new MockUniversalRouter(address(weth), address(token));
        permit2 = new MockPermit2();

        // Create pool key
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(weth)),
            currency1: Currency.wrap(address(token)),
            fee: 10000,
            tickSpacing: 200,
            hooks: address(0)
        });

        vault = new ClawdiceVault(
            address(token),
            address(weth),
            address(router),
            address(permit2),
            poolKey,
            "Clawdice Staked Token",
            "clawTOKEN"
        );
        clawdice = new Clawdice(address(vault), address(weth), address(router), address(permit2), poolKey);
        vault.setClawdice(address(clawdice));

        // For testing: grant router direct approval on WETH from the contracts
        vm.prank(address(clawdice));
        weth.approve(address(router), type(uint256).max);
        vm.prank(address(vault));
        weth.approve(address(router), type(uint256).max);

        // Fund stakers
        token.mint(staker1, 10000 ether);
        token.mint(staker2, 10000 ether);
        vm.deal(staker1, 100 ether);
        vm.deal(staker2, 100 ether);

        // Approve vault
        vm.prank(staker1);
        token.approve(address(vault), type(uint256).max);
        vm.prank(staker2);
        token.approve(address(vault), type(uint256).max);
    }

    function test_Stake() public {
        vm.prank(staker1);
        uint256 shares = vault.stake(1000 ether);

        assertEq(shares, 1000 ether); // First stake is 1:1
        assertEq(vault.balanceOf(staker1), 1000 ether);
        assertEq(token.balanceOf(address(vault)), 1000 ether);
    }

    function test_StakeWithETH() public {
        vm.prank(staker1);
        uint256 shares = vault.stakeWithETH{ value: 1 ether }(0);

        // 1 ETH * 1000 rate = 1000 tokens
        assertEq(shares, 1000 ether);
        assertEq(vault.balanceOf(staker1), 1000 ether);
        assertEq(token.balanceOf(address(vault)), 1000 ether);
    }

    function test_StakeWithETH_SlippageProtection() public {
        vm.prank(staker1);
        vm.expectRevert("Insufficient output");
        vault.stakeWithETH{ value: 1 ether }(2000 ether); // Require 2000 but only get 1000
    }

    function test_Stake_Multiple() public {
        vm.prank(staker1);
        vault.stake(1000 ether);

        vm.prank(staker2);
        uint256 shares = vault.stake(1000 ether);

        assertEq(shares, 1000 ether); // Same share price
        assertEq(vault.balanceOf(staker2), 1000 ether);
        assertEq(token.balanceOf(address(vault)), 2000 ether);
    }

    function test_Unstake() public {
        vm.prank(staker1);
        vault.stake(1000 ether);

        uint256 balanceBefore = token.balanceOf(staker1);

        vm.prank(staker1);
        uint256 assets = vault.unstake(1000 ether);

        assertEq(assets, 1000 ether);
        assertEq(token.balanceOf(staker1), balanceBefore + 1000 ether);
        assertEq(vault.balanceOf(staker1), 0);
    }

    function test_SharePriceIncrease() public {
        // Staker1 stakes 1000 tokens
        vm.prank(staker1);
        vault.stake(1000 ether);

        // Simulate house win (send 100 tokens to vault from clawdice)
        token.mint(address(clawdice), 100 ether);
        vm.prank(address(clawdice));
        token.transfer(address(vault), 100 ether);

        // Vault now has 1100 tokens, staker1 has 1000 shares
        // Each share worth 1.1 tokens
        uint256 assets = vault.previewRedeem(1000 ether);
        assertApproxEqAbs(assets, 1100 ether, 1); // Allow 1 wei difference
    }

    function test_SetClawdice_OnlyOnce() public {
        // Already set in setUp
        vm.expectRevert("Already set");
        vault.setClawdice(address(0x123));
    }

    function test_SetPoolKey() public {
        PoolKey memory newPoolKey = PoolKey({
            currency0: Currency.wrap(address(weth)),
            currency1: Currency.wrap(address(token)),
            fee: 3000,
            tickSpacing: 60,
            hooks: address(0)
        });
        vault.setPoolKey(newPoolKey);
        (Currency c0, Currency c1, uint24 fee, int24 tickSpacing, address hooks) = vault.poolKey();
        assertEq(fee, 3000);
        assertEq(tickSpacing, 60);
    }
}
