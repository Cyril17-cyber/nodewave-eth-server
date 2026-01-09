//compile script: npx hardhat compile
//deploy localhost: npx hardhat ignition deploy ./ignition/modules/NodeWave.js --network localhost

const { buildModule } = require("@nomicfoundation/hardhat-ignition/modules");

//define the initial owner address as needed
const initialOwner = "0x48844a7861CA6F203cd63B5356dcdb1594417D79";

const NodeWaveModule = buildModule("NodeWaveModule", (m) => {
  const NodeWave = m.contract("NodeWave", [initialOwner]);

  return { NodeWave };
});

//code if deployer's address is not required

// const NfTokenModule = buildModule("NfTokenModule", (m) => {
//   const NfToken = m.contract("Nodewave");

//   return { NfToken };
// });

module.exports = NodeWaveModule;
