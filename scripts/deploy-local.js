/**
 * Local deploy script — no forge-std / GitHub needed
 *
 * Prerequisites:
 *   1. anvil running:  `anvil`
 *   2. contracts compiled: `npm run compile`
 *
 * Usage:
 *   npm run deploy:local
 *
 * Output: prints contract addresses to paste into biliquid-be/.env and biliquid-fe/.env
 */
"use strict";

const { ethers } = require("ethers");
const fs         = require("fs");
const path       = require("path");

const RPC_URL     = process.env.RPC_URL     || "http://127.0.0.1:8545";
const PRIVATE_KEY = process.env.PRIVATE_KEY || "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"; // anvil[0]
const TREASURY    = process.env.TREASURY    || "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"; // anvil[1]

const artifactsPath = path.join(__dirname, "../test/artifacts.json");
if (!fs.existsSync(artifactsPath)) {
  console.error("artifacts.json not found. Run: npm run compile");
  process.exit(1);
}
const artifacts = JSON.parse(fs.readFileSync(artifactsPath, "utf8"));

// Always fetch the latest pending nonce before each deploy to avoid
// stale-nonce errors when running on an anvil that already has txs.
async function deployContract(provider, deployer, name, args = []) {
  const nonce = await provider.getTransactionCount(deployer.address, "pending");
  const { abi, bytecode } = artifacts[name];
  const factory  = new ethers.ContractFactory(abi, bytecode, deployer);
  const contract = await factory.deploy(...args, { nonce });
  await contract.waitForDeployment();
  return contract;
}

async function main() {
  const provider = new ethers.JsonRpcProvider(RPC_URL);
  const deployer = new ethers.Wallet(PRIVATE_KEY, provider);

  console.log(`\nDeployer : ${deployer.address}`);
  console.log(`Treasury : ${TREASURY}`);
  console.log(`RPC      : ${RPC_URL}\n`);

  // ── Deploy tokens ──────────────────────────────────────────────────────────
  const usdc = await deployContract(provider, deployer, "MockERC20", ["USD Coin", "USDC", 6]);
  console.log(`MockUSDC  deployed: ${await usdc.getAddress()}`);

  const usdt = await deployContract(provider, deployer, "MockERC20", ["Tether", "USDT", 6]);
  console.log(`MockUSDT  deployed: ${await usdt.getAddress()}`);

  // ── Deploy VIP card ────────────────────────────────────────────────────────
  const card = await deployContract(provider, deployer, "BiliquidVIPCard", [
    await usdc.getAddress(),
    await usdt.getAddress(),
    TREASURY,
  ]);
  console.log(`VIPCard   deployed: ${await card.getAddress()}`);

  // ── Mint 10,000 USDC to anvil test accounts [1..8] ────────────────────────
  const TEST_AMOUNT = ethers.parseUnits("10000", 6);
  const anvil_keys = [
    "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d", // [1]
    "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ea870594801966fce6c7d06", // [2]
    "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6", // [3]
    "0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926b", // [4]
    "0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba", // [5]
    "0x92db14e403b83dfe3df233f83dfa3a0d7096f21ca9b0d6d6b8d88b2b4ec1564e", // [6]
    "0x4bbbf85ce3377467afe5d46f804f221813b2bb87f24d81f60f1fcdbf7cbf4356", // [7]
    "0xdbda1821b80551c9d65939329250132c444b7a4f6f6f6d15b0f03d5f9f5fcf4", // [8]
  ];

  for (const pk of anvil_keys) {
    const acct = new ethers.Wallet(pk);
    const nonce = await provider.getTransactionCount(deployer.address, "pending");
    await (await usdc.connect(deployer).mint(acct.address, TEST_AMOUNT, { nonce })).wait();
  }
  console.log(`Minted 10,000 USDC to 8 test accounts\n`);

  // ── Print .env snippet ─────────────────────────────────────────────────────
  const sep = "-".repeat(54);
  console.log(sep);
  console.log("Copy into biliquid-be/.env AND biliquid-fe/.env:");
  console.log(sep);
  console.log(`BILIQUID_VIP_CARD_ADDRESS=${await card.getAddress()}`);
  console.log(`USDC_ADDRESS=${await usdc.getAddress()}`);
  console.log(`USDT_ADDRESS=${await usdt.getAddress()}`);
  console.log(`TREASURY_ADDRESS=${TREASURY}`);
  console.log(sep + "\n");
}

main().catch(err => {
  console.error("Deploy failed:", err.message);
  process.exit(1);
});
