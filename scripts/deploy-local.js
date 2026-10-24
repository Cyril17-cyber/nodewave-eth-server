// Deploys NodeWave to the local Hardhat node and points the API and web app at it.
//   npm run node          (terminal 1, keep it running)
//   npm run deploy:local  (terminal 2)
// Writes CONTRACT_ADDRESS into ../server/.env and NEXT_PUBLIC_CONTRACT_ADDRESS (+ chain/RPC)
// into ../nodewave-ui/.env.local. Restart the API and web app afterwards.
const fs = require("fs");
const path = require("path");
const hre = require("hardhat");

const RPC_URL = "http://127.0.0.1:8545";

/** Sets KEY=value in an env file, replacing an existing line or appending one. */
function setEnv(file, values) {
  if (!fs.existsSync(file)) {
    console.warn(`  skipped ${path.relative(process.cwd(), file)} (not found)`);
    return;
  }
  let text = fs.readFileSync(file, "utf8");
  for (const [key, value] of Object.entries(values)) {
    const line = `${key}=${value}`;
    const pattern = new RegExp(`^${key}=.*$`, "m");
    text = pattern.test(text) ? text.replace(pattern, line) : `${text.trimEnd()}\n${line}\n`;
  }
  fs.writeFileSync(file, text);
  console.log(`  updated ${path.relative(process.cwd(), file)}: ${Object.keys(values).join(", ")}`);
}

async function main() {
  const [owner] = await hre.ethers.getSigners();
  const { chainId } = await hre.ethers.provider.getNetwork();

  const nodewave = await hre.ethers.deployContract("NodeWave", [owner.address]);
  await nodewave.waitForDeployment();
  const address = await nodewave.getAddress();
  const block = (await nodewave.deploymentTransaction().wait()).blockNumber;

  console.log(`NodeWave deployed at ${address} (chain ${chainId}, block ${block}, owner ${owner.address})`);
  setEnv(path.resolve(__dirname, "../../server/.env"), {
    CONTRACT_ADDRESS: address,
    RPC_URL,
    INDEXER_START_BLOCK: block,
  });
  setEnv(path.resolve(__dirname, "../../nodewave-ui/.env.local"), {
    NEXT_PUBLIC_CONTRACT_ADDRESS: address,
    NEXT_PUBLIC_CHAIN_ID: chainId.toString(),
    NEXT_PUBLIC_RPC_URL: RPC_URL,
  });
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
