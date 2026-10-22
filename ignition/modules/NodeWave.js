//compile script: npx hardhat compile
//deploy localhost: npx hardhat ignition deploy ./ignition/modules/NodeWave.js --network localhost
//deploy sepolia: npx hardhat ignition deploy ./ignition/modules/NodeWave.js --network sepolia
//custom owner: add --parameters '{"NodeWaveModule":{"initialOwner":"0x..."}}'

const { buildModule } = require("@nomicfoundation/hardhat-ignition/modules");

const NodeWaveModule = buildModule("NodeWaveModule", (m) => {
  // Defaults to the deploying account so the owner always matches the network's signer
  const initialOwner = m.getParameter("initialOwner", m.getAccount(0));
  const NodeWave = m.contract("NodeWave", [initialOwner]);

  return { NodeWave };
});

module.exports = NodeWaveModule;
