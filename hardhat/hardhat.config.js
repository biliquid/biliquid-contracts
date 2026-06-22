import "@nomicfoundation/hardhat-ethers";

export default {
  solidity: {
    version: "0.8.24",
    settings: { optimizer: { enabled: true, runs: 200 } }
  },
  paths: {
    sources:   "../src",      // reuse Foundry src/
    tests:     "./test-js",
    artifacts: "./artifacts",
    cache:     "./cache"
  },
  networks: {
    hardhat: { chainId: 31337 }
  }
};
