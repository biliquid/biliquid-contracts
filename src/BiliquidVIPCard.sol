// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title  BiliquidVIPCard
 * @notice ERC-1155 VIP membership card — one-card-one-position staking model.
 *
 * ── Member Staking ────────────────────────────────────────────────────────────
 *   lockCard → openPosition (ONE per card) → addToPosition / partialWithdraw /
 *              upgradeTerms / claimMemberInterest → closePosition → unlockCard
 *
 * ── Interest ─────────────────────────────────────────────────────────────────
 *   Member:     continuous accrual  — principal * apyBps * elapsed / (10000 * 365d)
 *   Non-member: monthly accrual     — _claimInterestLegacy (30-day buckets)
 *
 * ── Card Synthesis ────────────────────────────────────────────────────────────
 *   Gold×4 → Platinum, Platinum×4 → Diamond, Diamond×6 → Black (no USDC cost)
 *
 * ── Upgradeability ────────────────────────────────────────────────────────────
 *   UUPS proxy. This is a FRESH DEPLOY — no legacy storage compatibility needed.
 */

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract BiliquidVIPCard is Initializable, OwnableUpgradeable, UUPSUpgradeable {

    // ─── Reentrancy guard ─────────────────────────────────────────────────────
    uint256 private _reentrancyStatus;
    modifier nonReentrant() {
        if (_reentrancyStatus == 2) revert Reentrant();
        _reentrancyStatus = 2;
        _;
        _reentrancyStatus = 1;
    }

    // ─── ERC-1155 storage ─────────────────────────────────────────────────────
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
        uint256 mintPrice;
        uint256 maxStakeAmountUsdc;
        uint256 apyBps;
        uint256 mintCap;
    }
    mapping(uint8 => TierConfig) public tierConfigs;

    // ─── Non-member config ────────────────────────────────────────────────────
    struct NonMemberConfig {
        uint256 stakeAmountUsdc;
        uint256 baseApyBps;
        uint256 flexibleApyBps;
        bool    flexibleEnabled;
    }
    NonMemberConfig public nonMemberConfig;

    // ─── Fixed-term config ────────────────────────────────────────────────────
    uint8[]  public validTerms;
    mapping(uint8 => uint256) public termMultiplierBps;
    bool    public memberFlexibleEnabled;
    uint256 public memberFlexibleApyBps;

    // ─── Card serial tracking ─────────────────────────────────────────────────
    mapping(uint8 => uint256) public nextSerial;
    mapping(uint8 => mapping(uint256 => address)) public cardOwner;
    mapping(address => mapping(uint8 => uint256[])) private _ownedSerials;
    mapping(uint8 => mapping(uint256 => uint256))   private _ownedSerialIndex;
    mapping(uint8 => mapping(uint256 => bool))      public  cardStaked;

    mapping(uint8 => uint256) public totalLockedByTier;

    // ─── Non-member stake records ─────────────────────────────────────────────
    struct StakeRecord {
        bool    isFlexible;
        uint8   termMonths;
        uint256 snapshotApyBps;
        uint256 usdcAmount;
        uint256 stakedAt;
        uint256 unlockedAt;
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

    // ─── Card locking ─────────────────────────────────────────────────────────
    mapping(uint8 => mapping(uint256 => address)) public lockedBy;
    mapping(address => mapping(uint8 => uint256)) public lockedCardCount;

    // ─── Minter allowlist (for admin-granted direct minting of Platinum+) ─────
    mapping(address => bool) public minters;

    // ─── Member positions (one per locked card) ───────────────────────────────
    struct Position {
        bool     active;
        bool     isFlexible;
        uint8    termMonths;
        uint256  usdcPrincipal;
        uint256  snapshotApyBps;
        uint256  openedAt;
        uint256  unlockedAt;
        uint256  lastClaimAt;
        uint256  claimableAmount; // accrued but not yet paid (from addToPosition / partialWithdraw / upgradeTerms)
    }
    mapping(uint8 => mapping(uint256 => Position)) public positions;

    // ─── Per-user locked serial index (for dashboard discovery) ──────────────
    mapping(address => mapping(uint8 => uint256[])) private _lockedSerials;
    mapping(uint8 => mapping(uint256 => uint256))   private _lockedSerialIndex;

    // ─── On-chain referral kill-switch (v8) ────────────────────────────────────
    //  Referral commissions moved OFF-CHAIN (accumulated in backend, claimed via
    //  CumulativeMerkleDistributor). This flag gates the legacy on-chain payout in
    //  mintCard so it cannot double-pay. Defaults to false on a fresh storage slot,
    //  so after the upgrade on-chain referral is DISABLED until explicitly re-enabled.
    bool public onChainReferralEnabled;

    // ─── Events ───────────────────────────────────────────────────────────────
    event Registered      (address indexed wallet, address indexed referrer, uint8 role);
    event CardMinted      (address indexed to, uint8 indexed tier, uint256 serial);
    event CardGifted      (address indexed to, uint8 indexed tier, uint256 serial);
    event CardTransferred (address indexed from, address indexed to, uint8 tier, uint256 serial);
    event CardLocked      (address indexed locker, uint8 indexed tier, uint256 indexed serial);
    event CardUnlocked    (address indexed locker, uint8 indexed tier, uint256 indexed serial);
    event CardSynthesized (address indexed user, uint8 fromTier, uint8 toTier, uint256 newSerial);

    event PositionOpened       (address indexed staker, uint8 indexed tier, uint256 indexed serial,
                                uint8 termMonths, bool isFlexible,
                                uint256 amount, uint256 snapshotApyBps, uint256 unlockedAt);
    event PositionClosed       (address indexed staker, uint8 indexed tier, uint256 indexed serial,
                                uint256 principalReturned, uint256 interestPaid);
    event AmountAdded          (address indexed staker, uint8 indexed tier, uint256 indexed serial,
                                uint256 amount, uint256 newTotal);
    event PartialWithdrawn     (address indexed staker, uint8 indexed tier, uint256 indexed serial,
                                uint256 amount, uint256 newTotal);
    event TermsUpgraded        (address indexed staker, uint8 indexed tier, uint256 indexed serial,
                                uint8 newTermMonths, uint256 newSnapshotApyBps, uint256 newUnlockedAt);
    event MemberInterestClaimed(address indexed staker, uint8 indexed tier, uint256 indexed serial,
                                uint256 usdcAmount);

    event Staked          (address indexed staker, uint256 indexed stakeId,
                           uint256 usdcAmount, uint8 termMonths, bool isFlexible,
                           uint256 snapshotApyBps, uint256 unlockedAt);
    event Unstaked        (address indexed staker, uint256 indexed stakeId);
    event InterestClaimed (address indexed staker, uint256 indexed stakeId, uint256 usdcAmount, uint256 daysAccrued);
    event ReferralReward  (address indexed recipient, address indexed buyer, uint256 usdcAmt, string reason);
    event TierUpdated     (uint8 tier);
    event TermAdded       (uint8 termMonths, uint256 multiplierBps);
    event TermRemoved     (uint8 termMonths);
    event ReferralEnabledSet(bool enabled);

    // ─── Custom errors ────────────────────────────────────────────────────────
    error Reentrant();
    error Paused();
    error AlreadyRegistered();
    error SelfRefer();
    error ReferrerNotRegistered();
    error ChainTooDeep();
    error InvalidRole();
    error ZeroAmount();
    error MintCapReached();
    error PaymentFailed();
    error ZeroRecipient();
    error NotInGiftPool();
    error CardStaked();
    error ZeroAddress();
    error NotOwner();
    error CardIsLocked();
    error NotCardOwner();
    error AlreadyLocked();
    error NotCardLocker();
    error PositionAlreadyOpen();
    error ExceedsCardCapacity();
    error UsdcTransferFailed();
    error NoActivePosition();
    error UseClosePosition();
    error StillLocked();
    error CannotUpgradeFlexible();
    error InvalidTerm();
    error MustUpgradeToLonger();
    error NoUsdcDeposited();
    error ClaimOncePer30Days();
    error ClaimTooSoon();
    error LengthMismatch();
    error TermMustBePositive();
    error TermExists();
    error TermNotFound();
    error PositionStillOpen();
    error PrincipalReturnFailed();
    error UseNonMemberUnstake();
    error UsdcReturnFailed();
    error NonMemberFlexibleDisabled();
    error FlexibleStakingDisabled();
    error InterestTransferFailed();
    error InvalidTier();
    error InvalidStakeId();
    error PositionNotActive();
    error WithdrawFailed();
    error OnlyMinter();
    error SynthTierInvalid();
    error SynthNotOwner();
    error SynthMintCap();

    // ─── Modifiers ────────────────────────────────────────────────────────────
    modifier notPaused() { if (paused) revert Paused(); _; }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    // ═══════════════════════════════════════════════════════════════════════════
    //  INITIALIZER
    // ═══════════════════════════════════════════════════════════════════════════

    function initialize(address _usdc, address _treasury) external initializer {
        __Ownable_init(msg.sender);
        _reentrancyStatus = 1;
        usdc     = IERC20(_usdc);
        treasury = _treasury;
        uri      = "https://biliquid.io/metadata/{id}.json";

        directReferralBps   = 1000;
        indirectReferralBps =  500;
        nodeBoostBps        =  500;
        superNodeBps        =  500;
        generalAgentBps     =  500;

        _addTerm(3,  10000);
        _addTerm(6,  13333);
        _addTerm(12, 20000);
        memberFlexibleEnabled = false;
        memberFlexibleApyBps  = 600;

        tierConfigs[GOLD]     = TierConfig({ mintPrice: 30_000_000,    maxStakeAmountUsdc: 300_000_000,    apyBps: 900,  mintCap: 100_000 });
        tierConfigs[PLATINUM] = TierConfig({ mintPrice: 120_000_000,   maxStakeAmountUsdc: 1_500_000_000,  apyBps: 1000, mintCap:  25_000 });
        tierConfigs[DIAMOND]  = TierConfig({ mintPrice: 480_000_000,   maxStakeAmountUsdc: 8_500_000_000,  apyBps: 1100, mintCap:  10_000 });
        tierConfigs[BLACK]    = TierConfig({ mintPrice: 1_920_000_000, maxStakeAmountUsdc: 80_000_000_000, apyBps: 1250, mintCap:   2_500 });

        nonMemberConfig = NonMemberConfig({ stakeAmountUsdc: 100_000_000, baseApyBps: 300, flexibleApyBps: 300, flexibleEnabled: true });

        nextSerial[GOLD] = nextSerial[PLATINUM] = nextSerial[DIAMOND] = nextSerial[BLACK] = 1;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    // ═══════════════════════════════════════════════════════════════════════════
    //  REGISTRATION
    // ═══════════════════════════════════════════════════════════════════════════

    function register(address referrer) external {
        if (registrationDepth[msg.sender] != 0) revert AlreadyRegistered();
        if (referrer == address(0)) {
            registrationDepth[msg.sender] = 1;
        } else {
            if (referrer == msg.sender) revert SelfRefer();
            uint256 d = registrationDepth[referrer];
            if (d == 0) revert ReferrerNotRegistered();
            if (d >= MAX_REFERRAL_DEPTH) revert ChainTooDeep();
            registrationDepth[msg.sender] = d + 1;
            referrerOf[msg.sender] = referrer;
        }
        emit Registered(msg.sender, referrer, roleOf[msg.sender]);
    }

    function setRole(address wallet, uint8 role) external onlyOwner {
        if (role > ROLE_GENERAL_AGENT) revert InvalidRole();
        roleOf[wallet] = role;
        emit Registered(wallet, referrerOf[wallet], role);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  MINTING
    // ═══════════════════════════════════════════════════════════════════════════

    function mintCard(uint8 tier, uint256 amount) external notPaused nonReentrant {
        _requireValidTier(tier);
        if (amount == 0) revert ZeroAmount();
        if (tier > GOLD && !minters[msg.sender]) revert OnlyMinter();
        TierConfig storage cfg = tierConfigs[tier];
        if (nextSerial[tier] - 1 + amount > cfg.mintCap) revert MintCapReached();
        uint256 totalCost = cfg.mintPrice * amount;
        if (!usdc.transferFrom(msg.sender, address(this), totalCost)) revert PaymentFailed();
        for (uint256 i = 0; i < amount; i++) {
            uint256 serial = nextSerial[tier]++;
            _assignCard(msg.sender, tier, serial);
            emit CardMinted(msg.sender, tier, serial);
        }
        if (onChainReferralEnabled) _distributeReferralRewards(msg.sender, totalCost);
    }

    function adminMintToPool(uint8 tier, uint256 amount) external onlyOwner {
        _requireValidTier(tier);
        if (amount == 0) revert ZeroAmount();
        for (uint256 i = 0; i < amount; i++) {
            uint256 serial = nextSerial[tier]++;
            _assignCard(address(this), tier, serial);
        }
    }

    function giftCard(uint8 tier, uint256 serial, address recipient) external onlyOwner {
        if (recipient == address(0)) revert ZeroRecipient();
        if (cardOwner[tier][serial] != address(this)) revert NotInGiftPool();
        if (cardStaked[tier][serial]) revert CardStaked();
        _transferCard(address(this), recipient, tier, serial);
        emit CardGifted(recipient, tier, serial);
    }

    function transferCard(uint8 tier, uint256 serial, address to) external notPaused {
        if (to == address(0)) revert ZeroAddress();
        if (cardOwner[tier][serial] != msg.sender) revert NotOwner();
        if (cardStaked[tier][serial]) revert CardIsLocked();
        _transferCard(msg.sender, to, tier, serial);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  CARD SYNTHESIS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Synthesize cards of `fromTier` into 1 card of the next tier.
    ///         Gold/Platinum → next tier requires 4 input cards.
    ///         Diamond → Black requires 6 input cards.
    ///         All serials must be distinct, owned by caller, and unlocked (no USDC cost).
    function synthesizeCard(uint8 fromTier, uint256[] calldata serials)
        external notPaused nonReentrant
    {
        if (fromTier < GOLD || fromTier >= BLACK) revert SynthTierInvalid();
        uint256 required = fromTier == DIAMOND ? 6 : 4;
        if (serials.length != required) revert SynthTierInvalid();
        uint8 toTier = fromTier + 1;
        if (nextSerial[toTier] > tierConfigs[toTier].mintCap) revert SynthMintCap();
        address me = msg.sender;
        // Interleaved check+burn prevents duplicate-serial exploits
        for (uint256 i = 0; i < required; ) {
            if (cardOwner[fromTier][serials[i]] != me) revert SynthNotOwner();
            _transferCard(me, address(0), fromTier, serials[i]);
            unchecked { ++i; }
        }
        uint256 newSerial = nextSerial[toTier]++;
        _assignCard(me, toTier, newSerial);
        emit CardSynthesized(me, fromTier, toTier, newSerial);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  MEMBER STAKING
    // ═══════════════════════════════════════════════════════════════════════════

    function lockCard(uint8 tier, uint256 cardSerial) external notPaused nonReentrant {
        _requireValidTier(tier);
        if (cardOwner[tier][cardSerial] != msg.sender) revert NotCardOwner();
        if (cardStaked[tier][cardSerial]) revert AlreadyLocked();

        _transferCard(msg.sender, address(this), tier, cardSerial);
        cardStaked[tier][cardSerial] = true;
        lockedBy[tier][cardSerial]   = msg.sender;
        totalLockedByTier[tier]++;
        lockedCardCount[msg.sender][tier]++;

        _lockedSerialIndex[tier][cardSerial] = _lockedSerials[msg.sender][tier].length;
        _lockedSerials[msg.sender][tier].push(cardSerial);

        emit CardLocked(msg.sender, tier, cardSerial);
    }

    /// @param termMonths 0 = flexible; 3/6/12 = fixed-term.
    function openPosition(uint8 tier, uint256 cardSerial, uint8 termMonths, uint256 amount)
        external notPaused nonReentrant
    {
        _requireValidTier(tier);
        if (lockedBy[tier][cardSerial] != msg.sender) revert NotCardLocker();
        if (!cardStaked[tier][cardSerial]) revert NotCardOwner();
        if (amount == 0) revert ZeroAmount();
        if (positions[tier][cardSerial].active) revert PositionAlreadyOpen();

        TierConfig storage cfg = tierConfigs[tier];
        if (amount > cfg.maxStakeAmountUsdc) revert ExceedsCardCapacity();

        (bool isFlexible_, uint256 snapshotApy, uint256 lockSeconds) =
            _memberTermParams(cfg.apyBps, termMonths);

        if (!usdc.transferFrom(msg.sender, address(this), amount)) revert UsdcTransferFailed();

        uint256 now_    = block.timestamp;
        uint256 unlock_ = isFlexible_ ? 0 : now_ + lockSeconds;

        positions[tier][cardSerial] = Position({
            active:          true,
            isFlexible:      isFlexible_,
            termMonths:      termMonths,
            usdcPrincipal:   amount,
            snapshotApyBps:  snapshotApy,
            openedAt:        now_,
            unlockedAt:      unlock_,
            lastClaimAt:     now_,
            claimableAmount: 0
        });

        emit PositionOpened(msg.sender, tier, cardSerial, termMonths, isFlexible_, amount, snapshotApy, unlock_);
    }

    /// @notice Add USDC to an active position. Accrues interest (does not pay out).
    function addToPosition(uint8 tier, uint256 serial, uint256 amount) external notPaused nonReentrant {
        _requireValidTier(tier);
        if (lockedBy[tier][serial] != msg.sender) revert NotCardLocker();
        Position storage p = positions[tier][serial];
        if (!p.active) revert NoActivePosition();
        if (amount == 0) revert ZeroAmount();
        TierConfig storage cfg = tierConfigs[tier];
        if (p.usdcPrincipal + amount > cfg.maxStakeAmountUsdc) revert ExceedsCardCapacity();

        _settleAndAccrue(tier, serial);
        if (!usdc.transferFrom(msg.sender, address(this), amount)) revert UsdcTransferFailed();
        p.usdcPrincipal += amount;

        emit AmountAdded(msg.sender, tier, serial, amount, p.usdcPrincipal);
    }

    /// @notice Reduce principal. Accrues interest (does not pay out).
    ///         Flexible: any time. Fixed-term: post-expiry only.
    function partialWithdraw(uint8 tier, uint256 serial, uint256 amount) external notPaused nonReentrant {
        _requireValidTier(tier);
        if (lockedBy[tier][serial] != msg.sender) revert NotCardLocker();
        Position storage p = positions[tier][serial];
        if (!p.active) revert NoActivePosition();
        if (amount == 0) revert ZeroAmount();
        if (amount >= p.usdcPrincipal) revert UseClosePosition();
        if (!p.isFlexible && block.timestamp < p.unlockedAt) revert StillLocked();

        _settleAndAccrue(tier, serial);
        p.usdcPrincipal -= amount;
        if (!usdc.transfer(msg.sender, amount)) revert WithdrawFailed();

        emit PartialWithdrawn(msg.sender, tier, serial, amount, p.usdcPrincipal);
    }

    /// @notice Upgrade a fixed-term to a longer term. Accrues interest (does not pay out).
    ///         New APY = baseApy * termMultiplier[newTerm].
    ///         New unlock = openedAt + newTermMonths*30d (anchored to open time).
    function upgradeTerms(uint8 tier, uint256 serial, uint8 newTermMonths) external notPaused nonReentrant {
        _requireValidTier(tier);
        if (lockedBy[tier][serial] != msg.sender) revert NotCardLocker();
        Position storage p = positions[tier][serial];
        if (!p.active) revert NoActivePosition();
        if (p.isFlexible) revert CannotUpgradeFlexible();
        if (!_isValidTerm(newTermMonths)) revert InvalidTerm();
        if (newTermMonths <= p.termMonths) revert MustUpgradeToLonger();

        _settleAndAccrue(tier, serial);

        TierConfig storage cfg = tierConfigs[tier];
        uint256 newApy      = cfg.apyBps * termMultiplierBps[newTermMonths] / 10_000;
        uint256 newUnlockAt = p.openedAt + uint256(newTermMonths) * SECONDS_PER_MONTH;

        p.termMonths     = newTermMonths;
        p.snapshotApyBps = newApy;
        p.unlockedAt     = newUnlockAt;

        emit TermsUpgraded(msg.sender, tier, serial, newTermMonths, newApy, newUnlockAt);
    }

    /// @notice Settle and pay all accrued interest for one position.
    ///         Enforces a 1-day minimum interval since lastClaimAt (or openedAt).
    function claimMemberInterest(uint8 tier, uint256 serial) external nonReentrant {
        _requireValidTier(tier);
        if (lockedBy[tier][serial] != msg.sender) revert NotCardLocker();
        Position storage p = positions[tier][serial];
        if (!p.active) revert NoActivePosition();
        if (block.timestamp < p.lastClaimAt + SECONDS_PER_DAY) revert ClaimTooSoon();
        _settleAndPay(tier, serial, msg.sender);
    }

    /// @notice Claim accrued interest for ALL active member positions of caller.
    ///         Silently skips positions whose 1-day cooldown has not elapsed yet.
    function claimAllInterest() external nonReentrant {
        uint8[4] memory tiers_ = [GOLD, PLATINUM, DIAMOND, BLACK];
        for (uint256 t = 0; t < 4; t++) {
            uint8 tier = tiers_[t];
            uint256[] storage ls = _lockedSerials[msg.sender][tier];
            uint256 len = ls.length;
            for (uint256 i = 0; i < len; i++) {
                uint256 serial = ls[i];
                Position storage p = positions[tier][serial];
                if (p.active && block.timestamp >= p.lastClaimAt + SECONDS_PER_DAY) {
                    _settleAndPay(tier, serial, msg.sender);
                }
            }
        }
    }

    /// @notice Close a member position: settle interest + return full principal.
    ///         Card remains locked; call unlockCard() separately to get it back.
    function closePosition(uint8 tier, uint256 serial) external nonReentrant {
        _requireValidTier(tier);
        if (lockedBy[tier][serial] != msg.sender) revert NotCardLocker();
        Position storage p = positions[tier][serial];
        if (!p.active) revert NoActivePosition();
        if (!p.isFlexible && block.timestamp < p.unlockedAt) revert StillLocked();

        uint256 principal = p.usdcPrincipal;
        uint256 interest  = _settleAndPay(tier, serial, msg.sender);

        p.active        = false;
        p.usdcPrincipal = 0;

        if (!usdc.transfer(msg.sender, principal)) revert PrincipalReturnFailed();
        emit PositionClosed(msg.sender, tier, serial, principal, interest);
    }

    /// @notice Return the locked card to the caller's wallet.
    ///         Requires: position must be closed first.
    function unlockCard(uint8 tier, uint256 cardSerial) external nonReentrant {
        if (lockedBy[tier][cardSerial] != msg.sender) revert NotCardLocker();
        if (positions[tier][cardSerial].active) revert PositionStillOpen();

        lockedBy[tier][cardSerial]   = address(0);
        cardStaked[tier][cardSerial] = false;
        totalLockedByTier[tier]--;
        if (lockedCardCount[msg.sender][tier] > 0) lockedCardCount[msg.sender][tier]--;

        uint256[] storage ls = _lockedSerials[msg.sender][tier];
        uint256 idx_         = _lockedSerialIndex[tier][cardSerial];
        uint256 last_        = ls[ls.length - 1];
        ls[idx_]             = last_;
        _lockedSerialIndex[tier][last_] = idx_;
        ls.pop();
        delete _lockedSerialIndex[tier][cardSerial];

        _transferCard(address(this), msg.sender, tier, cardSerial);
        emit CardUnlocked(msg.sender, tier, cardSerial);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  NON-MEMBER STAKING
    // ═══════════════════════════════════════════════════════════════════════════

    function stakeNonMember(uint8 termMonths) external notPaused nonReentrant returns (uint256 stakeId) {
        NonMemberConfig storage cfg = nonMemberConfig;
        bool    isFlexible_;
        uint256 snapshotApy;
        uint256 lockSeconds;
        if (termMonths == 0) {
            if (!cfg.flexibleEnabled) revert NonMemberFlexibleDisabled();
            isFlexible_ = true; snapshotApy = cfg.flexibleApyBps; lockSeconds = 0;
        } else {
            if (!_isValidTerm(termMonths)) revert InvalidTerm();
            isFlexible_ = false;
            snapshotApy = cfg.baseApyBps * termMultiplierBps[termMonths] / 10_000;
            lockSeconds = uint256(termMonths) * SECONDS_PER_MONTH;
        }
        uint256 usdcAmount = cfg.stakeAmountUsdc;
        if (!usdc.transferFrom(msg.sender, address(this), usdcAmount)) revert UsdcTransferFailed();
        uint256 now_ = block.timestamp;
        stakeId = stakeRecords[msg.sender].length;
        stakeRecords[msg.sender].push(StakeRecord({
            isFlexible:     isFlexible_,
            termMonths:     termMonths,
            snapshotApyBps: snapshotApy,
            usdcAmount:     usdcAmount,
            stakedAt:       now_,
            unlockedAt:     now_ + lockSeconds,
            lastClaimAt:    now_,
            active:         true
        }));
        emit Staked(msg.sender, stakeId, usdcAmount, termMonths, isFlexible_, snapshotApy, now_ + lockSeconds);
    }

    function unstakeNonMember(uint256 stakeId) external nonReentrant {
        StakeRecord storage rec = _requireActive(msg.sender, stakeId);
        if (!rec.isFlexible && block.timestamp < rec.unlockedAt) revert StillLocked();
        uint256 monthsPast = (block.timestamp - rec.lastClaimAt) / SECONDS_PER_MONTH;
        if (monthsPast > 0) _claimInterestLegacy(msg.sender, stakeId, rec);
        if (!usdc.transfer(msg.sender, rec.usdcAmount)) revert UsdcReturnFailed();
        rec.active = false;
        emit Unstaked(msg.sender, stakeId);
    }

    function claimInterest(uint256 stakeId) external nonReentrant {
        StakeRecord storage rec = _requireActive(msg.sender, stakeId);
        if (rec.usdcAmount == 0 || rec.lastClaimAt == 0) revert NoUsdcDeposited();
        uint256 monthsPast = (block.timestamp - rec.lastClaimAt) / SECONDS_PER_MONTH;
        if (monthsPast == 0) revert ClaimOncePer30Days();
        _claimInterestLegacy(msg.sender, stakeId, rec);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  VIEWS
    // ═══════════════════════════════════════════════════════════════════════════

    function getCardsByOwner(address owner, uint8 tier) external view returns (uint256[] memory) {
        return _ownedSerials[owner][tier];
    }

    function getLockedSerials(address owner, uint8 tier) external view returns (uint256[] memory) {
        return _lockedSerials[owner][tier];
    }

    function getStakeRecords(address wallet) external view returns (StakeRecord[] memory) {
        return stakeRecords[wallet];
    }

    function getPosition(uint8 tier, uint256 serial) external view returns (Position memory) {
        return positions[tier][serial];
    }

    function pendingMemberInterest(uint8 tier, uint256 serial) external view returns (uint256) {
        Position storage p = positions[tier][serial];
        if (!p.active || p.usdcPrincipal == 0) return 0;
        uint256 accrued = p.usdcPrincipal * p.snapshotApyBps * (block.timestamp - p.lastClaimAt) / (10_000 * 365 days);
        return p.claimableAmount + accrued;
    }

    function getValidTerms() external view returns (uint8[] memory) { return validTerms; }

    // ─── ERC-1155 standard views ───────────────────────────────────────────────
    function balanceOf(address account, uint256 id) public view returns (uint256) {
        return _balances[account][id];
    }

    function balanceOfBatch(address[] calldata accounts, uint256[] calldata ids)
        external view returns (uint256[] memory out)
    {
        if (accounts.length != ids.length) revert LengthMismatch();
        out = new uint256[](accounts.length);
        for (uint256 i = 0; i < accounts.length; i++) { out[i] = _balances[accounts[i]][ids[i]]; }
    }

    function isApprovedForAll(address account, address operator) public view returns (bool) {
        return _operatorApprovals[account][operator];
    }

    function setApprovalForAll(address operator, bool approved) external {
        _operatorApprovals[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == 0xd9b67a26 || id == 0x0e89341c || id == 0x01ffc9a7;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  ADMIN CONFIG
    // ═══════════════════════════════════════════════════════════════════════════

    function setTierConfig(uint8 tier, uint256 mintPrice, uint256 maxStakeAmountUsdc, uint256 apyBps, uint256 mintCap) external onlyOwner {
        _requireValidTier(tier);
        tierConfigs[tier] = TierConfig(mintPrice, maxStakeAmountUsdc, apyBps, mintCap);
        emit TierUpdated(tier);
    }

    function setNonMemberConfig(uint256 stakeAmountUsdc, uint256 baseApyBps, uint256 flexibleApyBps, bool flexibleEnabled) external onlyOwner {
        nonMemberConfig = NonMemberConfig(stakeAmountUsdc, baseApyBps, flexibleApyBps, flexibleEnabled);
    }

    function addTerm(uint8 termMonths, uint256 multiplierBps) external onlyOwner {
        if (termMonths == 0) revert TermMustBePositive();
        if (_isValidTerm(termMonths)) revert TermExists();
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
        revert TermNotFound();
    }

    function setTermMultiplier(uint8 termMonths, uint256 multiplierBps) external onlyOwner {
        if (!_isValidTerm(termMonths)) revert TermNotFound();
        termMultiplierBps[termMonths] = multiplierBps;
    }

    function setMemberFlexibleStaking(bool enabled, uint256 apyBps) external onlyOwner {
        memberFlexibleEnabled = enabled;
        memberFlexibleApyBps  = apyBps;
    }

    function setReferralRates(uint256 direct_, uint256 indirect_, uint256 nodeBoost_, uint256 superNode_, uint256 generalAgent_) external onlyOwner {
        directReferralBps   = direct_;
        indirectReferralBps = indirect_;
        nodeBoostBps        = nodeBoost_;
        superNodeBps        = superNode_;
        generalAgentBps     = generalAgent_;
    }

    /// @notice Toggle the legacy on-chain referral payout in mintCard.
    ///         Commissions are handled off-chain (Merkle claim) by default, so this
    ///         stays false. Only enable if reverting to on-chain distribution.
    function setReferralEnabled(bool enabled) external onlyOwner {
        onChainReferralEnabled = enabled;
        emit ReferralEnabledSet(enabled);
    }

    function setMinter(address wallet, bool enabled) external onlyOwner {
        minters[wallet] = enabled;
    }

    function setUri(string calldata newUri) external onlyOwner { uri = newUri; }
    function setUsdc(address _usdc)         external onlyOwner { usdc = IERC20(_usdc); }
    function setTreasury(address _treasury) external onlyOwner { treasury = _treasury; }
    function setPaused(bool _paused)        external onlyOwner { paused = _paused; }

    function withdrawToTreasury(address token, uint256 amount) external onlyOwner {
        if (!IERC20(token).transfer(treasury, amount)) revert WithdrawFailed();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  INTERNAL HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Accrue interest into claimableAmount without paying out.
    ///      Used by addToPosition / partialWithdraw / upgradeTerms so that
    ///      principal changes reset the accrual window without forcing a claim.
    function _settleAndAccrue(uint8 tier, uint256 serial) internal {
        Position storage p = positions[tier][serial];
        uint256 accrued = p.usdcPrincipal * p.snapshotApyBps * (block.timestamp - p.lastClaimAt)
                          / (10_000 * 365 days);
        p.lastClaimAt = block.timestamp;
        if (accrued > 0) p.claimableAmount += accrued;
    }

    /// @dev Pay out claimableAmount + newly accrued interest. Used by claim / close.
    function _settleAndPay(uint8 tier, uint256 serial, address to) internal returns (uint256 interest) {
        Position storage p = positions[tier][serial];
        uint256 accrued = p.usdcPrincipal * p.snapshotApyBps * (block.timestamp - p.lastClaimAt)
                          / (10_000 * 365 days);
        p.lastClaimAt = block.timestamp;
        interest = p.claimableAmount + accrued;
        p.claimableAmount = 0;
        if (interest > 0) {
            if (!usdc.transfer(to, interest)) revert InterestTransferFailed();
            emit MemberInterestClaimed(to, tier, serial, interest);
        }
    }

    function _assignCard(address to, uint8 tier, uint256 serial) internal {
        cardOwner[tier][serial] = to;
        _ownedSerialIndex[tier][serial] = _ownedSerials[to][tier].length;
        _ownedSerials[to][tier].push(serial);
        _balances[to][tier]++;
        emit TransferSingle(msg.sender, address(0), to, tier, 1);
    }

    function _transferCard(address from, address to, uint8 tier, uint256 serial) internal {
        uint256[] storage fromList = _ownedSerials[from][tier];
        uint256 idx        = _ownedSerialIndex[tier][serial];
        uint256 lastSerial = fromList[fromList.length - 1];
        fromList[idx]                      = lastSerial;
        _ownedSerialIndex[tier][lastSerial] = idx;
        fromList.pop();
        _ownedSerialIndex[tier][serial] = _ownedSerials[to][tier].length;
        _ownedSerials[to][tier].push(serial);
        cardOwner[tier][serial] = to;
        _balances[from][tier]--;
        _balances[to][tier]++;
        emit TransferSingle(msg.sender, from, to, tier, 1);
        if (to != address(0)) emit CardTransferred(from, to, tier, serial);
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
        if (tier < GOLD || tier > BLACK) revert InvalidTier();
    }

    function _requireActive(address wallet, uint256 stakeId) internal view returns (StakeRecord storage rec) {
        if (stakeId >= stakeRecords[wallet].length) revert InvalidStakeId();
        rec = stakeRecords[wallet][stakeId];
        if (!rec.active) revert PositionNotActive();
    }

    function _memberTermParams(uint256 baseApyBps, uint8 termMonths)
        internal view returns (bool isFlexible_, uint256 snapshotApy, uint256 lockSeconds)
    {
        if (termMonths == 0) {
            if (!memberFlexibleEnabled) revert FlexibleStakingDisabled();
            isFlexible_ = true;
            snapshotApy = memberFlexibleApyBps;
            lockSeconds = 0;
        } else {
            if (!_isValidTerm(termMonths)) revert InvalidTerm();
            isFlexible_ = false;
            snapshotApy = baseApyBps * termMultiplierBps[termMonths] / 10_000;
            lockSeconds = uint256(termMonths) * SECONDS_PER_MONTH;
        }
    }

    function _dailyInterest(StakeRecord storage rec) internal view returns (uint256) {
        return rec.usdcAmount * rec.snapshotApyBps / (10_000 * 365);
    }

    function _claimInterestLegacy(address wallet, uint256 stakeId, StakeRecord storage rec) internal {
        uint256 monthsPast = (block.timestamp - rec.lastClaimAt) / SECONDS_PER_MONTH;
        if (monthsPast == 0) return;
        uint256 daysPast = monthsPast * 30;
        uint256 interest = _dailyInterest(rec) * daysPast;
        rec.lastClaimAt += monthsPast * SECONDS_PER_MONTH;
        if (interest > 0) { if (!usdc.transfer(wallet, interest)) revert InterestTransferFailed(); }
        emit InterestClaimed(wallet, stakeId, interest, daysPast);
    }

    function _distributeReferralRewards(address buyer, uint256 totalUsdc) internal {
        address l1 = referrerOf[buyer];
        if (l1 == address(0)) return;
        _payReferral(l1, buyer, _bps(totalUsdc, directReferralBps), "direct");
        if (roleOf[l1] >= ROLE_NODE) { _payReferral(l1, buyer, _bps(totalUsdc, nodeBoostBps), "node_boost"); }
        address l2 = referrerOf[l1];
        if (l2 == address(0)) return;
        _payReferral(l2, buyer, _bps(totalUsdc, indirectReferralBps), "indirect");
        bool snPaid = false; bool gaPaid = false;
        address cur = referrerOf[l2];
        while (cur != address(0) && !(snPaid && gaPaid)) {
            uint8 r = roleOf[cur];
            if (!snPaid && r >= ROLE_SUPERNODE)     { _payReferral(cur, buyer, _bps(totalUsdc, superNodeBps),     "supernode");     snPaid = true; }
            if (!gaPaid && r >= ROLE_GENERAL_AGENT) { _payReferral(cur, buyer, _bps(totalUsdc, generalAgentBps), "general_agent"); gaPaid = true; }
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
