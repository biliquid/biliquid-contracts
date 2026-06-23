// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title BiliquidVIPCard
 * @notice ERC-1155 VIP membership card protocol — UUPS upgradeable.
 *
 * ── Design Philosophy ───────────────────────────────────────────────────────
 * ALL user-facing state is stored on-chain and readable via view functions.
 * No off-chain event indexing is required for user reads. The backend queries
 * getUserState(address) via RPC (1-minute local cache recommended).
 *
 * ── Token IDs ────────────────────────────────────────────────────────────────
 *   1 = Gold      (mint: 30 USDC)
 *   2 = Platinum  (merge: 4 Gold → 1 Platinum)
 *   3 = Diamond   (merge: 4 Platinum → 1 Diamond)
 *   4 = Black     (merge: 6 Diamond → 1 Black)
 *
 * ── Roles ────────────────────────────────────────────────────────────────────
 *   0 = User  1 = Node  2 = SuperNode  3 = GeneralAgent
 *
 * ── Referral Reward Matrix (per mint) ────────────────────────────────────────
 *   L1 (direct referrer):        10% USDC + 10% pts
 *   L1 is Node+:                 +5% USDC + 5% pts  (node boost, stacks)
 *   L2 (indirect referrer):       5% USDC + 5%  pts
 *   First SuperNode ancestor:     5% USDC + 5%  pts
 *   First GeneralAgent ancestor:  5% USDC + 5%  pts
 *
 * ── Merge Rewards ────────────────────────────────────────────────────────────
 *   Same tree walk, points only (no USDC).
 *   Source cards sent to treasury (not burned).
 *
 * ── Upgradeability ───────────────────────────────────────────────────────────
 *   UUPS proxy pattern (EIP-1822). Only owner can authorise upgrades.
 *   Deploy via: new ERC1967Proxy(impl, abi.encodeCall(initialize, (usdc, treasury)))
 */

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract BiliquidVIPCard is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuard,
    UUPSUpgradeable
{
    // ─── ERC-1155 storage ────────────────────────────────────────────────────
    mapping(address => mapping(uint256 => uint256)) private _balances;
    mapping(address => mapping(address => bool))    private _operatorApprovals;
    string public uri;

    event TransferSingle(address indexed operator, address indexed from, address indexed to, uint256 id, uint256 value);
    event TransferBatch (address indexed operator, address indexed from, address indexed to, uint256[] ids, uint256[] values);
    event ApprovalForAll(address indexed account, address indexed operator, bool approved);

    // ─── Access ───────────────────────────────────────────────────────────────
    bool public paused;

    modifier notPaused() { require(!paused, "paused"); _; }

    // ─── Token IDs ────────────────────────────────────────────────────────────
    uint8 public constant GOLD      = 1;
    uint8 public constant PLATINUM  = 2;
    uint8 public constant DIAMOND   = 3;
    uint8 public constant BLACK     = 4;

    // ─── Roles ────────────────────────────────────────────────────────────────
    uint8 public constant ROLE_USER          = 0;
    uint8 public constant ROLE_NODE          = 1;
    uint8 public constant ROLE_SUPERNODE     = 2;
    uint8 public constant ROLE_GENERAL_AGENT = 3;

    // ─── Tier Config ──────────────────────────────────────────────────────────
    struct TierConfig {
        uint256 mintPrice;      // USDC (6 dec); 0 = not directly purchasable
        uint256 mintPoints;     // points awarded to buyer on mint
        uint256 mergePoints;    // points awarded on merge into this tier
        uint8   mergeRequires;  // number of source cards to consume
        uint8   mergeFromTier;  // source token ID (0 = not a merge target)
        uint256 principalUsdc;  // nominal principal for APY calc (6 dec)
        uint256 apyBps;         // APY in basis points (e.g. 900 = 9%)
    }
    mapping(uint8 => TierConfig) public tierConfigs;

    // ─── Payment token ────────────────────────────────────────────────────────
    IERC20  public usdc;
    address public treasury;

    // ─── Referral ─────────────────────────────────────────────────────────────
    /// @notice referrerOf[wallet] — set once via register(), immutable
    mapping(address => address) public referrerOf;
    /// @notice roleOf[wallet] — set by owner via setRole()
    mapping(address => uint8)   public roleOf;

    /**
     * @notice registrationDepth[wallet]:
     *   0 = never registered
     *   1 = root (registered with no referrer)
     *   2+ = registered under a referrer at depth n → own depth = n+1
     *
     * Anti-cycle guarantee (O(1), no chain-walk):
     *   depth is strictly monotone: child.depth > parent.depth always.
     *   Since registration is one-time and requires parent to be registered first,
     *   cycles are mathematically impossible.
     */
    mapping(address => uint256) public registrationDepth;
    uint256 public constant MAX_REFERRAL_DEPTH = 20;

    uint256 public directReferralBps;
    uint256 public indirectReferralBps;
    uint256 public nodeBoostBps;
    uint256 public superNodeBps;
    uint256 public generalAgentBps;

    // ─── Points (on-chain) ────────────────────────────────────────────────────
    mapping(address => uint256) public points;

    // ─── Staking ──────────────────────────────────────────────────────────────
    mapping(address => mapping(uint8 => uint256)) public stakedBalance;

    // ─── Events ───────────────────────────────────────────────────────────────
    event Registered    (address indexed wallet, address indexed referrer, uint8 role);
    event Minted        (address indexed to, uint8 tokenId, uint256 amount, uint256 pts);
    event Merged        (address indexed by, uint8 fromTier, uint8 toTier, uint256 mergePoints);
    event PointsAwarded (address indexed wallet, uint256 amount, string reason);
    event ReferralReward(address indexed recipient, address indexed buyer,
                         uint256 usdcAmt, uint256 pts, string reason);
    event Staked        (address indexed staker, uint8 tokenId, uint256 amount);
    event Unstaked      (address indexed staker, uint8 tokenId, uint256 amount);
    event TierUpdated   (uint8 tokenId);

    // ─── Constructor (disabled — use initialize) ──────────────────────────────
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ─── Initializer (replaces constructor for upgradeable proxy) ────────────
    function initialize(address _usdc, address _treasury) external initializer {
        __Ownable_init(msg.sender);

        usdc     = IERC20(_usdc);
        directReferralBps   = 1000; // 10%
        indirectReferralBps =  500; //  5%
        nodeBoostBps        =  500; //  5%
        superNodeBps        =  500; //  5%
        generalAgentBps     =  500; //  5%
        treasury = _treasury;
        uri      = "https://biliquid.io/metadata/{id}.json";

        tierConfigs[GOLD] = TierConfig({
            mintPrice:     30_000_000,   // 30 USDC
            mintPoints:    10_000,
            mergePoints:   0,
            mergeRequires: 0,
            mergeFromTier: 0,
            principalUsdc: 30_000_000,
            apyBps:        900
        });
        tierConfigs[PLATINUM] = TierConfig({
            mintPrice:     0,
            mintPoints:    0,
            mergePoints:   4_000,
            mergeRequires: 4,
            mergeFromTier: GOLD,
            principalUsdc: 120_000_000,
            apyBps:        1000
        });
        tierConfigs[DIAMOND] = TierConfig({
            mintPrice:     0,
            mintPoints:    0,
            mergePoints:   8_000,
            mergeRequires: 4,
            mergeFromTier: PLATINUM,
            principalUsdc: 480_000_000,
            apyBps:        1200
        });
        tierConfigs[BLACK] = TierConfig({
            mintPrice:     0,
            mintPoints:    0,
            mergePoints:   15_000,
            mergeRequires: 6,
            mergeFromTier: DIAMOND,
            principalUsdc: 2_880_000_000,
            apyBps:        1500
        });
    }

    // ─── UUPS upgrade authorisation ───────────────────────────────────────────
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    // ─── Registration ─────────────────────────────────────────────────────────
    /**
     * @notice Register and optionally bind a referrer. One-time, immutable.
     *         Must be called before minting to receive referral attribution.
     * @param referrer  Your referrer's address, or address(0) to join as root.
     */
    function register(address referrer) external {
        require(registrationDepth[msg.sender] == 0, "already registered");

        if (referrer == address(0)) {
            registrationDepth[msg.sender] = 1;
        } else {
            require(referrer != msg.sender, "self-refer");
            uint256 refDepth = registrationDepth[referrer];
            require(refDepth > 0,                 "referrer not registered");
            require(refDepth < MAX_REFERRAL_DEPTH, "chain too deep");
            registrationDepth[msg.sender] = refDepth + 1;
            referrerOf[msg.sender]        = referrer;
        }

        emit Registered(msg.sender, referrer, roleOf[msg.sender]);
    }

    /// @notice Owner assigns role: Node=1, SuperNode=2, GeneralAgent=3
    function setRole(address wallet, uint8 role) external onlyOwner {
        require(role <= ROLE_GENERAL_AGENT, "invalid role");
        roleOf[wallet] = role;
        emit Registered(wallet, referrerOf[wallet], role);
    }

    // ─── Mint ─────────────────────────────────────────────────────────────────
    function mint(uint256 amount) external notPaused nonReentrant {
        require(amount > 0, "amount=0");
        TierConfig storage cfg = tierConfigs[GOLD];
        uint256 totalCost = cfg.mintPrice * amount;

        require(usdc.transferFrom(msg.sender, address(this), totalCost), "payment failed");

        _mint(msg.sender, GOLD, amount);

        uint256 earnedPts = cfg.mintPoints * amount;
        _addPoints(msg.sender, earnedPts, "mint");
        _distributeReferralRewards(msg.sender, totalCost, earnedPts);

        emit Minted(msg.sender, GOLD, amount, earnedPts);
    }

    // ─── Merge ────────────────────────────────────────────────────────────────
    function merge(uint8 targetTier) external notPaused nonReentrant {
        TierConfig storage cfg = tierConfigs[targetTier];
        require(cfg.mergeFromTier != 0, "not a merge target");
        uint8   fromTier = cfg.mergeFromTier;
        uint256 needed   = cfg.mergeRequires;
        require(_balances[msg.sender][fromTier] >= needed, "insufficient cards");

        _transfer(msg.sender, treasury, fromTier, needed);
        _mint(msg.sender, targetTier, 1);

        uint256 mpts = cfg.mergePoints;
        _addPoints(msg.sender, mpts, "merge");
        _distributeReferralPoints(msg.sender, mpts);

        emit Merged(msg.sender, fromTier, targetTier, mpts);
    }

    // ─── Staking ──────────────────────────────────────────────────────────────
    function stake(uint8 tokenId, uint256 amount) external notPaused nonReentrant {
        require(tokenId >= GOLD && tokenId <= BLACK, "invalid tier");
        require(_balances[msg.sender][tokenId] >= amount, "insufficient");
        _transfer(msg.sender, address(this), tokenId, amount);
        stakedBalance[msg.sender][tokenId] += amount;
        emit Staked(msg.sender, tokenId, amount);
    }

    function unstake(uint8 tokenId, uint256 amount) external nonReentrant {
        require(stakedBalance[msg.sender][tokenId] >= amount, "insufficient staked");
        stakedBalance[msg.sender][tokenId] -= amount;
        _transfer(address(this), msg.sender, tokenId, amount);
        emit Unstaked(msg.sender, tokenId, amount);
    }

    // ─── View functions (RPC-queryable) ───────────────────────────────────────
    function getUserState(address wallet) external view returns (
        uint256 pts,
        uint256 freeGold,     uint256 freePlatinum,   uint256 freeDiamond,   uint256 freeBlack,
        uint256 stakedGold,   uint256 stakedPlatinum, uint256 stakedDiamond, uint256 stakedBlack,
        address referrer,
        uint8   role
    ) {
        pts            = points[wallet];
        freeGold       = _balances[wallet][GOLD];
        freePlatinum   = _balances[wallet][PLATINUM];
        freeDiamond    = _balances[wallet][DIAMOND];
        freeBlack      = _balances[wallet][BLACK];
        stakedGold     = stakedBalance[wallet][GOLD];
        stakedPlatinum = stakedBalance[wallet][PLATINUM];
        stakedDiamond  = stakedBalance[wallet][DIAMOND];
        stakedBlack    = stakedBalance[wallet][BLACK];
        referrer       = referrerOf[wallet];
        role           = roleOf[wallet];
    }

    function getPoints(address wallet) external view returns (uint256) {
        return points[wallet];
    }

    function balanceOf(address account, uint256 id) public view returns (uint256) {
        return _balances[account][id];
    }

    function balanceOfBatch(address[] calldata accounts, uint256[] calldata ids)
        external view returns (uint256[] memory out)
    {
        require(accounts.length == ids.length, "length mismatch");
        out = new uint256[](accounts.length);
        for (uint256 i = 0; i < accounts.length; i++) {
            out[i] = _balances[accounts[i]][ids[i]];
        }
    }

    /// @notice Projected daily USDC interest for a staker (6 dec)
    function dailyInterest(address wallet) external view returns (uint256 total) {
        for (uint8 t = GOLD; t <= BLACK; t++) {
            uint256 amt = stakedBalance[wallet][t];
            if (amt == 0) continue;
            TierConfig storage cfg = tierConfigs[t];
            total += (cfg.principalUsdc * amt * cfg.apyBps) / 10_000 / 365;
        }
    }

    // ─── ERC-1155 operator approval ───────────────────────────────────────────
    function setApprovalForAll(address operator, bool approved) external {
        _operatorApprovals[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function isApprovedForAll(address account, address operator) public view returns (bool) {
        return _operatorApprovals[account][operator];
    }

    function safeTransferFrom(
        address from, address to, uint256 id, uint256 amount, bytes calldata
    ) external {
        require(from == msg.sender || isApprovedForAll(from, msg.sender), "not approved");
        _transfer(from, to, id, amount);
    }

    function safeBatchTransferFrom(
        address from, address to,
        uint256[] calldata ids, uint256[] calldata amounts, bytes calldata
    ) external {
        require(from == msg.sender || isApprovedForAll(from, msg.sender), "not approved");
        require(ids.length == amounts.length, "length mismatch");
        for (uint256 i = 0; i < ids.length; i++) {
            _transfer(from, to, ids[i], amounts[i]);
        }
        emit TransferBatch(msg.sender, from, to, ids, amounts);
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == 0xd9b67a26  // ERC-1155
            || interfaceId == 0x0e89341c  // ERC-1155 metadata
            || interfaceId == 0x01ffc9a7; // ERC-165
    }

    // ─── Admin ────────────────────────────────────────────────────────────────
    function setTierConfig(
        uint8 tokenId,
        uint256 mintPrice, uint256 mintPoints, uint256 mergePoints,
        uint8 mergeRequires, uint8 mergeFromTier,
        uint256 principalUsdc, uint256 apyBps_
    ) external onlyOwner {
        tierConfigs[tokenId] = TierConfig(
            mintPrice, mintPoints, mergePoints,
            mergeRequires, mergeFromTier,
            principalUsdc, apyBps_
        );
        emit TierUpdated(tokenId);
    }

    function setUsdc(address _usdc)           external onlyOwner { usdc     = IERC20(_usdc); }
    function setTreasury(address _treasury)   external onlyOwner { treasury = _treasury; }
    function setPaused(bool _paused)          external onlyOwner { paused   = _paused; }

    function setReferralRates(
        uint256 _direct, uint256 _indirect, uint256 _nodeBoost,
        uint256 _superNode, uint256 _generalAgent
    ) external onlyOwner {
        directReferralBps   = _direct;
        indirectReferralBps = _indirect;
        nodeBoostBps        = _nodeBoost;
        superNodeBps        = _superNode;
        generalAgentBps     = _generalAgent;
    }

    function withdrawToTreasury(address token, uint256 amount) external onlyOwner {
        require(IERC20(token).transfer(treasury, amount), "withdraw failed");
    }

    // ─── Internal ─────────────────────────────────────────────────────────────
    function _mint(address to, uint8 id, uint256 amount) internal {
        _balances[to][id] += amount;
        emit TransferSingle(msg.sender, address(0), to, id, amount);
    }

    function _transfer(address from, address to, uint256 id, uint256 amount) internal {
        require(_balances[from][id] >= amount, "insufficient balance");
        _balances[from][id] -= amount;
        _balances[to][id]   += amount;
        emit TransferSingle(msg.sender, from, to, id, amount);
    }

    function _addPoints(address wallet, uint256 amount, string memory reason) internal {
        if (amount == 0) return;
        points[wallet] += amount;
        emit PointsAwarded(wallet, amount, reason);
    }

    function _bps(uint256 amount, uint256 rate) internal pure returns (uint256) {
        return (amount * rate) / 10_000;
    }

    /**
     * @dev On mint: walk referral tree, pay USDC + points.
     *   L1 = direct referrer     → direct(10%) [+ nodeBoost(5%) if Node+]
     *   L2 = referrer of L1      → indirect(5%)
     *   ancestors above L2:
     *     first  SuperNode found → superNode(5%)
     *     first  GeneralAgent   → generalAgent(5%)
     */
    function _distributeReferralRewards(
        address buyer, uint256 totalUsdc, uint256 buyerPts
    ) internal {
        address l1 = referrerOf[buyer];
        if (l1 == address(0)) return;

        _payReferral(l1, buyer,
            _bps(totalUsdc, directReferralBps), _bps(buyerPts, directReferralBps),
            "direct");

        if (roleOf[l1] >= ROLE_NODE) {
            _payReferral(l1, buyer,
                _bps(totalUsdc, nodeBoostBps), _bps(buyerPts, nodeBoostBps),
                "node_boost");
        }

        address l2 = referrerOf[l1];
        if (l2 == address(0)) return;

        _payReferral(l2, buyer,
            _bps(totalUsdc, indirectReferralBps), _bps(buyerPts, indirectReferralBps),
            "indirect");

        bool snPaid = false;
        bool gaPaid = false;
        address cur = referrerOf[l2];
        while (cur != address(0) && !(snPaid && gaPaid)) {
            uint8 r = roleOf[cur];
            if (!snPaid && r >= ROLE_SUPERNODE) {
                _payReferral(cur, buyer,
                    _bps(totalUsdc, superNodeBps), _bps(buyerPts, superNodeBps),
                    "supernode");
                snPaid = true;
            }
            if (!gaPaid && r >= ROLE_GENERAL_AGENT) {
                _payReferral(cur, buyer,
                    _bps(totalUsdc, generalAgentBps), _bps(buyerPts, generalAgentBps),
                    "general_agent");
                gaPaid = true;
            }
            cur = referrerOf[cur];
        }
    }

    function _distributeReferralPoints(address merger, uint256 mPts) internal {
        address l1 = referrerOf[merger];
        if (l1 == address(0)) return;

        _addPoints(l1, _bps(mPts, directReferralBps),   "merge_direct");
        if (roleOf[l1] >= ROLE_NODE) {
            _addPoints(l1, _bps(mPts, nodeBoostBps),    "merge_node_boost");
        }

        address l2 = referrerOf[l1];
        if (l2 == address(0)) return;

        _addPoints(l2, _bps(mPts, indirectReferralBps), "merge_indirect");

        bool snPaid = false;
        bool gaPaid = false;
        address cur = referrerOf[l2];
        while (cur != address(0) && !(snPaid && gaPaid)) {
            uint8 r = roleOf[cur];
            if (!snPaid && r >= ROLE_SUPERNODE) {
                _addPoints(cur, _bps(mPts, superNodeBps),    "merge_supernode");
                snPaid = true;
            }
            if (!gaPaid && r >= ROLE_GENERAL_AGENT) {
                _addPoints(cur, _bps(mPts, generalAgentBps), "merge_general_agent");
                gaPaid = true;
            }
            cur = referrerOf[cur];
        }
    }

    function _payReferral(
        address recipient, address buyer,
        uint256 usdcAmt, uint256 ptsAmt,
        string memory reason
    ) internal {
        if (usdcAmt > 0) usdc.transfer(recipient, usdcAmt);
        if (ptsAmt  > 0) _addPoints(recipient, ptsAmt, reason);
        emit ReferralReward(recipient, buyer, usdcAmt, ptsAmt, reason);
    }
}
