// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Run: forge test --match-path test/BiliquidVIPCard.t.sol -vvv

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/BiliquidVIPCard.sol";
import "../src/MockERC20.sol";

contract BiliquidVIPCardTest is Test {

    BiliquidVIPCard card; // points to the proxy, cast to impl interface
    MockERC20       usdc;

    // Chain: A(GeneralAgent) -> B(SuperNode) -> C(SuperNode) -> D(Node) -> E(Node) -> F(User)
    address treasury = makeAddr("treasury");
    address A        = makeAddr("A"); // GeneralAgent
    address B        = makeAddr("B"); // SuperNode
    address C        = makeAddr("C"); // SuperNode
    address D        = makeAddr("D"); // Node
    address E        = makeAddr("E"); // Node
    address F        = makeAddr("F"); // User

    uint256 constant GOLD_PRICE   = 30_000_000;  // 30 USDC (6 dec)
    uint256 constant MINT_POINTS  = 10_000;
    uint256 constant MERGE_POINTS = 4_000;       // Gold->Platinum

    // Token ID constants — avoids vm.prank being consumed by card.GOLD() staticcall
    uint8 constant GOLD_ID     = 1;
    uint8 constant PLATINUM_ID = 2;
    uint8 constant DIAMOND_ID  = 3;
    uint8 constant BLACK_ID    = 4;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);

        // Deploy implementation + UUPS proxy
        BiliquidVIPCard impl = new BiliquidVIPCard();
        bytes memory initData = abi.encodeCall(BiliquidVIPCard.initialize, (address(usdc), treasury));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        card = BiliquidVIPCard(address(proxy));

        // Roles (called as address(this) = owner)
        card.setRole(A, 3); // GeneralAgent
        card.setRole(B, 2); // SuperNode
        card.setRole(C, 2); // SuperNode
        card.setRole(D, 1); // Node
        card.setRole(E, 1); // Node

        // Build referral tree — each person must register BEFORE their downstream
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
        assertEq(card.referrerOf(F), E, "F->E");
        assertEq(card.referrerOf(E), D, "E->D");
        assertEq(card.referrerOf(D), C, "D->C");
        assertEq(card.referrerOf(C), B, "C->B");
        assertEq(card.referrerOf(B), A, "B->A");
        assertEq(card.referrerOf(A), address(0), "A->none");
    }

    /// @dev Cycle impossible: A is already registered, can never re-register
    function test_AntiCycle_AlreadyRegistered() public {
        vm.prank(A);
        vm.expectRevert("already registered");
        card.register(F); // would create A->F (but A is already registered)
    }

    /// @dev Registering under an unregistered address is rejected
    function test_AntiCycle_UnregisteredReferrer() public {
        address stranger = makeAddr("stranger");
        address newUser  = makeAddr("newUser");
        vm.prank(newUser);
        vm.expectRevert("referrer not registered");
        card.register(stranger);
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
        card.register(address(0));
        assertEq(card.registrationDepth(newUser), 1);
        assertEq(card.referrerOf(newUser), address(0));
    }

    function test_AntiCycle_ChainTooDeep() public {
        uint256 maxDepth = card.MAX_REFERRAL_DEPTH();
        address prev = makeAddr("depth_root");
        vm.prank(prev); card.register(address(0));

        for (uint256 i = 1; i < maxDepth; i++) {
            address next = address(uint160(uint256(keccak256(abi.encode("depth", i)))));
            vm.prank(next); card.register(prev);
            prev = next;
        }
        address tooDeep = makeAddr("tooDeep");
        vm.prank(tooDeep);
        vm.expectRevert("chain too deep");
        card.register(prev);
    }

    // ── Mint Tests ────────────────────────────────────────────────────────────

    function test_Mint_OneGold_NFTBalance() public {
        vm.prank(F); card.mint(1);
        assertEq(card.balanceOf(F, card.GOLD()), 1, "F gold");
    }

    function test_Mint_OneGold_BuyerPoints() public {
        vm.prank(F); card.mint(1);
        assertEq(card.points(F), MINT_POINTS, "F pts");
    }

    function test_Mint_OneGold_ReferralPoints() public {
        vm.prank(F); card.mint(1);

        // E: direct(10%=1000) + nodeBoost(5%=500) = 1500
        assertEq(card.points(E), 1_500, "E pts");
        // D: indirect 5% = 500
        assertEq(card.points(D), 500,   "D pts");
        // C: superNode 5% = 500
        assertEq(card.points(C), 500,   "C pts");
        // B: same-level as C (both SuperNode) -> 0
        assertEq(card.points(B), 0,     "B pts (same-level, no reward)");
        // A: generalAgent 5% = 500
        assertEq(card.points(A), 500,   "A pts");
    }

    function test_Mint_OneGold_ReferralUsdc() public {
        vm.prank(F); card.mint(1);

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
        address G = makeAddr("G");
        usdc.mint(G, 100_000_000);
        vm.prank(G); usdc.approve(address(card), type(uint256).max);
        vm.prank(G); card.register(address(0));

        uint256 treasuryBefore = usdc.balanceOf(treasury);
        vm.prank(G); card.mint(1);

        assertEq(card.points(G), MINT_POINTS, "G pts");
        assertEq(usdc.balanceOf(treasury), treasuryBefore, "treasury unchanged");
    }

    // ── Merge Tests ───────────────────────────────────────────────────────────

    function test_Merge_GoldToPlatinum_NFTState() public {
        vm.prank(F); card.mint(4);
        vm.prank(F); card.setApprovalForAll(address(card), true);
        vm.prank(F); card.merge(PLATINUM_ID);

        assertEq(card.balanceOf(F, GOLD_ID),     0, "F gold=0");
        assertEq(card.balanceOf(F, PLATINUM_ID), 1, "F plat=1");
        assertEq(card.balanceOf(treasury, GOLD_ID), 4, "treasury holds 4 Gold");
    }

    function test_Merge_GoldToPlatinum_MergerPoints() public {
        vm.prank(F); card.mint(4);
        uint256 ptsBefore = card.points(F);
        vm.prank(F); card.setApprovalForAll(address(card), true);
        vm.prank(F); card.merge(PLATINUM_ID);
        assertEq(card.points(F), ptsBefore + MERGE_POINTS, "F merge pts");
    }

    function test_Merge_GoldToPlatinum_ReferralPoints() public {
        vm.prank(F); card.mint(4);
        vm.prank(F); card.setApprovalForAll(address(card), true);

        uint256 eBefore = card.points(E);
        uint256 dBefore = card.points(D);
        uint256 cBefore = card.points(C);
        uint256 bBefore = card.points(B);
        uint256 aBefore = card.points(A);

        vm.prank(F); card.merge(PLATINUM_ID);

        // E: direct 10% + nodeBoost 5% = 400+200 = 600
        assertEq(card.points(E) - eBefore, 600, "E merge pts");
        // D: indirect 5% = 200
        assertEq(card.points(D) - dBefore, 200, "D merge pts");
        // C: superNode 5% = 200
        assertEq(card.points(C) - cBefore, 200, "C merge pts");
        // B: same-level -> 0
        assertEq(card.points(B) - bBefore, 0,   "B merge pts (same-level)");
        // A: generalAgent 5% = 200
        assertEq(card.points(A) - aBefore, 200, "A merge pts");
    }

    function test_Merge_RevertIfInsufficientCards() public {
        vm.prank(F); card.setApprovalForAll(address(card), true);
        vm.expectRevert("insufficient cards");
        vm.prank(F); card.merge(PLATINUM_ID);
    }

    // ── Staking Tests ─────────────────────────────────────────────────────────

    function test_Stake_LocksNFT() public {
        vm.prank(F); card.mint(1);
        vm.prank(F); card.setApprovalForAll(address(card), true);
        vm.prank(F); card.stake(GOLD_ID, 1);

        assertEq(card.balanceOf(F, GOLD_ID),     0, "free=0");
        assertEq(card.stakedBalance(F, GOLD_ID), 1, "staked=1");
    }

    function test_Unstake_ReturnsNFT() public {
        vm.prank(F); card.mint(1);
        vm.prank(F); card.setApprovalForAll(address(card), true);
        vm.prank(F); card.stake(GOLD_ID, 1);
        vm.prank(F); card.unstake(GOLD_ID, 1);

        assertEq(card.balanceOf(F, GOLD_ID),     1, "restored");
        assertEq(card.stakedBalance(F, GOLD_ID), 0, "staked=0");
    }

    function test_DailyInterest_Gold() public {
        vm.prank(F); card.mint(1);
        vm.prank(F); card.setApprovalForAll(address(card), true);
        vm.prank(F); card.stake(GOLD_ID, 1);

        uint256 expected = (uint256(30_000_000) * 900) / 10_000 / 365;
        assertEq(card.dailyInterest(F), expected, "gold daily interest");
    }

    function test_DailyInterest_Platinum() public {
        vm.prank(F); card.mint(4);
        vm.prank(F); card.setApprovalForAll(address(card), true);
        vm.prank(F); card.merge(PLATINUM_ID);
        vm.prank(F); card.stake(PLATINUM_ID, 1);

        uint256 expected = (uint256(120_000_000) * 1000) / 10_000 / 365;
        assertEq(card.dailyInterest(F), expected, "platinum daily interest");
    }

    // ── getUserState Tests ────────────────────────────────────────────────────

    function test_GetUserState_Snapshot() public {
        vm.prank(F); card.mint(1);

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
        vm.prank(F); card.mint(4);

        assertEq(card.points(F), MINT_POINTS * 4,   "F pts after 4 mints");
        assertEq(card.points(E), 1_500 * 4,         "E pts after 4 mints");
        assertEq(card.points(D), 500 * 4,           "D pts after 4 mints");
        assertEq(card.points(C), 500 * 4,           "C pts after 4 mints");
        assertEq(card.points(B), 0,                 "B pts always 0");
        assertEq(card.points(A), 500 * 4,           "A pts after 4 mints");

        assertEq(usdc.balanceOf(E), 4_500_000 * 4,  "E usdc after 4 mints");
        assertEq(usdc.balanceOf(D), 1_500_000 * 4,  "D usdc after 4 mints");
        assertEq(usdc.balanceOf(C), 1_500_000 * 4,  "C usdc after 4 mints");
        assertEq(usdc.balanceOf(B), 0,              "B usdc always 0");
        assertEq(usdc.balanceOf(A), 1_500_000 * 4,  "A usdc after 4 mints");

        vm.prank(F); card.setApprovalForAll(address(card), true);
        vm.prank(F); card.merge(PLATINUM_ID);

        assertEq(card.points(F), MINT_POINTS * 4 + MERGE_POINTS, "F total pts");
        assertEq(card.points(E), 1_500 * 4 + 600,                "E total pts");
        assertEq(card.points(D), 500 * 4 + 200,                  "D total pts");
        assertEq(card.points(C), 500 * 4 + 200,                  "C total pts");
        assertEq(card.points(B), 0,                               "B total pts");
        assertEq(card.points(A), 500 * 4 + 200,                  "A total pts");

        // Contract holds: 120 paid - 36 distributed = 84 USDC
        assertEq(usdc.balanceOf(address(card)), 84_000_000, "contract net usdc");
    }

    // ── Upgrade Tests ─────────────────────────────────────────────────────────

    function test_Upgrade_OnlyOwner() public {
        BiliquidVIPCard impl2 = new BiliquidVIPCard();
        vm.prank(F);
        vm.expectRevert();
        card.upgradeToAndCall(address(impl2), "");
    }

    function test_Upgrade_OwnerCanUpgrade() public {
        // Deploy new impl and upgrade — state should persist
        vm.prank(F); card.mint(1);
        assertEq(card.balanceOf(F, GOLD_ID), 1, "before upgrade");

        BiliquidVIPCard impl2 = new BiliquidVIPCard();
        // address(this) is the owner (setUp deployer)
        card.upgradeToAndCall(address(impl2), "");

        // State preserved across upgrade
        assertEq(card.balanceOf(F, GOLD_ID), 1, "after upgrade");
    }
}
