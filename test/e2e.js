/**
 * Biliquid E2E Test — uses pre-compiled artifacts.json + Hardhat in-process EVM
 * No compiler download needed.
 *
 * Scenario (per product spec):
 *   A = GeneralAgent
 *   B = SuperNode  (referrer: A)
 *   C = SuperNode  (referrer: B)
 *   D = Node       (referrer: C)
 *   E = Node       (referrer: D)
 *   F = User       (referrer: E)
 *
 *   1. F mints 1 Gold (30 USDC) → verify pts + USDC payouts
 *   2. F mints 3 more Gold → verify 4 total
 *   3. F merges 4 Gold → 1 Platinum → verify merge pts
 *   4. F stakes Platinum → verify dailyInterest
 *   5. getUserState(F) → single RPC call
 *   6. Final leaderboard + USDC ledger
 */
"use strict";

process.env.HARDHAT_NETWORK = "hardhat";

const hre     = require("./node_modules/hardhat/internal/lib/hardhat-lib");
const ethers  = require("./node_modules/ethers");
const fs      = require("fs");

const artifacts = JSON.parse(fs.readFileSync("./artifacts.json", "utf8"));

// ── ANSI helpers ──────────────────────────────────────────────────────────────
const G   = s => `\x1b[32m${s}\x1b[0m`;
const R   = s => `\x1b[31m${s}\x1b[0m`;
const BL  = s => `\x1b[34m${s}\x1b[0m`;
const Y   = s => `\x1b[33m${s}\x1b[0m`;
const DIM = s => `\x1b[90m${s}\x1b[0m`;

let passed = 0, failed = 0;

function assert(cond, label, got, expected) {
  if (cond) { console.log(`  ${G("✓")} ${label}`); passed++; }
  else       { console.log(`  ${R("✗")} ${label}  got=${got}  expected=${expected}`); failed++; }
}
function section(t) {
  console.log(`\n${BL("═".repeat(62))}`);
  console.log(`${BL("  " + t)}`);
  console.log(`${BL("═".repeat(62))}`);
}
function fmt6(n) { return (Number(BigInt(n)) / 1e6).toFixed(2) + " USDC"; }

// ── Ethers provider wrapping the Hardhat in-process EVM ──────────────────────
const provider = new ethers.BrowserProvider(hre.network.provider);

async function getSigner(idx) {
  const accounts = await hre.network.provider.send("eth_accounts", []);
  return new ethers.JsonRpcSigner(provider, accounts[idx]);
}

async function deploy(signer, name, args = []) {
  const { abi, bytecode } = artifacts[name];
  const factory = new ethers.ContractFactory(abi, bytecode, signer);
  const contract = await factory.deploy(...args);
  await contract.waitForDeployment();
  return contract;
}

// ── Main ──────────────────────────────────────────────────────────────────────
async function main() {
  const [deployer, treasury, A, B, C, D, E, F] = await Promise.all(
    [0,1,2,3,4,5,6,7].map(getSigner)
  );

  console.log(Y("\n🚀  Biliquid E2E Test — Hardhat In-Process EVM\n"));
  const names = { [A.address]:"A(GA)", [B.address]:"B(SN)", [C.address]:"C(SN)",
                  [D.address]:"D(N)",  [E.address]:"E(N)",  [F.address]:"F(User)" };
  for (const [k,v] of Object.entries(names)) console.log(DIM(`  ${v.padEnd(10)}: ${k}`));

  // ── Deploy ──────────────────────────────────────────────────────────────────
  section("1. DEPLOY");

  const usdc = await deploy(deployer, "MockERC20", ["USD Coin","USDC",6]);
  const usdt = await deploy(deployer, "MockERC20", ["Tether","USDT",6]);
  const card = await deploy(deployer, "BiliquidVIPCard", [
    await usdc.getAddress(), await usdt.getAddress(), treasury.address
  ]);

  console.log(`  ${G("✓")} USDC   : ${await usdc.getAddress()}`);
  console.log(`  ${G("✓")} USDT   : ${await usdt.getAddress()}`);
  console.log(`  ${G("✓")} VIPCard: ${await card.getAddress()}`);

  // ── Roles ────────────────────────────────────────────────────────────────────
  section("2. ROLES & REFERRAL TREE");

  await (await card.connect(deployer).setRole(A.address, 3)).wait(); // GeneralAgent
  await (await card.connect(deployer).setRole(B.address, 2)).wait(); // SuperNode
  await (await card.connect(deployer).setRole(C.address, 2)).wait(); // SuperNode
  await (await card.connect(deployer).setRole(D.address, 1)).wait(); // Node
  await (await card.connect(deployer).setRole(E.address, 1)).wait(); // Node

  await (await card.connect(B).register(A.address)).wait();
  await (await card.connect(C).register(B.address)).wait();
  await (await card.connect(D).register(C.address)).wait();
  await (await card.connect(E).register(D.address)).wait();
  await (await card.connect(F).register(E.address)).wait();

  assert(await card.referrerOf(F.address) === E.address, "F.referrerOf = E");
  assert(await card.referrerOf(E.address) === D.address, "E.referrerOf = D");
  assert(await card.referrerOf(D.address) === C.address, "D.referrerOf = C");
  assert(await card.referrerOf(C.address) === B.address, "C.referrerOf = B");
  assert(await card.referrerOf(B.address) === A.address, "B.referrerOf = A");

  // ── Anti-cycle checks ──────────────────────────────────────────────────────
  // A trying to register E as referrer would create A→...→F→E→D→C→B→A cycle
  let caught = false;
  try { await card.connect(A).register(E.address); }
  catch(e) { caught = e.message.includes("cyclic referral") || e.message.includes("already registered"); }
  // A has no referrer yet, so "already registered" won't fire — it must be "cyclic referral"
  assert(caught, "cycle A→E rejected (would create A→B→C→D→E→...→A)");

  // Self-refer rejected
  let caughtSelf = false;
  try { await card.connect(deployer).register(deployer.address); }
  catch(e) { caughtSelf = e.message.includes("self-refer"); }
  assert(caughtSelf, "self-referral rejected");

  // Zero address rejected
  let caughtZero = false;
  try { await card.connect(deployer).register(ethers.ZeroAddress); }
  catch(e) { caughtZero = e.message.includes("zero referrer"); }
  assert(caughtZero, "zero-address referrer rejected");
  assert(BigInt(await card.roleOf(A.address)) === 3n, "A.role = GeneralAgent");
  assert(BigInt(await card.roleOf(E.address)) === 1n, "E.role = Node");
  assert(BigInt(await card.roleOf(F.address)) === 0n, "F.role = User");

  // Fund F
  await usdc.mint(F.address, 1_200_000_000n);
  await (await usdc.connect(F).approve(await card.getAddress(), ethers.MaxUint256)).wait();
  console.log(`  ${G("✓")} F funded 1200 USDC + approved VIPCard`);

  // ── Mint 1 Gold ──────────────────────────────────────────────────────────────
  section("3. F MINTS 1 GOLD  (30 USDC)");

  const wallets = [["A",A],["B",B],["C",C],["D",D],["E",E],["F",F]];
  const snapAll = async () => {
    const out = {};
    for (const [k,w] of wallets) {
      out[k] = {
        pts:  BigInt(await card.points(w.address)),
        usdc: BigInt(await usdc.balanceOf(w.address)),
        gold: BigInt(await card.balanceOf(w.address, 1)),
        plat: BigInt(await card.balanceOf(w.address, 2)),
      };
    }
    out.contract = { usdc: BigInt(await usdc.balanceOf(await card.getAddress())) };
    return out;
  };

  const b1 = await snapAll();
  await (await card.connect(F).mint(1n, false)).wait();
  const a1 = await snapAll();

  // Expected per spec after 1 Gold mint (30 USDC):
  //   F: +10000 pts, -30 USDC
  //   E: +1500 pts (+1000 direct + 500 nodeBoost), +4.5 USDC (+3 direct + 1.5 boost)
  //   D: +500 pts (indirect), +1.5 USDC
  //   C: +500 pts (superNode), +1.5 USDC
  //   B: 0 pts, 0 USDC  (same-level as C, both SuperNode → no reward)
  //   A: +500 pts (generalAgent), +1.5 USDC
  const exp1 = {
    F: { pts: 10_000n, usdc: -30_000_000n },
    E: { pts:  1_500n, usdc:   4_500_000n },
    D: { pts:    500n, usdc:   1_500_000n },
    C: { pts:    500n, usdc:   1_500_000n },
    B: { pts:      0n, usdc:           0n },
    A: { pts:    500n, usdc:   1_500_000n },
  };

  console.log(`\n  ${"Wallet".padEnd(7)} ${"Δ Points".padEnd(11)} ${"Exp Pts".padEnd(11)} ${"Δ USDC".padEnd(14)} ${"Exp USDC".padEnd(14)} Status`);
  console.log(`  ${"-".repeat(68)}`);
  let mint1Ok = true;
  for (const [k,] of wallets) {
    const dpts  = a1[k].pts  - b1[k].pts;
    const dusdc = a1[k].usdc - b1[k].usdc;
    const pok   = dpts  === exp1[k].pts;
    const uok   = dusdc === exp1[k].usdc;
    const ok    = pok && uok;
    if (!ok) mint1Ok = false;
    console.log(`  ${k.padEnd(7)} ${(ok?G:R)(dpts.toString().padEnd(11))} ${exp1[k].pts.toString().padEnd(11)} ${(ok?G:R)(fmt6(dusdc).padEnd(14))} ${fmt6(exp1[k].usdc).padEnd(14)} ${ok?G("✓"):R("✗")}`);
    assert(pok,  `${k} pts  (+1 mint)`, dpts,  exp1[k].pts);
    assert(uok,  `${k} usdc (+1 mint)`, fmt6(dusdc), fmt6(exp1[k].usdc));
  }
  assert(a1.F.gold === 1n, "F holds 1 Gold NFT");
  // Contract: received 30, paid out 4.5+1.5+1.5+0+1.5 = 9 → holds 21
  assert(a1.contract.usdc === 21_000_000n, "Contract holds 21 USDC net", fmt6(a1.contract.usdc), "21.00 USDC");

  // ── Mint 3 more Gold ─────────────────────────────────────────────────────────
  section("4. F MINTS 3 MORE GOLD  (90 USDC, total 4)");

  await (await card.connect(F).mint(3n, false)).wait();
  const goldBal = BigInt(await card.balanceOf(F.address, 1));
  const ptsBal  = BigInt(await card.points(F.address));
  assert(goldBal === 4n,      "F holds 4 Gold",       goldBal, 4n);
  assert(ptsBal  === 40_000n, "F has 40,000 pts",     ptsBal, 40_000n);

  // ── Merge 4 Gold → 1 Platinum ────────────────────────────────────────────────
  section("5. F MERGES 4 GOLD → 1 PLATINUM");

  const ptsBefore = {};
  for (const [k,w] of wallets) ptsBefore[k] = BigInt(await card.points(w.address));

  await (await card.connect(F).setApprovalForAll(await card.getAddress(), true)).wait();
  await (await card.connect(F).merge(2)).wait(); // PLATINUM = 2

  const ptsAfter = {};
  for (const [k,w] of wallets) ptsAfter[k] = BigInt(await card.points(w.address));

  // Expected merge pts (base = 4000):
  //   F: +4000
  //   E: +400 (direct 10%) +200 (nodeBoost 5%) = +600
  //   D: +200 (indirect 5%)
  //   C: +200 (superNode 5%)
  //   B: 0
  //   A: +200 (generalAgent 5%)
  const expMerge = { F:4_000n, E:600n, D:200n, C:200n, B:0n, A:200n };

  console.log(`\n  ${"Wallet".padEnd(7)} ${"Δ Pts".padEnd(10)} ${"Expected".padEnd(10)} Status`);
  console.log(`  ${"-".repeat(35)}`);
  for (const [k,] of wallets) {
    const d = ptsAfter[k] - ptsBefore[k];
    const ok = d === expMerge[k];
    console.log(`  ${k.padEnd(7)} ${(ok?G:R)(d.toString().padEnd(10))} ${expMerge[k].toString().padEnd(10)} ${ok?G("✓"):R("✗")}`);
    assert(ok, `${k} merge pts`, d, expMerge[k]);
  }

  assert(BigInt(await card.balanceOf(F.address, 1)) === 0n, "F.gold = 0 after merge");
  assert(BigInt(await card.balanceOf(F.address, 2)) === 1n, "F.platinum = 1 after merge");
  assert(BigInt(await card.balanceOf(treasury.address, 1)) === 4n, "Treasury holds 4 Gold (not burned)");

  // ── Stake & unstake ──────────────────────────────────────────────────────────
  section("6. F STAKES 1 PLATINUM → dailyInterest → UNSTAKE");

  await (await card.connect(F).stake(2, 1n)).wait();
  assert(BigInt(await card.balanceOf(F.address, 2))       === 0n, "F.freePlat = 0 after stake");
  assert(BigInt(await card.stakedBalance(F.address, 2))   === 1n, "F.stakedPlat = 1");

  // dailyInterest = principal * amount * apyBps / 10000 / 365
  // Platinum: principal=120_000_000, apyBps=1000
  // = 120_000_000 * 1 * 1000 / 10000 / 365 = 32876 (6 dec ≈ 0.032876 USDC/day)
  const expectedDI = (120_000_000n * 1n * 1000n) / 10_000n / 365n;
  const actualDI   = BigInt(await card.dailyInterest(F.address));
  assert(actualDI === expectedDI,
    `F.dailyInterest = ${expectedDI} (${(Number(expectedDI)/1e6).toFixed(6)} USDC/day)`,
    actualDI, expectedDI);

  await (await card.connect(F).unstake(2, 1n)).wait();
  assert(BigInt(await card.balanceOf(F.address, 2)) === 1n, "F.platinum restored after unstake");

  // ── getUserState snapshot ────────────────────────────────────────────────────
  section("7. getUserState(F) — single RPC call");

  const st = await card.getUserState(F.address);
  const [pts, fGold, fPlat, fDia, fBlack, sGold, sPlat, sDia, sBlack, referrer, role] = st;

  console.log(`\n  ${"Field".padEnd(22)} Value`);
  console.log(`  ${"-".repeat(45)}`);
  const stRows = [
    ["points",         pts],
    ["freeGold",       fGold],
    ["freePlatinum",   fPlat],
    ["freeDiamond",    fDia],
    ["freeBlack",      fBlack],
    ["stakedGold",     sGold],
    ["stakedPlatinum", sPlat],
    ["referrer",       referrer],
    ["role",           role],
  ];
  for (const [label, val] of stRows)
    console.log(`  ${label.padEnd(22)} ${val}`);

  // F total pts = 4×10000 (mints) + 4000 (merge) = 44000
  assert(BigInt(pts)  === 44_000n,    "F.pts = 44,000 total");
  assert(BigInt(fPlat) === 1n,        "F.freePlatinum = 1");
  assert(BigInt(fGold) === 0n,        "F.freeGold = 0");
  assert(referrer === E.address,      "F.referrer = E");
  assert(BigInt(role)  === 0n,        "F.role = User(0)");

  // ── Full leaderboard ─────────────────────────────────────────────────────────
  section("8. FULL LEADERBOARD");

  // Total expected points after 4 mints + 1 merge:
  //   Mints (×4): F+40000, E+6000, D+2000, C+2000, B+0, A+2000
  //   Merge:      F+4000,  E+600,  D+200,  C+200,  B+0, A+200
  const totalExpPts = { F:44_000n, E:6_600n, D:2_200n, C:2_200n, B:0n, A:2_200n };
  // Total expected USDC (×4 mints):
  const totalExpUsdc = { E:18_000_000n, D:6_000_000n, C:6_000_000n, B:0n, A:6_000_000n };
  const roleNames = ["User","Node","SuperNode","GeneralAgent"];

  console.log(`\n  ${"Wallet".padEnd(9)} ${"Role".padEnd(14)} ${"Points".padEnd(10)} ${"Exp Pts".padEnd(10)} ${"USDC".padEnd(11)} ${"Exp USDC".padEnd(11)} Status`);
  console.log(`  ${"-".repeat(72)}`);

  let allOk = true;
  for (const [k,w] of wallets) {
    const wState = await card.getUserState(w.address);
    const wPts   = BigInt(wState[0]);
    const wRole  = Number(wState[10]);
    const wUsdc  = BigInt(await usdc.balanceOf(w.address));
    const expPts = totalExpPts[k];
    const expU   = totalExpUsdc[k] ?? 0n;
    const ptsOk  = wPts  === expPts;
    const usdcOk = k === "F" ? true : wUsdc === expU;
    const ok     = ptsOk && usdcOk;
    if (!ok) allOk = false;
    const usdcDisplay = k === "F" ? DIM(("spent " + fmt6(120_000_000n)).padEnd(11)) : (usdcOk?G:R)(fmt6(wUsdc).padEnd(11));
    console.log(`  ${k.padEnd(9)} ${roleNames[wRole].padEnd(14)} ${(ptsOk?G:R)(wPts.toString().padEnd(10))} ${expPts.toString().padEnd(10)} ${usdcDisplay} ${fmt6(expU).padEnd(11)} ${ok?G("✓"):R("✗")}`);
    assert(ptsOk, `${k} total pts`,  wPts,  expPts);
    if (k !== "F") assert(usdcOk, `${k} total usdc`, fmt6(wUsdc), fmt6(expU));
  }

  // Contract should hold: 120 USDC paid - 36 USDC distributed = 84 USDC
  const contractFinalUsdc = BigInt(await usdc.balanceOf(await card.getAddress()));
  assert(contractFinalUsdc === 84_000_000n,
    "Contract holds 84 USDC (120 - 36 distributed)",
    fmt6(contractFinalUsdc), "84.00 USDC");

  // ── Results ──────────────────────────────────────────────────────────────────
  section("RESULTS");
  const total = passed + failed;
  console.log(`\n  ${passed === total ? G("ALL TESTS PASSED 🎉") : R("SOME TESTS FAILED ❌")}`);
  console.log(`  ${G(passed + " passed")}  ${failed > 0 ? R(failed + " failed") : DIM("0 failed")}  (${total} total)\n`);

  if (failed > 0) process.exit(1);
}

main().catch(err => {
  console.error(R("\nFatal: " + err.message));
  console.error(err.stack);
  process.exit(1);
});
