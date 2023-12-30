pragma solidity ^0.8.7;

import "./EIP712-2.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import {BitMaps} from "@openzeppelin/contracts/utils/structs/BitMaps.sol";

interface UserCollection {
    function mintExtension(address to, string calldata uri) external returns (uint256);
    function owner() external view returns (address);
}
interface ISealedPool {
    function deposit(address receiver) external payable;
}

contract SealedArtMarket is EIP712, Ownable {
    using BitMaps for BitMaps.BitMap;

    // sequencer and settleSequencer are separated as an extra security measure against key leakage through side attacks
    // If a side channel attack is possible that requires multiple signatures to be made, settleSequencer will be more protected
    // against it because each signature will require an onchain action, which will make the attack extremely expensive
    // It also allows us to use different security systems for the two keys, since settleSequencer is much more sensitive
    address public sequencer; // Invariant: always different than address(0)
    address public settleSequencer; // Invariant: always different than address(0)
    address payable public treasury;
    uint256 internal constant MAX_PROTOCOL_FEE = 0.1e18; // 10%
    uint256 public feeMultiplier;
    ISealedPool public immutable sealedPool;

    mapping(address => bool) public guardians;

    mapping(address => BitMaps.BitMap) private usedOrderNonces;
    mapping(address => uint256) public accountCounter;

    constructor(address _sequencer, address payable _treasury, address _settleSequencer, ISealedPool _sealedPool) {
        require(_sequencer != address(0) && _settleSequencer != address(0), "0x0 sequencer not allowed");
        sequencer = _sequencer;
        treasury = _treasury;
        settleSequencer = _settleSequencer;
        sealedPool = _sealedPool;
    }

    event SequencerChanged(address newSequencer, address newSettleSequencer);

    function changeSequencer(address newSequencer, address newSettleSequencer) external onlyOwner {
        require(newSequencer != address(0) && newSettleSequencer != address(0), "0x0 sequencer not allowed");
        sequencer = newSequencer;
        settleSequencer = newSettleSequencer;
        emit SequencerChanged(newSequencer, newSettleSequencer);
    }

    event TreasuryChanged(address newTreasury);

    function changeTreasury(address payable newTreasury) external onlyOwner {
        treasury = newTreasury;
        emit TreasuryChanged(newTreasury);
    }

    event GuardianSet(address guardian, bool value);

    function setGuardian(address guardian, bool value) external onlyOwner {
        guardians[guardian] = value;
        emit GuardianSet(guardian, value);
    }

    event SequencerDisabled(address guardian);

    function emergencyDisableSequencer() external {
        require(guardians[msg.sender] == true, "not guardian");
        // Maintain the invariant that sequencers are not 0x0
        sequencer = address(0x000000000000000000000000000000000000dEaD);
        settleSequencer = address(0x000000000000000000000000000000000000dEaD);
        emit SequencerDisabled(msg.sender);
    }

    event FeeChanged(uint256 newFeeMultiplier);

    function changeFee(uint256 newFeeMultiplier) external onlyOwner {
        require(newFeeMultiplier <= MAX_PROTOCOL_FEE, "fee too high");
        feeMultiplier = newFeeMultiplier;
        emit FeeChanged(newFeeMultiplier);
    }

    function _transferETH(address payable receiver, uint256 amount) internal {
        (bool success,) = receiver.call{value: amount, gas: 300_000}("");
        if (success == false) {
            sealedPool.deposit{value:amount}(receiver);
        }
    }

    function _distributePrimarySale(uint256 amount, address payable seller) internal {
        uint256 feeAmount = (amount * feeMultiplier) / 1e18;
        _transferETH(treasury, feeAmount);
        _transferETH(seller, amount - feeAmount);
    }

    event CounterIncreased(address account, uint256 newCounter);

    function increaseCounter(uint256 newCounter) external {
        require(newCounter > accountCounter[msg.sender], "too low");
        accountCounter[msg.sender] = newCounter;
        emit CounterIncreased(msg.sender, newCounter);
    }

    event OfferCancelled(address account, uint256 nonce);

    function cancelOffer(uint256 nonce) external {
        usedOrderNonces[msg.sender].set(nonce);
        emit OfferCancelled(msg.sender, nonce);
    }

    function _verifyMintOffer(MintOffer memory offer, address creator) view private {
        require(offer.deadline > block.timestamp, "!deadline");
        require(offer.counter > accountCounter[creator], "!counter");
    }

    function _verifyMintOfferAlways(MintOffer memory offer, address creator) private {
        require(orderNonces(creator, offer.nonce) == false, "!orderNonce");
        usedOrderNonces[msg.sender].set(offer.nonce);
    }

    function _verifyBuyerMintOfferAlways(BuyerMintOffer memory offer, address creator) private {
        require(orderNonces(creator, offer.nonce) == false, "!orderNonce");
        usedOrderNonces[msg.sender].set(offer.nonce);
    }

    event MintSale(address buyer, address seller, uint256 amount, address nftContract, string uri);

    fallback(bytes calldata data) external payable returns (bytes memory){
       (address caller,
        address buyer,
        uint sequencerRank,
        BuyerMintOffer memory buyerOffer,
        MintOffer memory sellerOffer,
        MintOfferAttestation memory sequencerStamp,
        address nftContract,
        string memory uri) = abi.decode(data, (address, address, uint, BuyerMintOffer, MintOffer, MintOfferAttestation, address, string));

        require(msg.sender == address(sealedPool) && sequencerRank == 2);
        if (caller != buyer) {
            require(buyerOffer.counter > accountCounter[buyer], "!counter");
        }
        _verifyBuyerMintOfferAlways(buyerOffer, buyer);
        if (caller != sequencerStamp.seller) {
            _verifyMintOffer(sellerOffer, sequencerStamp.seller);
            require(
                _verifySellMintOffer(sellerOffer) == sequencerStamp.seller && sequencerStamp.seller != address(0), "!seller"
            );
        }
        _verifyMintOfferAlways(sellerOffer, sequencerStamp.seller);
        bytes32 mintHash = keccak256(abi.encode(nftContract, uri));
        require(mintHash == sellerOffer.mintHash && mintHash == buyerOffer.mintHash, "!mintHash");

        require(UserCollection(nftContract).owner() == sequencerStamp.seller, "!owner");
        require(msg.value >= sellerOffer.amount, "!amount");

        UserCollection(nftContract).mintExtension(buyer, uri);
        _distributePrimarySale(msg.value, payable(sequencerStamp.seller)); // skip royalties since its a primary sale
        emit MintSale(buyer, sequencerStamp.seller, msg.value, nftContract, uri);
    }

    function orderNonces(address account, uint256 nonce) public view returns (bool) {
        return usedOrderNonces[account].get(nonce);
    }
}
