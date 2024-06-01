pragma solidity ^0.8.7;

import "./EIP712.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import {BitMaps} from "@openzeppelin/contracts/utils/structs/BitMaps.sol";

interface IERC721 {
    function ownerOf(uint256 _tokenId) external view returns (address);
    function transferFrom(address _from, address _to, uint256 _tokenId) external;
}

interface RoyaltyEngine {
    function getRoyalty(address tokenAddress, uint256 tokenId, uint256 value)
        external
        returns (address payable[] memory recipients, uint256[] memory amounts);
}

interface ISealedPool {
    function deposit(address user) external payable;
}

contract Auctions is EIP712, Ownable {
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
    uint256 public forcedWithdrawDelay = 2 days;
    RoyaltyEngine public constant royaltyEngine = RoyaltyEngine(0xEF770dFb6D5620977213f55f99bfd781D04BBE15);
    ISealedPool public immutable sealedPool;

    enum AuctionState {
        NONE, // 0 -> doesnt exist, default state
        CREATED,
        CLOSED
    }

    mapping(bytes32 => AuctionState) public auctionState;
    mapping(bytes32 => uint256) public pendingAuctionCancels;
    mapping(address => bool) public guardians;

    mapping(address => BitMaps.BitMap) private usedOrderNonces;
    mapping(address => uint256) public accountCounter;

    constructor(address _sequencer, address payable _treasury, address _settleSequencer, address _sealedPool) {
        require(_sequencer != address(0) && _settleSequencer != address(0), "0x0 sequencer not allowed");
        sequencer = _sequencer;
        treasury = _treasury;
        settleSequencer = _settleSequencer;
        sealedPool = ISealedPool(_sealedPool);
    }

    event SequencerChanged(address newSequencer, address newSettleSequencer);

    function changeSequencer(address newSequencer, address newSettleSequencer) external onlyOwner {
        require(newSequencer != address(0) && newSettleSequencer != address(0), "0x0 sequencer not allowed");
        sequencer = newSequencer;
        settleSequencer = newSettleSequencer;
        emit SequencerChanged(newSequencer, newSettleSequencer);
    }

    event ForcedWithdrawDelayChanged(uint256 newDelay);

    function changeForcedWithdrawDelay(uint256 newDelay) external onlyOwner {
        require(newDelay < 10 days, "<10 days");
        forcedWithdrawDelay = newDelay;
        emit ForcedWithdrawDelayChanged(newDelay);
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

    function calculateAuctionHash(
        address owner,
        address nftContract,
        bytes32 auctionType,
        uint256 nftId,
        uint256 reserve
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(owner, nftContract, auctionType, nftId, reserve));
    }

    event AuctionCreated(
        address owner, address nftContract, uint256 auctionDuration, bytes32 auctionType, uint256 nftId, uint256 reserve
    );

    function _createAuction(
        address nftContract,
        uint256 auctionDuration,
        bytes32 auctionType,
        uint256 nftId,
        uint256 reserve
    ) internal {
        bytes32 auctionId = calculateAuctionHash(msg.sender, nftContract, auctionType, nftId, reserve);
        require(auctionState[auctionId] == AuctionState.NONE, "repeated auction id"); // maybe this is not needed?
        auctionState[auctionId] = AuctionState.CREATED;
        emit AuctionCreated(msg.sender, nftContract, auctionDuration, auctionType, nftId, reserve);
    }

    function createAuction(
        address nftContract,
        uint256 auctionDuration,
        bytes32 auctionType,
        uint256 nftId,
        uint256 reserve
    ) external {
        IERC721(nftContract).transferFrom(msg.sender, address(this), nftId);
        _createAuction(nftContract, auctionDuration, auctionType, nftId, reserve);
    }

    event AuctionCancelled(bytes32 auctionId);

    function _cancelAuction(
        address nftContract,
        bytes32 auctionType,
        uint256 nftId,
        uint256 reserve,
        CancelAuction calldata cancelAuctionPacket
    ) internal {
        require(_verifyCancelAuction(cancelAuctionPacket) == sequencer, "!sequencer");
        bytes32 auctionId = calculateAuctionHash(msg.sender, nftContract, auctionType, nftId, reserve);
        require(auctionState[auctionId] == AuctionState.CREATED, "bad state");
        require(cancelAuctionPacket.auctionId == auctionId, "!auctionId");
        auctionState[auctionId] = AuctionState.CLOSED;
        emit AuctionCancelled(auctionId);
    }

    function cancelAuction(
        address nftContract,
        bytes32 auctionType,
        uint256 nftId,
        uint256 reserve,
        CancelAuction calldata cancelAuctionPacket
    ) external {
        _cancelAuction(nftContract, auctionType, nftId, reserve, cancelAuctionPacket);
        IERC721(nftContract).transferFrom(address(this), msg.sender, nftId);
    }

    function changeAuction(
        address nftContract,
        bytes32 auctionType,
        uint256 nftId,
        uint256 reserve,
        uint256 newAuctionDuration,
        bytes32 newAuctionType,
        uint256 newReserve,
        CancelAuction calldata cancelAuctionPacket
    ) external {
        _cancelAuction(nftContract, auctionType, nftId, reserve, cancelAuctionPacket);
        _createAuction(nftContract, newAuctionDuration, newAuctionType, nftId, newReserve);
    }

    event StartDelayedAuctionCancel(bytes32 auctionId);

    function startCancelAuction(
        address nftContract,
        bytes32 auctionType,
        uint256 nftId,
        uint256 reserve
    ) external {
        bytes32 auctionId = calculateAuctionHash(msg.sender, nftContract, auctionType, nftId, reserve);
        require(auctionState[auctionId] == AuctionState.CREATED, "bad auction state");
        pendingAuctionCancels[auctionId] = block.timestamp;
        emit StartDelayedAuctionCancel(auctionId);
    }

    event ExecuteDelayedAuctionCancel(bytes32 auctionId);

    function executeCancelAuction(
        address nftContract,
        bytes32 auctionType,
        uint256 nftId,
        uint256 reserve
    ) external {
        bytes32 auctionId = calculateAuctionHash(msg.sender, nftContract, auctionType, nftId, reserve);
        uint256 timestamp = pendingAuctionCancels[auctionId];
        require(timestamp != 0 && (timestamp + forcedWithdrawDelay) < block.timestamp, "too soon");
        require(auctionState[auctionId] == AuctionState.CREATED, "not open");
        auctionState[auctionId] = AuctionState.CLOSED;
        pendingAuctionCancels[auctionId] = 0;
        emit AuctionCancelled(auctionId);
        IERC721(nftContract).transferFrom(address(this), msg.sender, nftId);
        emit ExecuteDelayedAuctionCancel(auctionId);
    }

    function _transferETH(address payable receiver, uint256 amount) internal {
        (bool success,) = receiver.call{value: amount, gas: 300_000}("");
        if (success == false) {
            sealedPool.deposit{value: amount}(receiver);
        }
    }

    function _distributeSale(address nftContract, uint256 nftId, uint256 amount, address payable seller) internal {
        uint256 totalRoyalty = 0;
        try royaltyEngine.getRoyalty{gas: 500_000}(nftContract, nftId, amount) returns (address payable[] memory recipients, uint256[] memory amounts) {
            uint length = 5; // Use a maximum of 5 items to avoid attacks that blow up gas limit
            if(recipients.length < length){
                length = recipients.length;
            }
            if(amounts.length < length){
                length = amounts.length;
            }
            for (uint256 i; i < length;) {
                _transferETH(recipients[i], amounts[i]);
                totalRoyalty += amounts[i];
                unchecked {
                    ++i;
                }
            }
            require(totalRoyalty <= (amount / 3), "Royalty too high"); // Protect against royalty hacks
        } catch {}
        uint256 feeAmount = (amount * feeMultiplier) / 1e18;
        _transferETH(treasury, feeAmount);
        _transferETH(seller, amount - (totalRoyalty + feeAmount)); // totalRoyalty+feeAmount <= amount*0.43
    }

    event AuctionSettled(bytes32 auctionId, address nftContract, uint tokenId, address seller, address buyer, uint price);

    function settleAuction(
        address caller,
        address buyer,
        uint sequencerRank,
        uint,
        uint,
        uint,
        Bid calldata bid,
        uint,
        SequencerStamp calldata sequencerStamp
    ) external payable {
        require(msg.sender == address(sealedPool) && sequencerRank == 1, "!auth");
        bytes32 auctionId = calculateAuctionHash(sequencerStamp.nftOwner, sequencerStamp.nftContract, sequencerStamp.auctionType, sequencerStamp.nftId, sequencerStamp.reserve);
        require(auctionState[auctionId] == AuctionState.CREATED, "bad auction state");
        auctionState[auctionId] = AuctionState.CLOSED;
        require(bid.auctionId == auctionId, "!auctionId");
        require(msg.value >= sequencerStamp.reserve, "<reserve");
        IERC721(sequencerStamp.nftContract).transferFrom(address(this), buyer, sequencerStamp.nftId);
        _distributeSale(sequencerStamp.nftContract, sequencerStamp.nftId, msg.value, sequencerStamp.nftOwner);
        emit AuctionSettled(auctionId, sequencerStamp.nftContract, sequencerStamp.nftId, sequencerStamp.nftOwner, buyer, msg.value);
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

    function _verifyOffer(Offer calldata offer, address creator) private {
        require(offer.deadline > block.timestamp, "!deadline");
        require(orderNonces(creator, offer.nonce) == false, "!orderNonce");
        usedOrderNonces[msg.sender].set(offer.nonce);
        require(offer.counter > accountCounter[creator], "!counter");
    }

    event OrdersMatched(bytes32 auctionId, address nftContract, uint tokenId, address seller, address buyer, uint price, uint256 sellerNonce, uint256 buyerNonce);

    function matchOrders(
        Offer calldata sellerOffer,
        Offer calldata buyerOffer,
        OfferAttestation calldata sequencerStamp,
        address nftContract,
        bytes32 auctionType,
        uint256 nftId,
        uint256 reserve
    ) external {
        // First run verifications that can fail due to a delayed tx
        require(sequencerStamp.deadline > block.timestamp, "!deadline");
        if (msg.sender != sequencerStamp.buyer) {
            _verifyOffer(buyerOffer, sequencerStamp.buyer);
            require(_verifyBuyOffer(buyerOffer) == sequencerStamp.buyer && sequencerStamp.buyer != address(0), "!buyer");
        }
        if (msg.sender != sequencerStamp.seller) {
            _verifyOffer(sellerOffer, sequencerStamp.seller);
            require(
                _verifySellOffer(sellerOffer) == sequencerStamp.seller && sequencerStamp.seller != address(0), "!seller"
            );
        }
        // Verify NFT is owned by seller
        bytes32 auctionId = calculateAuctionHash(
            sequencerStamp.seller,
            nftContract,
            auctionType,
            nftId,
            reserve
        );
        require(auctionState[auctionId] == AuctionState.CREATED && sequencerStamp.auctionId == auctionId, "bad auction state");
        // Execute sale
        auctionState[auctionId] = AuctionState.CLOSED;

        // Run verifications that can't fail due to external factors
        require(sequencerStamp.amount == sellerOffer.amount && sequencerStamp.amount == buyerOffer.amount, "!amount");
        require(
            nftContract == sellerOffer.nftContract
                && nftContract == buyerOffer.nftContract,
            "!nftContract"
        );
        require(nftId == sellerOffer.nftId && nftId == buyerOffer.nftId, "!nftId");
        require(_verifyOfferAttestation(sequencerStamp) == sequencer, "!sequencer"); // This needs sequencer approval to avoid someone rugging their bids by buying another NFT

        // Finish executing sale
        IERC721(nftContract).transferFrom(address(this), sequencerStamp.buyer, nftId);
        _distributeSale(
            nftContract, nftId, sequencerStamp.amount, payable(sequencerStamp.seller)
        );
        emit OrdersMatched(auctionId, nftContract, nftId, sequencerStamp.seller, sequencerStamp.buyer, sequencerStamp.amount, sellerOffer.nonce, buyerOffer.nonce);
    }

    function orderNonces(address account, uint256 nonce) public view returns (bool) {
        return usedOrderNonces[account].get(nonce);
    }
}
