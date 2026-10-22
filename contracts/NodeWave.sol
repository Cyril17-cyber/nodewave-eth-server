// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {ERC1155Supply} from "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Supply.sol";
import {ERC1155URIStorage} from "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155URIStorage.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title NodeWave
/// @notice Music NFT marketplace: artistes mint singles or collections (albums/EPs),
///         fans buy them, resell them (with artiste royalties) and swap them via escrowed trades.
/// @dev All ETH owed to artistes/sellers is credited to `pendingWithdrawals` and pulled
///      with `withdraw()`; platform revenue accumulates in `platformFees`.
contract NodeWave is
    ERC1155Supply,
    ERC1155URIStorage,
    ERC1155Holder,
    Ownable2Step,
    Pausable,
    ReentrancyGuard,
    IERC2981
{
    uint256 private constant BPS = 10_000;
    uint256 public constant MAX_FEE_BPS = 1_000; // 10%
    uint256 public constant MAX_COLLECTION_SIZE = 50;

    uint256 public currentTokenId;
    uint256 public currentCollectionId;
    uint256 public currentListingId;
    uint256 public currentTradeId;

    uint256 public listingPrice = 0.00095 ether; // per copy, single drop
    uint256 public collectionListingPrice = 0.0009 ether; // per copy, per track
    uint256 public marketplaceCommission = 500; // 5% in basis points (bps), 1% = 100 bps
    uint256 public royaltyFee = 300; // 3% in basis points, paid to the artiste on resales
    uint256 public tradeFee = 0.00045 ether;

    uint256 public platformFees;
    mapping(address => uint256) public pendingWithdrawals;

    // Primary-sale listing created at mint. `uri` is kept here (as well as in URI storage)
    // because the frontend reads it from `idMarketItem`.
    struct MarketItem {
        uint256 tokenId;
        string uri;
        address payable artiste;
        uint256 price;
        uint256 supply; // copies still held by the marketplace for primary sale
        bool sold; // true once supply reaches 0
    }

    struct Collection {
        address artiste;
        uint256 firstTokenId; // tracks occupy firstTokenId .. firstTokenId + trackCount - 1
        uint256 trackCount;
    }

    struct ResaleListing {
        address seller;
        uint256 tokenId;
        uint256 amount;
        uint256 price; // per copy
    }

    struct TradeOffer {
        address maker;
        address taker;
        uint256 offeredTokenId;
        uint256 offeredAmount;
        uint256 requestedTokenId;
        uint256 requestedAmount;
        uint256 feePaid;
        bool active;
    }

    mapping(uint256 => MarketItem) public idMarketItem;
    mapping(uint256 => Collection) public collections;
    mapping(uint256 => uint256) public tokenCollection; // tokenId => collectionId (0 = single)
    mapping(uint256 => ResaleListing) public resaleListings;
    mapping(uint256 => TradeOffer) public tradeOffers;

    // keccak256(uri) => minted, so the same song can't be minted twice
    mapping(bytes32 => bool) private _mintedURIs;

    error ZeroAmount();
    error EmptyURI();
    error URIAlreadyMinted(string uri);
    error LengthMismatch();
    error InvalidCollectionSize(uint256 size);
    error IncorrectPayment(uint256 expected, uint256 sent);
    error ItemNotFound(uint256 tokenId);
    error InsufficientSupply(uint256 available, uint256 requested);
    error NotArtiste();
    error ListingNotFound(uint256 listingId);
    error NotSeller();
    error TradeNotActive(uint256 tradeId);
    error NotTradeParty();
    error InvalidAddress();
    error FeeTooHigh();
    error NothingToWithdraw();
    error TransferFailed();

    event MarketItemCreated(
        uint256 indexed tokenId,
        string uri,
        address artiste,
        uint256 price,
        uint256 supply,
        bool sold
    );
    event CollectionCreated(
        uint256 indexed collectionId,
        address indexed artiste,
        uint256 firstTokenId,
        uint256 trackCount
    );
    event MarketItemSold(uint256 indexed tokenId, address indexed buyer, uint256 amount, uint256 totalPrice);
    event MarketItemPriceUpdated(uint256 indexed tokenId, uint256 newPrice);
    event MarketItemWithdrawn(uint256 indexed tokenId, address indexed artiste, uint256 amount);
    event ResaleListed(
        uint256 indexed listingId,
        address indexed seller,
        uint256 indexed tokenId,
        uint256 amount,
        uint256 price
    );
    event ResaleCancelled(uint256 indexed listingId);
    event ResaleSold(uint256 indexed listingId, address indexed buyer, uint256 amount, uint256 totalPrice);
    event TradeOfferCreated(
        uint256 indexed tradeId,
        address indexed maker,
        address indexed taker,
        uint256 offeredTokenId,
        uint256 offeredAmount,
        uint256 requestedTokenId,
        uint256 requestedAmount
    );
    event TradeOfferAccepted(uint256 indexed tradeId);
    event TradeOfferCancelled(uint256 indexed tradeId, address indexed cancelledBy);
    event Withdrawal(address indexed account, uint256 amount);
    event PlatformFeesWithdrawn(address indexed to, uint256 amount);
    event FeesUpdated(
        uint256 listingPrice,
        uint256 collectionListingPrice,
        uint256 marketplaceCommission,
        uint256 royaltyFee,
        uint256 tradeFee
    );

    constructor(address initialOwner) ERC1155("") Ownable(initialOwner) {}

    // ---------------------------------------------------------------------
    // Minting
    // ---------------------------------------------------------------------

    /// @notice Owner mints a collection (album/EP) without paying listing fees.
    function ownerMintCollection(
        uint256 amount,
        string[] calldata uris,
        uint256[] calldata prices
    ) external onlyOwner whenNotPaused nonReentrant returns (uint256) {
        return _mintCollection(amount, uris, prices, false);
    }

    /// @notice Mint a collection (album/EP). `amount` copies of each track are listed for sale.
    function mintCollection(
        uint256 amount,
        string[] calldata uris,
        uint256[] calldata prices
    ) external payable whenNotPaused nonReentrant returns (uint256) {
        _collectFee(collectionListingPrice * uris.length * amount);
        return _mintCollection(amount, uris, prices, true);
    }

    /// @notice Owner mints a single without paying listing fees.
    function ownerMintToken(
        uint256 amount,
        string calldata uri_,
        uint256 price
    ) external onlyOwner whenNotPaused nonReentrant returns (uint256) {
        return _mintAndList(amount, uri_, price, false);
    }

    /// @notice Mint a single drop. `amount` copies are listed for sale.
    function mintToken(
        uint256 amount,
        string calldata uri_,
        uint256 price
    ) external payable whenNotPaused nonReentrant returns (uint256) {
        _collectFee(listingPrice * amount);
        return _mintAndList(amount, uri_, price, true);
    }

    // ---------------------------------------------------------------------
    // Primary sales
    // ---------------------------------------------------------------------

    /// @notice Buy copies of a song directly from the artiste's primary listing.
    /// @dev `msg.value` must equal price * amount exactly, so a price change between
    ///      quoting and sending reverts instead of over/under-charging.
    function buyToken(uint256 tokenId, uint256 amount) external payable whenNotPaused nonReentrant {
        if (amount == 0) revert ZeroAmount();
        MarketItem storage item = idMarketItem[tokenId];
        if (item.artiste == address(0)) revert ItemNotFound(tokenId);
        if (item.supply < amount) revert InsufficientSupply(item.supply, amount);

        uint256 totalPrice = item.price * amount;
        if (msg.value != totalPrice) revert IncorrectPayment(totalPrice, msg.value);

        item.supply -= amount;
        item.sold = item.supply == 0;

        uint256 commission = (totalPrice * marketplaceCommission) / BPS;
        platformFees += commission;
        pendingWithdrawals[item.artiste] += totalPrice - commission;

        emit MarketItemSold(tokenId, msg.sender, amount, totalPrice);
        _safeTransferFrom(address(this), msg.sender, tokenId, amount, "");
    }

    /// @notice Artiste changes the primary-sale price of their song.
    function updateItemPrice(uint256 tokenId, uint256 newPrice) external {
        _artisteItem(tokenId).price = newPrice;
        emit MarketItemPriceUpdated(tokenId, newPrice);
    }

    /// @notice Artiste takes unsold copies back out of the marketplace (partially or fully delisting).
    function withdrawUnsold(uint256 tokenId, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        MarketItem storage item = _artisteItem(tokenId);
        if (item.supply < amount) revert InsufficientSupply(item.supply, amount);

        item.supply -= amount;
        item.sold = item.supply == 0;

        emit MarketItemWithdrawn(tokenId, msg.sender, amount);
        _safeTransferFrom(address(this), msg.sender, tokenId, amount, "");
    }

    // ---------------------------------------------------------------------
    // Secondary market (resales pay the artiste a royalty)
    // ---------------------------------------------------------------------

    /// @notice List copies you own for resale. The copies are held in escrow until sold or cancelled.
    function listForResale(
        uint256 tokenId,
        uint256 amount,
        uint256 price
    ) external whenNotPaused nonReentrant returns (uint256 listingId) {
        if (amount == 0) revert ZeroAmount();
        if (idMarketItem[tokenId].artiste == address(0)) revert ItemNotFound(tokenId);

        listingId = ++currentListingId;
        resaleListings[listingId] = ResaleListing(msg.sender, tokenId, amount, price);

        emit ResaleListed(listingId, msg.sender, tokenId, amount, price);
        _safeTransferFrom(msg.sender, address(this), tokenId, amount, "");
    }

    function cancelResale(uint256 listingId) external nonReentrant {
        ResaleListing memory listing = resaleListings[listingId];
        if (listing.seller != msg.sender) revert NotSeller();

        delete resaleListings[listingId];

        emit ResaleCancelled(listingId);
        _safeTransferFrom(address(this), msg.sender, listing.tokenId, listing.amount, "");
    }

    function buyResale(uint256 listingId, uint256 amount) external payable whenNotPaused nonReentrant {
        if (amount == 0) revert ZeroAmount();
        ResaleListing storage listing = resaleListings[listingId];
        if (listing.seller == address(0)) revert ListingNotFound(listingId);
        if (listing.amount < amount) revert InsufficientSupply(listing.amount, amount);

        uint256 totalPrice = listing.price * amount;
        if (msg.value != totalPrice) revert IncorrectPayment(totalPrice, msg.value);

        address seller = listing.seller;
        uint256 tokenId = listing.tokenId;
        listing.amount -= amount;
        if (listing.amount == 0) delete resaleListings[listingId];

        uint256 commission = (totalPrice * marketplaceCommission) / BPS;
        uint256 royalty = (totalPrice * royaltyFee) / BPS;
        platformFees += commission;
        pendingWithdrawals[idMarketItem[tokenId].artiste] += royalty;
        pendingWithdrawals[seller] += totalPrice - commission - royalty;

        emit ResaleSold(listingId, msg.sender, amount, totalPrice);
        _safeTransferFrom(address(this), msg.sender, tokenId, amount, "");
    }

    // ---------------------------------------------------------------------
    // Trades (escrowed swaps that the counterparty must accept)
    // ---------------------------------------------------------------------

    /// @notice Offer `offeredAmount` of `offeredTokenId` to `taker` in exchange for
    ///         `requestedAmount` of `requestedTokenId`. Your copies and the trade fee are escrowed.
    function createTradeOffer(
        address taker,
        uint256 offeredTokenId,
        uint256 offeredAmount,
        uint256 requestedTokenId,
        uint256 requestedAmount
    ) external payable whenNotPaused nonReentrant returns (uint256 tradeId) {
        if (taker == address(0) || taker == msg.sender) revert InvalidAddress();
        if (offeredAmount == 0 || requestedAmount == 0) revert ZeroAmount();
        if (msg.value != tradeFee) revert IncorrectPayment(tradeFee, msg.value);

        tradeId = ++currentTradeId;
        tradeOffers[tradeId] = TradeOffer(
            msg.sender,
            taker,
            offeredTokenId,
            offeredAmount,
            requestedTokenId,
            requestedAmount,
            msg.value,
            true
        );

        emit TradeOfferCreated(tradeId, msg.sender, taker, offeredTokenId, offeredAmount, requestedTokenId, requestedAmount);
        _safeTransferFrom(msg.sender, address(this), offeredTokenId, offeredAmount, "");
    }

    /// @notice Taker accepts: their requested copies go to the maker, the escrowed copies go to them.
    function acceptTradeOffer(uint256 tradeId) external whenNotPaused nonReentrant {
        TradeOffer storage offer = tradeOffers[tradeId];
        if (!offer.active) revert TradeNotActive(tradeId);
        if (msg.sender != offer.taker) revert NotTradeParty();

        offer.active = false;
        platformFees += offer.feePaid;

        emit TradeOfferAccepted(tradeId);
        _safeTransferFrom(msg.sender, offer.maker, offer.requestedTokenId, offer.requestedAmount, "");
        _safeTransferFrom(address(this), msg.sender, offer.offeredTokenId, offer.offeredAmount, "");
    }

    /// @notice Maker cancels or taker rejects. Escrowed copies return to the maker and the
    ///         trade fee is refunded to them (claim via `withdraw`).
    function cancelTradeOffer(uint256 tradeId) external nonReentrant {
        TradeOffer storage offer = tradeOffers[tradeId];
        if (!offer.active) revert TradeNotActive(tradeId);
        if (msg.sender != offer.maker && msg.sender != offer.taker) revert NotTradeParty();

        offer.active = false;
        pendingWithdrawals[offer.maker] += offer.feePaid;

        emit TradeOfferCancelled(tradeId, msg.sender);
        _safeTransferFrom(address(this), offer.maker, offer.offeredTokenId, offer.offeredAmount, "");
    }

    // ---------------------------------------------------------------------
    // Withdrawals
    // ---------------------------------------------------------------------

    /// @notice Claim ETH owed to you from sales, royalties or refunded trade fees.
    function withdraw() external nonReentrant {
        uint256 amount = pendingWithdrawals[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        pendingWithdrawals[msg.sender] = 0;

        emit Withdrawal(msg.sender, amount);
        _sendETH(msg.sender, amount);
    }

    function withdrawPlatformFees(address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert InvalidAddress();
        uint256 amount = platformFees;
        if (amount == 0) revert NothingToWithdraw();
        platformFees = 0;

        emit PlatformFeesWithdrawn(to, amount);
        _sendETH(to, amount);
    }

    // ---------------------------------------------------------------------
    // Admin
    // ---------------------------------------------------------------------

    function updateMarketplaceCommission(uint256 newCommission) external onlyOwner {
        if (newCommission > MAX_FEE_BPS) revert FeeTooHigh();
        marketplaceCommission = newCommission;
        _emitFeesUpdated();
    }

    function updateRoyaltyFee(uint256 newRoyaltyFee) external onlyOwner {
        if (newRoyaltyFee > MAX_FEE_BPS) revert FeeTooHigh();
        royaltyFee = newRoyaltyFee;
        _emitFeesUpdated();
    }

    function updateListingPrice(uint256 newListingPrice) external onlyOwner {
        listingPrice = newListingPrice;
        _emitFeesUpdated();
    }

    function updateCollectionListingPrice(uint256 newListingPrice) external onlyOwner {
        collectionListingPrice = newListingPrice;
        _emitFeesUpdated();
    }

    function updateTradeFee(uint256 newTradeFee) external onlyOwner {
        tradeFee = newTradeFee;
        _emitFeesUpdated();
    }

    /// @notice Stops minting, buying, listing and new trades. Cancelling and withdrawing still work.
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ---------------------------------------------------------------------
    // Royalties (ERC-2981), so other marketplaces pay the artiste too
    // ---------------------------------------------------------------------

    function royaltyInfo(
        uint256 tokenId,
        uint256 salePrice
    ) external view override returns (address receiver, uint256 royaltyAmount) {
        receiver = idMarketItem[tokenId].artiste;
        royaltyAmount = receiver == address(0) ? 0 : (salePrice * royaltyFee) / BPS;
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    function _mintCollection(
        uint256 amount,
        string[] calldata uris,
        uint256[] calldata prices,
        bool platformCopy
    ) private returns (uint256 collectionId) {
        uint256 trackCount = uris.length;
        if (trackCount == 0 || trackCount > MAX_COLLECTION_SIZE) revert InvalidCollectionSize(trackCount);
        if (trackCount != prices.length) revert LengthMismatch();

        collectionId = ++currentCollectionId;
        collections[collectionId] = Collection(msg.sender, currentTokenId + 1, trackCount);

        for (uint256 i = 0; i < trackCount; i++) {
            uint256 tokenId = _mintAndList(amount, uris[i], prices[i], platformCopy);
            tokenCollection[tokenId] = collectionId;
        }

        emit CollectionCreated(collectionId, msg.sender, currentTokenId - trackCount + 1, trackCount);
    }

    /// @dev Mints `amount` copies into the marketplace for sale, 1 copy to the artiste
    ///      and, for paid mints, 1 copy to the platform owner.
    function _mintAndList(
        uint256 amount,
        string calldata uri_,
        uint256 price,
        bool platformCopy
    ) private returns (uint256 tokenId) {
        if (amount == 0) revert ZeroAmount();
        if (bytes(uri_).length == 0) revert EmptyURI();
        bytes32 uriHash = keccak256(bytes(uri_));
        if (_mintedURIs[uriHash]) revert URIAlreadyMinted(uri_);
        _mintedURIs[uriHash] = true;

        tokenId = ++currentTokenId;
        _setURI(tokenId, uri_);
        idMarketItem[tokenId] = MarketItem(tokenId, uri_, payable(msg.sender), price, amount, false);
        emit MarketItemCreated(tokenId, uri_, msg.sender, price, amount, false);

        _mint(address(this), tokenId, amount, "");
        _mint(msg.sender, tokenId, 1, "");
        if (platformCopy) _mint(owner(), tokenId, 1, "");
    }

    function _collectFee(uint256 expected) private {
        if (msg.value != expected) revert IncorrectPayment(expected, msg.value);
        platformFees += msg.value;
    }

    function _artisteItem(uint256 tokenId) private view returns (MarketItem storage item) {
        item = idMarketItem[tokenId];
        if (item.artiste != msg.sender) revert NotArtiste();
    }

    function _sendETH(address to, uint256 amount) private {
        (bool success, ) = payable(to).call{value: amount}("");
        if (!success) revert TransferFailed();
    }

    function _emitFeesUpdated() private {
        emit FeesUpdated(listingPrice, collectionListingPrice, marketplaceCommission, royaltyFee, tradeFee);
    }

    // ---------------------------------------------------------------------
    // Overrides required by Solidity
    // ---------------------------------------------------------------------

    function uri(uint256 tokenId) public view override(ERC1155, ERC1155URIStorage) returns (string memory) {
        return super.uri(tokenId);
    }

    function _update(
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory values
    ) internal override(ERC1155, ERC1155Supply) {
        super._update(from, to, ids, values);
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view override(ERC1155, ERC1155Holder, IERC165) returns (bool) {
        return interfaceId == type(IERC2981).interfaceId || super.supportsInterface(interfaceId);
    }
}
