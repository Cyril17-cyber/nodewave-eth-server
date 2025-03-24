// SPDX-License-Identifier: MIT
pragma solidity >=0.7.0 <0.9.0;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Supply.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";

contract NodeWave is ERC1155, Ownable, ERC1155Supply, IERC1155Receiver {
    uint256 public currentTokenId;
    uint256 private _itemsSold;
    uint256 public listingPrice = 0.00095 ether;
    uint256 public collectionListingPrice = 0.0009 ether;
    uint256 public marketplaceCommission = 500; // 5% in basis points (bps), 1% = 100 bps
    uint256 public royaltyFee = 300; // 3% in basis points
    uint256 public tradeFee = 0.00045 ether;

    struct MarketItem {
        uint256 tokenId;
        string uri;
        address payable artiste;
        uint256 price;
        uint256 supply;
        bool sold;
    }

    // Mapping of tokenId and seller to their market item
    mapping(uint256 => MarketItem) public idMarketItem;

    event MarketItemCreated(
        uint256 indexed tokenId,
        string uri,
        address artiste,
        uint256 price,
        uint256 supply,
        bool sold
    );
    

    // mapping to keep track of the uris and make sure an nft isn't minted more than once
    mapping(string => uint8) existingURIs;

    constructor(address initialOwner) ERC1155("ipfs://{id}.json") Ownable(initialOwner) {}

// Function to allow owner mint a collection of NFTs for free (e.g., an album or EP)
    function ownerMintintCollection(
        uint256 amount, 
        string[] memory uris, 
        uint256[] memory prices
    ) public onlyOwner {
        require(uris.length == prices.length, "URI and price length mismatch");

        for (uint256 i = 0; i < uris.length; i++) {
            currentTokenId += 1;
            uint256 tokenId = currentTokenId;

            //ensuring the nft doesn't already exist
            require(existingURIs[uris[i]] != 1, 'NFT already minted!'); 
            uint256 amountWithOwnersMusic = amount + 1;

            // Mint the NFT for each song in the album or EP
            _mint(msg.sender, tokenId, amountWithOwnersMusic, "");
            _setURI(tokenId, uris[i]);

            // Transfer the tokens to the marketplace
            _safeTransferFrom(msg.sender, address(this), tokenId, amount, "");

            // Create a market item for each song
            idMarketItem[tokenId] = MarketItem(
                tokenId,
                uris[i],
                payable(msg.sender),
                prices[i],
                amount,
                false
            );

            emit MarketItemCreated(tokenId, uris[i], msg.sender, prices[i], amount, false);
        }
    }
    // Function to mint a collection of NFTs (e.g., an album or EP)
    function mintCollection(
        uint256 amount, 
        string[] memory uris, 
        uint256[] memory prices
    ) public payable {
        require(uris.length == prices.length, "URI and price length mismatch");
        require(msg.value >= collectionListingPrice * uris.length * amount, "Insufficient ETH for listing fees");

        for (uint256 i = 0; i < uris.length; i++) {
            currentTokenId += 1;
            uint256 tokenId = currentTokenId;

            //ensuring the nft doesn't already exist
            require(existingURIs[uris[i]] != 1, 'NFT already minted!'); 
            uint256 amountWithOwnersMusic = amount + 2;

            // Mint the NFT for each song in the album or EP
            _mint(msg.sender, tokenId, amountWithOwnersMusic, "");
            _setURI(tokenId, uris[i]);

            // Transfer the tokens to the marketplace
            _safeTransferFrom(msg.sender, address(this), tokenId, amount, "");

            //transfer the token to the contract owner
        _safeTransferFrom(msg.sender, owner(), tokenId, 1, "");

            // Create a market item for each song
            idMarketItem[tokenId] = MarketItem(
                tokenId,
                uris[i],
                payable(msg.sender),
                prices[i],
                amount,
                false
            );

            emit MarketItemCreated(tokenId, uris[i], msg.sender, prices[i], amount, false);
        }
    }

    // owner minting new music
    function ownerMintToken(uint256 amount, string memory uri, uint256 price) public onlyOwner returns(uint256) {
        uint256 amountWithOwnersMusic = amount + 1;
        
        currentTokenId += 1;
        uint256 tokenId = currentTokenId;
        require(existingURIs[uri] != 1, 'NFT already minted!'); 


        // Mint multiple copies of the token
        _mint(msg.sender, tokenId, amountWithOwnersMusic, "");
        _setURI(tokenId, uri);

        //transfer the token to the market
        _safeTransferFrom(msg.sender, address(this), tokenId, amount, "");

        // Save the artiste as the original minter
        idMarketItem[tokenId] = MarketItem(tokenId, uri, payable(msg.sender), price, amount, false);

        emit MarketItemCreated(tokenId, uri, msg.sender, price, amount, false);
        return tokenId;
    }

    // Function to mint new music
    function mintToken(uint256 amount, string memory uri, uint256 price) public payable returns (uint256) {
        uint256 totalPrice = listingPrice * amount;
        require(msg.value >= totalPrice, "Insufficient ETHs... Unable to mint NFT");
        uint256 amountWithOwnersMusic = amount + 2;
        
        currentTokenId += 1;
        uint256 tokenId = currentTokenId;
        require(existingURIs[uri] != 1, 'NFT already minted!'); 


        // Pay the minting fee
        payable(owner()).transfer(msg.value);


        // Mint multiple copies of the token
        _mint(msg.sender, tokenId, amountWithOwnersMusic, "");
        _setURI(tokenId, uri);

        //transfer the token to the market
        _safeTransferFrom(msg.sender, address(this), tokenId, amount, "");

        //transfer the token to the contract owner
        _safeTransferFrom(msg.sender, owner(), tokenId, 1, "");

        // Save the artiste as the original minter
        idMarketItem[tokenId] = MarketItem(tokenId, uri, payable(msg.sender), price, amount, false);

        emit MarketItemCreated(tokenId, uri, msg.sender, price, amount, false);
        return tokenId;
    }

    // Function for buying tokens from the market
    function buyToken(uint256 tokenId, uint256 amount) public payable {
        MarketItem memory item = idMarketItem[tokenId];
        uint256 totalPrice = item.price * amount;
        require(msg.value >= totalPrice, "Insufficient ETH for transaction");
        require(item.supply >= amount, "Not enough tokens available for sale");
        uint256 contractBalance = balanceOf(address(this), tokenId);
        require(contractBalance >= amount, "Contract does not hold enough tokens");

        // Calculate marketplace commission and royalties
        uint256 commissionAmount = (totalPrice * marketplaceCommission) / 10000;  // Convert basis points to percentage
        uint256 sellerAmount = totalPrice - commissionAmount;

        // Pay the marketplace commission
        payable(owner()).transfer(commissionAmount);

        // Pay the artiste
        item.artiste.transfer(sellerAmount);

        // Transfer the tokens to the buyer
        _safeTransferFrom(address(this), msg.sender, tokenId, amount, "");

        // Update the supply
        idMarketItem[tokenId].supply -= amount;
        if (idMarketItem[tokenId].supply == 0) {
            idMarketItem[tokenId].sold = true;
        }
    }

    // function for when someone requests a trade of music
    function requestTrade() public  payable returns(string memory) {
        require(msg.value >= tradeFee, "Please transfer the required transction fee");

        return "Successful";
    }
    //in case of a rejected trade, refunding transaction fee
    function refundTradeFee(address payable refundAddress) public payable {
        require(address(this).balance >= tradeFee, "Insufficient ETH to refund transaction fee");
        //Refund the trade fee
        refundAddress.transfer(tradeFee);
    }
    //function for exchanging nfts
    function tradeMusic(uint256 tokenId1, address owner1, uint256 amount1, uint256 tokenId2, address owner2, uint256 amount2) public payable {
        //uint256 royaltyAmount = (totalPrice * royaltyFee) / 10000;
        //uint256 sellerAmount = totalPrice - commissionAmount - royaltyAmount;
        // Pay the royalties to the artiste
        //item.artiste.transfer(royaltyAmount);
        require(msg.value >= tradeFee, "Please transfer the required transction fee");
        // Pay the transaction fee to the owner
        payable(owner()).transfer(msg.value);

        // Transfer the token 1 to the party 2
        _safeTransferFrom(owner1, owner2, tokenId1, amount1, "");
        // Transfer the token 2 to the party 1
        _safeTransferFrom(owner2, owner1, tokenId2, amount2, "");
        
    }

    // Function to set URI for each token
    function _setURI(uint256 tokenId, string memory uri) internal {
        emit URI(uri, tokenId);
    }



    // Function to update the marketplace commission rate (in basis points)
    function updateMarketplaceCommission(uint256 newCommission) public onlyOwner {
        require(newCommission <= 1000, "Marketplace commission cannot exceed 10%");
        marketplaceCommission = newCommission;
    }

    // Function to update the royalty fee rate (in basis points)
    function updateRoyaltyFee(uint256 newRoyaltyFee) public onlyOwner {
        require(newRoyaltyFee <= 1000, "Royalty fee cannot exceed 10%");
        royaltyFee = newRoyaltyFee;
    }

    //Function to update listing fee
    function updateListingPrice(uint256 newMintingFee) public onlyOwner {
        require(newMintingFee > 0, "Listing fee is required");
        listingPrice = newMintingFee;
    }

    //Function to update collecton listing fee
    function updateCollectionListingPrice(uint256 newMintingFee) public onlyOwner {
        require(newMintingFee > 0, "Listing fee is required");
        collectionListingPrice = newMintingFee;
    }

    // The following functions are overrides required by Solidity.
    function _update(address from, address to, uint256[] memory ids, uint256[] memory values)
        internal
        override(ERC1155, ERC1155Supply)
    {
        super._update(from, to, ids, values);
    }

    // Implement the onERC1155Received function
    function onERC1155Received(
        address operator,
        address from,
        uint256 id,
        uint256 value,
        bytes calldata data
    ) external pure override returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    // Implement the onERC1155BatchReceived function
    function onERC1155BatchReceived(
        address operator,
        address from,
        uint256[] calldata ids,
        uint256[] calldata values,
        bytes calldata data
    ) external pure override returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }
}
