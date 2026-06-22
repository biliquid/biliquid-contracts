/**
 * Compile contracts using bundled solc (no network needed)
 * Output: test/artifacts.json  (used by e2e tests + deploy-local.js)
 *
 * Usage: node scripts/compile.js
 */
"use strict";

const solc = require("solc");
const fs   = require("fs");
const path = require("path");

const srcDir = path.join(__dirname, "../src");
const out    = path.join(__dirname, "../test/artifacts.json");

const sources = {};
for (const f of fs.readdirSync(srcDir)) {
  if (f.endsWith(".sol")) {
    sources[f] = { content: fs.readFileSync(path.join(srcDir, f), "utf8") };
  }
}

const input = {
  language: "Solidity",
  sources,
  settings: {
    optimizer: { enabled: true, runs: 200 },
    outputSelection: { "*": { "*": ["abi", "evm.bytecode"] } },
  },
};

const result = JSON.parse(solc.compile(JSON.stringify(input)));
const errors = (result.errors || []).filter(e => e.severity === "error");

if (errors.length) {
  for (const e of errors) console.error(e.formattedMessage);
  process.exit(1);
}

const artifacts = {};
for (const [, contracts] of Object.entries(result.contracts || {})) {
  for (const [name, data] of Object.entries(contracts)) {
    artifacts[name] = {
      abi:      data.abi,
      bytecode: "0x" + data.evm.bytecode.object,
    };
  }
}

fs.writeFileSync(out, JSON.stringify(artifacts, null, 2));
console.log("Compiled:", Object.keys(artifacts).join(", "));
console.log("Output  :", out);
