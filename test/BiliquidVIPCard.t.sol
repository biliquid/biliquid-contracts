// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/BiliquidVIPCard.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// ─── Mock USDC ────────────────────────────────────────────────────────────────
contract MockUSDC {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external { balanceOf[to] += amount; }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to]         += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from]             >= amount, "insufficient");
        require(allowance[from][msg.sender] >= amount, "not allowed");
        balanceOf[from]             -= amount;
        balanceOf[to]               += amount;
        allowance[from][msg.sender] -= amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

// ─── Test Base ────────────────────────────────────────────────────────────────
contract BiliquidVIPCardTest is Test {
    BiliquidVIPCard public card;
    MockUSDC        public usdc;

    address owner    = address(0xABCD);
    address alice    = address(0x1);
    address bob      = address(0x2);
    address carol    = address(0x3);
    address treasury_ = address(0xFEED);

    uint256 constant GOLD_MINT_PRICE   = 30_000_000;
    uint256 constant PLAT_MINT_PRICE   = 120_000_000;
    uint256 constant DIAM_MINT_PRICE   = 480_000_000;
    uint256 constant BLACK_MINT_PRICE  = 1_920_000_000;
    uint256 constant NON_MEMBER_AMOUNT = 100_000_000;
    uint256 constant SECONDS_PER_MONTH = 30 * 86_400;
    uint256 constant SECONDS_PER_DAY   = 86_400;

    function setUp() public {
        usdc = new MockUSDC();

        vm.startPrank(owner);
        BiliquidVIPCard impl = new BiliquidVIPCard();
        bytes memory initData = abi.encodeWithSelector(
            BiliquidVIPCard.initialize.selector, address(usdc), treasury_
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        card = BiliquidVIPCard(address(proxy));
        vm.stopPrank();

        usdc.mint(alice, 10_000_000_000);
        usdc.mint(bob,   10_000_000_000);
        usdc.mint(carol, 10_000_000_000);

        vm.prank(alice); usdc.approve(address(card), type(uint256).max);
        vm.prank(bob);   usdc.approve(address(card), type(uint256).max);
        vm.prank(carol); usdc.approve(address(card), type(uint256).max);
    }

    function _fundContractForInterest() internal {
        usdc.mint(address(card), 100_000_000_000);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  INITIALIZATION
    // ═══════════════════════════════════════════════════════════════════════════

    function test_init_tierConfigs() public view {
        (uint256 mp, uint256 msa, uint256 apy, uint256 maxCount) = card.tierConfigs(1);
        assertEq(mp,       30_000_000);
        assertEq(msa,      30_000_000);
        assertEq(apy,      900);
        assertEq(maxCount, 100_000);

        (mp, msa, apy, maxCount) = card.tierConfigs(4);
        assertEq(mp,  1_920_000_000);
        assertEq(apy, 1500);
    }

    function test_init_validTerms() public view {
        uint8[] memory terms = card.getValidTerms();
        assertEq(terms.length, 3);
        bool has3; bool has6; bool has12;
        for (uint256 i = 0; i < terms.length; i++) {
            if (terms[i] == 3)  has3  = true;
            if (terms[i] == 6)  has6  = true;
            if (terms[i] == 12) has12 = true;
        }
        assertTrue(has3 && has6 && has12);
        assertEq(card.termMultiplierBps(3),  10500);
        assertEq(card.termMultiplierBps(6),  11000);
        assertEq(card.termMultiplierBps(12), 11500);
    }

    function test_init_nonMemberConfig() public view {
        (uint256 amount, uint256 baseApy, uint256 flexApy, bool flexEnabled) = card.nonMemberConfig();
        assertEq(amount,  100_000_000);
        assertEq(baseApy, 400);
        assertEq(flexApy, 300);
        assertFalse(flexEnabled);
    }

    function test_init_nextSerials() public view {
        assertEq(card.nextSerial(1), 1);
        assertEq(card.nextSerial(2), 1);
        assertEq(card.nextSerial(3), 1);
        assertEq(card.nextSerial(4), 1);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  MINTING
    // ═══════════════════════════════════════════════════════════════════════════

    function test_mintCard_gold() public {
        vm.prank(alice);
        card.mintCard(1, 1);

        assertEq(usdc.balanceOf(alice), 10_000_000_000 - GOLD_MINT_PRICE);
        assertEq(card.balanceOf(alice, 1), 1);
        assertEq(card.nextSerial(1), 2);
        assertEq(card.cardOwner(1, 1), alice);

        uint256[] memory serials = card.getCardsByOwner(alice, 1);
        assertEq(serials.length, 1);
        assertEq(serials[0], 1);
    }

    function test_mintCard_multipleCards() public {
        vm.prank(alice);
        card.mintCard(1, 3);

        assertEq(card.balanceOf(alice, 1), 3);
        assertEq(card.nextSerial(1), 4);
        assertEq(card.getCardsByOwner(alice, 1).length, 3);
    }

    function test_mintCard_allTiers() public {
        vm.startPrank(alice);
        card.mintCard(1, 1);
        card.mintCard(2, 1);
        card.mintCard(3, 1);
        card.mintCard(4, 1);
        vm.stopPrank();

        assertEq(card.balanceOf(alice, 1), 1);
        assertEq(card.balanceOf(alice, 2), 1);
        assertEq(card.balanceOf(alice, 3), 1);
        assertEq(card.balanceOf(alice, 4), 1);
    }

    function test_mintCard_invalidTier_reverts() public {
        vm.prank(alice);
        vm.expectRevert("BiliquidVIPCard: invalid tier");
        card.mintCard(5, 1);
    }

    function test_mintCard_zeroAmount_reverts() public {
        vm.prank(alice);
        vm.expectRevert("BiliquidVIPCard: amount=0");
        card.mintCard(1, 0);
    }

    function test_mintCard_serialsSequential_multiUser() public {
        vm.prank(alice); card.mintCard(1, 2);
        vm.prank(bob);   card.mintCard(1, 1);

        assertEq(card.cardOwner(1, 1), alice);
        assertEq(card.cardOwner(1, 2), alice);
        assertEq(card.cardOwner(1, 3), bob);
        assertEq(card.nextSerial(1), 4);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  GIFT POOL
    // ═══════════════════════════════════════════════════════════════════════════

    function test_adminMintToPool_and_giftCard() public {
        vm.startPrank(owner);
        card.adminMintToPool(2, 3);
        assertEq(card.balanceOf(address(card), 2), 3);
        assertEq(card.cardOwner(2, 1), address(card));

        card.giftCard(2, 2, alice);
        vm.stopPrank();

        assertEq(card.cardOwner(2, 2), alice);
        assertEq(card.balanceOf(alice, 2), 1);
        assertEq(card.balanceOf(address(card), 2), 2);
    }

    function test_giftCard_notInPool_reverts() public {
        vm.prank(alice); card.mintCard(1, 1);

        vm.prank(owner);
        vm.expectRevert("BiliquidVIPCard: not in gift pool");
        card.giftCard(1, 1, bob);
    }

    function test_adminMintToPool_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        card.adminMintToPool(1, 1);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  CARD TRANSFER
    // ═══════════════════════════════════════════════════════════════════════════

    function test_transferCard() public {
        vm.prank(alice); card.mintCard(1, 2); // serials 1, 2

        vm.prank(alice); card.transferCard(1, 1, bob);

        assertEq(card.cardOwner(1, 1), bob);
        assertEq(card.balanceOf(alice, 1), 1);
        assertEq(card.balanceOf(bob, 1), 1);

        uint256[] memory aliceSerials = card.getCardsByOwner(alice, 1);
        assertEq(aliceSerials.length, 1);

        uint256[] memory bobSerials = card.getCardsByOwner(bob, 1);
        assertEq(bobSerials.length, 1);
        assertEq(bobSerials[0], 1);
    }

    function test_transferCard_swapAndPop_integrity() public {
        vm.prank(alice); card.mintCard(1, 3); // serials 1, 2, 3

        vm.prank(alice); card.transferCard(1, 2, bob); // remove middle

        uint256[] memory serials = card.getCardsByOwner(alice, 1);
        assertEq(serials.length, 2);
        assertEq(card.cardOwner(1, 1), alice);
        assertEq(card.cardOwner(1, 3), alice);
        assertEq(card.cardOwner(1, 2), bob);
    }

    function test_transferCard_notOwner_reverts() public {
        vm.prank(alice); card.mintCard(1, 1);

        vm.prank(bob);
        vm.expectRevert("BiliquidVIPCard: not owner");
        card.transferCard(1, 1, carol);
    }

    function test_transferCard_stakedCard_reverts() public {
        _fundContractForInterest();
        vm.prank(alice); card.mintCard(1, 1);
        vm.prank(alice); card.stakeCard(1, 1, 3);

        vm.prank(alice);
        vm.expectRevert("BiliquidVIPCard: card is staked");
        card.transferCard(1, 1, bob);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  MEMBER STAKING
    // ═══════════════════════════════════════════════════════════════════════════

    function test_stakeCard_3month() public {
        _fundContractForInterest();
        vm.prank(alice); card.mintCard(1, 1);

        uint256 aliceBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        uint256 stakeId = card.stakeCard(1, 1, 3);

        assertEq(stakeId, 0);
        assertEq(usdc.balanceOf(alice), aliceBefore - GOLD_MINT_PRICE);
        assertTrue(card.cardStaked(1, 1));
        assertEq(card.totalStakedByTier(1), 1);

        BiliquidVIPCard.StakeRecord[] memory records = card.getStakeRecords(alice);
        assertEq(records.length, 1);
        assertTrue(records[0].isMember);
        assertEq(records[0].tier, 1);
        assertEq(records[0].cardSerial, 1);
        assertFalse(records[0].isFlexible);
        assertEq(records[0].termMonths, 3);
        assertEq(records[0].usdcAmount, GOLD_MINT_PRICE);
        assertTrue(records[0].active);
        // Gold 9% * 105% = 945 bps
        assertEq(records[0].snapshotApyBps, 900 * 10500 / 10000);
    }

    function test_stakeCard_activePositionTracking() public {
        _fundContractForInterest();
        vm.prank(alice); card.mintCard(1, 1);
        vm.prank(alice); card.stakeCard(1, 1, 3);

        (uint256 sid, bool hasPos) = card.getActivePositionByCard(1, 1);
        assertTrue(hasPos);
        assertEq(sid, 0);
    }

    function test_stakeCard_doubleStake_reverts() public {
        vm.prank(alice); card.mintCard(1, 1);
        vm.prank(alice); card.stakeCard(1, 1, 3);

        vm.prank(alice);
        vm.expectRevert("BiliquidVIPCard: card already staked");
        card.stakeCard(1, 1, 6);
    }

    function test_stakeCard_invalidTerm_reverts() public {
        vm.prank(alice); card.mintCard(1, 1);

        vm.prank(alice);
        vm.expectRevert("BiliquidVIPCard: invalid term");
        card.stakeCard(1, 1, 9);
    }

    function test_stakeCard_notOwner_reverts() public {
        vm.prank(alice); card.mintCard(1, 1);

        vm.prank(bob);
        vm.expectRevert("BiliquidVIPCard: not card owner");
        card.stakeCard(1, 1, 3);
    }

    function test_stakeCard_flexible_disabled_reverts() public {
        vm.prank(alice); card.mintCard(1, 1);

        vm.prank(alice);
        vm.expectRevert("BiliquidVIPCard: flexible staking disabled");
        card.stakeCard(1, 1, 0);
    }

    function test_stakeCard_flexible_enabled() public {
        _fundContractForInterest();
        vm.prank(owner); card.setMemberFlexibleStaking(true, 600);

        vm.prank(alice); card.mintCard(1, 1);
        vm.prank(alice); card.stakeCard(1, 1, 0);

        BiliquidVIPCard.StakeRecord[] memory records = card.getStakeRecords(alice);
        assertTrue(records[0].isFlexible);
        assertEq(records[0].snapshotApyBps, 600);
        assertEq(records[0].unlockedAt, records[0].stakedAt);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  NON-MEMBER STAKING
    // ═══════════════════════════════════════════════════════════════════════════

    function test_stakeNonMember_3month() public {
        _fundContractForInterest();
        uint256 bobBefore = usdc.balanceOf(bob);

        vm.prank(bob); card.stakeNonMember(3);

        assertEq(usdc.balanceOf(bob), bobBefore - NON_MEMBER_AMOUNT);

        BiliquidVIPCard.StakeRecord[] memory records = card.getStakeRecords(bob);
        assertEq(records.length, 1);
        assertFalse(records[0].isMember);
        assertEq(records[0].usdcAmount, NON_MEMBER_AMOUNT);
        // 4% * 105% = 420 bps
        assertEq(records[0].snapshotApyBps, 400 * 10500 / 10000);
        assertFalse(records[0].isFlexible);
        assertEq(records[0].termMonths, 3);
    }

    function test_stakeNonMember_flexible_enabled() public {
        _fundContractForInterest();
        vm.prank(owner); card.setNonMemberConfig(100_000_000, 400, 300, true);

        vm.prank(bob); card.stakeNonMember(0);

        BiliquidVIPCard.StakeRecord[] memory records = card.getStakeRecords(bob);
        assertTrue(records[0].isFlexible);
        assertEq(records[0].snapshotApyBps, 300);
    }

    function test_stakeNonMember_flexible_disabled_reverts() public {
        vm.prank(bob);
        vm.expectRevert("BiliquidVIPCard: non-member flexible disabled");
        card.stakeNonMember(0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  INTEREST CALCULATIONS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_dailyInterest_gold_3month() public {
        _fundContractForInterest();
        vm.prank(alice); card.mintCard(1, 1);
        vm.prank(alice); card.stakeCard(1, 1, 3);

        // Gold 9% * 105% = 945 bps
        uint256 expected = uint256(30_000_000) * 945 / (uint256(10_000) * 365);
        assertEq(card.dailyInterestFor(alice, 0), expected);
    }

    function test_pendingInterest_after30days() public {
        _fundContractForInterest();
        vm.prank(alice); card.mintCard(1, 1);
        vm.prank(alice); card.stakeCard(1, 1, 3);

        vm.warp(block.timestamp + 30 * SECONDS_PER_DAY);

        uint256 pending = card.pendingInterest(alice, 0);
        uint256 daily   = card.dailyInterestFor(alice, 0);
        assertEq(pending, daily * 30);
    }

    function test_pendingInterest_15days_is_zero() public {
        _fundContractForInterest();
        vm.prank(alice); card.mintCard(1, 1);
        vm.prank(alice); card.stakeCard(1, 1, 3);

        vm.warp(block.timestamp + 15 * SECONDS_PER_DAY);

        assertEq(card.pendingInterest(alice, 0), 0); // not yet claimable
        assertGt(card.pendingInterestExact(alice, 0), 0); // but accruing
    }

    function test_claimInterest_after30days() public {
        _fundContractForInterest();
        vm.prank(alice); card.mintCard(1, 1);
        vm.prank(alice); card.stakeCard(1, 1, 3);

        vm.warp(block.timestamp + 31 * SECONDS_PER_DAY);

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice); card.claimInterest(0);

        uint256 daily = uint256(30_000_000) * 945 / (uint256(10_000) * 365);
        assertEq(usdc.balanceOf(alice), aliceBefore + daily * 30);
    }

    function test_claimInterest_twice_in_60days() public {
        _fundContractForInterest();
        vm.prank(alice); card.mintCard(1, 1);
        vm.prank(alice); card.stakeCard(1, 1, 12);

        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 daily = card.dailyInterestFor(alice, 0);

        vm.warp(block.timestamp + 30 * SECONDS_PER_DAY);
        vm.prank(alice); card.claimInterest(0);
        assertEq(usdc.balanceOf(alice), aliceBefore + daily * 30);

        vm.warp(block.timestamp + 30 * SECONDS_PER_DAY);
        vm.prank(alice); card.claimInterest(0);
        assertEq(usdc.balanceOf(alice), aliceBefore + daily * 60);
    }

    function test_claimInterest_tooEarly_reverts() public {
        _fundContractForInterest();
        vm.prank(alice); card.mintCard(1, 1);
        vm.prank(alice); card.stakeCard(1, 1, 3);

        vm.warp(block.timestamp + 29 * SECONDS_PER_DAY);
        vm.prank(alice);
        vm.expectRevert("BiliquidVIPCard: claim once per 30 days");
        card.claimInterest(0);
    }

    function test_claimAllInterest_multiplePositions() public {
        _fundContractForInterest();
        vm.prank(owner); card.setNonMemberConfig(100_000_000, 400, 300, true);

        vm.prank(alice); card.mintCard(1, 1);
        vm.prank(alice); card.stakeCard(1, 1, 3);     // position 0 (member)
        vm.prank(alice); card.stakeNonMember(3);      // position 1 (non-member)

        vm.warp(block.timestamp + 31 * SECONDS_PER_DAY);
        uint256 aliceBefore = usdc.balanceOf(alice);

        vm.prank(alice); card.claimAllInterest();

        uint256 memberDaily = card.dailyInterestFor(alice, 0);
        uint256 nmApyBps    = 400 * 10500 / 10000; // 420 bps
        uint256 nmDaily     = 100_000_000 * nmApyBps / (10_000 * 365);
        assertEq(usdc.balanceOf(alice), aliceBefore + (memberDaily + nmDaily) * 30);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  UNSTAKE
    // ═══════════════════════════════════════════════════════════════════════════

    function test_unstake_fixedTerm_afterMaturity() public {
        _fundContractForInterest();
        vm.prank(alice); card.mintCard(1, 1);
        vm.prank(alice); card.stakeCard(1, 1, 3);

        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 daily       = card.dailyInterestFor(alice, 0);

        vm.warp(block.timestamp + 3 * SECONDS_PER_MONTH + 1);
        vm.prank(alice); card.unstake(0);

        // Principal + 3 months (90 days) interest
        assertEq(usdc.balanceOf(alice), aliceBefore + GOLD_MINT_PRICE + daily * 90);
        assertFalse(card.cardStaked(1, 1));
        assertEq(card.totalStakedByTier(1), 0);

        (,bool hasPos) = card.getActivePositionByCard(1, 1);
        assertFalse(hasPos);

        assertFalse(card.getStakeRecords(alice)[0].active);
    }

    function test_unstake_fixedTerm_beforeMaturity_reverts() public {
        vm.prank(alice); card.mintCard(1, 1);
        vm.prank(alice); card.stakeCard(1, 1, 3);

        vm.warp(block.timestamp + 89 * SECONDS_PER_DAY);

        vm.prank(alice);
        vm.expectRevert("BiliquidVIPCard: still locked");
        card.unstake(0);
    }

    function test_unstake_flexible_anytime() public {
        _fundContractForInterest();
        vm.prank(owner); card.setMemberFlexibleStaking(true, 600);

        vm.prank(alice); card.mintCard(1, 1);
        vm.prank(alice); card.stakeCard(1, 1, 0);

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.warp(block.timestamp + 5 * SECONDS_PER_DAY); // no lock

        vm.prank(alice); card.unstake(0);
        assertEq(usdc.balanceOf(alice), aliceBefore + GOLD_MINT_PRICE); // no interest (< 30 days)
    }

    function test_unstake_forfeits_partial_month_interest() public {
        _fundContractForInterest();
        vm.prank(alice); card.mintCard(1, 1);
        vm.prank(alice); card.stakeCard(1, 1, 3);

        uint256 daily = card.dailyInterestFor(alice, 0);
        vm.warp(block.timestamp + 3 * SECONDS_PER_MONTH + 15 * SECONDS_PER_DAY);

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice); card.unstake(0);

        // Only 3 whole months (90 days); partial 15 days forfeited
        assertEq(usdc.balanceOf(alice), aliceBefore + GOLD_MINT_PRICE + daily * 90);
    }

    function test_unstake_nonMember() public {
        _fundContractForInterest();
        vm.prank(bob); card.stakeNonMember(6);

        uint256 bobBefore = usdc.balanceOf(bob);
        uint256 daily     = card.dailyInterestFor(bob, 0);

        vm.warp(block.timestamp + 6 * SECONDS_PER_MONTH);
        vm.prank(bob); card.unstake(0);

        assertEq(usdc.balanceOf(bob), bobBefore + NON_MEMBER_AMOUNT + daily * 180);
    }

    function test_unstake_thenRestake_sameCard() public {
        _fundContractForInterest();
        vm.prank(alice); card.mintCard(1, 1);
        vm.prank(alice); card.stakeCard(1, 1, 3);

        vm.warp(block.timestamp + 3 * SECONDS_PER_MONTH);
        vm.prank(alice); card.unstake(0);

        // Re-stake same card
        vm.prank(alice);
        uint256 stakeId2 = card.stakeCard(1, 1, 6);
        assertEq(stakeId2, 1);
        assertTrue(card.cardStaked(1, 1));
    }

    function test_unstake_inactive_reverts() public {
        _fundContractForInterest();
        vm.prank(alice); card.mintCard(1, 1);
        vm.prank(alice); card.stakeCard(1, 1, 3);

        vm.warp(block.timestamp + 3 * SECONDS_PER_MONTH);
        vm.prank(alice); card.unstake(0);

        vm.prank(alice);
        vm.expectRevert("BiliquidVIPCard: position not active");
        card.unstake(0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  APY SNAPSHOT ISOLATION
    // ═══════════════════════════════════════════════════════════════════════════

    function test_snapshotApy_unchangedByAdminUpdate() public {
        _fundContractForInterest();
        vm.prank(alice); card.mintCard(1, 1);
        vm.prank(alice); card.stakeCard(1, 1, 3);

        uint256 originalApy = card.getStakeRecords(alice)[0].snapshotApyBps;

        vm.prank(owner); card.setTierConfig(1, 30_000_000, 30_000_000, 1500, 100_000);

        assertEq(card.getStakeRecords(alice)[0].snapshotApyBps, originalApy);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  GLOBAL STAKE CAP
    // ═══════════════════════════════════════════════════════════════════════════

    function test_globalStakeCap() public {
        // Set cap to 2 for gold to keep test cheap
        vm.prank(owner); card.setTierConfig(1, 30_000_000, 30_000_000, 900, 2);
        _fundContractForInterest();

        vm.prank(alice); card.mintCard(1, 1);
        vm.prank(bob);   card.mintCard(1, 1);
        vm.prank(carol); card.mintCard(1, 1);

        vm.prank(alice); card.stakeCard(1, 1, 3); // count = 1
        vm.prank(bob);   card.stakeCard(1, 2, 3); // count = 2

        vm.prank(carol);
        vm.expectRevert("BiliquidVIPCard: tier stake cap reached");
        card.stakeCard(1, 3, 3);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  USER STATE VIEW
    // ═══════════════════════════════════════════════════════════════════════════

    function test_getUserState() public {
        _fundContractForInterest();
        vm.prank(alice); card.mintCard(1, 2);
        vm.prank(alice); card.mintCard(2, 1);
        vm.prank(alice); card.stakeCard(1, 1, 3);

        (uint256 gc, uint256 pc, uint256 dc, uint256 bc,
         uint256 gs, uint256 ps, uint256 ds, uint256 bs,
         address ref, uint8 role) = card.getUserState(alice);

        assertEq(gc, 2);  // 2 gold cards
        assertEq(pc, 1);  // 1 platinum card
        assertEq(dc, 0);
        assertEq(bc, 0);
        assertEq(gs, 1);  // 1 gold staked
        assertEq(ps, 0);
        assertEq(ds, 0);
        assertEq(bs, 0);
        assertEq(ref, address(0));
        assertEq(role, 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  REGISTRATION & REFERRAL
    // ═══════════════════════════════════════════════════════════════════════════

    function test_register_noReferrer() public {
        vm.prank(alice); card.register(address(0));
        assertEq(card.registrationDepth(alice), 1);
        assertEq(card.referrerOf(alice), address(0));
    }

    function test_register_withReferrer() public {
        vm.prank(alice); card.register(address(0));
        vm.prank(bob);   card.register(alice);

        assertEq(card.registrationDepth(bob), 2);
        assertEq(card.referrerOf(bob), alice);
    }

    function test_register_twice_reverts() public {
        vm.prank(alice); card.register(address(0));
        vm.prank(alice);
        vm.expectRevert("BiliquidVIPCard: already registered");
        card.register(address(0));
    }

    function test_referral_directReward() public {
        vm.prank(alice); card.register(address(0));
        vm.prank(bob);   card.register(alice);

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(bob); card.mintCard(1, 1); // 30 USDC mint

        // direct: 10% of 30 USDC = 3 USDC
        assertEq(usdc.balanceOf(alice), aliceBefore + 3_000_000);
    }

    function test_referral_indirectReward() public {
        vm.prank(alice); card.register(address(0));
        vm.prank(bob);   card.register(alice);
        vm.prank(carol); card.register(bob);

        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 bobBefore   = usdc.balanceOf(bob);

        vm.prank(carol); card.mintCard(1, 1); // 30 USDC

        assertEq(usdc.balanceOf(bob),   bobBefore   + 3_000_000); // direct 10%
        assertEq(usdc.balanceOf(alice), aliceBefore + 1_500_000); // indirect 5%
    }

    function test_referral_nodeBoost() public {
        vm.prank(alice); card.register(address(0));
        vm.prank(owner); card.setRole(alice, 1); // ROLE_NODE
        vm.prank(bob);   card.register(alice);

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(bob); card.mintCard(1, 1); // 30 USDC

        // direct 10% + node_boost 5% = 15% of 30 = 4.5 USDC
        assertEq(usdc.balanceOf(alice), aliceBefore + 4_500_000);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  ADMIN FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_setTierConfig() public {
        vm.prank(owner); card.setTierConfig(1, 50_000_000, 50_000_000, 1000, 50_000);
        (uint256 mp,,,) = card.tierConfigs(1);
        assertEq(mp, 50_000_000);
    }

    function test_addTerm_and_useIt() public {
        _fundContractForInterest();
        vm.prank(owner); card.addTerm(24, 12500);

        vm.prank(alice); card.mintCard(1, 1);
        vm.prank(alice); card.stakeCard(1, 1, 24);

        // Gold 9% * 125% = 1125 bps
        assertEq(card.getStakeRecords(alice)[0].snapshotApyBps, 900 * 12500 / 10000);
    }

    function test_removeTerm() public {
        vm.prank(owner); card.removeTerm(6);

        vm.prank(alice); card.mintCard(1, 1);
        vm.prank(alice);
        vm.expectRevert("BiliquidVIPCard: invalid term");
        card.stakeCard(1, 1, 6);
    }

    function test_setPaused() public {
        vm.prank(owner); card.setPaused(true);

        vm.prank(alice);
        vm.expectRevert("BiliquidVIPCard: paused");
        card.mintCard(1, 1);
    }

    function test_withdrawToTreasury() public {
        usdc.mint(address(card), 1_000_000);
        vm.prank(owner); card.withdrawToTreasury(address(usdc), 1_000_000);
        assertEq(usdc.balanceOf(treasury_), 1_000_000);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  ERC-1155 STANDARD
    // ═══════════════════════════════════════════════════════════════════════════

    function test_supportsInterface() public view {
        assertTrue(card.supportsInterface(0xd9b67a26));
        assertTrue(card.supportsInterface(0x01ffc9a7));
    }

    function test_balanceOfBatch() public {
        vm.prank(alice); card.mintCard(1, 2);
        vm.prank(alice); card.mintCard(2, 1);

        address[] memory accounts = new address[](2);
        uint256[] memory ids      = new uint256[](2);
        accounts[0] = alice; ids[0] = 1;
        accounts[1] = alice; ids[1] = 2;

        uint256[] memory bals = card.balanceOfBatch(accounts, ids);
        assertEq(bals[0], 2);
        assertEq(bals[1], 1);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  EDGE CASES & MULTI-POSITION
    // ═══════════════════════════════════════════════════════════════════════════

    function test_multiplePositions_sameWallet() public {
        _fundContractForInterest();
        vm.prank(alice); card.mintCard(1, 3);

        vm.startPrank(alice);
        card.stakeCard(1, 1, 3);
        card.stakeCard(1, 2, 6);
        card.stakeCard(1, 3, 12);
        card.stakeNonMember(3);
        vm.stopPrank();

        assertEq(card.getStakeRecords(alice).length, 4);
        assertEq(card.totalStakedByTier(1), 3);
    }

    function test_pendingInterest_inactivePosition_zero() public {
        _fundContractForInterest();
        vm.prank(alice); card.mintCard(1, 1);
        vm.prank(alice); card.stakeCard(1, 1, 3);

        vm.warp(block.timestamp + 3 * SECONDS_PER_MONTH);
        vm.prank(alice); card.unstake(0);

        assertEq(card.pendingInterest(alice, 0), 0);
        assertEq(card.pendingInterestExact(alice, 0), 0);
    }

    function test_getActivePositionByCard_afterUnstake() public {
        _fundContractForInterest();
        vm.prank(alice); card.mintCard(1, 1);
        vm.prank(alice); card.stakeCard(1, 1, 3);

        vm.warp(block.timestamp + 3 * SECONDS_PER_MONTH);
        vm.prank(alice); card.unstake(0);

        (,bool hasPos) = card.getActivePositionByCard(1, 1);
        assertFalse(hasPos);
    }

    function test_claimAllInterest_skipsInactive() public {
        _fundContractForInterest();
        vm.prank(alice); card.mintCard(1, 2);

        vm.startPrank(alice);
        card.stakeCard(1, 1, 3);
        card.stakeCard(1, 2, 3);
        vm.stopPrank();

        vm.warp(block.timestamp + 3 * SECONDS_PER_MONTH);
        vm.prank(alice); card.unstake(0); // unstake position 0

        // Advance time; claimAllInterest should work (only position 1 is active)
        vm.warp(block.timestamp + 30 * SECONDS_PER_DAY);
        vm.prank(alice); card.claimAllInterest(); // must not revert
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  INTEREST MATH PRECISION
    // ═══════════════════════════════════════════════════════════════════════════

    function test_interest_gold_12month_fullCycle() public {
        _fundContractForInterest();
        vm.prank(alice); card.mintCard(1, 1);
        vm.prank(alice); card.stakeCard(1, 1, 12);

        // Gold 9% * 115% = 1035 bps
        uint256 daily = card.dailyInterestFor(alice, 0);
        assertEq(daily, uint256(30_000_000) * 1035 / (uint256(10_000) * 365));

        vm.warp(block.timestamp + 360 * SECONDS_PER_DAY + 1);
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice); card.unstake(0);

        assertEq(usdc.balanceOf(alice), aliceBefore + GOLD_MINT_PRICE + daily * 360);
    }

    function test_interest_nonMember_12month() public {
        _fundContractForInterest();
        vm.prank(bob); card.stakeNonMember(12);

        // 4% * 115% = 460 bps
        uint256 daily = card.dailyInterestFor(bob, 0);
        assertEq(daily, uint256(100_000_000) * 460 / (uint256(10_000) * 365));

        vm.warp(block.timestamp + 360 * SECONDS_PER_DAY + 1);
        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob); card.unstake(0);

        assertEq(usdc.balanceOf(bob), bobBefore + NON_MEMBER_AMOUNT + daily * 360);
    }
}
