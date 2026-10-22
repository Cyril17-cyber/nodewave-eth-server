//test script: npx hardhat test

const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture } = require("@nomicfoundation/hardhat-toolbox/network-helpers");

const PRICE = ethers.parseEther("0.01");

describe("NodeWave", function () {
  async function deployFixture() {
    const [owner, artiste, fan, other] = await ethers.getSigners();
    const nodewave = await ethers.deployContract("NodeWave", [owner.address]);
    return { nodewave, owner, artiste, fan, other };
  }

  // artiste mints a single with `amount` copies for sale; returns the tokenId
  async function mintSingle(nodewave, artiste, uri = "ipfs://song", amount = 10n, price = PRICE) {
    const fee = (await nodewave.listingPrice()) * amount;
    await nodewave.connect(artiste).mintToken(amount, uri, price, { value: fee });
    return nodewave.currentTokenId();
  }

  async function mintAndBuy(nodewave, artiste, fan, amount = 2n) {
    const tokenId = await mintSingle(nodewave, artiste);
    await nodewave.connect(fan).buyToken(tokenId, amount, { value: PRICE * amount });
    return tokenId;
  }

  describe("minting", function () {
    it("mints a single: copies to market, 1 to artiste, 1 to platform; fee held for owner", async function () {
      const { nodewave, owner, artiste } = await loadFixture(deployFixture);
      const tokenId = await mintSingle(nodewave, artiste);
      const addr = await nodewave.getAddress();

      expect(await nodewave.balanceOf(addr, tokenId)).to.equal(10);
      expect(await nodewave.balanceOf(artiste.address, tokenId)).to.equal(1);
      expect(await nodewave.balanceOf(owner.address, tokenId)).to.equal(1);
      expect(await nodewave.platformFees()).to.equal((await nodewave.listingPrice()) * 10n);

      const [id, uri, itemArtiste, price, supply, sold] = await nodewave.idMarketItem(tokenId);
      expect([id, uri, itemArtiste, price, supply, sold]).to.deep.equal([
        tokenId, "ipfs://song", artiste.address, PRICE, 10n, false,
      ]);
    });

    it("returns each token's own URI", async function () {
      const { nodewave, artiste } = await loadFixture(deployFixture);
      await mintSingle(nodewave, artiste, "https://gateway/ipfs/cidA");
      await mintSingle(nodewave, artiste, "https://gateway/ipfs/cidB");
      expect(await nodewave.uri(1)).to.equal("https://gateway/ipfs/cidA");
      expect(await nodewave.uri(2)).to.equal("https://gateway/ipfs/cidB");
    });

    it("rejects minting the same URI twice", async function () {
      const { nodewave, artiste, other } = await loadFixture(deployFixture);
      await mintSingle(nodewave, artiste, "ipfs://same");
      await expect(mintSingle(nodewave, other, "ipfs://same"))
        .to.be.revertedWithCustomError(nodewave, "URIAlreadyMinted");
    });

    it("rejects duplicate URIs inside one collection", async function () {
      const { nodewave, artiste } = await loadFixture(deployFixture);
      const fee = (await nodewave.collectionListingPrice()) * 2n * 5n;
      await expect(
        nodewave.connect(artiste).mintCollection(5, ["ipfs://x", "ipfs://x"], [1, 1], { value: fee })
      ).to.be.revertedWithCustomError(nodewave, "URIAlreadyMinted");
    });

    it("requires the exact listing fee", async function () {
      const { nodewave, artiste } = await loadFixture(deployFixture);
      const fee = (await nodewave.listingPrice()) * 10n;
      await expect(nodewave.connect(artiste).mintToken(10, "ipfs://a", PRICE, { value: fee - 1n }))
        .to.be.revertedWithCustomError(nodewave, "IncorrectPayment");
      await expect(nodewave.connect(artiste).mintToken(10, "ipfs://a", PRICE, { value: fee + 1n }))
        .to.be.revertedWithCustomError(nodewave, "IncorrectPayment");
    });

    it("rejects zero amount and empty URI", async function () {
      const { nodewave, artiste } = await loadFixture(deployFixture);
      await expect(nodewave.connect(artiste).mintToken(0, "ipfs://a", PRICE))
        .to.be.revertedWithCustomError(nodewave, "ZeroAmount");
      const fee = await nodewave.listingPrice();
      await expect(nodewave.connect(artiste).mintToken(1, "", PRICE, { value: fee }))
        .to.be.revertedWithCustomError(nodewave, "EmptyURI");
    });

    it("mints a collection and records it on-chain", async function () {
      const { nodewave, artiste } = await loadFixture(deployFixture);
      await mintSingle(nodewave, artiste, "ipfs://earlier-single");
      const uris = ["ipfs://t1", "ipfs://t2", "ipfs://t3"];
      const fee = (await nodewave.collectionListingPrice()) * 3n * 5n;

      await expect(nodewave.connect(artiste).mintCollection(5, uris, [1, 2, 3], { value: fee }))
        .to.emit(nodewave, "CollectionCreated")
        .withArgs(1, artiste.address, 2, 3);

      const [collectionArtiste, firstTokenId, trackCount] = await nodewave.collections(1);
      expect([collectionArtiste, firstTokenId, trackCount]).to.deep.equal([artiste.address, 2n, 3n]);
      expect(await nodewave.tokenCollection(1)).to.equal(0);
      expect(await nodewave.tokenCollection(4)).to.equal(1);
      expect(await nodewave.uri(4)).to.equal("ipfs://t3");
      expect(await nodewave.platformFees()).to.equal((await nodewave.listingPrice()) * 10n + fee);
    });

    it("validates collection size and array lengths", async function () {
      const { nodewave, artiste } = await loadFixture(deployFixture);
      await expect(nodewave.connect(artiste).mintCollection(1, [], []))
        .to.be.revertedWithCustomError(nodewave, "InvalidCollectionSize");
      const fee = (await nodewave.collectionListingPrice()) * 2n;
      await expect(nodewave.connect(artiste).mintCollection(1, ["ipfs://a", "ipfs://b"], [1], { value: fee }))
        .to.be.revertedWithCustomError(nodewave, "LengthMismatch");
    });

    it("lets only the owner mint for free, without a platform copy", async function () {
      const { nodewave, owner, artiste } = await loadFixture(deployFixture);
      await expect(nodewave.connect(artiste).ownerMintToken(5, "ipfs://a", PRICE))
        .to.be.revertedWithCustomError(nodewave, "OwnableUnauthorizedAccount");
      await expect(nodewave.connect(artiste).ownerMintCollection(5, ["ipfs://a"], [PRICE]))
        .to.be.revertedWithCustomError(nodewave, "OwnableUnauthorizedAccount");

      await nodewave.ownerMintToken(5, "ipfs://a", PRICE);
      await nodewave.ownerMintCollection(5, ["ipfs://b", "ipfs://c"], [PRICE, PRICE]);
      expect(await nodewave.balanceOf(owner.address, 1)).to.equal(1);
      expect(await nodewave.balanceOf(owner.address, 3)).to.equal(1);
      expect(await nodewave.platformFees()).to.equal(0);
    });
  });

  describe("primary sales", function () {
    it("transfers copies and credits artiste and platform", async function () {
      const { nodewave, artiste, fan } = await loadFixture(deployFixture);
      const tokenId = await mintSingle(nodewave, artiste);
      const feesBefore = await nodewave.platformFees();

      await expect(nodewave.connect(fan).buyToken(tokenId, 2, { value: PRICE * 2n }))
        .to.emit(nodewave, "MarketItemSold")
        .withArgs(tokenId, fan.address, 2, PRICE * 2n);

      const commission = (PRICE * 2n * 500n) / 10000n;
      expect(await nodewave.balanceOf(fan.address, tokenId)).to.equal(2);
      expect((await nodewave.idMarketItem(tokenId)).supply).to.equal(8);
      expect(await nodewave.platformFees()).to.equal(feesBefore + commission);
      expect(await nodewave.pendingWithdrawals(artiste.address)).to.equal(PRICE * 2n - commission);
    });

    it("marks the item sold when supply runs out and blocks further buys", async function () {
      const { nodewave, artiste, fan } = await loadFixture(deployFixture);
      const tokenId = await mintSingle(nodewave, artiste, "ipfs://song", 2n);
      await nodewave.connect(fan).buyToken(tokenId, 2, { value: PRICE * 2n });
      expect((await nodewave.idMarketItem(tokenId)).sold).to.equal(true);
      await expect(nodewave.connect(fan).buyToken(tokenId, 1, { value: PRICE }))
        .to.be.revertedWithCustomError(nodewave, "InsufficientSupply");
    });

    it("requires exact payment, a real item and a non-zero amount", async function () {
      const { nodewave, artiste, fan } = await loadFixture(deployFixture);
      const tokenId = await mintSingle(nodewave, artiste);
      await expect(nodewave.connect(fan).buyToken(tokenId, 1, { value: PRICE + 1n }))
        .to.be.revertedWithCustomError(nodewave, "IncorrectPayment");
      await expect(nodewave.connect(fan).buyToken(tokenId, 0))
        .to.be.revertedWithCustomError(nodewave, "ZeroAmount");
      await expect(nodewave.connect(fan).buyToken(999, 1))
        .to.be.revertedWithCustomError(nodewave, "ItemNotFound");
    });
  });

  describe("artiste listing management", function () {
    it("lets the artiste change price and withdraw unsold copies", async function () {
      const { nodewave, artiste } = await loadFixture(deployFixture);
      const tokenId = await mintSingle(nodewave, artiste);

      await nodewave.connect(artiste).updateItemPrice(tokenId, PRICE * 2n);
      expect((await nodewave.idMarketItem(tokenId)).price).to.equal(PRICE * 2n);

      await nodewave.connect(artiste).withdrawUnsold(tokenId, 10);
      expect(await nodewave.balanceOf(artiste.address, tokenId)).to.equal(11);
      expect((await nodewave.idMarketItem(tokenId)).supply).to.equal(0);
    });

    it("blocks anyone else", async function () {
      const { nodewave, artiste, other } = await loadFixture(deployFixture);
      const tokenId = await mintSingle(nodewave, artiste);
      await expect(nodewave.connect(other).updateItemPrice(tokenId, 1))
        .to.be.revertedWithCustomError(nodewave, "NotArtiste");
      await expect(nodewave.connect(other).withdrawUnsold(tokenId, 1))
        .to.be.revertedWithCustomError(nodewave, "NotArtiste");
    });
  });

  describe("resales", function () {
    it("escrows, sells and splits commission, royalty and seller proceeds", async function () {
      const { nodewave, artiste, fan, other } = await loadFixture(deployFixture);
      const tokenId = await mintAndBuy(nodewave, artiste, fan);
      const resalePrice = ethers.parseEther("0.05");

      await nodewave.connect(fan).listForResale(tokenId, 2, resalePrice);
      expect(await nodewave.balanceOf(fan.address, tokenId)).to.equal(0);

      const artisteBefore = await nodewave.pendingWithdrawals(artiste.address);
      const feesBefore = await nodewave.platformFees();
      await nodewave.connect(other).buyResale(1, 1, { value: resalePrice });

      const commission = (resalePrice * 500n) / 10000n;
      const royalty = (resalePrice * 300n) / 10000n;
      expect(await nodewave.balanceOf(other.address, tokenId)).to.equal(1);
      expect(await nodewave.platformFees()).to.equal(feesBefore + commission);
      expect(await nodewave.pendingWithdrawals(artiste.address)).to.equal(artisteBefore + royalty);
      expect(await nodewave.pendingWithdrawals(fan.address)).to.equal(resalePrice - commission - royalty);
      expect((await nodewave.resaleListings(1)).amount).to.equal(1);
    });

    it("lets only the seller cancel and returns the copies", async function () {
      const { nodewave, artiste, fan, other } = await loadFixture(deployFixture);
      const tokenId = await mintAndBuy(nodewave, artiste, fan);
      await nodewave.connect(fan).listForResale(tokenId, 2, PRICE);

      await expect(nodewave.connect(other).cancelResale(1)).to.be.revertedWithCustomError(nodewave, "NotSeller");
      await nodewave.connect(fan).cancelResale(1);
      expect(await nodewave.balanceOf(fan.address, tokenId)).to.equal(2);
      await expect(nodewave.connect(other).buyResale(1, 1, { value: PRICE }))
        .to.be.revertedWithCustomError(nodewave, "ListingNotFound");
    });

    it("cannot list copies you don't own", async function () {
      const { nodewave, artiste, other } = await loadFixture(deployFixture);
      const tokenId = await mintSingle(nodewave, artiste);
      await expect(nodewave.connect(other).listForResale(tokenId, 1, PRICE))
        .to.be.revertedWithCustomError(nodewave, "ERC1155InsufficientBalance");
    });
  });

  describe("trades", function () {
    async function tradeFixture() {
      const base = await deployFixture();
      const { nodewave, artiste, fan, other } = base;
      const tokenA = await mintAndBuy(nodewave, artiste, fan, 1n); // fan holds A
      const tokenB = await mintSingle(nodewave, artiste, "ipfs://song-b");
      await nodewave.connect(other).buyToken(tokenB, 1, { value: PRICE }); // other holds B
      return { ...base, tokenA, tokenB, tradeFee: await nodewave.tradeFee() };
    }

    it("swaps tokens only once the taker accepts", async function () {
      const { nodewave, fan, other, tokenA, tokenB, tradeFee } = await loadFixture(tradeFixture);
      await nodewave.connect(fan).createTradeOffer(other.address, tokenA, 1, tokenB, 1, { value: tradeFee });
      expect(await nodewave.balanceOf(fan.address, tokenA)).to.equal(0); // escrowed

      const feesBefore = await nodewave.platformFees();
      await nodewave.connect(other).acceptTradeOffer(1);
      expect(await nodewave.balanceOf(fan.address, tokenB)).to.equal(1);
      expect(await nodewave.balanceOf(other.address, tokenA)).to.equal(1);
      expect(await nodewave.platformFees()).to.equal(feesBefore + tradeFee);
      await expect(nodewave.connect(other).acceptTradeOffer(1))
        .to.be.revertedWithCustomError(nodewave, "TradeNotActive");
    });

    it("only the named taker can accept", async function () {
      const { nodewave, artiste, fan, other, tokenA, tokenB, tradeFee } = await loadFixture(tradeFixture);
      await nodewave.connect(fan).createTradeOffer(other.address, tokenA, 1, tokenB, 1, { value: tradeFee });
      await expect(nodewave.connect(artiste).acceptTradeOffer(1))
        .to.be.revertedWithCustomError(nodewave, "NotTradeParty");
    });

    it("refunds escrow and fee when the taker rejects", async function () {
      const { nodewave, fan, other, tokenA, tokenB, tradeFee } = await loadFixture(tradeFixture);
      await nodewave.connect(fan).createTradeOffer(other.address, tokenA, 1, tokenB, 1, { value: tradeFee });
      await expect(nodewave.connect(other).cancelTradeOffer(1))
        .to.emit(nodewave, "TradeOfferCancelled").withArgs(1, other.address);
      expect(await nodewave.balanceOf(fan.address, tokenA)).to.equal(1);
      expect(await nodewave.pendingWithdrawals(fan.address)).to.equal(tradeFee);
    });

    it("rejects invalid offers", async function () {
      const { nodewave, fan, other, tokenA, tokenB, tradeFee } = await loadFixture(tradeFixture);
      await expect(nodewave.connect(fan).createTradeOffer(fan.address, tokenA, 1, tokenB, 1, { value: tradeFee }))
        .to.be.revertedWithCustomError(nodewave, "InvalidAddress");
      await expect(nodewave.connect(fan).createTradeOffer(other.address, tokenA, 1, tokenB, 1))
        .to.be.revertedWithCustomError(nodewave, "IncorrectPayment");
      await expect(nodewave.connect(fan).createTradeOffer(other.address, tokenB, 1, tokenA, 1, { value: tradeFee }))
        .to.be.revertedWithCustomError(nodewave, "ERC1155InsufficientBalance");
    });
  });

  describe("withdrawals", function () {
    it("pays artistes what they're owed, once", async function () {
      const { nodewave, artiste, fan } = await loadFixture(deployFixture);
      await mintAndBuy(nodewave, artiste, fan);
      const owed = await nodewave.pendingWithdrawals(artiste.address);

      await expect(nodewave.connect(artiste).withdraw()).to.changeEtherBalance(artiste, owed);
      await expect(nodewave.connect(artiste).withdraw())
        .to.be.revertedWithCustomError(nodewave, "NothingToWithdraw");
    });

    it("lets only the owner withdraw platform fees", async function () {
      const { nodewave, owner, artiste, fan, other } = await loadFixture(deployFixture);
      await mintAndBuy(nodewave, artiste, fan);
      const fees = await nodewave.platformFees();

      await expect(nodewave.connect(other).withdrawPlatformFees(other.address))
        .to.be.revertedWithCustomError(nodewave, "OwnableUnauthorizedAccount");
      await expect(nodewave.withdrawPlatformFees(owner.address)).to.changeEtherBalance(owner, fees);
      expect(await ethers.provider.getBalance(await nodewave.getAddress()))
        .to.equal(await nodewave.pendingWithdrawals(artiste.address));
    });
  });

  describe("admin", function () {
    it("caps commission and royalty at 10%", async function () {
      const { nodewave } = await loadFixture(deployFixture);
      await expect(nodewave.updateMarketplaceCommission(1001)).to.be.revertedWithCustomError(nodewave, "FeeTooHigh");
      await expect(nodewave.updateRoyaltyFee(1001)).to.be.revertedWithCustomError(nodewave, "FeeTooHigh");
      await expect(nodewave.updateTradeFee(1)).to.emit(nodewave, "FeesUpdated");
    });

    it("pause blocks trading but not withdrawals or cancellations", async function () {
      const { nodewave, artiste, fan } = await loadFixture(deployFixture);
      const tokenId = await mintAndBuy(nodewave, artiste, fan);
      await nodewave.connect(fan).listForResale(tokenId, 1, PRICE);
      await nodewave.pause();

      await expect(nodewave.connect(fan).buyToken(tokenId, 1, { value: PRICE }))
        .to.be.revertedWithCustomError(nodewave, "EnforcedPause");
      await nodewave.connect(fan).cancelResale(1);
      await nodewave.connect(artiste).withdraw();
    });

    it("uses two-step ownership transfer", async function () {
      const { nodewave, other } = await loadFixture(deployFixture);
      await nodewave.transferOwnership(other.address);
      expect(await nodewave.pendingOwner()).to.equal(other.address);
      await nodewave.connect(other).acceptOwnership();
      expect(await nodewave.owner()).to.equal(other.address);
    });
  });

  describe("royalties (ERC-2981)", function () {
    it("reports the artiste and royalty amount", async function () {
      const { nodewave, artiste } = await loadFixture(deployFixture);
      const tokenId = await mintSingle(nodewave, artiste);
      const [receiver, amount] = await nodewave.royaltyInfo(tokenId, ethers.parseEther("1"));
      expect(receiver).to.equal(artiste.address);
      expect(amount).to.equal(ethers.parseEther("0.03"));
      expect(await nodewave.supportsInterface("0x2a55205a")).to.equal(true); // IERC2981
      expect(await nodewave.supportsInterface("0xd9b67a26")).to.equal(true); // IERC1155
    });
  });

  // Exploits that worked against the previous version of the contract
  describe("regressions", function () {
    it("no function moves someone else's tokens or marketplace stock", async function () {
      const { nodewave, artiste, other } = await loadFixture(deployFixture);
      await mintSingle(nodewave, artiste);
      expect(nodewave.interface.getFunction("tradeMusic")).to.equal(null);
      // The only paths out of the marketplace are paid buys, artiste withdrawals, and escrow returns
      await expect(nodewave.connect(other).withdrawUnsold(1, 10))
        .to.be.revertedWithCustomError(nodewave, "NotArtiste");
    });

    it("no one can drain contract ETH", async function () {
      const { nodewave, artiste, other } = await loadFixture(deployFixture);
      await mintSingle(nodewave, artiste);
      expect(nodewave.interface.getFunction("refundTradeFee")).to.equal(null);
      await expect(nodewave.connect(other).withdraw())
        .to.be.revertedWithCustomError(nodewave, "NothingToWithdraw");
    });
  });
});
