// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title Upgrade
 * @notice UUPS upgrade script for BiliquidVIPCard.
 *
 * ── Usage ────────────────────────────────────────────────────────────────────
 *
 *   # Check storage layout safety FIRST (requires slither or foundry-upgrades)
 *   forge build --sizes
 *
 *   # Dry-run (no broadcast)
 *   forge script script/Upgrade.s.sol \
 *     --rpc-url $BASE_SEPOLIA_RPC_URL \
 *     --private-key $PRIVATE_KEY \
 *     -vvv
 *
 *   # Broadcast (real upgrade)
 *   forge script script/Upgrade.s.sol \
 *     --rpc-url $BASE_SEPOLIA_RPC_URL \
 *     --private-key $PRIVATE_KEY \
 *     --broadcast -vvv
 *
 * ── Storage Layout Safety Rules ──────────────────────────────────────────────
 *   Before upgrading, verify there are NO breaking changes to existing storage:
 *
 *   ✅ SAFE:
 *     - Appending new state variables at the end of the contract
 *     - Adding new functions
 *     - Changing function logic (without touching storage layout)
 *     - Adding fields to the END of a struct that is only used in NEW arrays
 *       (existing records read wrong if fields are inserted in the middle)
 *
 *   ❌ UNSAFE (requires redeploy instead):
 *     - Inserting/removing/reordering existing state variables
 *     - Inserting fields IN THE MIDDLE of an existing struct
 *       (e.g. adding isFlexible before stakedAt in StakeRecord corrupts old records)
 *     - Changing the type of an existing variable
 *     - Changing inheritance order
 *
 *   ── Quick check (run before Upgrade.s.sol) ───────────────────────────────
 *   Compare `forge inspect BiliquidVIPCard storageLayout` output
 *   between the current deployed implementation and the new one.
 *   If any existing slot changes index → STOP, redeploy instead.
 *
 * ── Environment variables ─────────────────────────────────────────────────────
 *   PROXY_ADDRESS   - The ERC1967 proxy address (required)
 *   PRIVATE_KEY     - Owner's private key (required)
 *   CALL_DATA       - Optional calldata for upgradeToAndCall (default: empty)
 */

import "forge-std/Script.sol";
import "../src/BiliquidVIPCard.sol";

interface IUUPSProxy {
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
    function implementation() external view returns (address);
}

contract Upgrade is Script {

    function run() external {
        address proxy = vm.envOr(
            "PROXY_ADDRESS",
            address(0xfE73547Ef451d9b6CeD7e0FBf400F10a2C5EAE17)  // BiliquidVIPCard proxy on Base Sepolia
        );
        bytes memory callData = vm.envOr("CALL_DATA", bytes(""));

        require(proxy != address(0), "PROXY_ADDRESS not set");

        // ── Pre-upgrade checks ─────────────────────────────────────────────────
        console.log("=== Pre-Upgrade Check ===");
        console.log("Proxy       :", proxy);

        // Read current implementation via ERC1967 slot
        bytes32 implSlot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        bytes32 slotVal  = vm.load(proxy, implSlot);
        address oldImpl  = address(uint160(uint256(slotVal)));
        console.log("Old impl    :", oldImpl);

        vm.startBroadcast();

        // ── Deploy new implementation ─────────────────────────────────────────
        BiliquidVIPCard newImpl = new BiliquidVIPCard();
        console.log("New impl    :", address(newImpl));

        // ── Upgrade proxy ─────────────────────────────────────────────────────
        // upgradeToAndCall is payable so we can pass init calldata for re-init.
        // For a plain upgrade with no re-init, pass empty bytes.
        IUUPSProxy(proxy).upgradeToAndCall(address(newImpl), callData);

        vm.stopBroadcast();

        // ── Post-upgrade verification ──────────────────────────────────────────
        bytes32 newSlotVal  = vm.load(proxy, implSlot);
        address confirmedImpl = address(uint160(uint256(newSlotVal)));
        console.log("=== Post-Upgrade Check ===");
        console.log("Confirmed impl:", confirmedImpl);
        require(confirmedImpl == address(newImpl), "Upgrade failed: impl slot not updated");
        console.log("Upgrade SUCCESS");
    }
}
