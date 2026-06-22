// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title BiliquidVIPCard
 * @notice ERC-1155 VIP membership card with on-chain points, referral tree,
 *         merge mechanics, and staking yield. All state is queryable via RPC
 *         — no off-chain event indexing required for user-facing reads.
 *
 * Token IDs:
 *   1 = Gold      (mint: 30 USDC)
 *   2 = Platinum  (merge: 4 Gold  → 1 Platinum)
 *   3 = Diamond   (merge: 4 Platinum → 1 Diamond)
 *   4 = Black     (merge: 6 Diamond → 1 Black)
 *
 * Roles:
 *   0 = User
 *   1 = Node
 *   2 = SuperNode
 *   3 = GeneralAgent
 */
contract BiliquidVIPCard is ERC1155, Ownable, ReentrancyGuard {

    // ─── Constants ────────────────────────────────────────────────────────────
    uint8 public constant GOLD     = 1;
    uint8 public constant PLATINUM = 2;
    uint8 public constant DIAMOND  = 3;
    uint8 public constant BLACK    = 4;

    uint8 public constant ROLE_USER         = 0;
    uint8 public constant ROLE_NODE         = 1;
    uint8 public constant ROLE_SUPERNODE    = 2;
    uint8 public constant ROLE_GENERAL_AGENT = 3;

    // ─── Tier Config ──────────────────────────────────────────────────────────
    struct TierConfig {
        uint256 mintPrice;      // in payment token units (USDC 6 decimals)
        uint256 mintPoints;     // points awarded to buyer on mint
        uint256 mergePoints;    // points awarded to merger on merge
        uint8   mergeRequires;  // number of lower-tier cards needed
        uint8   mergeFromTier;  // tokenId of source tier (0 = not mergeable into)
        uint256 principalUsdc;  // staking principal in USDC (6 decimals)
        uint256 apyBps;         // APY in basis points (e.g. 900 = 9%)
    }
    mapping(uint8 => TierConfig) public tierConfigs;

    // ─── Payment ──────────────────────────────────────────────────────────────
    IERC20 public usdc;
    IERC20 public usdt;
    address public treasury;

    // ─── Referral ─────────────────────────────────────────────────────────────
    /// @notice Maps wallet → direct referrer. Set once, immutable.
    mapping(address => address) public referrerOf;

    /// @notice Role of each wallet (0=User, 1=Node, 2=SuperNode, 3=GeneralAgent)
    mapping(address => uint8) public roleOf;

    // Referral reward rates in basis points (100 bps = 1%)
    uint256 public directReferralBps   = 1000; // 10%
    uint256 public indirectReferralBps =  500; //  5%
    uint256 public nodeBoostBps        =  500; //  5%
    uint256 public superNodeBps        =  500; //  5%
    uint256 public generalAgentBps     =  500; //  5%

    // ─── Points ───────────────────────────────────────────────────────────────
    /// @notice On-chain points balance per wallet. Queryable via getPoints().
    mapping(address => uint256) public points;

    // ─── Staking ──────────────────────────────────────────────────────────────
    /// @notice stakedBalance[wallet][tokenId] = amount staked
    mapping(address => mapping(uint8 => uint256)) public stakedBalance;

    // APY settlement: track last settlement timestamp per staker (for BE use)
    mapping(address => uint256) public lastSettleAt;

    // ─── Events ───────────────────────────────────────────────────────────────
    event Registered(address indexed wallet, address indexed referrer, uint8 role);
    event Minted(address indexed to, uint8 tokenId, uint256 amount, uint256 pointsAwarded);
    event Merged(address indexed by, uint8 fromTier, uint8 toTier, uint256 mergePoints);
    event PointsAwarded(address indexed wallet, uint256 amount, string reason);
    event ReferralReward(address indexed recipient, address indexed buyer, uint256 usdcAmt, uint256 pts, string reason);
    event Staked(address indexed staker, uint8 tokenId, uint256 amount);
    event Unstaked(address indexed staker, uint8 tokenId, uint256 amount);
    event TierConfigUpdated(uint8 tokenId);
    event TreasuryUpdated(address newTreasury);

    // ─── Constructor ──────────────────────────────────────────────────────────
    constructor(address _usdc, address _usdt, address _treasury)
        ERC1155("https://biliquid.io/metadata/{id}.json")
        Ownable(msg.sender)
    {
        usdc     = IERC20(_usdc);
        usdt     = IERC20(_usdt);
        treasury = _treasury;

        // Gold — directly purchasable
        tierConfigs[GOLD] = TierConfig({
            mintPrice:     30_000_000,  // 30 USDC (6 decimals)
            mintPoints:    10_000,
            mergePoints:   0,
            mergeRequires: 0,
            mergeFromTier: 0,
            principalUsdc: 30_000_000,
            apyBps:        900          // 9%
        });

        // Platinum — merge from 4 Gold
        tierConfigs[PLATINUM] = TierConfig({
            mintPrice:     0,
            mintPoints:    0,
            mergePoints:   4_000,
            mergeRequires: 4,
            mergeFromTier: GOLD,
            principalUsdc: 120_000_000,
            apyBps:        1000         // 10% (placeholder)
        });

        // Diamond — merge from 4 Platinum
        tierConfigs[DIAMOND] = TierConfig({
            mintPrice:     0,
            mintPoints:    0,
            mergePoints:   8_000,
            mergeRequires: 4,
            mergeFromTier: PLATINUM,
            principalUsdc: 480_000_000,
            apyBps:        1200         // 12% (placeholder)
        });

        // Black — merge from 6 Diamond
        tierConfigs[BLACK] = TierConfig({
            mintPrice:     0,
            mintPoints:    0,
            mergePoints:   15_000,
            mergeRequires: 6,
            mergeFromTier: DIAMOND,
            principalUsdc: 2_880_000_000,
            apyBps:        1500         // 15% (placeholder)
        });
    }

    // ─── Registration ─────────────────────────────────────────────────────────
    /**
     * @notice Register and optionally bind a referrer. Must be called before mint.
     *         Can also be called by owner to set a user's role.
     */
    function register(address referrer) external {
        require(referrerOf[msg.sender] == address(0), "already registered");
        require(referrer != msg.sender, "cannot self-refer");
        if (referrer != address(0)) {
            referrerOf[msg.sender] = referrer;
        }
        emit Registered(msg.sender, referrer, roleOf[msg.sender]);
    }

    /// @notice Owner sets a wallet's role (Node / SuperNode / GeneralAgent)
    function setRole(address wallet, uint8 role) external onlyOwner {
        require(role <= ROLE_GENERAL_AGENT, "invalid role");
        roleOf[wallet] = role;
        emit Registered(wallet, referrerOf[wallet], role);
    }

    // ─── Mint ─────────────────────────────────────────────────────────────────
    /**
     * @notice Mint Gold cards. Pays in USDC.
     *         Distributes referral rewards on-chain immediately.
     * @param amount   Number of Gold cards to mint
     * @param useUsdt  true = pay with USDT, false = pay with USDC
     */
    function mint(uint256 amount, bool useUsdt) external nonReentrant {
        TierConfig storage cfg = tierConfigs[GOLD];
        require(cfg.mintPrice > 0, "not for sale");

        uint256 totalCost = cfg.mintPrice * amount;
        IERC20 token = useUsdt ? usdt : usdc;

        // Pull payment
        require(token.transferFrom(msg.sender, address(this), totalCost), "payment failed");

        // Mint NFT
        _mint(msg.sender, GOLD, amount, "");

        // Award mint points
        uint256 earnedPoints = cfg.mintPoints * amount;
        _addPoints(msg.sender, earnedPoints, "mint");

        // Distribute referral rewards (USDC + points)
        _distributeReferralRewards(msg.sender, totalCost, earnedPoints, token);

        emit Minted(msg.sender, GOLD, amount, earnedPoints);
    }

    // ─── Merge ────────────────────────────────────────────────────────────────
    /**
     * @notice Merge lower-tier cards into the next tier.
     *         Source cards are transferred to treasury (not burned).
     * @param targetTier  The tier to merge INTO (PLATINUM=2, DIAMOND=3, BLACK=4)
     */
    function merge(uint8 targetTier) external nonReentrant {
        TierConfig storage cfg = tierConfigs[targetTier];
        require(cfg.mergeFromTier != 0, "not a merge target");

        uint8 fromTier = cfg.mergeFromTier;
        uint256 needed = cfg.mergeRequires;

        require(balanceOf(msg.sender, fromTier) >= needed, "insufficient cards");

        // Transfer source cards to treasury (not burned)
        safeTransferFrom(msg.sender, treasury, fromTier, needed, "");

        // Mint target card
        _mint(msg.sender, targetTier, 1, "");

        // Award merge points
        uint256 mergePoints = cfg.mergePoints;
        _addPoints(msg.sender, mergePoints, "merge");

        // Distribute referral points (no USDC for merge)
        _distributeReferralPoints(msg.sender, mergePoints);

        emit Merged(msg.sender, fromTier, targetTier, mergePoints);
    }

    // ─── Staking ──────────────────────────────────────────────────────────────
    function stake(uint8 tokenId, uint256 amount) external nonReentrant {
        require(tokenId >= GOLD && tokenId <= BLACK, "invalid tier");
        require(balanceOf(msg.sender, tokenId) >= amount, "insufficient balance");

        // Transfer NFTs to this contract (lock)
        safeTransferFrom(msg.sender, address(this), tokenId, amount, "");
        stakedBalance[msg.sender][tokenId] += amount;
        if (lastSettleAt[msg.sender] == 0) {
            lastSettleAt[msg.sender] = block.timestamp;
        }

        emit Staked(msg.sender, tokenId, amount);
    }

    function unstake(uint8 tokenId, uint256 amount) external nonReentrant {
        require(stakedBalance[msg.sender][tokenId] >= amount, "insufficient staked");

        stakedBalance[msg.sender][tokenId] -= amount;
        // Return NFTs
        _safeTransferFrom(address(this), msg.sender, tokenId, amount, "");

        emit Unstaked(msg.sender, tokenId, amount);
    }

    // ─── On-chain Query Helpers ───────────────────────────────────────────────
    /// @notice Returns points balance (same as public mapping, convenience alias)
    function getPoints(address wallet) external view returns (uint256) {
        return points[wallet];
    }

    /// @notice Returns wallet's free (unstaked) holdings for all 4 tiers
    function getHoldings(address wallet) external view returns (
        uint256 gold, uint256 platinum, uint256 diamond, uint256 black
    ) {
        gold     = balanceOf(wallet, GOLD);
        platinum = balanceOf(wallet, PLATINUM);
        diamond  = balanceOf(wallet, DIAMOND);
        black    = balanceOf(wallet, BLACK);
    }

    /// @notice Returns wallet's staked amounts for all 4 tiers
    function getStaked(address wallet) external view returns (
        uint256 gold, uint256 platinum, uint256 diamond, uint256 black
    ) {
        gold     = stakedBalance[wallet][GOLD];
        platinum = stakedBalance[wallet][PLATINUM];
        diamond  = stakedBalance[wallet][DIAMOND];
        black    = stakedBalance[wallet][BLACK];
    }

    /// @notice Full user snapshot in one call (for BE cache)
    function getUserState(address wallet) external view returns (
        uint256 pts,
        uint256 freeGold, uint256 freePlatinum, uint256 freeDiamond, uint256 freeBlack,
        uint256 stakedGold, uint256 stakedPlatinum, uint256 stakedDiamond, uint256 stakedBlack,
        address referrer,
        uint8   role
    ) {
        pts           = points[wallet];
        freeGold      = balanceOf(wallet, GOLD);
        freePlatinum  = balanceOf(wallet, PLATINUM);
        freeDiamond   = balanceOf(wallet, DIAMOND);
        freeBlack     = balanceOf(wallet, BLACK);
        stakedGold    = stakedBalance[wallet][GOLD];
        stakedPlatinum= stakedBalance[wallet][PLATINUM];
        stakedDiamond = stakedBalance[wallet][DIAMOND];
        stakedBlack   = stakedBalance[wallet][BLACK];
        referrer      = referrerOf[wallet];
        role          = roleOf[wallet];
    }

    /// @notice Compute daily interest (USDC, 6 decimals) for a staker
    function dailyInterest(address wallet) external view returns (uint256 totalUsdc) {
        for (uint8 t = GOLD; t <= BLACK; t++) {
            uint256 amt = stakedBalance[wallet][t];
            if (amt == 0) continue;
            TierConfig storage cfg = tierConfigs[t];
            // dailyInterest = principal * amount * apyBps / 10000 / 365
            totalUsdc += (cfg.principalUsdc * amt * cfg.apyBps) / 10_000 / 365;
        }
    }

    // ─── Admin ────────────────────────────────────────────────────────────────
    function setTierConfig(
        uint8 tokenId,
        uint256 mintPrice,
        uint256 mintPoints,
        uint256 mergePoints,
        uint8   mergeRequires,
        uint8   mergeFromTier,
        uint256 principalUsdc,
        uint256 apyBps
    ) external onlyOwner {
        tierConfigs[tokenId] = TierConfig(mintPrice, mintPoints, mergePoints, mergeRequires, mergeFromTier, principalUsdc, apyBps);
        emit TierConfigUpdated(tokenId);
    }

    function setTreasury(address _treasury) external onlyOwner {
        treasury = _treasury;
        emit TreasuryUpdated(_treasury);
    }

    function setReferralRates(
        uint256 _direct,
        uint256 _indirect,
        uint256 _nodeBoost,
        uint256 _superNode,
        uint256 _generalAgent
    ) external onlyOwner {
        directReferralBps   = _direct;
        indirectReferralBps = _indirect;
        nodeBoostBps        = _nodeBoost;
        superNodeBps        = _superNode;
        generalAgentBps     = _generalAgent;
    }

    /// @notice Withdraw accumulated USDC/USDT (net of referral payouts) to treasury
    function withdrawToTreasury(address token, uint256 amount) external onlyOwner {
        require(IERC20(token).transfer(treasury, amount), "transfer failed");
    }

    // ─── ERC-1155 Receiver (for stake lockup) ────────────────────────────────
    function onERC1155Received(address, address, uint256, uint256, bytes calldata)
        external pure returns (bytes4)
    {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external pure returns (bytes4)
    {
        return this.onERC1155BatchReceived.selector;
    }

    // ─── Internal ─────────────────────────────────────────────────────────────
    function _addPoints(address wallet, uint256 amount, string memory reason) internal {
        points[wallet] += amount;
        emit PointsAwarded(wallet, amount, reason);
    }

    /**
     * @dev Walk up the referral tree and distribute USDC + points on mint.
     *
     * Reward logic:
     *   Level-1 referrer:
     *     - Direct referral:  10% USDC + 10% points
     *     - If Node+:         additional 5% USDC + 5% points (node boost)
     *   Level-2 referrer:
     *     - Indirect referral: 5% USDC + 5% points
     *     - (No node boost — same-level rule)
     *   First SuperNode ancestor:   5% USDC + 5% points
     *   First GeneralAgent ancestor: 5% USDC + 5% points
     */
    function _distributeReferralRewards(
        address buyer,
        uint256 totalUsdc,
        uint256 buyerPoints,
        IERC20 token
    ) internal {
        address lvl1 = referrerOf[buyer];
        if (lvl1 == address(0)) return; // no referrer → treasury keeps

        // Level-1: direct referral 10%
        uint256 usdcL1 = (totalUsdc * directReferralBps) / 10_000;
        uint256 ptsL1  = (buyerPoints * directReferralBps) / 10_000;
        _payReferral(lvl1, buyer, usdcL1, ptsL1, token, "direct");

        // Level-1 node boost if Node or above
        if (roleOf[lvl1] >= ROLE_NODE) {
            uint256 usdcBoost = (totalUsdc * nodeBoostBps) / 10_000;
            uint256 ptsBoost  = (buyerPoints * nodeBoostBps) / 10_000;
            _payReferral(lvl1, buyer, usdcBoost, ptsBoost, token, "node_boost");
        }

        address lvl2 = referrerOf[lvl1];
        if (lvl2 == address(0)) return;

        // Level-2: indirect referral 5%
        uint256 usdcL2 = (totalUsdc * indirectReferralBps) / 10_000;
        uint256 ptsL2  = (buyerPoints * indirectReferralBps) / 10_000;
        _payReferral(lvl2, buyer, usdcL2, ptsL2, token, "indirect");

        // Walk up for SuperNode and GeneralAgent (first occurrence each)
        bool superNodePaid   = false;
        bool generalAgentPaid = false;
        address cur = referrerOf[lvl2];

        while (cur != address(0)) {
            uint8 r = roleOf[cur];

            if (!superNodePaid && r >= ROLE_SUPERNODE) {
                uint256 usdcSN = (totalUsdc * superNodeBps) / 10_000;
                uint256 ptsSN  = (buyerPoints * superNodeBps) / 10_000;
                _payReferral(cur, buyer, usdcSN, ptsSN, token, "supernode");
                superNodePaid = true;
            }

            if (!generalAgentPaid && r >= ROLE_GENERAL_AGENT) {
                uint256 usdcGA = (totalUsdc * generalAgentBps) / 10_000;
                uint256 ptsGA  = (buyerPoints * generalAgentBps) / 10_000;
                _payReferral(cur, buyer, usdcGA, ptsGA, token, "general_agent");
                generalAgentPaid = true;
            }

            if (superNodePaid && generalAgentPaid) break;
            cur = referrerOf[cur];
        }
    }

    /// @dev Distribute merge points up the referral tree (no USDC for merges)
    function _distributeReferralPoints(address merger, uint256 mergePoints) internal {
        address lvl1 = referrerOf[merger];
        if (lvl1 == address(0)) return;

        // Direct 10%
        uint256 ptsL1 = (mergePoints * directReferralBps) / 10_000;
        _addPoints(lvl1, ptsL1, "merge_direct");

        // Node boost 5%
        if (roleOf[lvl1] >= ROLE_NODE) {
            _addPoints(lvl1, (mergePoints * nodeBoostBps) / 10_000, "merge_node_boost");
        }

        address lvl2 = referrerOf[lvl1];
        if (lvl2 == address(0)) return;

        // Indirect 5%
        _addPoints(lvl2, (mergePoints * indirectReferralBps) / 10_000, "merge_indirect");

        bool superNodePaid    = false;
        bool generalAgentPaid = false;
        address cur = referrerOf[lvl2];

        while (cur != address(0)) {
            uint8 r = roleOf[cur];
            if (!superNodePaid && r >= ROLE_SUPERNODE) {
                _addPoints(cur, (mergePoints * superNodeBps) / 10_000, "merge_supernode");
                superNodePaid = true;
            }
            if (!generalAgentPaid && r >= ROLE_GENERAL_AGENT) {
                _addPoints(cur, (mergePoints * generalAgentBps) / 10_000, "merge_general_agent");
                generalAgentPaid = true;
            }
            if (superNodePaid && generalAgentPaid) break;
            cur = referrerOf[cur];
        }
    }

    function _payReferral(
        address recipient,
        address buyer,
        uint256 usdcAmt,
        uint256 ptsAmt,
        IERC20 token,
        string memory reason
    ) internal {
        if (usdcAmt > 0) {
            token.transfer(recipient, usdcAmt);
        }
        if (ptsAmt > 0) {
            _addPoints(recipient, ptsAmt, reason);
        }
        emit ReferralReward(recipient, buyer, usdcAmt, ptsAmt, reason);
    }
}
