pragma solidity ^0.8.7;

import "./EIP712Editions.sol";
import "../shared/Nonces.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

interface UserCollection {
    function mintExtensionNew(address[] calldata to, uint256[] calldata amounts, string[] calldata uris) external returns (uint256[] memory);
    function mintExtensionExisting(address[] calldata to, uint256[] calldata tokenIds, uint256[] calldata amounts) external;
    function isAdmin(address admin) external view returns (bool);
}

interface IDelegationRegistry {
    function checkDelegateForContract(address to, address from, address contract_, bytes32 rights) external view returns (bool valid);
}

contract SealedEditions is EIP712Editions, Ownable, Nonces {
    mapping(bytes32 => uint256) public editionsMinted;
    mapping(address => mapping(uint256 => uint256)) public nonceToNftId;
    mapping(address => mapping(uint256 => mapping(address => uint256))) public nftsMintedByAddress;
    address public sequencer; // Invariant: always different than address(0)
    uint256 internal constant MIN_WITHOUT_FEE = 0.9e18; // 90%
    uint256 public feeMultiplier = 0.98e18; // Invariant: between 90% and 100%

    constructor(address _sequencer) {
        require(_sequencer != address(0), "0x0 sequencer not allowed");
        sequencer = _sequencer;
    }

    event AdminConfigChanged(address sequencer, uint feeMultiplier);

    function changeAdminConfig(address _sequencer, uint _feeMultiplier) external onlyOwner {
        require(_sequencer != address(0), "0x0 sequencer not allowed");
        sequencer = _sequencer;
        require(_feeMultiplier >= MIN_WITHOUT_FEE && _feeMultiplier <= 1e18, ">MAX_PROTOCOL_FEE");
        feeMultiplier = _feeMultiplier;
        emit AdminConfigChanged(_sequencer, _feeMultiplier);
    }

    event FeesWithdrawn(address receiver);

    function withdrawFees(address payable receiver) external onlyOwner {
        _transferETH(receiver, address(this).balance);
        emit FeesWithdrawn(receiver);
    }

    function _transferETH(address payable receiver, uint256 amount) internal {
        (bool success,) = receiver.call{value: amount}("");
        require(success, "eth send"); // if it fails to send then reverting is ok since its seller thats causing it to fail
    }

    function _distributePrimarySale(uint256 cost, uint256 amount, address payable seller) internal {
        if(cost > 0){
            uint total = amount * cost;
            require(msg.value == total, "msg.value");
            uint256 amountWithoutFee = (total * feeMultiplier) / 1e18;
            _transferETH(seller, amountWithoutFee);
        }
    }

    function calculateEditionHash(address nftContract, uint nftId, uint cost, uint startDate, uint endDate, uint maxToMint, uint maxPerWallet, address seller, bytes32 merkleRoot) pure public returns (bytes32) {
        return keccak256(abi.encode(nftContract, nftId, cost, startDate, endDate, maxToMint, maxPerWallet, seller, merkleRoot));
    }

    modifier nftAdmin(address nftContract) {
        require(UserCollection(nftContract).isAdmin(msg.sender), "Wallet is not an administrator for contract");
        _;
    }

    /*
    We could add a function to reject a specific signature onchain by setting:
        nonceToNftId[msg.sender][nonce] = 1;

    However this would create a potential attack where:
        1. Seller creates a mint for a bad NFT with nftId = 0
        2. Seller lists another more appealing NFT through a signature
        3. User sends a tx calling mintNew()
        4. Seller finds the tx in mempool and frontruns it by calling cancelOffer() to set nonceToNftId to 1
        5. User's tx is executed and mints nft with nftId = 0 instead of the new NFT

    There's very little incentive for this attack, because seller is already selling an NFT and by doing this attack they'd be ruining their own reputation,
    however it's still bad, so for that reason we didn't add this function.

    Instead, on-chain rejections will be handled with increaseCounter(), but we expect most rejections to be handled off-chain through the sequencer.
    */

    event MintCreated(address nftContract, uint nftId, uint cost, uint startDate, uint endDate, uint maxToMint, uint maxPerWallet, address seller, bytes32 merkleRoot);
    event Mint(address nftContract, uint tokenId, uint amount, uint price, address seller, address buyer);

    function verifyNewMint(MintOffer calldata offer, MintOfferAttestation calldata attestation, uint amount, address seller, uint realCost) internal returns (uint nftId){
        require(amount > 0, "amount != 0");
        require(attestation.deadline > block.timestamp && offer.deadline > block.timestamp && offer.endDate > block.timestamp, ">deadline");
        nonceToNftId[seller][offer.nonce] = type(uint).max; // temporary value to avoid reentrancy
        require(seller != address(0) && UserCollection(offer.nftContract).isAdmin(seller), "!auth");
        require(offer.counter > accountCounter[seller], "<counter");
        require(attestation.offerHash == keccak256(abi.encode(
            msg.sender,
            seller,
            offer.nftContract,
            offer.uri,
            offer.cost,
            offer.startDate,
            offer.endDate,
            offer.maxToMint,
            offer.maxPerWallet,
            offer.merkleRoot,
            offer.deadline,
            offer.counter,
            offer.nonce
        )), "!offerHash");
        require(_verifyAttestation(attestation) == sequencer, "!sequencer"); // No need to check against address(0) because sequencer will never be 0x0

        address[] memory to = new address[](1);
        to[0] = msg.sender;
        uint[] memory amounts = new uint[](1);
        amounts[0] = amount;
        string[] memory uris = new string[](1);
        uris[0] = offer.uri;
        uint[] memory nftIds = UserCollection(offer.nftContract).mintExtensionNew(to, amounts, uris); // if its an ipfs uri, separating prefix doesnt improve gas

        nftId = nftIds[0];
        nonceToNftId[seller][offer.nonce] = (nftId << 1) | 1; // assumes nftId will always be < 2**254
        bytes32 editionHash = calculateEditionHash(offer.nftContract, nftId, offer.cost, offer.startDate, offer.endDate, offer.maxToMint, offer.maxPerWallet, seller, offer.merkleRoot);
        editionsMinted[editionHash] += amount;
        require(editionsMinted[editionHash] <= offer.maxToMint, ">maxToMint");
        _distributePrimarySale(realCost, amount, payable(seller));
        emit MintCreated(offer.nftContract, nftId, offer.cost, offer.startDate, offer.endDate, offer.maxToMint, offer.maxPerWallet, seller, offer.merkleRoot);
        emit Mint(offer.nftContract, nftId, amount, realCost, seller, msg.sender);
    }

    function checkMaxPerWallet(address nftContract, uint nftId, uint amount, uint maxPerWallet) internal {
        if(maxPerWallet != 0){
            uint newMinted = nftsMintedByAddress[nftContract][nftId][msg.sender] + amount;
            nftsMintedByAddress[nftContract][nftId][msg.sender] = newMinted;
            require(newMinted <= maxPerWallet, ">maxPerWallet");
        }
    }

    // IMPORTANT: All modifications to the same offer should reuse the same nonce
    function mintNew(MintOffer calldata offer, MintOfferAttestation calldata attestation, uint amount) external payable {
        require(offer.startDate < block.timestamp, "startDate");
        address seller = _verifySellMintOffer(offer);
        uint nftId = nonceToNftId[seller][offer.nonce];
        if(nftId != 0){
            mint(amount, offer.nftContract, nftId >> 1, offer.cost, offer.startDate, offer.endDate, offer.maxToMint, offer.maxPerWallet, seller, offer.merkleRoot);
            return;
        }
        
        uint mintedNftId = verifyNewMint(offer, attestation, amount, seller, offer.cost);
        checkMaxPerWallet(offer.nftContract, mintedNftId, amount, offer.maxPerWallet);
    }

    function mintNewWithMerkle(MintOffer calldata offer, MintOfferAttestation calldata attestation, uint amount,
            bytes32[] calldata merkleProof, MerkleLeaf calldata merkleLeaf) external payable {
        require(merkleLeaf.startDate < block.timestamp, "startDate");
        address seller = _verifySellMintOffer(offer);
        uint nftId = nonceToNftId[seller][offer.nonce];
        if(nftId != 0){
            mintWithMerkle(amount, offer.nftContract, nftId >> 1, offer.cost, offer.startDate, offer.endDate, offer.maxToMint, offer.maxPerWallet, seller, offer.merkleRoot, 
                merkleProof, merkleLeaf);
            return;
        }
        
        uint mintedNftId = verifyNewMint(offer, attestation, amount, seller, merkleLeaf.cost);
        checkMerkle(offer.nftContract, mintedNftId, amount, offer.merkleRoot, merkleProof, merkleLeaf);
    }

    event MintStopped(bytes32 editionHash);

    function stopMint(address nftContract, uint nftId, uint cost, uint startDate, uint endDate, uint maxToMint, uint maxPerWallet, address seller, bytes32 merkleRoot) public nftAdmin(nftContract) {
        bytes32 editionHash = calculateEditionHash(nftContract, nftId, cost, startDate, endDate, maxToMint, maxPerWallet, seller, merkleRoot);
        editionsMinted[editionHash] = type(uint256).max;
        emit MintStopped(editionHash);
    }

    // Shouldn't be used to change numbers on an active mint because it can be frontran
    function createMint(address nftContract, uint nftId, uint cost, uint startDate, uint endDate, uint maxToMint, uint maxPerWallet, bytes32 merkleRoot, uint minted) public nftAdmin(nftContract) {
        require(minted > 0, "minted > 0");
        bytes32 editionHash = calculateEditionHash(nftContract, nftId, cost, startDate, endDate, maxToMint, maxPerWallet, msg.sender, merkleRoot);
        editionsMinted[editionHash] = minted;
        emit MintCreated(nftContract, nftId, cost, startDate, endDate, maxToMint, maxPerWallet, msg.sender, merkleRoot);
    }

    function editMint(address nftContract, uint nftId, uint cost, uint startDate, uint endDate, uint maxToMint, uint maxPerWallet, bytes32 merkleRoot,
            uint newCost, uint newStartDate, uint newEndDate, uint newMaxToMint, uint newMaxPerWallet, bytes32 newMerkleRoot) external {
        // Could be optimized by removing duplicated code between stop and create calls, but would rather keep it simple
        bytes32 oldEditionHash = calculateEditionHash(nftContract, nftId, cost, startDate, endDate, maxToMint, maxPerWallet, msg.sender, merkleRoot);
        uint minted = editionsMinted[oldEditionHash];
        stopMint(nftContract, nftId, cost, startDate, endDate, maxToMint, maxPerWallet, msg.sender, merkleRoot);
        createMint(nftContract, nftId, newCost, newStartDate, newEndDate, newMaxToMint, newMaxPerWallet, newMerkleRoot, minted);
    }

    struct MerkleLeaf {
        address mintFor;
        uint startDate;
        uint cost;
        uint maxMint;
    }

    function checkMerkle(address nftContract, uint nftId, uint amount,
            bytes32 merkleRoot, bytes32[] calldata merkleProof, MerkleLeaf calldata merkleLeaf) internal {
        if (merkleLeaf.mintFor != msg.sender) {
            IDelegationRegistry dr = IDelegationRegistry(0x00000000000000447e69651d841bD8D104Bed493);
            require(dr.checkDelegateForContract(msg.sender, merkleLeaf.mintFor, address(this), ""), "Invalid delegate");
        }
        bytes32 leaf = keccak256(abi.encode(merkleLeaf));
        require(MerkleProof.verifyCalldata(merkleProof, merkleRoot, leaf), "bad merkle proof");
        uint minted = nftsMintedByAddress[nftContract][nftId][merkleLeaf.mintFor];
        minted += amount;
        nftsMintedByAddress[nftContract][nftId][merkleLeaf.mintFor] = minted;
        require(minted <= merkleLeaf.maxMint, ">maxMint");
    }

    function mintWithMerkle(uint amount, address nftContract, uint nftId, uint cost, uint startDate, uint endDate, uint maxToMint, uint maxPerWallet, address seller, bytes32 merkleRoot,
            bytes32[] calldata merkleProof, MerkleLeaf calldata merkleLeaf) payable public {
        bytes32 editionHash = calculateEditionHash(nftContract, nftId, cost, startDate, endDate, maxToMint, maxPerWallet, seller, merkleRoot);
        mintExisting(editionHash, amount, nftContract, nftId, merkleLeaf.cost, merkleLeaf.startDate, endDate, maxToMint, seller);
        checkMerkle(nftContract, nftId, amount, merkleRoot, merkleProof, merkleLeaf);
    }

    function mintExisting(bytes32 editionHash, uint amount, address nftContract, uint nftId, uint cost, uint startDate, uint endDate, uint maxToMint, address seller) internal {
        uint minted = editionsMinted[editionHash];
        uint newMinted = minted + amount;
        require(newMinted <= maxToMint && minted > 0, ">maxToMint"); // not doing require() after write to save gas for ppl that go over limit
        require(block.timestamp > startDate, "<startDate");
        require(block.timestamp <= endDate, ">endDate");
        editionsMinted[editionHash] = newMinted;
        _distributePrimarySale(cost, amount, payable(seller));

        address[] memory to = new address[](1);
        to[0] = msg.sender;
        uint[] memory tokenIds = new uint[](1);
        tokenIds[0] = nftId;
        uint[] memory amounts = new uint[](1);
        amounts[0] = amount;
        UserCollection(nftContract).mintExtensionExisting(to, tokenIds, amounts);
        emit Mint(nftContract, nftId, amount, cost, seller, msg.sender);
    }

    function mint(uint amount, address nftContract, uint nftId, uint cost, uint startDate, uint endDate, uint maxToMint, uint maxPerWallet, address seller, bytes32 merkleRoot) payable public {
        bytes32 editionHash = calculateEditionHash(nftContract, nftId, cost, startDate, endDate, maxToMint, maxPerWallet, seller, merkleRoot);
        mintExisting(editionHash, amount, nftContract, nftId, cost, startDate, endDate, maxToMint, seller);
        checkMaxPerWallet(nftContract, nftId, amount, maxPerWallet);
    }
    
    event Airdropped(address nftContract, uint nftId, address seller, address[] recipients, uint256[] amounts);

    function airdrop(address nftContract, uint nftId, uint cost, uint startDate, uint endDate, uint maxToMint, uint maxPerWallet, address seller, bytes32 merkleRoot,
        address[] calldata recipients, uint256[] calldata amounts) external nftAdmin(nftContract) {
        require(recipients.length == amounts.length, "Unequal number of recipients and amounts provided");

        uint256 totalAmount;
        for (uint256 i; i < amounts.length;) {
            totalAmount += amounts[i];
            unchecked{ ++i; }
        }

        bytes32 editionHash = calculateEditionHash(nftContract, nftId, cost, startDate, endDate, maxToMint, maxPerWallet, seller, merkleRoot);
        uint minted = editionsMinted[editionHash];
        uint newMinted = minted + totalAmount;
        require(newMinted <= maxToMint && minted > 0, ">maxToMint");
        editionsMinted[editionHash] = newMinted;

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = nftId;
        UserCollection(nftContract).mintExtensionExisting(recipients, tokenIds, amounts);
        emit Airdropped(nftContract, nftId, msg.sender, recipients, amounts);
    }
}