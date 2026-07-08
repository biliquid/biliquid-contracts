// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/CumulativeMerkleDistributor.sol";

/**
 * Deploy CumulativeMerkleDistributor for off-chain referral commissions.
 *
 *   forge script script/DeployDistributor.s.sol \
 *     --rpc-url base_sepolia --private-key $PRIVATE_KEY --broadcast -vvv
 *
 * Env:
 *   USDC_ADDRESS - the commission payout token (required)
 */
contract DeployDistributor is Script {
    function run() external {
        address usdc = vm.envAddress("USDC_ADDRESS");
        require(usdc != address(0), "USDC_ADDRESS not set");

        vm.startBroadcast();
        CumulativeMerkleDistributor dist = new CumulativeMerkleDistributor(usdc);
        vm.stopBroadcast();

        console.log("=== CumulativeMerkleDistributor deployed ===");
        console.log("distributor:", address(dist));
        console.log("token (USDC):", usdc);
        console.log("owner:", dist.owner());
        console.log("--- Copy into biliquid-be/.env and biliquid-fe/.env ---");
        console.log("MERKLE_DISTRIBUTOR_ADDRESS=%s", address(dist));
        console.log("VITE_MERKLE_DISTRIBUTOR_ADDRESS=%s", address(dist));
    }
}
