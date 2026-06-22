// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Run: forge test --match-path test/BiliquidVIPCard.t.sol -vvv
// Requires: forge install foundry-rs/forge-std --no-commit

import "forge-std/Test.sol";
import "../src/BiliquidVIPCard.sol";
import "../src/MockERC20.sol";

contract BiliquidVIPCardTest is Test {

    BiliquidVIPCard card;
    MockERC20       usdc;
    MockERC20       usdt;

    // Chain: A(GeneralAgent) → B(SuperNode) → C(SuperNode) → D(Node) → E(Node) → F(User)
    address treasury = makeAddr("treasury");
    address A        = makeAddr("A"); // GeneralAgent
    address B        = makeAddr("B"); // SuperNode
    address C        = makeAddr("C"); // SuperNode
    address D        = makeAddr("D"); // Node
    address E        = makeAddr("E"); // Node
    address F        = makeAddr("F"); // User

    uint256 constant GOLD_PRICE   = 30_000_000;  // 30 USDC (6 dec)
    uint256 constant MINT_POINTS  = 10_000;
    uint256 constant MERGE_POINTS = 4_000;       // Gold→Platinum

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        usdt = new MockERC20("Tether",   "USDT", 6);
        card = new BiliquidVIPCard(address(usdc), address(usdt), treasury);

        // Roles (called as deployer = address(this) = owner)
        card.setRole(A, 3); // GeneralAgent
        card.setRole(B, 2); // SuperNode
        card.setRole(C, 2); // SuperNode
        card.setRole(D, 1); // Node
        card.setRole(E, 1); // Node

        // Build referral tree — each person must register BEFORE their downstream
        // A registers as root first
        vm.prank(A); card.register(address(0));   // A: root, depth=1
        vm.prank(B); card.register(A);            // B: depth=2
        vm.prank(C); card.register(B);            // C: depth=3
        vm.prank(D); card.register(C);            // D: depth=4
        vm.prank(E); card.register(D);            // E: depth=5
        vm.prank(F); card.register(E);            // F: depth=6

        // Fund F with 1200 USDC
        usdc.mint(F, 1_200_000_000);
        vm.prank(F);
        usdc.approve(address(card), type(uint256).max);
    }

    // ── Registration & Anti-Cycle Tests ───────────────────────────────────────

    function test_Referral_Tree_Depths() public view {
        assertEq(card.registrationDepth(A), 1, "A depth");
        assertEq(card.registrationDepth(B), 2, "B depth");
        assertEq(card.registrationDepth(C), 3, "C depth");
        assertEq(card.registrationDepth(D), 4, "D depth");
        assertEq(card.registrationDepth(E), 5, "E depth");
        assertEq(card.registrationDepth(F), 6, "F depth");
    }

    function test_Referral_Tree_Links() public view {
        assertEq(card.referrerOf(F), E, "F→E");
        assertEq(card.referrerOf(E), D, "E→D");
        assertEq(card.referrerOf(D), C, "D→C");
        assertEq(card.referrerOf(C), B, "C→B");
        assertEq(card.referrerOf(B), A, "B→A");
        assertEq(card.referrerOf(A), address(0), "A→none");
    }

    /// @dev Cycle impossible: A is already registered, can never re-register
    function test_AntiCycle_AlreadyRegistered() public {
        vm.prank(A);
        vm.expectRevert("already registered");
        card.register(F); // would create A→F (but A is already registered)
    }

    /// @dev Registering under an unregistered address is rejected
    function test_AntiCycle_UnregisteredReferrer() public {
        address stranger = makeAddr("stranger");
        address newUser  = makeAddr("newUser");
        vm.prank(newUser);
        vm.expectRevert("referrer not registered");
        card.register(stranger); // stranger never called register()
    }

    function test_AntiCycle_SelfRefer() public {
        address newUser = makeAddr("newUser");
        vm.prank(newUser);
        vm.expectRevert("self-refer");
        card.register(newUser);
    }

    function test_AntiCycle_RootRegister() public {
        address newUser = makeAddr("newUser");
        vm.prank(newUser);
        card.register(address(0)); // root — always allowed
        assertEq(card.registrationDepth(newUser), 1);
        assertEq(card.referrerOf(newUser), address(0));
    }

    function test_AntiCycle_ChainTooDeep() public {
        // Build a chain of MAX_REFERRAL_DEPTH nodes, then try to add one more
        uint256 maxDepth = card.MAX_REFERRAL_DEPTH();
        address prev = makeAddr("depth_root");
        vm.prank(prev); card.register(address(0));

        for (uint256 i = 1; i < maxDepth; i++) {
            address next = address(uint160(uint256(keccak256(abi.encode("depth", i)))));
            vm.prank(next); card.register(prev);
            prev = next;
        }
        // prev is now at depth = maxDepth; trying to register one more should fail
        address tooDeep = makeAddr("tooDeep");
        vm.prank(tooDeep);
        vm.expectRevert("chain too deep");
        card.register(prev);
    }

    // ── Mint Tests ────────────────────────────────────────────────────────────

    function test_Mint_OneGold_NFTBalance() public {
        vm.prank(F); card.mint(1, false);
        assertEq(card.balanceOf(F, card.GOLD()), 1, "F gold");
    }

    function test_Mint_OneGold_BuyerPoints() public {
        vm.prank(F); card.mint(1, false);
        assertEq(card.points(F), MINT_POINTS, "F pts");
    }

    function test_Mint_OneGold_ReferralPoints() public {
        vm.prank(F); card.mint(1, false);

        // E: direct(10%=1000) + nodeBoost(5%=500) = 1500
        assertEq(card.points(E), 1_500, "E pts");
        // D: indirect 5% = 500
        assertEq(card.points(D), 500,   "D pts");
        // C: superNode 5% = 500
        assertEq(card.points(C), 500,   "C pts");
        // B: same-level as C (both SuperNode) → 0
        assertEq(card.points(B), 0,     "B pts (same-level, no reward)");
        // A: generalAgent 5% = 500
        assertEq(card.points(A), 500,   "A pts");
    }

    function test_Mint_OneGold_ReferralUsdc() public {
        vm.prank(F); card.mint(1, false);

        // E: 3 USDC (direct) + 1.5 USDC (nodeBoost) = 4.5 USDC
        assertEq(usdc.balanceOf(E), 4_500_000, "E usdc");
        // D: 1.5 USDC
        assertEq(usdc.balanceOf(D), 1_500_000, "D usdc");
        // C: 1.5 USDC
        assertEq(usdc.balanceOf(C), 1_500_000, "C usdc");
        // B: 0
        assertEq(usdc.balanceOf(B), 0,         "B usdc");
        // A: 1.5 USDC
        assertEq(usdc.balanceOf(A), 1_500_000, "A usdc");
        // Contract net: 30 - 9 = 21 USDC
        assertEq(usdc.balanceOf(address(card)), 21_000_000, "contract net");
    }

    function test_Mint_NoReferrer_RewardsToTreasury() public {
        // G has no referrer (registered as root)
        address G = makeAddr("G");
        usdc.mint(G, 100_000_000);
        vm.prank(G); usdc.approve(address(card), type(uint256).max);
        vm.prank(G); card.register(address(0));

        uint256 treasuryBefore = usdc.balanceOf(treasury);
        vm.prank(G); card.mint(1, false);

        // No referrer → all 30 USDC stays in contract (treasury withdraws later)
        // Points only go to G
        assertEq(card.points(G), MINT_POINTS, "G pts");
        // No USDC distributed to any referrer
        assertEq(usdc.balanceOf(treasury), treasuryBefore, "treasury unchanged");
    }

    // ── Merge Tests ───────────────────────────────────────────────────────────

    function test_Merge_GoldToPlatinum_NFTState() public {
        vm.prank(F); card.mint(4, false);
        vm.prank(F); card.setApprovalForAll(address(card), true);
        vm.prank(F); card.merge(card.PLATINUM());

        assertEq(card.balanceOf(F, card.GOLD()),     0, "F gold=0");
        assertEq(card.balanceOf(F, card.PLATINUM()), 1, "F plat=1");
        assertEq(card.balanceOf(treasury, card.GOLD()), 4, "treasury holds 4 Gold");
    }

    function test_Merge_GoldToPlatinum_MergerPoints() public {
        vm.prank(F); card.mint(4, false);
        uint256 ptsBefore = card.points(F);
        vm.prank(F); card.setApprovalForAll(address(card), true);
        vm.prank(F); card.merge(card.PLATINUM());
        assertEq(card.points(F), ptsBefore + MERGE_POINTS, "F merge pts");
    }

    function test_Merge_GoldToPlatinum_ReferralPoints() public {
        vm.prank(F); card.mint(4, false);
        vm.prank(F); card.setApprovalForAll(address(card), true);

        uint256 eBefore = card.points(E);
        uint256 dBefore = card.points(D);
        uint256 cBefore = card.points(C);
        uint256 bBefore = card.points(B);
        uint256 aBefore = card.points(A);

        vm.prank(F); card.merge(card.PLATINUM());

        // E: direct 10% + nodeBoost 5% = 400+200 = 600
        assertEq(card.points(E) - eBefore, 600, "E merge pts");
        // D: indirect 5% = 200
        assertEq(card.points(D) - dBefore, 200, "D merge pts");
        // C: superNode 5% = 200
        assertEq(card.points(C) - cBefore, 200, "C merge pts");
        // B: same-level → 0
        assertEq(card.points(B) - bBefore, 0,   "B merge pts (same-level)");
        // A: generalAgent 5% = 200
        assertEq(card.points(A) - aBefore, 200, "A merge pts");
    }

    function test_Merge_RevertIfInsufficientCards() public {
        // F has 0 Gold
        vm.prank(F); card.setApprovalForAll(address(card), true);
        vm.expectRevert("insufficient cards");
        vm.prank(F); card.merge(card.PLATINUM());
    }

    // ── Staking Tests ─────────────────────────────────────────────────────────

    function test_Stake_LocksNFT() public {
        vm.prank(F); card.mint(1, false);
        vm.prank(F); card.setApprovalForAll(address(card), true);
        vm.prank(F); card.stake(card.GOLD(), 1);

        assertEq(card.balanceOf(F, card.GOLD()),          0, "free=0");
        assertEq(card.stakedBalance(F, card.GOLD()),      1, "staked=1");
    }

    function test_Unstake_ReturnsNFT() public {
        vm.prank(F); card.mint(1, false);
        vm.prank(F); card.setApprovalForAll(address(card), true);
        vm.prank(F); card.stake(card.GOLD(), 1);
        vm.prank(F); card.unstake(card.GOLD(), 1);

        assertEq(card.balanceOf(F, card.GOLD()),     1, "restored");
        assertEq(card.stakedBalance(F, card.GOLD()), 0, "staked=0");
    }

    function test_DailyInterest_Gold() public {
        vm.prank(F); card.mint(1, false);
        vm.prank(F); card.setApprovalForAll(address(card), true);
        vm.prank(F); card.stake(card.GOLD(), 1);

        // Gold: principal=30_000_000, apyBps=900
        // daily = 30_000_000 * 1 * 900 / 10_000 / 365
        uint256 expected = (uint256(30_000_000) * 900) / 10_000 / 365;
        assertEq(card.dailyInterest(F), expected, "gold daily interest");
    }

    function test_DailyInterest_Platinum() public {
        // Give F a Platinum directly via 4x mint + merge
        vm.prank(F); card.mint(4, false);
        vm.prank(F); card.setApprovalForAll(address(card), true);
        vm.prank(F); card.merge(card.PLATINUM());
        vm.prank(F); card.stake(card.PLATINUM(), 1);

        // Platinum: principal=120_000_000, apyBps=1000
        uint256 expected = (uint256(120_000_000) * 1000) / 10_000 / 365;
        assertEq(card.dailyInterest(F), expected, "platinum daily interest");
    }

    // ── getUserState Tests ────────────────────────────────────────────────────

    function test_GetUserState_Snapshot() public {
        vm.prank(F); card.mint(1, false);

        (
            uint256 pts,
            uint256 fGold, uint256 fPlat, uint256 fDia, uint256 fBlack,
            uint256 sGold, uint256 sPlat, uint256 sDia, uint256 sBlack,
            address referrer,
            uint8   role
        ) = card.getUserState(F);

        assertEq(pts,      MINT_POINTS, "pts");
        assertEq(fGold,    1,           "freeGold");
        assertEq(fPlat,    0,           "freePlat");
        assertEq(fDia,     0,           "freeDia");
        assertEq(fBlack,   0,           "freeBlack");
        assertEq(sGold,    0,           "stakedGold");
        assertEq(sPlat,    0,           "stakedPlat");
        assertEq(sDia,     0,           "stakedDia");
        assertEq(sBlack,   0,           "stakedBlack");
        assertEq(referrer, E,           "referrer");
        assertEq(role,     0,           "role=User");
    }

    // ── Full Scenario Test ────────────────────────────────────────────────────

    function test_FullScenario_FourMintsAndMerge() public {
        // 4 mints
        vm.prank(F); card.mint(4, false);

        assertEq(card.points(F), MINT_POINTS * 4,   "F pts after 4 mints");
        assertEq(card.points(E), 1_500 * 4,         "E pts after 4 mints");
        assertEq(card.points(D), 500 * 4,            "D pts after 4 mints");
        assertEq(card.points(C), 500 * 4,            "C pts after 4 mints");
        assertEq(card.points(B), 0,                  "B pts always 0");
        assertEq(card.points(A), 500 * 4,            "A pts after 4 mints");

        assertEq(usdc.balanceOf(E), 4_500_000 * 4,  "E usdc after 4 mints");
        assertEq(usdc.balanceOf(D), 1_500_000 * 4,  "D usdc after 4 mints");
        assertEq(usdc.balanceOf(C), 1_500_000 * 4,  "C usdc after 4 mints");
        assertEq(usdc.balanceOf(B), 0,              "B usdc always 0");
        assertEq(usdc.balanceOf(A), 1_500_000 * 4,  "A usdc after 4 mints");

        // Merge
        vm.prank(F); card.setApprovalForAll(address(card), true);
        vm.prank(F); card.merge(card.PLATINUM());

        assertEq(card.points(F), MINT_POINTS * 4 + MERGE_POINTS, "F total pts");
        assertEq(card.points(E), 1_500 * 4 + 600,                "E total pts");
        assertEq(card.points(D), 500 * 4 + 200,                  "D total pts");
        assertEq(card.points(C), 500 * 4 + 200,                  "C total pts");
        assertEq(card.points(B), 0,                               "B total pts");
        assertEq(card.points(A), 500 * 4 + 200,                  "A total pts");

        // Contract holds: 120 paid - 36 distributed = 84 USDC
        assertEq(usdc.balanceOf(address(card)), 84_000_000, "contract net usdc");
    }
}
