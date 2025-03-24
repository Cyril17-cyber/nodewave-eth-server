//test script: npx hardhat test

const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("Nodewave Minter", function () {
  let Nodewave, nodewave, owner, addr1, addr2, addr3;

  beforeEach(async function () {
    Nodewave = await ethers.getContractFactory("NodeWave");
    [owner, addr1, addr2, addr3] = await ethers.getSigners();

    //depoy the contract
    nodewave = await Nodewave.deploy(owner.address);
  });

  it("Should mint an NFT to the owner", async function () {
    await nodewave.ownerMintToken(2, "ipfs://tokenURI1", 2000000000000000);
    expect(await nodewave.currentTokenId()).to.equal(1);
    console.log(await nodewave.balanceOf(owner.address, 1));
  });
});
