pragma solidity ^0.8.7;

import "./EIP712.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "../funding/SealedFundingFactory.sol";
import {BitMaps} from "@openzeppelin/contracts/utils/structs/BitMaps.sol";

interface OldSealedMarket {
    function deposit(address user) external payable;
    struct Bid {
        uint8 v;
        bytes32 r;
        bytes32 s;
        bytes32 auctionId;
        uint256 maxAmount;
    }
    struct BidWinner {
        uint8 v;
        bytes32 r;
        bytes32 s;
        bytes32 auctionId;
        uint256 amount;
        address winner;
    }
    function settleAuctionWithSealedBids(
        bytes32[] calldata salts,
        address payable nftOwner,
        address nftContract,
        bytes32 auctionType,
        uint256 nftId,
        uint256 reserve,
        Bid calldata bid,
        BidWinner calldata bidWinner
    ) external;
}

contract SealedPool is EIP712, Ownable {
    using BitMaps for BitMaps.BitMap;

    event Transfer(address indexed from, address indexed to, uint256 value);

    mapping(address => uint256) private _balances;
    string public constant name = "Sealed ETH";
    string public constant symbol = "SETH";
    uint8 public constant decimals = 18;

    function totalSupply() public view returns (uint256) {
        return address(this).balance;
    }

    // having multiple separated sequencers by rank is an extra security measure against key leakage through side attacks
    // If a side channel attack is possible that requires multiple signatures to be made, higher rank sequencers will be more protected
    // against it because each signature will require an onchain action, which will make the attack extremely expensive
    // It also allows us to use different security systems for the multiple sequencer keys
    mapping(address => uint256) public sequencers; // Invariant: sequencer[address(0)] == 0 always
    SealedFundingFactory public immutable sealedFundingFactory;
    OldSealedMarket private constant oldSealedMarket = OldSealedMarket(0x2cBe14b7F60Fbe6A323cBA7Db56f2D916C137F3C);
    uint256 public forcedWithdrawDelay = 7 days;

    mapping(address => mapping(uint256 => mapping(uint256 => uint256)))
        public pendingWithdrawals;
    mapping(address => bool) public guardians;

    BitMaps.BitMap private usedNonces;

    //mapping(address => BitMaps.BitMap) private usedOrderNonces;
    //mapping(address => uint256) public accountCounter;

    function balanceOf(address account) public view returns (uint256) {
        return _balances[account];
    }

    constructor(address _sequencer) {
        require(_sequencer != address(0), "0x0 sequencer not allowed");
        sequencers[_sequencer] = 1;
        sealedFundingFactory = new SealedFundingFactory(address(this));
    }

    event SequencerChanged(address sequencer, uint rank);

    function changeSequencer(address sequencer, uint rank) external onlyOwner {
        require(sequencer != address(0), "0x0 sequencer not allowed");
        sequencers[sequencer] = rank;
        emit SequencerChanged(sequencer, rank);
    }

    event ForcedWithdrawDelayChanged(uint256 newDelay);

    function changeForcedWithdrawDelay(uint256 newDelay) external onlyOwner {
        require(newDelay < 10 days, "<10 days");
        forcedWithdrawDelay = newDelay;
        emit ForcedWithdrawDelayChanged(newDelay);
    }

    event GuardianSet(address guardian, bool value);

    function setGuardian(address guardian, bool value) external onlyOwner {
        guardians[guardian] = value;
        emit GuardianSet(guardian, value);
    }

    event SequencerDisabled(address guardian, address sequencer);

    function emergencyDisableSequencer(address sequencer) external {
        require(guardians[msg.sender] == true, "not guardian");
        sequencers[sequencer] = 0; // Maintains the invariant that sequencers[0] == 0
        emit SequencerDisabled(msg.sender, sequencer);
    }

    function deposit(address receiver) public payable {
        _balances[receiver] += msg.value;
        emit Transfer(address(0), receiver, msg.value);
    }

    function _withdraw(uint256 amount) internal {
        _balances[msg.sender] -= amount;
        (bool success, ) = payable(msg.sender).call{value: amount}("");
        require(success);
        emit Transfer(msg.sender, address(0), amount);
    }

    function withdraw(WithdrawalPacket calldata packet) public {
        address signer = _verifyWithdrawal(packet);
        require(sequencers[signer] == 1, "!sequencer");
        require(nonceState(packet.nonce) == false, "replayed");
        usedNonces.set(packet.nonce);
        require(packet.account == msg.sender, "not sender");
        _withdraw(packet.amount);
    }

    event StartWithdrawal(
        address owner,
        uint256 timestamp,
        uint256 nonce,
        uint256 amount
    );

    function startWithdrawal(uint256 amount, uint256 nonce) external {
        pendingWithdrawals[msg.sender][block.timestamp][nonce] = amount;
        emit StartWithdrawal(msg.sender, block.timestamp, nonce, amount);
    }

    event CancelWithdrawal(address owner, uint256 timestamp, uint256 nonce);

    function cancelPendingWithdrawal(
        uint256 timestamp,
        uint256 nonce
    ) external {
        pendingWithdrawals[msg.sender][timestamp][nonce] = 0;
        emit CancelWithdrawal(msg.sender, timestamp, nonce);
    }

    event ExecuteDelayedWithdrawal(
        address owner,
        uint256 timestamp,
        uint256 nonce
    );

    function executePendingWithdrawal(
        uint256 timestamp,
        uint256 nonce
    ) external {
        require(timestamp + forcedWithdrawDelay < block.timestamp, "too soon");
        uint256 amount = pendingWithdrawals[msg.sender][timestamp][nonce];
        pendingWithdrawals[msg.sender][timestamp][nonce] = 0;
        _withdraw(amount);
        emit ExecuteDelayedWithdrawal(msg.sender, timestamp, nonce);
    }

    function _revealBids(bytes32[] calldata salts, address owner) internal {
        for (uint256 i = 0; i < salts.length; ) {
            // We use try/catch here to prevent a griefing attack where someone could deploySealedFunding() one of the
            // sealed fundings of the buyer right before another user calls this function, thus making it revert
            // It's still possible for the buyer to perform this attack by frontrunning the call with a withdraw()
            // but that's trivial to solve by just revealing all the salts of the griefing user
            try sealedFundingFactory.deploySealedFunding{gas: 100_000}(salts[i], owner) {} // cost of deploySealedFunding() is between 55k and 82k
                catch {}
            unchecked {
                ++i;
            }
        }
    }

    function withdrawWithSealedBids(
        bytes32[] calldata salts,
        WithdrawalPacket calldata packet
    ) external {
        _revealBids(salts, msg.sender);
        withdraw(packet);
    }

    function settle(
        Action calldata action,
        ActionAttestation calldata actionAttestation,
        bytes4 sig
    ) public payable {
        uint sequencerRank = sequencers[
            _verifyActionAttestation(actionAttestation)
        ];
        require(sequencerRank > 0, "!sequencer");
        if (actionAttestation.account != msg.sender) {
            require(
                actionAttestation.account == _verifyAction(action),
                "diff user"
            );
        }
        require(nonceState(actionAttestation.nonce) == false, "replayed");
        usedNonces.set(actionAttestation.nonce);
        require(actionAttestation.amount <= action.maxAmount);
        require(keccak256(abi.encode(action.operator, action.data)) == actionAttestation.callHash, "!callHash");
        if(msg.value < actionAttestation.amount){ // WARNING! If msg.value > amount, ETH will be stuck in the contract!
            _balances[actionAttestation.account] -= actionAttestation.amount;
            emit Transfer(actionAttestation.account, address(0), actionAttestation.amount);
        }
        // Replay protection for users is left to the called contract, since in some cases (eg auctionHash) its not needed
        (bool success, bytes memory data) = action.operator.call{
            value: actionAttestation.amount
        }(
            abi.encodeWithSelector(sig,
                msg.sender,
                actionAttestation.account,
                sequencerRank,
                action.data,
                actionAttestation.attestationData
            )
        );
        if(!success) {
            assembly{
                let revertStringLength := mload(data)
                let revertStringPtr := add(data, 0x20)
                revert(revertStringPtr, revertStringLength)
            }
        }
        require(success, "failed");
    }

/*
    function settleWithSealedBids(
        bytes32[] calldata salts,
        Action calldata action,
        ActionAttestation calldata actionAttestation
    ) external {
        _revealBids(salts, actionAttestation.account);
        settle(action, actionAttestation);
    }
*/
    function nonceState(uint256 nonce) public view returns (bool) {
        return usedNonces.get(nonce);
    }

    function settleOld(
        bytes32[] calldata salts,
        bytes32[] calldata oldSalts,
        address payable nftOwner,
        address nftContract,
        bytes32 auctionType,
        uint256 nftId,
        uint256 reserve,
        OldSealedMarket.Bid calldata bid,
        OldSealedMarket.BidWinner calldata bidWinner
    ) external {
        _revealBids(salts, bidWinner.winner);
        oldSealedMarket.deposit{value: bidWinner.amount}(bidWinner.winner);
        _balances[bidWinner.winner] -= bidWinner.amount;
        emit Transfer(bidWinner.winner, address(0), bidWinner.amount);
        // settleAuction verifies signatures on bid and bidWinner
        oldSealedMarket.settleAuctionWithSealedBids(oldSalts, nftOwner, nftContract, auctionType, nftId, reserve, bid, bidWinner);
    }
}
