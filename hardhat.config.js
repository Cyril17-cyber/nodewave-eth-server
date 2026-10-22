require("@nomicfoundation/hardhat-toolbox");
const { vars } = require("hardhat/config");
require("dotenv").config();

// Secrets live in Hardhat's encrypted-at-rest vars store, never in this file:
//   npx hardhat vars set INFURA_API_KEY
//   npx hardhat vars set SEPOLIA_PRIVATE_KEY
const networks = {
  hardhat: {
    // chainId 1337 matches the localhost address in nodewave-ui's contractConfig.js
    chainId: 1337,
    ...(process.env.MNEMONIC && { accounts: { mnemonic: process.env.MNEMONIC } }),
  },
};

if (vars.has("INFURA_API_KEY") && vars.has("SEPOLIA_PRIVATE_KEY")) {
  networks.sepolia = {
    url: `https://sepolia.infura.io/v3/${vars.get("INFURA_API_KEY")}`,
    accounts: [vars.get("SEPOLIA_PRIVATE_KEY")],
  };
}

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: {
    version: "0.8.24",
    settings: { optimizer: { enabled: true, runs: 200 } },
  },
  networks,
};
