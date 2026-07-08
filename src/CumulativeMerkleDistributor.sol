// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title  CumulativeMerkleDistributor
 * @notice Cumulative Merkle drop for off-chain referral commissions (USDC).
 *
 *  Design (matches 1inch CumulativeMerkleDrop, proof-compatible with the
 *  merkletreejs sorted-pair layout used by the backend generator):
 *
 *    leaf   = keccak256(abi.encodePacked(account, cumulativeAmount))
 *    parent = keccak256(sorted(a, b))            // commutative / sorted pairs
 *
 *  Each published root carries the CUMULATIVE amount owed to each account since
 *  genesis. On claim, the contract pays only the delta over what the account has
 *  already claimed (`cumulativeClaimed`). Re-publishing a larger root lets a user
 *  claim the increment; the contract never double-pays.
 *
 *  Owner (backend admin wallet) publishes new roots via setMerkleRoot() and funds
 *  the contract by transferring USDC directly to this address. adminWithdraw()
 *  rescues stranded tokens.
 */

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract CumulativeMerkleDistributor is Ownable {
    address public immutable token;

    bytes32 public merkleRoot;
    mapping(address => uint256) public cumulativeClaimed;

    event MerkelRootUpdated(bytes32 oldMerkleRoot, bytes32 newMerkleRoot);
    event Claimed(address indexed account, uint256 amount);

    error MerkleRootWasUpdated();
    error InvalidProof();
    error NothingToClaim();
    error TransferFailed();

    constructor(address token_) Ownable(msg.sender) {
        token = token_;
    }

    /// @notice Publish a new cumulative Merkle root.
    function setMerkleRoot(bytes32 merkleRoot_) external onlyOwner {
        emit MerkelRootUpdated(merkleRoot, merkleRoot_);
        merkleRoot = merkleRoot_;
    }

    /// @notice Claim the delta between `cumulativeAmount` (from the current root)
    ///         and what `account` has already claimed. Anyone may submit on behalf
    ///         of `account`; funds always go to `account`.
    /// @param  expectedMerkleRoot guards against a root update racing the claim tx.
    function claim(
        address account,
        uint256 cumulativeAmount,
        bytes32 expectedMerkleRoot,
        bytes32[] calldata merkleProof
    ) external {
        if (merkleRoot != expectedMerkleRoot) revert MerkleRootWasUpdated();

        bytes32 leaf = keccak256(abi.encodePacked(account, cumulativeAmount));
        if (!MerkleProof.verify(merkleProof, expectedMerkleRoot, leaf)) revert InvalidProof();

        uint256 preclaimed = cumulativeClaimed[account];
        if (preclaimed >= cumulativeAmount) revert NothingToClaim();
        cumulativeClaimed[account] = cumulativeAmount;

        uint256 amount = cumulativeAmount - preclaimed;
        if (!IERC20(token).transfer(account, amount)) revert TransferFailed();
        emit Claimed(account, amount);
    }

    /// @notice Rescue tokens sent to this contract (owner only).
    function adminWithdraw(address tokenAddress, uint256 amount) external onlyOwner {
        if (!IERC20(tokenAddress).transfer(msg.sender, amount)) revert TransferFailed();
    }
}
