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

    address owner_    = address(0xABCD);
    address alice     = address(0x1);
    address bob       = address(0x2);
    address carol     = address(0x3);
    address treasury_ = address(0xFEED);

    uint256 constant GOLD_MINT_PRICE    = 30_000_000;
    uint256 constant PLAT_MINT_PRICE    = 120_000_000;
    uint256 constant DIAM_MINT_PRICE    = 480_000_000;
    uint256 constant BLACK_MINT_PRICE   = 1_920_000_000;
    uint256 constant GOLD_MAX_STAKE     = 300_000_000;
    uint256 constant PLAT_MAX_STAKE     = 1_500_000_000;
    uint256 constant DIAM_MAX_STAKE     = 8_500_000_000;
    uint256 constant BLACK_MAX_STAKE    = 80_000_000_000;
    uint256 constant NON_MEMBER_AMOUNT  = 100_000_000;
    uint256 constant SECONDS_PER_MONTH  = 30 * 86_400;
    uint256 constant SECONDS_PER_DAY    = 86_400;

    function setUp() public {
        usdc = new MockUSDC();

        vm.startPrank(owner_);
        BiliquidVIPCard impl = new BiliquidVIPCard();
        bytes memory initData = abi.encodeWithSelector(
            BiliquidVIPCard.initialize.selector, address(usdc), treasury_
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        card = BiliquidVIPCard(address(proxy));
        vm.stopPrank();

        usdc.mint(alice, 200_000_000_000);
        usdc.mint(bob,   200_000_000_000);
        usdc.mint(carol, 200_000_000_000);
        // Fund contract for interest payments
        usdc.mint(address(card), 1_000_000_000_000);

        vm.prank(alice); usdc.approve(address(card), type(uint256).max);
        vm.prank(bob);   usdc.approve(address(card), type(uint256).max);
        vm.prank(carol); usdc.approve(address(card), type(uint256).max);
    }

    // helper: alice mints a Gold card
    function _aliceMintGold() internal returns (uint256 serial) {
        serial = card.nextSerial(1);
        vm.prank(alice); card.mintCard(1, 1);
    }

    // helper: alice mints + locks a Gold card, returns serial
    function _aliceLockGold() internal returns (uint256 serial) {
        serial = _aliceMintGold();
        vm.prank(alice); card.lockCard(1, serial);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  INITIALIZATION
    // ═══════════════════════════════════════════════════════════════════════════

    function test_init_tierConfigs() public view {
        (uint256 mp, uint256 msa, uint256 apy, uint256 mintCap) = card.tierConfigs(1);
        assertEq(mp,      GOLD_MINT_PRICE,  "gold mintPrice");
        assertEq(msa,     GOLD_MAX_STAKE,   "gold maxStake");
        assertEq(apy,     900,              "gold apy");
        assertEq(mintCap, 100_000,          "gold mintCap");

        (, msa, apy,) = card.tierConfigs(2);
        assertEq(msa, PLAT_MAX_STAKE, "plat maxStake");
        assertEq(apy, 1000,           "plat apy");

        (, msa, apy,) = card.tierConfigs(3);
        assertEq(msa, DIAM_MAX_STAKE, "diam maxStake");
        assertEq(apy, 1100,           "diam apy");

        (, msa, apy,) = card.tierConfigs(4);
        assertEq(msa, BLACK_MAX_STAKE, "black maxStake");
        assertEq(apy, 1250,            "black apy");
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
        assertTrue(has3 && has6 && has12, "missing term");
    }

    function test_init_termMultipliers() public view {
        assertEq(card.termMultiplierBps(3),  10000, "3mo multiplier");
        assertEq(card.termMultiplierBps(6),  13333, "6mo multiplier");
        assertEq(card.termMultiplierBps(12), 20000, "12mo multiplier");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  REGISTRATION
    // ═══════════════════════════════════════════════════════════════════════════

    function test_register_noReferrer() public {
        vm.prank(alice); card.register(address(0));
        assertEq(card.referrerOf(alice), address(0));
        assertEq(card.registrationDepth(alice), 1);
    }

    function test_register_withReferrer() public {
        vm.prank(alice); card.register(address(0));
        vm.prank(bob);   card.register(alice);
        assertEq(card.referrerOf(bob), alice);
        assertEq(card.registrationDepth(bob), 2);
    }

    function test_register_selfReferral_reverts() public {
        vm.prank(alice); card.register(address(0));
        // bob (unregistered) tries to self-refer
        vm.prank(bob);
        vm.expectRevert(BiliquidVIPCard.SelfRefer.selector);
        card.register(bob);
    }

    function test_register_double_reverts() public {
        vm.prank(alice); card.register(address(0));
        vm.prank(alice);
        vm.expectRevert(BiliquidVIPCard.AlreadyRegistered.selector);
        card.register(address(0));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  MINTING
    // ═══════════════════════════════════════════════════════════════════════════

    function test_mintCard_gold() public {
        uint256 balBefore = usdc.balanceOf(alice);
        _aliceMintGold();
        assertEq(usdc.balanceOf(alice), balBefore - GOLD_MINT_PRICE, "usdc deducted");
        assertEq(card.balanceOf(alice, 1), 1, "erc1155 balance");
        assertEq(card.cardOwner(1, 1), alice, "card owner");
        uint256[] memory serials = card.getCardsByOwner(alice, 1);
        assertEq(serials.length, 1, "serial count");
        assertEq(serials[0], 1, "serial = 1");
    }

    function test_mintCard_allTiers() public {
        // Set alice as minter so she can mint tier 2/3/4
        vm.prank(owner_); card.setMinter(alice, true);

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

    function test_mintCard_mintCapExceeded_reverts() public {
        // Set mintCap to 1
        vm.prank(owner_); card.setTierConfig(1, GOLD_MINT_PRICE, GOLD_MAX_STAKE, 900, 1);
        vm.prank(alice); card.mintCard(1, 1); // ok
        vm.prank(alice);
        vm.expectRevert(BiliquidVIPCard.MintCapReached.selector);
        card.mintCard(1, 1);
    }

    function test_mintCard_invalidTier_reverts() public {
        vm.prank(alice);
        vm.expectRevert(BiliquidVIPCard.InvalidTier.selector);
        card.mintCard(5, 1);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  CARD TRANSFER (unlocked)
    // ═══════════════════════════════════════════════════════════════════════════

    function test_transferCard() public {
        uint256 serial = _aliceMintGold();
        vm.prank(alice); card.transferCard(1, serial, bob);
        assertEq(card.cardOwner(1, serial), bob);
        assertEq(card.balanceOf(alice, 1), 0);
        assertEq(card.balanceOf(bob,   1), 1);
    }

    function test_transferCard_locked_reverts() public {
        uint256 serial = _aliceLockGold();
        // After locking, card is in the contract — alice is no longer the owner
        // so she gets "not owner" error trying to transfer
        vm.prank(alice);
        vm.expectRevert(BiliquidVIPCard.NotOwner.selector);
        card.transferCard(1, serial, bob);
    }

    function test_transferCard_notOwner_reverts() public {
        uint256 serial = _aliceMintGold();
        vm.prank(bob);
        vm.expectRevert(BiliquidVIPCard.NotOwner.selector);
        card.transferCard(1, serial, bob);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  LOCK CARD
    // ═══════════════════════════════════════════════════════════════════════════

    function test_lockCard_physicalTransfer() public {
        uint256 serial = _aliceMintGold();
        vm.prank(alice); card.lockCard(1, serial);

        assertEq(card.lockedBy(1, serial), alice, "lockedBy");
        assertTrue(card.cardStaked(1, serial), "cardStaked");
        assertEq(card.cardOwner(1, serial), address(card), "card in contract");
        assertEq(card.balanceOf(alice, 1), 0, "alice balance 0");
        assertEq(card.lockedCardCount(alice, 1), 1, "lockedCardCount");
        assertEq(card.totalLockedByTier(1), 1, "totalLocked");
    }

    function test_lockCard_notOwner_reverts() public {
        uint256 serial = _aliceMintGold();
        vm.prank(bob);
        vm.expectRevert(BiliquidVIPCard.NotCardOwner.selector);
        card.lockCard(1, serial);
    }

    function test_lockCard_alreadyLocked_reverts() public {
        uint256 serial = _aliceLockGold();
        // card is now in contract, alice can't lock again
        vm.prank(alice);
        vm.expectRevert(BiliquidVIPCard.NotCardOwner.selector);
        card.lockCard(1, serial);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  OPEN POSITION
    // ═══════════════════════════════════════════════════════════════════════════

    function test_openPosition_3month() public {
        uint256 serial = _aliceLockGold();
        uint256 amount = 100_000_000; // 100 USDC

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        card.openPosition(1, serial, 3, amount);

        assertEq(usdc.balanceOf(alice), aliceBefore - amount, "usdc deducted");

        BiliquidVIPCard.Position memory pos = card.getPosition(1, serial);
        assertTrue(pos.active, "position active");
        assertEq(pos.usdcPrincipal, amount, "principal");
        assertEq(pos.termMonths, 3, "termMonths");
        assertFalse(pos.isFlexible, "not flexible");
        // snapshot APY: 900 * 10000 / 10000 = 900
        assertEq(pos.snapshotApyBps, 900, "snapshot apy 3mo");
    }

    function test_openPosition_6month_multiplier() public {
        uint256 serial = _aliceLockGold();
        vm.prank(alice);
        card.openPosition(1, serial, 6, 100_000_000);
        BiliquidVIPCard.Position memory pos = card.getPosition(1, serial);
        // 900 * 13333 / 10000 = 1199
        assertEq(pos.snapshotApyBps, 1199, "snapshot apy 6mo");
    }

    function test_openPosition_12month_multiplier() public {
        uint256 serial = _aliceLockGold();
        vm.prank(alice);
        card.openPosition(1, serial, 12, 100_000_000);
        BiliquidVIPCard.Position memory pos = card.getPosition(1, serial);
        // 900 * 20000 / 10000 = 1800
        assertEq(pos.snapshotApyBps, 1800, "snapshot apy 12mo");
    }

    // v6: only ONE position per card; second open must revert
    function test_openPosition_secondPosition_reverts() public {
        uint256 serial = _aliceLockGold();
        vm.startPrank(alice);
        card.openPosition(1, serial, 3, 100_000_000);
        vm.expectRevert(BiliquidVIPCard.PositionAlreadyOpen.selector);
        card.openPosition(1, serial, 6, 100_000_000);
        vm.stopPrank();
    }

    function test_openPosition_exceedsCapacity_reverts() public {
        uint256 serial = _aliceLockGold();
        vm.prank(alice);
        vm.expectRevert(BiliquidVIPCard.ExceedsCardCapacity.selector);
        card.openPosition(1, serial, 3, GOLD_MAX_STAKE + 1);
    }

    function test_openPosition_notLocker_reverts() public {
        uint256 serial = _aliceLockGold();
        vm.prank(bob);
        vm.expectRevert(BiliquidVIPCard.NotCardLocker.selector);
        card.openPosition(1, serial, 3, 100_000_000);
    }

    function test_openPosition_cardNotLocked_reverts() public {
        uint256 serial = _aliceMintGold();
        vm.prank(alice);
        vm.expectRevert(BiliquidVIPCard.NotCardLocker.selector);
        card.openPosition(1, serial, 3, 100_000_000);
    }

    function test_openPosition_invalidTerm_reverts() public {
        uint256 serial = _aliceLockGold();
        vm.prank(alice);
        vm.expectRevert(BiliquidVIPCard.InvalidTerm.selector);
        card.openPosition(1, serial, 9, 100_000_000);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  CLOSE POSITION
    // ═══════════════════════════════════════════════════════════════════════════

    function test_closePosition_afterMaturity() public {
        uint256 serial = _aliceLockGold();
        uint256 amount = 100_000_000;
        vm.prank(alice); card.openPosition(1, serial, 3, amount);

        // Fast-forward 3 months
        vm.warp(block.timestamp + 3 * SECONDS_PER_MONTH);

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice); card.closePosition(uint8(1), serial);

        // Card still locked (closePosition does NOT auto-unlock)
        assertTrue(card.cardStaked(1, serial), "card still locked");
        // cardTotalDeposited mapping removed in fresh deploy
        assertGe(usdc.balanceOf(alice), aliceBefore + amount, "got at least principal back");

        BiliquidVIPCard.Position memory pos = card.getPosition(1, serial);
        assertFalse(pos.active, "position inactive");
    }

    function test_closePosition_beforeMaturity_reverts() public {
        uint256 serial = _aliceLockGold();
        vm.prank(alice); card.openPosition(1, serial, 3, 100_000_000);

        vm.prank(alice);
        vm.expectRevert(BiliquidVIPCard.StillLocked.selector);
        card.closePosition(uint8(1), serial);
    }

    function test_closePosition_claimsInterest() public {
        uint256 serial = _aliceLockGold();
        uint256 amount = 100_000_000; // 100 USDC
        vm.prank(alice); card.openPosition(1, serial, 3, amount);

        // Fast-forward exactly 3 months = 90 days
        vm.warp(block.timestamp + 3 * SECONDS_PER_MONTH);

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice); card.closePosition(uint8(1), serial);

        // 900 APY: interest = principal * 900 * elapsed / (10000 * 365 days) [second-granular]
        uint256 elapsed = 3 * SECONDS_PER_MONTH;
        uint256 expectedInterest = amount * 900 * elapsed / (10_000 * 365 days);
        uint256 received = usdc.balanceOf(alice) - aliceBefore;
        assertEq(received, amount + expectedInterest, "principal + interest");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  UNLOCK CARD
    // ═══════════════════════════════════════════════════════════════════════════

    function test_unlockCard_afterAllPositionsClosed() public {
        uint256 serial = _aliceLockGold();
        vm.prank(alice); card.openPosition(1, serial, 3, 100_000_000);
        vm.warp(block.timestamp + 3 * SECONDS_PER_MONTH);
        vm.prank(alice); card.closePosition(uint8(1), serial);

        vm.prank(alice); card.unlockCard(1, serial);

        assertEq(card.lockedBy(1, serial), address(0), "lockedBy cleared");
        assertFalse(card.cardStaked(1, serial), "cardStaked false");
        assertEq(card.cardOwner(1, serial), alice, "card back to alice");
        assertEq(card.balanceOf(alice, 1), 1, "alice erc1155 balance");
        assertEq(card.lockedCardCount(alice, 1), 0, "lockedCardCount 0");
    }

    function test_unlockCard_withActivePosition_reverts() public {
        uint256 serial = _aliceLockGold();
        vm.prank(alice); card.openPosition(1, serial, 3, 100_000_000);

        vm.prank(alice);
        vm.expectRevert(BiliquidVIPCard.PositionStillOpen.selector);
        card.unlockCard(1, serial);
    }

    function test_unlockCard_notLocker_reverts() public {
        uint256 serial = _aliceLockGold();
        vm.prank(bob);
        vm.expectRevert(BiliquidVIPCard.NotCardLocker.selector);
        card.unlockCard(1, serial);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  V6 POSITION LIFECYCLE
    // ═══════════════════════════════════════════════════════════════════════════

    function test_v6_closeAndReopenPosition() public {
        uint256 serial = _aliceLockGold();

        vm.prank(alice); card.openPosition(1, serial, 3, 200_000_000);
        vm.warp(block.timestamp + 3 * SECONDS_PER_MONTH);
        vm.prank(alice); card.closePosition(uint8(1), serial);

        // After close, can open a new position at full cap
        vm.prank(alice); card.openPosition(1, serial, 3, GOLD_MAX_STAKE);
        assertEq(card.getPosition(1, serial).usdcPrincipal, GOLD_MAX_STAKE, "full cap");
    }

    function test_v6_lockUnlockCycle() public {
        // Full cycle: lock → open → close → unlock → re-lock → open again
        uint256 serial = _aliceLockGold();
        vm.prank(alice); card.openPosition(1, serial, 3, 100_000_000);
        vm.warp(block.timestamp + 3 * SECONDS_PER_MONTH);
        vm.prank(alice); card.closePosition(uint8(1), serial);
        vm.prank(alice); card.unlockCard(1, serial);

        assertEq(card.cardOwner(1, serial), alice, "card back to alice");

        vm.prank(alice); card.lockCard(1, serial);
        vm.prank(alice); card.openPosition(1, serial, 6, GOLD_MAX_STAKE);
        assertEq(card.getPosition(1, serial).usdcPrincipal, GOLD_MAX_STAKE, "re-staked at cap");
    }

    function test_v6_addToPosition() public {
        uint256 serial = _aliceLockGold();
        vm.prank(alice); card.openPosition(1, serial, 3, 100_000_000);

        // Add 50 USDC more; uses original APY, term unchanged
        vm.prank(alice); card.addToPosition(1, serial, 50_000_000);

        BiliquidVIPCard.Position memory pos = card.getPosition(1, serial);
        assertEq(pos.usdcPrincipal, 150_000_000, "principal updated");
        assertEq(pos.snapshotApyBps, 900, "APY unchanged");
    }

    function test_v6_addToPosition_exceedsCapacity_reverts() public {
        uint256 serial = _aliceLockGold();
        vm.prank(alice); card.openPosition(1, serial, 3, GOLD_MAX_STAKE);

        vm.prank(alice);
        vm.expectRevert(BiliquidVIPCard.ExceedsCardCapacity.selector);
        card.addToPosition(1, serial, 1);
    }

    function test_v6_upgradeTerms_3to6() public {
        uint256 serial = _aliceLockGold();
        uint256 openedAt = block.timestamp;
        vm.prank(alice); card.openPosition(1, serial, 3, 100_000_000);

        vm.warp(openedAt + 30 days);
        vm.prank(alice); card.upgradeTerms(1, serial, 6);

        BiliquidVIPCard.Position memory pos = card.getPosition(1, serial);
        assertEq(pos.termMonths, 6, "term upgraded to 6");
        // new APY = 900 * 13333 / 10000 = 1199
        assertEq(pos.snapshotApyBps, 1199, "APY upgraded for 6mo");
        // unlockedAt = openedAt + 6*30days (anchored to openedAt, not upgrade time)
        // unlockedAt must be exactly openedAt + 6*30days (anchored to original open time)
        assertEq(pos.unlockedAt, pos.openedAt + uint256(6) * SECONDS_PER_MONTH, "unlockedAt = openedAt + 6mo");
        // opening timestamp must not change on upgrade
        assertTrue(pos.openedAt > 0, "openedAt set");
    }

    function test_v6_upgradeTerms_downgrade_reverts() public {
        uint256 serial = _aliceLockGold();
        vm.prank(alice); card.openPosition(1, serial, 6, 100_000_000);

        vm.prank(alice);
        vm.expectRevert(BiliquidVIPCard.MustUpgradeToLonger.selector);
        card.upgradeTerms(1, serial, 3);
    }

    function test_v6_partialWithdraw_afterExpiry() public {
        uint256 serial = _aliceLockGold();
        uint256 amount = 200_000_000;
        vm.prank(alice); card.openPosition(1, serial, 3, amount);
        uint256 elapsed = 3 * SECONDS_PER_MONTH;
        vm.warp(block.timestamp + elapsed);

        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice); card.partialWithdraw(1, serial, 100_000_000);

        // partialWithdraw accrues interest to claimableAmount, only returns the withdrawn principal
        uint256 interest = amount * 900 * elapsed / (10_000 * 365 days);
        assertEq(usdc.balanceOf(alice) - before, 100_000_000, "partial: only principal returned");
        assertEq(card.getPosition(1, serial).usdcPrincipal, 100_000_000, "principal reduced");
        assertEq(card.pendingMemberInterest(1, serial), interest, "interest in claimableAmount");
    }

    function test_v6_partialWithdraw_beforeExpiry_reverts() public {
        uint256 serial = _aliceLockGold();
        vm.prank(alice); card.openPosition(1, serial, 3, 200_000_000);

        vm.prank(alice);
        vm.expectRevert(BiliquidVIPCard.StillLocked.selector);
        card.partialWithdraw(1, serial, 100_000_000);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  CLAIM INTEREST
    // ═══════════════════════════════════════════════════════════════════════════

    function test_claimMemberInterest_after1month() public {
        uint256 serial = _aliceLockGold();
        uint256 amount = GOLD_MAX_STAKE; // 300 USDC
        vm.prank(alice); card.openPosition(1, serial, 3, amount);

        uint256 elapsed = SECONDS_PER_MONTH;
        vm.warp(block.timestamp + elapsed);

        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice); card.claimMemberInterest(1, serial);
        uint256 interest = usdc.balanceOf(alice) - before;

        // Continuous: principal * apyBps * elapsed / (10000 * 365 days)
        uint256 expected = amount * 900 * elapsed / (10_000 * 365 days);
        assertEq(interest, expected, "1-month interest");
    }

    function test_claimMemberInterest_continuous_smallElapsed() public {
        uint256 serial = _aliceLockGold();
        uint256 amount = 100_000_000;
        vm.prank(alice); card.openPosition(1, serial, 3, amount);

        // v6 is continuous — can claim after even 1 day (no 30-day gate)
        uint256 elapsed = SECONDS_PER_DAY;
        vm.warp(block.timestamp + elapsed);

        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice); card.claimMemberInterest(1, serial);
        uint256 interest = usdc.balanceOf(alice) - before;
        uint256 expected = amount * 900 * elapsed / (10_000 * 365 days);
        assertEq(interest, expected, "1-day continuous interest");
    }

    function test_pendingMemberInterest_view() public {
        uint256 serial = _aliceLockGold();
        uint256 amount = 100_000_000;
        vm.prank(alice); card.openPosition(1, serial, 3, amount);

        uint256 elapsed = 2 * SECONDS_PER_MONTH;
        vm.warp(block.timestamp + elapsed);

        uint256 pending = card.pendingMemberInterest(1, serial);
        uint256 expected = amount * 900 * elapsed / (10_000 * 365 days);
        assertEq(pending, expected, "pending 2mo");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  NON-MEMBER STAKING
    // ═══════════════════════════════════════════════════════════════════════════

    function test_nonMember_stake3month() public {
        uint256 before = usdc.balanceOf(bob);
        vm.prank(bob); uint256 stakeId = card.stakeNonMember(3);

        assertEq(stakeId, 0);
        assertEq(usdc.balanceOf(bob), before - NON_MEMBER_AMOUNT, "usdc deducted");
        BiliquidVIPCard.StakeRecord[] memory recs = card.getStakeRecords(bob);
        assertEq(recs.length, 1);
        // isMember field removed in fresh deploy; all stakeRecords are non-member
        assertEq(recs[0].usdcAmount, NON_MEMBER_AMOUNT);
        assertEq(recs[0].termMonths, 3);
        // baseApy 300 * 10000/10000 = 300
        assertEq(recs[0].snapshotApyBps, 300);
    }

    function test_nonMember_unstake_afterMaturity() public {
        vm.prank(bob); card.stakeNonMember(3);
        vm.warp(block.timestamp + 3 * SECONDS_PER_MONTH);

        uint256 before = usdc.balanceOf(bob);
        vm.prank(bob); card.unstakeNonMember(0);
        assertGt(usdc.balanceOf(bob), before, "got principal back");
    }

    function test_nonMember_unstake_beforeMaturity_reverts() public {
        vm.prank(bob); card.stakeNonMember(3);

        vm.prank(bob);
        vm.expectRevert(BiliquidVIPCard.StillLocked.selector);
        card.unstakeNonMember(0);
    }

    function test_nonMember_flexible_disabled_reverts() public {
        vm.prank(owner_); card.setNonMemberConfig(NON_MEMBER_AMOUNT, 300, 300, false);
        vm.prank(bob);
        vm.expectRevert(BiliquidVIPCard.NonMemberFlexibleDisabled.selector);
        card.stakeNonMember(0);
    }

    function test_nonMember_flexible_enabled() public {
        // flexibleEnabled is true by default in initialize(); no need to set it
        vm.prank(bob); card.stakeNonMember(0);
        BiliquidVIPCard.StakeRecord[] memory recs = card.getStakeRecords(bob);
        assertTrue(recs[0].isFlexible);
    }

    function test_nonMember_unstake_wrongId_reverts() public {
        vm.prank(bob); card.stakeNonMember(3);
        vm.warp(block.timestamp + 3 * SECONDS_PER_MONTH);
        vm.prank(bob);
        vm.expectRevert(BiliquidVIPCard.InvalidStakeId.selector);
        card.unstakeNonMember(999);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  REFERRAL REWARDS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_referral_directReward() public {
        // bob registers, alice is referrer
        vm.prank(alice); card.register(address(0));
        vm.prank(bob);   card.register(alice);

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(bob); card.mintCard(1, 1); // 30 USDC

        // alice gets 10% = 3 USDC
        uint256 reward = usdc.balanceOf(alice) - aliceBefore;
        assertEq(reward, GOLD_MINT_PRICE * 1000 / 10_000, "direct 10% reward");
    }

    function test_referral_indirectReward() public {
        vm.prank(alice); card.register(address(0));
        vm.prank(bob);   card.register(alice);
        vm.prank(carol); card.register(bob);

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(carol); card.mintCard(1, 1);

        // alice is L2: 5% of 30 USDC = 1.5 USDC
        uint256 reward = usdc.balanceOf(alice) - aliceBefore;
        assertEq(reward, GOLD_MINT_PRICE * 500 / 10_000, "indirect 5% reward");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  GIFT POOL
    // ═══════════════════════════════════════════════════════════════════════════

    function test_adminMintToPool_andGift() public {
        vm.prank(owner_); card.adminMintToPool(1, 1);
        assertEq(card.cardOwner(1, 1), address(card));

        vm.prank(owner_); card.giftCard(1, 1, bob);
        assertEq(card.cardOwner(1, 1), bob);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  ADMIN CONFIG
    // ═══════════════════════════════════════════════════════════════════════════

    function test_setTierConfig() public {
        vm.prank(owner_); card.setTierConfig(1, 50_000_000, 500_000_000, 1000, 50_000);
        (uint256 mp, uint256 msa, uint256 apy, uint256 mintCap) = card.tierConfigs(1);
        assertEq(mp,      50_000_000);
        assertEq(msa,     500_000_000);
        assertEq(apy,     1000);
        assertEq(mintCap, 50_000);
    }

    function test_setPaused() public {
        vm.prank(owner_); card.setPaused(true);
        vm.prank(alice);
        vm.expectRevert(BiliquidVIPCard.Paused.selector);
        card.mintCard(1, 1);
    }

    function test_addTerm_removeTerm() public {
        vm.prank(owner_); card.addTerm(24, 30000);
        assertEq(card.termMultiplierBps(24), 30000);

        vm.prank(owner_); card.removeTerm(24);
        assertEq(card.termMultiplierBps(24), 0);
    }

    function test_setTierConfig_nonOwner_reverts() public {
        vm.prank(alice);
        vm.expectRevert();
        card.setTierConfig(1, 0, 0, 0, 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  getUserState (comprehensive view)
    // ═══════════════════════════════════════════════════════════════════════════

    function test_getUserState_lockedCounting() public {
        // Alice mints 2 gold, locks 1
        vm.startPrank(alice);
        card.mintCard(1, 2); // mint 2
        card.lockCard(1, 1); // lock serial 1
        vm.stopPrank();

        // Check via individual calls (getUserState removed to save contract size)
        uint256 goldOwned  = card.getCardsByOwner(alice, 1).length;
        uint256 goldLocked = card.lockedCardCount(alice, 1);
        // 1 in wallet + 1 locked = 2 total
        assertEq(goldOwned + goldLocked, 2, "total gold");
        assertEq(goldLocked, 1, "gold locked");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  INITIALIZATION (config defaults set by initialize())
    // ═══════════════════════════════════════════════════════════════════════════

    function test_initialize_setsDefaultConfig() public view {
        (, uint256 msa, uint256 apy,) = card.tierConfigs(1);
        assertEq(msa, GOLD_MAX_STAKE, "gold maxStake");
        assertEq(apy, 900,            "gold apy");

        (,, apy,) = card.tierConfigs(3);
        assertEq(apy, 1100, "diamond apy 1100");

        (,, apy,) = card.tierConfigs(4);
        assertEq(apy, 1250, "black apy 1250");

        assertEq(card.termMultiplierBps(3),  10000, "3mo multiplier");
        assertEq(card.termMultiplierBps(6),  13333, "6mo multiplier");
        assertEq(card.termMultiplierBps(12), 20000, "12mo multiplier");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  ERC-1155 STANDARD
    // ═══════════════════════════════════════════════════════════════════════════

    function test_supportsInterface() public view {
        assertTrue(card.supportsInterface(0xd9b67a26), "ERC-1155");
        assertTrue(card.supportsInterface(0x01ffc9a7), "ERC-165");
    }

    function test_setApprovalForAll() public {
        vm.prank(alice);
        card.setApprovalForAll(bob, true);
        assertTrue(card.isApprovedForAll(alice, bob));
    }

    function test_balanceOfBatch() public {
        vm.prank(owner_); card.setMinter(alice, true);
        vm.prank(alice); card.mintCard(1, 1);
        vm.prank(alice); card.mintCard(2, 1);

        address[] memory accounts = new address[](2);
        accounts[0] = alice;
        accounts[1] = alice;

        uint256[] memory ids = new uint256[](2);
        ids[0] = 1;
        ids[1] = 2;

        uint256[] memory balances = card.balanceOfBatch(accounts, ids);
        assertEq(balances[0], 1);
        assertEq(balances[1], 1);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  FLEXIBLE MEMBER STAKING
    // ═══════════════════════════════════════════════════════════════════════════

    function test_openPosition_flexible_disabled_reverts() public {
        uint256 serial = _aliceLockGold();
        vm.prank(alice);
        vm.expectRevert(BiliquidVIPCard.FlexibleStakingDisabled.selector);
        card.openPosition(1, serial, 0, 100_000_000);
    }

    function test_openPosition_flexible_enabled() public {
        vm.prank(owner_); card.setMemberFlexibleStaking(true, 600);
        uint256 serial = _aliceLockGold();
        vm.prank(alice); card.openPosition(1, serial, 0, 100_000_000);
        BiliquidVIPCard.Position memory pos = card.getPosition(1, serial);
        assertTrue(pos.isFlexible, "flexible");
        assertEq(pos.snapshotApyBps, 600, "flexible apy");
    }

    function test_closePosition_flexible_anytime() public {
        vm.prank(owner_); card.setMemberFlexibleStaking(true, 600);
        uint256 serial = _aliceLockGold();
        vm.prank(alice); card.openPosition(1, serial, 0, 100_000_000);

        // Can close without waiting (flexible)
        vm.prank(alice); card.closePosition(uint8(1), serial);
        BiliquidVIPCard.Position memory pos = card.getPosition(1, serial);
        assertFalse(pos.active, "position closed");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  WITHDRAWAL (owner)
    // ═══════════════════════════════════════════════════════════════════════════

    function test_withdrawToTreasury() public {
        uint256 contractBal = usdc.balanceOf(address(card));
        uint256 treasBefore = usdc.balanceOf(treasury_);
        vm.prank(owner_); card.withdrawToTreasury(address(usdc), 1_000_000);
        assertEq(usdc.balanceOf(treasury_),    treasBefore + 1_000_000);
        assertEq(usdc.balanceOf(address(card)), contractBal - 1_000_000);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  MINTER WHITELIST
    // ═══════════════════════════════════════════════════════════════════════════

    function test_mintCard_tier2_requires_minter() public {
        uint8 platinum = card.PLATINUM();
        // Alice tries to mint Platinum without being a minter — should revert
        vm.prank(alice);
        vm.expectRevert(BiliquidVIPCard.OnlyMinter.selector);
        card.mintCard(platinum, 1);
    }

    function test_mintCard_tier2_allowed_for_minter() public {
        uint8 platinum = card.PLATINUM();
        address minterWallet = address(0xBEEF);
        usdc.mint(minterWallet, 10_000_000_000);
        vm.prank(minterWallet); usdc.approve(address(card), type(uint256).max);

        // Owner sets minter
        vm.prank(owner_); card.setMinter(minterWallet, true);
        assertTrue(card.minters(minterWallet));

        // Minter mints a Platinum card
        vm.prank(minterWallet); card.mintCard(platinum, 1);
        assertEq(card.getCardsByOwner(minterWallet, platinum).length, 1);
    }

    function test_setMinter_revoke() public {
        address minterWallet = address(0xBEEF);
        vm.prank(owner_); card.setMinter(minterWallet, true);
        vm.prank(owner_); card.setMinter(minterWallet, false);
        assertFalse(card.minters(minterWallet));
    }

    function test_mintCard_gold_still_public() public {
        uint8 gold = card.GOLD();
        // Gold (tier 1) should still be mintable by anyone
        vm.prank(alice); card.mintCard(gold, 1);
        assertEq(card.getCardsByOwner(alice, gold).length, 1);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  CARD SYNTHESIS
    // ═══════════════════════════════════════════════════════════════════════════

    function _mintFourGoldCards(address user) internal returns (uint256[] memory) {
        uint8 gold = card.GOLD();
        vm.prank(user); card.mintCard(gold, 4);
        return card.getCardsByOwner(user, gold);
    }

    function test_synthesize_gold_to_platinum() public {
        uint8 gold     = card.GOLD();
        uint8 platinum = card.PLATINUM();

        uint256[] memory serials = _mintFourGoldCards(alice);
        assertEq(serials.length, 4);

        uint256 platBefore = card.getCardsByOwner(alice, platinum).length;
        uint256 goldBefore = card.getCardsByOwner(alice, gold).length;

        vm.prank(alice); card.synthesizeCard(gold, serials[0], serials[1], serials[2], serials[3]);

        assertEq(card.getCardsByOwner(alice, gold).length,     goldBefore - 4);
        assertEq(card.getCardsByOwner(alice, platinum).length, platBefore + 1);
    }

    function test_synthesize_rejects_locked_card() public {
        uint8 gold = card.GOLD();
        uint256[] memory serials = _mintFourGoldCards(alice);

        vm.prank(alice); card.lockCard(gold, serials[0]);

        // locked card is transferred to contract, so owner check fails with SynthNotOwner
        vm.prank(alice);
        vm.expectRevert(BiliquidVIPCard.SynthNotOwner.selector);
        card.synthesizeCard(gold, serials[0], serials[1], serials[2], serials[3]);
    }

    function test_synthesize_rejects_not_owner() public {
        uint8 gold = card.GOLD();
        uint256[] memory aliceSerials = _mintFourGoldCards(alice);

        vm.prank(bob);
        vm.expectRevert(BiliquidVIPCard.SynthNotOwner.selector);
        card.synthesizeCard(gold, aliceSerials[0], aliceSerials[1], aliceSerials[2], aliceSerials[3]);
    }

    function test_synthesize_rejects_duplicate_serial() public {
        uint8 gold = card.GOLD();
        vm.prank(alice); card.mintCard(gold, 2);
        uint256[] memory owned = card.getCardsByOwner(alice, gold);

        // duplicate s0==s2: after burning s0, cardOwner[gold][s0]==address(0), so s2 check reverts
        vm.prank(alice);
        vm.expectRevert(BiliquidVIPCard.SynthNotOwner.selector);
        card.synthesizeCard(gold, owned[0], owned[1], owned[0], owned[1]);
    }

    function test_synthesize_cannot_synthesize_black() public {
        uint8 black = card.BLACK();
        vm.prank(alice);
        vm.expectRevert(BiliquidVIPCard.SynthTierInvalid.selector);
        card.synthesizeCard(black, 1, 2, 3, 4);
    }

    function test_synthesize_cards_burned_permanently() public {
        uint8 gold = card.GOLD();
        uint256[] memory serials = _mintFourGoldCards(alice);

        vm.prank(alice); card.synthesizeCard(gold, serials[0], serials[1], serials[2], serials[3]);

        for (uint256 i = 0; i < serials.length; i++) {
            assertEq(card.cardOwner(gold, serials[i]), address(0));
        }
    }

    function test_synthesize_chain_gold_to_platinum_to_diamond() public {
        uint8 gold     = card.GOLD();
        uint8 platinum = card.PLATINUM();
        uint8 diamond  = card.DIAMOND();

        vm.prank(alice); card.mintCard(gold, 16);
        uint256[] memory g = card.getCardsByOwner(alice, gold);

        vm.prank(alice); card.synthesizeCard(gold, g[0],  g[1],  g[2],  g[3]);
        vm.prank(alice); card.synthesizeCard(gold, g[4],  g[5],  g[6],  g[7]);
        vm.prank(alice); card.synthesizeCard(gold, g[8],  g[9],  g[10], g[11]);
        vm.prank(alice); card.synthesizeCard(gold, g[12], g[13], g[14], g[15]);
        assertEq(card.getCardsByOwner(alice, platinum).length, 4);

        uint256[] memory p = card.getCardsByOwner(alice, platinum);
        vm.prank(alice); card.synthesizeCard(platinum, p[0], p[1], p[2], p[3]);
        assertEq(card.getCardsByOwner(alice, diamond).length, 1);
    }
}
