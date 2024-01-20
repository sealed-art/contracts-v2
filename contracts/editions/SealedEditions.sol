pragma solidity ^0.8.7;

import "./EIP712Editions.sol";
import "../shared/Nonces.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import {BitMaps} from "@openzeppelin/contracts/utils/structs/BitMaps.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

interface UserCollection {
    function mintExtensionNew(address[] calldata to, uint256[] calldata amounts, string[] calldata uris) external returns (uint256[] memory);
    function mintExtensionExisting(address[] calldata to, uint256[] calldata tokenIds, uint256[] calldata amounts) external;
    function owner() external view returns (address);
}

interface IDelegationRegistry {
    function checkDelegateForContract(address delegate, address vault, address contract_) external view returns (bool);
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

    function changeAdminConfig(address _sequencer, uint _feeMultiplier) external onlyOwner {
        require(_sequencer != address(0), "0x0 sequencer not allowed");
        sequencer = _sequencer;
        require(_feeMultiplier >= MIN_WITHOUT_FEE && _feeMultiplier <= 1e18, ">MAX_PROTOCOL_FEE");
        feeMultiplier = _feeMultiplier;
    }

    function withdrawFees(address payable receiver) external onlyOwner(){
        _transferETH(receiver, address(this).balance);
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

    function calculateEditionHash(address nftContract, uint nftId, uint cost, uint startDate, uint endDate, uint maxToMint, address seller, bytes32 merkleRoot) pure public returns (bytes32) {
        return keccak256(abi.encode(nftContract, nftId, cost, startDate, endDate, maxToMint, seller, merkleRoot));
    }

    event OfferCancelled(address account, uint256 nonce);

    function cancelOffer(uint256 nonce) external {
        nonceToNftId[msg.sender][nonce] = 1;
        emit OfferCancelled(msg.sender, nonce);
    }

    event Mint(address nftContract, uint tokenId, uint amount, uint price, address seller, address buyer);

    function verifyNewMint(MintOffer calldata offer, MintOfferAttestation calldata attestation, uint amount, address seller, uint realCost) internal returns (uint nftId){
        require(amount > 0, "amount != 0");
        nonceToNftId[seller][offer.nonce] = 1; // temporary value to avoid reentrancy
        require(seller != address(0) && seller == UserCollection(offer.nftContract).owner(), "!auth");
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
            offer.merkleRoot,
            offer.deadline,
            offer.counter,
            offer.nonce
        )), "!offerHash");
        require(attestation.deadline > block.timestamp && offer.deadline > block.timestamp && offer.endDate > block.timestamp, ">deadline");
        require(_verifyAttestation(attestation) == sequencer, "!sequencer"); // No need to check against address(0) because sequencer will never be 0x0

        address[] memory to = new address[](1);
        to[0] = msg.sender;
        uint[] memory amounts = new uint[](1);
        amounts[0] = amount;
        string[] memory uris = new string[](1);
        uris[0] = offer.uri;
        uint[] memory nftIds = UserCollection(offer.nftContract).mintExtensionNew(to, amounts, uris); // if its an ipfs uri, separating prefix doesnt improve gas

        nonceToNftId[seller][offer.nonce] = (nftIds[0] << 1) | 1; // assumes nftId will always be < 2**254
        bytes32 editionHash = calculateEditionHash(offer.nftContract, nftIds[0], offer.cost, offer.startDate, offer.endDate, offer.maxToMint, seller, offer.merkleRoot);
        editionsMinted[editionHash] += amount;
        require(editionsMinted[editionHash] <= offer.maxToMint, ">maxToMint");
        _distributePrimarySale(realCost, amount, payable(seller));
        emit Mint(offer.nftContract, nftIds[0], amount, realCost, seller, msg.sender);
        return nftIds[0];
    }

    // IMPORTANT: All modifications to the same offer should reuse the same nonce
    function mintNew(MintOffer calldata offer, MintOfferAttestation calldata attestation, uint amount) external payable {
        address seller = _verifySellMintOffer(offer);
        uint nftId = nonceToNftId[seller][offer.nonce];
        if(nftId != 0){
            mint(amount, offer.nftContract, nftId >> 1, offer.cost, offer.startDate, offer.endDate, offer.maxToMint, seller, offer.merkleRoot);
            return;
        }
        require(offer.startDate < block.timestamp, "startDate");
        
        verifyNewMint(offer, attestation, amount, seller, offer.cost);
    }

    function mintNewWithMerkle(MintOffer calldata offer, MintOfferAttestation calldata attestation, uint amount,
            bytes32[] calldata merkleProof, address mintFor, uint wlStartDate, uint wlCost, uint wlMaxMint) external payable {
        address seller = _verifySellMintOffer(offer);
        uint nftId = nonceToNftId[seller][offer.nonce];
        if(nftId != 0){
            mintWithMerkle(amount, offer.nftContract, nftId >> 1, offer.cost, offer.startDate, offer.endDate, offer.maxToMint, seller, offer.merkleRoot, 
                merkleProof, mintFor, wlStartDate, wlCost, wlMaxMint);
            return;
        }
        require(wlStartDate < block.timestamp, "startDate");
        uint mintedNftId = verifyNewMint(offer, attestation, amount, seller, wlCost);
        checkMerkle(offer.nftContract, mintedNftId, amount, offer.merkleRoot, merkleProof, mintFor, wlStartDate, wlCost, wlMaxMint);
    }

    event MintStopped(bytes32 editionHash);

    function stopMint(address nftContract, uint nftId, uint cost, uint startDate, uint endDate, uint maxToMint, bytes32 merkleRoot) public {
        require(msg.sender == UserCollection(nftContract).owner(), "!auth");
        bytes32 editionHash = calculateEditionHash(nftContract, nftId, cost, startDate, endDate, maxToMint, msg.sender, merkleRoot);
        editionsMinted[editionHash] = type(uint256).max;
        emit MintStopped(editionHash);
    }

    event NewMint(address nftContract, uint nftId, uint cost, uint startDate, uint endDate, uint maxToMint, address seller, bytes32 merkleRoot);
    function editMint(address nftContract, uint nftId, uint cost, uint startDate, uint endDate, uint maxToMint, bytes32 merkleRoot,
            uint newCost, uint newStartDate, uint newEndDate, uint newMaxToMint, bytes32 newMerkleRoot) external {
        bytes32 oldEditionHash = calculateEditionHash(nftContract, nftId, cost, startDate, endDate, maxToMint, msg.sender, merkleRoot);
        bytes32 newEditionHash = calculateEditionHash(nftContract, nftId, newCost, newStartDate, newEndDate, newMaxToMint, msg.sender, newMerkleRoot);
        editionsMinted[newEditionHash] = editionsMinted[oldEditionHash];
        stopMint(nftContract, nftId, cost, startDate, endDate, maxToMint, merkleRoot);
        emit NewMint(nftContract, nftId, newCost, newStartDate, newEndDate, newMaxToMint, msg.sender, newMerkleRoot);
    }

    function checkMerkle(address nftContract, uint nftId, uint amount,
            bytes32 merkleRoot, bytes32[] calldata merkleProof, address mintFor, uint startDate, uint cost, uint maxMint) internal {
        if (mintFor != msg.sender) {
            IDelegationRegistry dr = IDelegationRegistry(0x00000000000076A84feF008CDAbe6409d2FE638B);
            require(dr.checkDelegateForContract(msg.sender, mintFor, address(this)), "Invalid delegate");
        }
        bytes32 leaf = keccak256(abi.encode(mintFor, startDate, cost, maxMint));
        require(MerkleProof.verifyCalldata(merkleProof, merkleRoot, leaf), "bad merkle proof");
        nftsMintedByAddress[nftContract][nftId][mintFor] += amount;
        require(nftsMintedByAddress[nftContract][nftId][mintFor] <= maxMint, ">maxMint");
    }

    function mintWithMerkle(uint amount, address nftContract, uint nftId, uint cost, uint startDate, uint endDate, uint maxToMint, address seller, bytes32 merkleRoot,
            bytes32[] calldata merkleProof, address mintFor, uint wlStartDate, uint wlCost, uint wlMaxMint) payable public {
        checkMerkle(nftContract, nftId, amount, merkleRoot, merkleProof, mintFor, wlStartDate, wlCost, wlMaxMint);
        bytes32 editionHash = calculateEditionHash(nftContract, nftId, cost, startDate, endDate, maxToMint, seller, merkleRoot);
        mintExisting(editionHash, amount, nftContract, nftId, wlCost, wlStartDate, endDate, maxToMint, seller);
    }

    function mintExisting(bytes32 editionHash, uint amount, address nftContract, uint nftId, uint cost, uint startDate, uint endDate, uint maxToMint, address seller) internal {
        require(block.timestamp > startDate, "<startDate");
        uint minted = editionsMinted[editionHash];
        require(minted + amount <= maxToMint && minted > 0, ">maxToMint"); // not doing require() after write to save gas for ppl that go over limit
        require(block.timestamp <= endDate, ">endDate");
        editionsMinted[editionHash] += amount;
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

    function mint(uint amount, address nftContract, uint nftId, uint cost, uint startDate, uint endDate, uint maxToMint, address seller, bytes32 merkleRoot) payable public {
        bytes32 editionHash = calculateEditionHash(nftContract, nftId, cost, startDate, endDate, maxToMint, seller, merkleRoot);
        mintExisting(editionHash, amount, nftContract, nftId, cost, startDate, endDate, maxToMint, seller);
    }
}