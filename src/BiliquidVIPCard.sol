// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title  BiliquidVIPCard v3
 * @notice ERC-1155 VIP membership card protocol with per-card serial tracking
 *         and a dual staking model (member + non-member).
 *
 * ── Card Model ────────────────────────────────────────────────────────────────
 *   4 tiers: Gold(1), Platinum(2), Diamond(3), Black(4)
 *   Each card has a unique identity: (tier, serialNumber).
 *   Serials are sequential per tier, starting at 1; never reused.
 *   All tiers are directly purchasable. No merge mechanism.
 *
 * ── Member Staking (two-step, v3) ────────────────────────────────────────────
 *   Step 1 — lockCard(tier, serial, termMonths):
 *     Lock the card for a term. No USDC required.
 *     StakeRecord is created with usdcAmount = 0, lastClaimAt = 0.
 *   Step 2 — depositUsdc(stakeId, amount):
 *     Deposit 1 .. maxStakeAmountUsdc USDC. APY accrual starts at deposit time.
 *     Card must already be locked (active member position with usdcAmount == 0).
 *   - APY = tier.apyBps x termMultiplierBps / 10_000 (snapshotted at lock time).
 *   - Flexible: memberFlexibleApyBps used directly, no multiplier.
 *   - One active position per card. Must unstake before re-staking same card.
 *
 * ── Non-Member Staking ────────────────────────────────────────────────────────
 *   - No card required. Fixed USDC amount (nonMemberConfig.stakeAmountUsdc).
 *   - APY = nonMemberConfig.baseApyBps x termMultiplierBps / 10_000.
 *   - Flexible: nonMemberConfig.flexibleApyBps.
 *
 * ── Claim Rule (all positions) ────────────────────────────────────────────────
 *   - Interest accrues daily. Claim allowed only every 30 days.
 *   - Sub-30-day interest is permanently forfeited on unstake.
 *   - Member positions without deposited USDC (usdcAmount == 0) earn no interest.
 *
 * ── Upgradeability ────────────────────────────────────────────────────────────
 *   UUPS proxy (EIP-1822). Only owner may authorise upgrades.
 */

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract BiliquidVIPCard is
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable
{
    // ─── Reentrancy guard (inline, upgradeable-safe) ───────────────────────────
    uint256 private _reentrancyStatus; // 0 = unset, 1 = not entered, 2 = entered
    modifier nonReentrant() {
        require(_reentrancyStatus != 2, "BiliquidVIPCard: reentrant call");
        _reentrancyStatus = 2;
        _;
        _reentrancyStatus = 1;
    }
    // ─── ERC-1155 storage ─────────────────────────────────────────────────────
    // Balances include both free and staked cards.
    mapping(address => mapping(uint256 => uint256)) private _balances;
    mapping(address => mapping(address => bool))    private _operatorApprovals;
    string public uri;

    event TransferSingle(address indexed operator, address indexed from, address indexed to, uint256 id, uint256 value);
    event ApprovalForAll(address indexed account, address indexed operator, bool approved);

    // ─── Tier constants ────────────────────────────────────────────────────────
    uint8 public constant GOLD     = 1;
    uint8 public constant PLATINUM = 2;
    uint8 public constant DIAMOND  = 3;
    uint8 public constant BLACK    = 4;

    // ─── Referral roles ───────────────────────────────────────────────────────
    uint8 public constant ROLE_USER          = 0;
    uint8 public constant ROLE_NODE          = 1;
    uint8 public constant ROLE_SUPERNODE     = 2;
    uint8 public constant ROLE_GENERAL_AGENT = 3;

    mapping(address => address) public referrerOf;
    mapping(address => uint8)   public roleOf;
    mapping(address => uint256) public registrationDepth;
    uint256 public constant MAX_REFERRAL_DEPTH = 20;

    uint256 public directReferralBps;
    uint256 public indirectReferralBps;
    uint256 public nodeBoostBps;
    uint256 public superNodeBps;
    uint256 public generalAgentBps;

    // ─── Tier config ──────────────────────────────────────────────────────────
    struct TierConfig {
        uint256 mintPrice;          // USDC price per card (6 decimals)
        uint256 maxStakeAmountUsdc; // USDC principal per member stake (6 dec)
        uint256 apyBps;             // base APY in bps (e.g. 900 = 9%)
        uint256 maxStakeCount;      // global cap: max simultaneously staked cards
    }
    mapping(uint8 => TierConfig) public tierConfigs;

    // ─── Non-member config ────────────────────────────────────────────────────
    struct NonMemberConfig {
        uint256 stakeAmountUsdc;  // fixed principal (6 dec)
        uint256 baseApyBps;       // base APY for fixed-term positions
        uint256 flexibleApyBps;   // APY for flexible positions
        bool    flexibleEnabled;
    }
    NonMemberConfig public nonMemberConfig;

    // ─── Fixed-term config ────────────────────────────────────────────────────
    uint8[]  public validTerms;
    mapping(uint8 => uint256) public termMultiplierBps; // e.g. 3mo -> 10500 (105%)
    bool    public memberFlexibleEnabled;
    uint256 public memberFlexibleApyBps;

    // ─── Card serial tracking ─────────────────────────────────────────────────
    mapping(uint8 => uint256) public nextSerial;   // next serial to assign (starts at 1)
    mapping(uint8 => mapping(uint256 => address)) public cardOwner; // tier -> serial -> owner

    // Owned serial list per (owner, tier) with O(1) removal via swap-and-pop
    mapping(address => mapping(uint8 => uint256[])) private _ownedSerials;
    mapping(uint8 => mapping(uint256 => uint256))   private _ownedSerialIndex; // tier -> serial -> index

    // Staked flag: card cannot be transferred while staked
    mapping(uint8 => mapping(uint256 => bool)) public cardStaked;

    // Active position per card: stores (stakeId + 1), so 0 = "no active position"
    mapping(uint8 => mapping(uint256 => uint256)) private _activePositionByCard;

    // ─── Global staked counts ─────────────────────────────────────────────────
    mapping(uint8 => uint256) public totalStakedByTier;

    // ─── Stake records ────────────────────────────────────────────────────────
    struct StakeRecord {
        bool    isMember;       // true = card-linked member position
        uint8   tier;           // tier of linked card (0 for non-member)
        uint256 cardSerial;     // serial of linked card (0 for non-member)
        bool    isFlexible;
        uint8   termMonths;
        uint256 snapshotApyBps; // effective APY locked at stake time
        uint256 usdcAmount;     // principal USDC deposited
        uint256 stakedAt;
        uint256 unlockedAt;     // for flexible = stakedAt (no lock)
        uint256 lastClaimAt;
        bool    active;
    }
    mapping(address => StakeRecord[]) public stakeRecords;

    // ─── Admin & payment ──────────────────────────────────────────────────────
    IERC20  public usdc;
    address public treasury;
    bool    public paused;

    // ─── Time constants ───────────────────────────────────────────────────────
    uint256 public constant SECONDS_PER_DAY   = 86_400;
    uint256 public constant SECONDS_PER_MONTH = 30 * 86_400;

    // ─── Events ───────────────────────────────────────────────────────────────
    event Registered      (address indexed wallet, address indexed referrer, uint8 role);
    event CardMinted      (address indexed to, uint8 indexed tier, uint256 serial);
    event CardGifted      (address indexed to, uint8 indexed tier, uint256 serial);
    event CardTransferred (address indexed from, address indexed to, uint8 tier, uint256 serial);
    // v3: member staking emits CardLocked then UsdcDeposited separately.
    // Non-member staking still emits Staked (one-step, unchanged).
    event CardLocked      (address indexed staker, uint256 indexed stakeId,
                           uint8 tier, uint256 cardSerial,
                           uint8 termMonths, bool isFlexible,
                           uint256 snapshotApyBps, uint256 unlockedAt);
    event UsdcDeposited   (address indexed staker, uint256 indexed stakeId, uint256 amount);
    event Staked          (address indexed staker, uint256 indexed stakeId, bool isMember,
                           uint8 tier, uint256 cardSerial, uint256 usdcAmount,
                           uint8 termMonths, bool isFlexible, uint256 snapshotApyBps, uint256 unlockedAt);
    event Unstaked        (address indexed staker, uint256 indexed stakeId);
    event InterestClaimed (address indexed staker, uint256 indexed stakeId,
                           uint256 usdcAmount, uint256 daysAccrued);
    event ReferralReward  (address indexed recipient, address indexed buyer,
                           uint256 usdcAmt, string reason);
    event TierUpdated     (uint8 tier);
    event TermAdded       (uint8 termMonths, uint256 multiplierBps);
    event TermRemoved     (uint8 termMonths);

    // ─── Modifiers ────────────────────────────────────────────────────────────
    modifier notPaused() { require(!paused, "BiliquidVIPCard: paused"); _; }

    // ─── Constructor ─────────────────────────────────────────────────────────
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    // ─── Initializer ─────────────────────────────────────────────────────────
    function initialize(address _usdc, address _treasury) external initializer {
        __Ownable_init(msg.sender);
        _reentrancyStatus = 1;
        usdc     = IERC20(_usdc);
        treasury = _treasury;
        uri      = "https://biliquid.io/metadata/{id}.json";

        // Referral rates
        directReferralBps   = 1000; // 10 %
        indirectReferralBps =  500; //  5 %
        nodeBoostBps        =  500; //  5 %
        superNodeBps        =  500; //  5 %
        generalAgentBps     =  500; //  5 %

        // Fixed terms: 3 / 6 / 12 months
        _addTerm(3,  10500);  // +5 %
        _addTerm(6,  11000);  // +10 %
        _addTerm(12, 11500);  // +15 %

        // Member flexible staking: disabled by default, 6 %
        memberFlexibleEnabled = false;
        memberFlexibleApyBps  = 600;

        // Tier configs
        tierConfigs[GOLD]     = TierConfig({ mintPrice: 30_000_000,    maxStakeAmountUsdc: 30_000_000,    apyBps: 900,  maxStakeCount: 100_000 });
        tierConfigs[PLATINUM] = TierConfig({ mintPrice: 120_000_000,   maxStakeAmountUsdc: 120_000_000,   apyBps: 1000, maxStakeCount:  25_000 });
        tierConfigs[DIAMOND]  = TierConfig({ mintPrice: 480_000_000,   maxStakeAmountUsdc: 480_000_000,   apyBps: 1200, maxStakeCount:  10_000 });
        tierConfigs[BLACK]    = TierConfig({ mintPrice: 1_920_000_000, maxStakeAmountUsdc: 1_920_000_000, apyBps: 1500, maxStakeCount:   2_500 });

        // Non-member config: 100 USDC, 4 % base, 3 % flexible
        nonMemberConfig = NonMemberConfig({
            stakeAmountUsdc: 100_000_000,
            baseApyBps:      400,
            flexibleApyBps:  300,
            flexibleEnabled: false
        });

        // Serials start at 1
        nextSerial[GOLD] = nextSerial[PLATINUM] = nextSerial[DIAMOND] = nextSerial[BLACK] = 1;
    }

    // ─── UUPS ─────────────────────────────────────────────────────────────────
    function _authorizeUpgrade(address) internal override onlyOwner {}

    // ═══════════════════════════════════════════════════════════════════════════
    //  REGISTRATION
    // ═══════════════════════════════════════════════════════════════════════════

    function register(address referrer) external {
        require(registrationDepth[msg.sender] == 0, "BiliquidVIPCard: already registered");
        if (referrer == address(0)) {
            registrationDepth[msg.sender] = 1;
        } else {
            require(referrer != msg.sender, "BiliquidVIPCard: self-refer");
            uint256 d = registrationDepth[referrer];
            require(d > 0, "BiliquidVIPCard: referrer not registered");
            require(d < MAX_REFERRAL_DEPTH, "BiliquidVIPCard: chain too deep");
            registrationDepth[msg.sender] = d + 1;
            referrerOf[msg.sender] = referrer;
        }
        emit Registered(msg.sender, referrer, roleOf[msg.sender]);
    }

    function setRole(address wallet, uint8 role) external onlyOwner {
        require(role <= ROLE_GENERAL_AGENT, "BiliquidVIPCard: invalid role");
        roleOf[wallet] = role;
        emit Registered(wallet, referrerOf[wallet], role);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  MINTING
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Purchase `amount` cards of `tier`. USDC is pulled from the caller.
    function mintCard(uint8 tier, uint256 amount) external notPaused nonReentrant {
        _requireValidTier(tier);
        require(amount > 0, "BiliquidVIPCard: amount=0");

        uint256 totalCost = tierConfigs[tier].mintPrice * amount;
        require(usdc.transferFrom(msg.sender, address(this), totalCost), "BiliquidVIPCard: payment failed");

        for (uint256 i = 0; i < amount; i++) {
            uint256 serial = nextSerial[tier]++;
            _assignCard(msg.sender, tier, serial);
            emit CardMinted(msg.sender, tier, serial);
        }

        _distributeReferralRewards(msg.sender, totalCost);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  GIFT POOL  (admin only)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Pre-mint cards into the contract's gift pool (no USDC required).
    function adminMintToPool(uint8 tier, uint256 amount) external onlyOwner {
        _requireValidTier(tier);
        require(amount > 0, "BiliquidVIPCard: amount=0");
        for (uint256 i = 0; i < amount; i++) {
            uint256 serial = nextSerial[tier]++;
            _assignCard(address(this), tier, serial);
        }
    }

    /// @notice Gift a card from the pool to `recipient`.
    function giftCard(uint8 tier, uint256 serial, address recipient) external onlyOwner {
        require(recipient != address(0), "BiliquidVIPCard: zero recipient");
        require(cardOwner[tier][serial] == address(this), "BiliquidVIPCard: not in gift pool");
        require(!cardStaked[tier][serial], "BiliquidVIPCard: card staked");
        _transferCard(address(this), recipient, tier, serial);
        emit CardGifted(recipient, tier, serial);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  CARD TRANSFER
    // ═══════════════════════════════════════════════════════════════════════════

    function transferCard(uint8 tier, uint256 serial, address to) external notPaused {
        require(to != address(0), "BiliquidVIPCard: zero address");
        require(cardOwner[tier][serial] == msg.sender, "BiliquidVIPCard: not owner");
        require(!cardStaked[tier][serial], "BiliquidVIPCard: card is staked");
        _transferCard(msg.sender, to, tier, serial);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  MEMBER STAKING  (v3 two-step: lockCard → depositUsdc)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Step 1 — Lock a VIP card for a term. No USDC is required here.
    ///         The returned stakeId is used in the subsequent depositUsdc() call.
    /// @param termMonths  0 = flexible; 3/6/12 = fixed term.
    function lockCard(
        uint8   tier,
        uint256 cardSerial,
        uint8   termMonths
    ) external notPaused nonReentrant returns (uint256 stakeId) {
        _requireValidTier(tier);
        require(cardOwner[tier][cardSerial] == msg.sender,    "BiliquidVIPCard: not card owner");
        require(!cardStaked[tier][cardSerial],                "BiliquidVIPCard: card already staked");
        require(_activePositionByCard[tier][cardSerial] == 0, "BiliquidVIPCard: card has active position");

        TierConfig storage cfg = tierConfigs[tier];
        require(totalStakedByTier[tier] < cfg.maxStakeCount, "BiliquidVIPCard: tier stake cap reached");

        (bool isFlexible_, uint256 snapshotApy, uint256 lockSeconds) =
            _memberTermParams(cfg.apyBps, termMonths);

        cardStaked[tier][cardSerial] = true;
        totalStakedByTier[tier]++;

        uint256 now_ = block.timestamp;
        stakeId = stakeRecords[msg.sender].length;
        stakeRecords[msg.sender].push(StakeRecord({
            isMember:       true,
            tier:           tier,
            cardSerial:     cardSerial,
            isFlexible:     isFlexible_,
            termMonths:     termMonths,
            snapshotApyBps: snapshotApy,
            usdcAmount:     0,           // no USDC yet; filled by depositUsdc()
            stakedAt:       now_,
            unlockedAt:     now_ + lockSeconds,
            lastClaimAt:    0,           // sentinel: 0 means USDC not yet deposited
            active:         true
        }));

        _activePositionByCard[tier][cardSerial] = stakeId + 1;

        emit CardLocked(msg.sender, stakeId, tier, cardSerial,
                        termMonths, isFlexible_, snapshotApy, now_ + lockSeconds);
    }

    /// @notice Step 2 — Deposit USDC into a locked card position to start earning APY.
    ///         Can only be called once per stakeId. APY accrual begins at deposit time.
    /// @param stakeId  The stakeId returned by lockCard().
    /// @param amount   USDC amount (6 dec). Must be between 1 and maxStakeAmountUsdc.
    function depositUsdc(uint256 stakeId, uint256 amount) external notPaused nonReentrant {
        require(stakeId < stakeRecords[msg.sender].length, "BiliquidVIPCard: invalid stakeId");
        StakeRecord storage rec = stakeRecords[msg.sender][stakeId];
        require(rec.active,    "BiliquidVIPCard: position not active");
        require(rec.isMember,  "BiliquidVIPCard: not a member position");
        require(rec.usdcAmount == 0, "BiliquidVIPCard: USDC already deposited");
        require(amount > 0,    "BiliquidVIPCard: amount must be > 0");

        TierConfig storage cfg = tierConfigs[rec.tier];
        require(amount <= cfg.maxStakeAmountUsdc, "BiliquidVIPCard: exceeds max stake amount");

        require(usdc.transferFrom(msg.sender, address(this), amount), "BiliquidVIPCard: usdc transfer failed");

        rec.usdcAmount  = amount;
        rec.lastClaimAt = block.timestamp; // APY accrual starts from now

        emit UsdcDeposited(msg.sender, stakeId, amount);
    }

    /// @notice One-step convenience: lock card AND deposit maxStakeAmountUsdc in a single tx.
    ///         Kept for backward compatibility; the preferred flow is lockCard() + depositUsdc().
    function stakeCard(uint8 tier, uint256 cardSerial, uint8 termMonths)
        external notPaused nonReentrant returns (uint256 stakeId)
    {
        _requireValidTier(tier);
        require(cardOwner[tier][cardSerial] == msg.sender,    "BiliquidVIPCard: not card owner");
        require(!cardStaked[tier][cardSerial],                "BiliquidVIPCard: card already staked");
        require(_activePositionByCard[tier][cardSerial] == 0, "BiliquidVIPCard: card has active position");

        TierConfig storage cfg = tierConfigs[tier];
        require(totalStakedByTier[tier] < cfg.maxStakeCount, "BiliquidVIPCard: tier stake cap reached");

        (bool isFlexible_, uint256 snapshotApy, uint256 lockSeconds) =
            _memberTermParams(cfg.apyBps, termMonths);

        uint256 usdcAmount = cfg.maxStakeAmountUsdc;
        require(usdc.transferFrom(msg.sender, address(this), usdcAmount), "BiliquidVIPCard: usdc transfer failed");

        cardStaked[tier][cardSerial] = true;
        totalStakedByTier[tier]++;

        uint256 now_ = block.timestamp;
        stakeId = stakeRecords[msg.sender].length;
        stakeRecords[msg.sender].push(StakeRecord({
            isMember:       true,
            tier:           tier,
            cardSerial:     cardSerial,
            isFlexible:     isFlexible_,
            termMonths:     termMonths,
            snapshotApyBps: snapshotApy,
            usdcAmount:     usdcAmount,
            stakedAt:       now_,
            unlockedAt:     now_ + lockSeconds,
            lastClaimAt:    now_,
            active:         true
        }));

        _activePositionByCard[tier][cardSerial] = stakeId + 1;

        emit CardLocked(msg.sender, stakeId, tier, cardSerial, termMonths, isFlexible_, snapshotApy, now_ + lockSeconds);
        emit UsdcDeposited(msg.sender, stakeId, usdcAmount);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  NON-MEMBER STAKING
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Stake USDC without owning a VIP card.
    function stakeNonMember(uint8 termMonths) external notPaused nonReentrant returns (uint256 stakeId) {
        NonMemberConfig storage cfg = nonMemberConfig;

        bool    isFlexible_;
        uint256 snapshotApy;
        uint256 lockSeconds;

        if (termMonths == 0) {
            require(cfg.flexibleEnabled, "BiliquidVIPCard: non-member flexible disabled");
            isFlexible_ = true;
            snapshotApy = cfg.flexibleApyBps;
            lockSeconds = 0;
        } else {
            require(_isValidTerm(termMonths), "BiliquidVIPCard: invalid term");
            isFlexible_ = false;
            snapshotApy = cfg.baseApyBps * termMultiplierBps[termMonths] / 10_000;
            lockSeconds = uint256(termMonths) * SECONDS_PER_MONTH;
        }

        uint256 usdcAmount = cfg.stakeAmountUsdc;
        require(usdc.transferFrom(msg.sender, address(this), usdcAmount), "BiliquidVIPCard: usdc transfer failed");

        uint256 now_ = block.timestamp;
        stakeId = stakeRecords[msg.sender].length;
        stakeRecords[msg.sender].push(StakeRecord({
            isMember:       false,
            tier:           0,
            cardSerial:     0,
            isFlexible:     isFlexible_,
            termMonths:     termMonths,
            snapshotApyBps: snapshotApy,
            usdcAmount:     usdcAmount,
            stakedAt:       now_,
            unlockedAt:     now_ + lockSeconds,
            lastClaimAt:    now_,
            active:         true
        }));

        emit Staked(msg.sender, stakeId, false, 0, 0, usdcAmount,
                    termMonths, isFlexible_, snapshotApy, now_ + lockSeconds);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  UNSTAKE
    // ═══════════════════════════════════════════════════════════════════════════

    function unstake(uint256 stakeId) external nonReentrant {
        StakeRecord storage rec = _requireActive(msg.sender, stakeId);

        if (!rec.isFlexible) {
            require(block.timestamp >= rec.unlockedAt, "BiliquidVIPCard: still locked");
        }

        // Return USDC principal (if deposited). Positions locked without depositing USDC
        // (usdcAmount == 0, lastClaimAt == 0) just unlock the card, no USDC to return.
        if (rec.usdcAmount > 0) {
            uint256 monthsPast = (block.timestamp - rec.lastClaimAt) / SECONDS_PER_MONTH;
            if (monthsPast > 0) {
                _claimInterest(msg.sender, stakeId, rec);
            }
            require(usdc.transfer(msg.sender, rec.usdcAmount), "BiliquidVIPCard: usdc return failed");
        }

        if (rec.isMember) {
            cardStaked[rec.tier][rec.cardSerial] = false;
            totalStakedByTier[rec.tier]--;
            _activePositionByCard[rec.tier][rec.cardSerial] = 0;
        }

        rec.active = false;
        emit Unstaked(msg.sender, stakeId);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  CLAIM INTEREST
    // ═══════════════════════════════════════════════════════════════════════════

    function claimInterest(uint256 stakeId) external nonReentrant {
        StakeRecord storage rec = _requireActive(msg.sender, stakeId);
        require(rec.usdcAmount > 0, "BiliquidVIPCard: no USDC deposited");
        uint256 monthsPast = (block.timestamp - rec.lastClaimAt) / SECONDS_PER_MONTH;
        require(monthsPast > 0, "BiliquidVIPCard: claim once per 30 days");
        _claimInterest(msg.sender, stakeId, rec);
    }

    function claimAllInterest() external nonReentrant {
        StakeRecord[] storage records = stakeRecords[msg.sender];
        for (uint256 i = 0; i < records.length; i++) {
            if (!records[i].active) continue;
            if (records[i].usdcAmount == 0) continue; // card locked but no USDC deposited yet
            uint256 monthsPast = (block.timestamp - records[i].lastClaimAt) / SECONDS_PER_MONTH;
            if (monthsPast == 0) continue;
            _claimInterest(msg.sender, i, records[i]);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  VIEWS
    // ═══════════════════════════════════════════════════════════════════════════

    function getCardsByOwner(address owner, uint8 tier) external view returns (uint256[] memory) {
        return _ownedSerials[owner][tier];
    }

    /// @return stakeId_    The active stakeId for this card.
    /// @return hasPosition True if the card has an active stake position.
    function getActivePositionByCard(uint8 tier, uint256 serial)
        external view returns (uint256 stakeId_, bool hasPosition)
    {
        uint256 raw = _activePositionByCard[tier][serial];
        if (raw == 0) return (0, false);
        return (raw - 1, true);
    }

    function getStakeRecords(address wallet) external view returns (StakeRecord[] memory) {
        return stakeRecords[wallet];
    }

    /// @notice Claimable interest (whole months only, same rounding as actual claim).
    function pendingInterest(address wallet, uint256 stakeId) external view returns (uint256) {
        if (stakeId >= stakeRecords[wallet].length) return 0;
        StakeRecord storage rec = stakeRecords[wallet][stakeId];
        if (!rec.active) return 0;
        uint256 monthsPast = (block.timestamp - rec.lastClaimAt) / SECONDS_PER_MONTH;
        if (monthsPast == 0) return 0;
        return _dailyInterest(rec) * (monthsPast * 30);
    }

    /// @notice Accrued interest by day (not yet claimable unless >= 30 days).
    function pendingInterestExact(address wallet, uint256 stakeId) external view returns (uint256) {
        if (stakeId >= stakeRecords[wallet].length) return 0;
        StakeRecord storage rec = stakeRecords[wallet][stakeId];
        if (!rec.active) return 0;
        uint256 daysPast = (block.timestamp - rec.lastClaimAt) / SECONDS_PER_DAY;
        return _dailyInterest(rec) * daysPast;
    }

    function dailyInterestFor(address wallet, uint256 stakeId) external view returns (uint256) {
        if (stakeId >= stakeRecords[wallet].length) return 0;
        StakeRecord storage rec = stakeRecords[wallet][stakeId];
        if (!rec.active) return 0;
        return _dailyInterest(rec);
    }

    /// @notice Summary of a wallet's card holdings and staking activity.
    function getUserState(address wallet) external view returns (
        uint256 goldCards,     uint256 platinumCards, uint256 diamondCards, uint256 blackCards,
        uint256 goldStaked,    uint256 platinumStaked, uint256 diamondStaked, uint256 blackStaked,
        address referrer,      uint8   role
    ) {
        goldCards     = _ownedSerials[wallet][GOLD].length;
        platinumCards = _ownedSerials[wallet][PLATINUM].length;
        diamondCards  = _ownedSerials[wallet][DIAMOND].length;
        blackCards    = _ownedSerials[wallet][BLACK].length;

        StakeRecord[] storage records = stakeRecords[wallet];
        for (uint256 i = 0; i < records.length; i++) {
            if (!records[i].active || !records[i].isMember) continue;
            uint8 t = records[i].tier;
            if      (t == GOLD)     goldStaked++;
            else if (t == PLATINUM) platinumStaked++;
            else if (t == DIAMOND)  diamondStaked++;
            else if (t == BLACK)    blackStaked++;
        }
        referrer = referrerOf[wallet];
        role     = roleOf[wallet];
    }

    function getValidTerms() external view returns (uint8[] memory) {
        return validTerms;
    }

    // ─── ERC-1155 standard views ───────────────────────────────────────────────
    function balanceOf(address account, uint256 id) public view returns (uint256) {
        return _balances[account][id];
    }

    function balanceOfBatch(address[] calldata accounts, uint256[] calldata ids)
        external view returns (uint256[] memory out)
    {
        require(accounts.length == ids.length, "BiliquidVIPCard: length mismatch");
        out = new uint256[](accounts.length);
        for (uint256 i = 0; i < accounts.length; i++) {
            out[i] = _balances[accounts[i]][ids[i]];
        }
    }

    function isApprovedForAll(address account, address operator) public view returns (bool) {
        return _operatorApprovals[account][operator];
    }

    function setApprovalForAll(address operator, bool approved) external {
        _operatorApprovals[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == 0xd9b67a26  // ERC-1155
            || id == 0x0e89341c  // ERC-1155MetadataURI
            || id == 0x01ffc9a7; // ERC-165
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  ADMIN CONFIG
    // ═══════════════════════════════════════════════════════════════════════════

    function setTierConfig(
        uint8   tier,
        uint256 mintPrice,
        uint256 maxStakeAmountUsdc,
        uint256 apyBps,
        uint256 maxStakeCount
    ) external onlyOwner {
        _requireValidTier(tier);
        tierConfigs[tier] = TierConfig(mintPrice, maxStakeAmountUsdc, apyBps, maxStakeCount);
        emit TierUpdated(tier);
    }

    function setNonMemberConfig(
        uint256 stakeAmountUsdc,
        uint256 baseApyBps,
        uint256 flexibleApyBps,
        bool    flexibleEnabled
    ) external onlyOwner {
        nonMemberConfig = NonMemberConfig(stakeAmountUsdc, baseApyBps, flexibleApyBps, flexibleEnabled);
    }

    function addTerm(uint8 termMonths, uint256 multiplierBps) external onlyOwner {
        require(termMonths > 0, "BiliquidVIPCard: term must be >0");
        require(!_isValidTerm(termMonths), "BiliquidVIPCard: term exists");
        _addTerm(termMonths, multiplierBps);
    }

    function removeTerm(uint8 termMonths) external onlyOwner {
        uint256 len = validTerms.length;
        for (uint256 i = 0; i < len; i++) {
            if (validTerms[i] == termMonths) {
                validTerms[i] = validTerms[len - 1];
                validTerms.pop();
                delete termMultiplierBps[termMonths];
                emit TermRemoved(termMonths);
                return;
            }
        }
        revert("BiliquidVIPCard: term not found");
    }

    function setTermMultiplier(uint8 termMonths, uint256 multiplierBps) external onlyOwner {
        require(_isValidTerm(termMonths), "BiliquidVIPCard: term not found");
        termMultiplierBps[termMonths] = multiplierBps;
    }

    function setMemberFlexibleStaking(bool enabled, uint256 apyBps) external onlyOwner {
        memberFlexibleEnabled = enabled;
        memberFlexibleApyBps  = apyBps;
    }

    function setReferralRates(
        uint256 direct_, uint256 indirect_, uint256 nodeBoost_,
        uint256 superNode_, uint256 generalAgent_
    ) external onlyOwner {
        directReferralBps   = direct_;
        indirectReferralBps = indirect_;
        nodeBoostBps        = nodeBoost_;
        superNodeBps        = superNode_;
        generalAgentBps     = generalAgent_;
    }

    function setUri(string calldata newUri) external onlyOwner { uri = newUri; }
    function setUsdc(address _usdc)         external onlyOwner { usdc = IERC20(_usdc); }
    function setTreasury(address _treasury) external onlyOwner { treasury = _treasury; }
    function setPaused(bool _paused)        external onlyOwner { paused = _paused; }

    /// @notice Withdraw any ERC-20 to `treasury`.
    function withdrawToTreasury(address token, uint256 amount) external onlyOwner {
        require(IERC20(token).transfer(treasury, amount), "BiliquidVIPCard: withdraw failed");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  INTERNAL HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    function _assignCard(address to, uint8 tier, uint256 serial) internal {
        cardOwner[tier][serial] = to;
        _ownedSerialIndex[tier][serial] = _ownedSerials[to][tier].length;
        _ownedSerials[to][tier].push(serial);
        _balances[to][tier]++;
        emit TransferSingle(msg.sender, address(0), to, tier, 1);
    }

    function _transferCard(address from, address to, uint8 tier, uint256 serial) internal {
        // O(1) removal from `from` list via swap-and-pop
        uint256[] storage fromList = _ownedSerials[from][tier];
        uint256 idx        = _ownedSerialIndex[tier][serial];
        uint256 lastSerial = fromList[fromList.length - 1];
        fromList[idx]                       = lastSerial;
        _ownedSerialIndex[tier][lastSerial]  = idx;
        fromList.pop();

        // Append to `to` list
        _ownedSerialIndex[tier][serial] = _ownedSerials[to][tier].length;
        _ownedSerials[to][tier].push(serial);

        cardOwner[tier][serial] = to;
        _balances[from][tier]--;
        _balances[to][tier]++;

        emit TransferSingle(msg.sender, from, to, tier, 1);
        emit CardTransferred(from, to, tier, serial);
    }

    function _addTerm(uint8 termMonths, uint256 multiplierBps) internal {
        validTerms.push(termMonths);
        termMultiplierBps[termMonths] = multiplierBps;
        emit TermAdded(termMonths, multiplierBps);
    }

    function _isValidTerm(uint8 termMonths) internal view returns (bool) {
        for (uint256 i = 0; i < validTerms.length; i++) {
            if (validTerms[i] == termMonths) return true;
        }
        return false;
    }

    function _requireValidTier(uint8 tier) internal pure {
        require(tier >= GOLD && tier <= BLACK, "BiliquidVIPCard: invalid tier");
    }

    function _requireActive(address wallet, uint256 stakeId)
        internal view returns (StakeRecord storage rec)
    {
        require(stakeId < stakeRecords[wallet].length, "BiliquidVIPCard: invalid stakeId");
        rec = stakeRecords[wallet][stakeId];
        require(rec.active, "BiliquidVIPCard: position not active");
    }

    function _memberTermParams(uint256 baseApyBps, uint8 termMonths)
        internal view returns (bool isFlexible_, uint256 snapshotApy, uint256 lockSeconds)
    {
        if (termMonths == 0) {
            require(memberFlexibleEnabled, "BiliquidVIPCard: flexible staking disabled");
            isFlexible_  = true;
            snapshotApy  = memberFlexibleApyBps;
            lockSeconds  = 0;
        } else {
            require(_isValidTerm(termMonths), "BiliquidVIPCard: invalid term");
            isFlexible_  = false;
            snapshotApy  = baseApyBps * termMultiplierBps[termMonths] / 10_000;
            lockSeconds  = uint256(termMonths) * SECONDS_PER_MONTH;
        }
    }

    function _dailyInterest(StakeRecord storage rec) internal view returns (uint256) {
        // interest per day = principal x APY / (10_000 x 365)
        return rec.usdcAmount * rec.snapshotApyBps / (10_000 * 365);
    }

    function _claimInterest(address wallet, uint256 stakeId, StakeRecord storage rec) internal {
        uint256 monthsPast = (block.timestamp - rec.lastClaimAt) / SECONDS_PER_MONTH;
        if (monthsPast == 0) return;

        uint256 daysPast = monthsPast * 30;
        uint256 interest = _dailyInterest(rec) * daysPast;

        // Advance lastClaimAt by exactly the elapsed whole months
        rec.lastClaimAt += monthsPast * SECONDS_PER_MONTH;

        if (interest > 0) {
            require(usdc.transfer(wallet, interest), "BiliquidVIPCard: interest transfer failed");
        }
        emit InterestClaimed(wallet, stakeId, interest, daysPast);
    }

    function _distributeReferralRewards(address buyer, uint256 totalUsdc) internal {
        address l1 = referrerOf[buyer];
        if (l1 == address(0)) return;

        _payReferral(l1, buyer, _bps(totalUsdc, directReferralBps), "direct");

        uint8 r1 = roleOf[l1];
        if (r1 >= ROLE_NODE) {
            _payReferral(l1, buyer, _bps(totalUsdc, nodeBoostBps), "node_boost");
        }

        address l2 = referrerOf[l1];
        if (l2 == address(0)) return;
        _payReferral(l2, buyer, _bps(totalUsdc, indirectReferralBps), "indirect");

        bool snPaid = false;
        bool gaPaid = false;
        address cur = referrerOf[l2];
        while (cur != address(0) && !(snPaid && gaPaid)) {
            uint8 r = roleOf[cur];
            if (!snPaid && r >= ROLE_SUPERNODE) {
                _payReferral(cur, buyer, _bps(totalUsdc, superNodeBps), "supernode");
                snPaid = true;
            }
            if (!gaPaid && r >= ROLE_GENERAL_AGENT) {
                _payReferral(cur, buyer, _bps(totalUsdc, generalAgentBps), "general_agent");
                gaPaid = true;
            }
            cur = referrerOf[cur];
        }
    }

    function _payReferral(address recipient, address buyer, uint256 usdcAmt, string memory reason) internal {
        if (usdcAmt > 0) usdc.transfer(recipient, usdcAmt);
        emit ReferralReward(recipient, buyer, usdcAmt, reason);
    }

    function _bps(uint256 amount, uint256 rate) internal pure returns (uint256) {
        return amount * rate / 10_000;
    }
}
