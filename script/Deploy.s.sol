// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/BiliquidVIPCard.sol";
import "../src/MockERC20.sol";

/**
 * Local dev deploy (anvil):
 *   forge script script/Deploy.s.sol \
 *     --rpc-url http://127.0.0.1:8545 \
 *     --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
 *     --broadcast -vvv
 *
 * Base Sepolia deploy:
 *   forge script script/Deploy.s.sol \
 *     --rpc-url base_sepolia \
 *     --private-key $DEPLOYER_PRIVATE_KEY \
 *     --broadcast --verify -vvv
 *
 * After deploy: copy printed addresses into biliquid-be/.env and biliquid-fe/.env
 */
contract Deploy is Script {
    function run() external {
        address deployer  = vm.envOr("DEPLOYER_ADDRESS",  address(0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266)); // anvil[0]
        address treasury  = vm.envOr("TREASURY_ADDRESS",  address(0x70997970C51812dc3A010C7d01b50e0d17dc79C8)); // anvil[1]
        address usdcAddr  = vm.envOr("USDC_ADDRESS",      address(0));
        address usdtAddr  = vm.envOr("USDT_ADDRESS",      address(0));

        vm.startBroadcast();

        // Deploy mock tokens if addresses not provided (local dev)
        if (usdcAddr == address(0)) {
            MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
            usdcAddr = address(usdc);
            console.log("MockUSDC deployed:", usdcAddr);

            // Mint 10,000 USDC to deployer and anvil accounts for testing
            usdc.mint(deployer, 10_000_000_000);  // 10,000 USDC
            for (uint256 i = 2; i < 10; i++) {
                // Mint to first 8 extra anvil accounts (indices 2-9)
                address acct = vm.addr(i + 1);
                usdc.mint(acct, 10_000_000_000);
            }
        }

        if (usdtAddr == address(0)) {
            MockERC20 usdt = new MockERC20("Tether", "USDT", 6);
            usdtAddr = address(usdt);
            console.log("MockUSDT deployed:", usdtAddr);
        }

        // Deploy main contract
        BiliquidVIPCard card = new BiliquidVIPCard(usdcAddr, usdtAddr, treasury);
        console.log("BiliquidVIPCard deployed:", address(card));

        vm.stopBroadcast();

        // Print .env snippet for easy copy-paste
        console.log("--- Copy into biliquid-be/.env and biliquid-fe/.env ---");
        console.log("BILIQUID_VIP_CARD_ADDRESS=%s", address(card));
        console.log("USDC_ADDRESS=%s", usdcAddr);
        console.log("USDT_ADDRESS=%s", usdtAddr);
        console.log("TREASURY_ADDRESS=%s", treasury);
        console.log("-------------------------------------------------------");
    }
}
