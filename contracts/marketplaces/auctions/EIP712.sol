// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.4;
import "../../shared/EIP712Base.sol";

abstract contract EIP712 is EIP712Base {
    struct Bid {
        uint8 v;
        bytes32 r;
        bytes32 s;
        bytes32 auctionId;
        uint256 maxAmount;
    }

    function _verifyBid(Bid calldata packet) internal virtual returns (address) {
        address recoveredAddress = _verifySig(
            abi.encode(keccak256("Bid(bytes32 auctionId,uint256 maxAmount)"), packet.auctionId, packet.maxAmount),
            packet.v,
            packet.r,
            packet.s
        );
        require(recoveredAddress != address(0), "sig");
        return recoveredAddress;
    }

    struct BidWinner {
        uint8 v;
        bytes32 r;
        bytes32 s;
        bytes32 auctionId;
        uint256 amount;
        address winner;
    }

    function _verifyBidWinner(BidWinner calldata packet) internal virtual returns (address) {
        return _verifySig(
            abi.encode(
                keccak256("BidWinner(bytes32 auctionId,uint256 amount,address winner)"),
                packet.auctionId,
                packet.amount,
                packet.winner
            ),
            packet.v,
            packet.r,
            packet.s
        );
    }

    struct CancelAuction {
        uint8 v;
        bytes32 r;
        bytes32 s;
        bytes32 auctionId;
        uint256 deadline;
    }

    function _verifyCancelAuction(CancelAuction calldata packet) internal virtual returns (address) {
        require(block.timestamp <= packet.deadline, "deadline");
        return _verifySig(
            abi.encode(
                keccak256("CancelAuction(bytes32 auctionId,uint256 deadline)"), packet.auctionId, packet.deadline
            ),
            packet.v,
            packet.r,
            packet.s
        );
    }

    struct Offer {
        uint8 v;
        bytes32 r;
        bytes32 s;
        address nftContract;
        uint256 nftId;
        uint256 amount;
        uint256 deadline;
        uint256 counter;
        uint256 nonce;
    }

    function _verifyBuyOffer(Offer calldata packet) internal virtual returns (address) {
        return _verifySig(
            abi.encode(
                keccak256(
                    "BuyOffer(address nftContract,uint256 nftId,uint256 amount,uint256 deadline,uint256 counter,uint256 nonce)"
                ),
                packet.nftContract,
                packet.nftId,
                packet.amount,
                packet.deadline,
                packet.counter,
                packet.nonce
            ),
            packet.v,
            packet.r,
            packet.s
        );
    }

    function _verifySellOffer(Offer calldata packet) internal virtual returns (address) {
        return _verifySig(
            abi.encode(
                keccak256(
                    "SellOffer(address nftContract,uint256 nftId,uint256 amount,uint256 deadline,uint256 counter,uint256 nonce)"
                ),
                packet.nftContract,
                packet.nftId,
                packet.amount,
                packet.deadline,
                packet.counter,
                packet.nonce
            ),
            packet.v,
            packet.r,
            packet.s
        );
    }

    struct OfferAttestation {
        uint8 v;
        bytes32 r;
        bytes32 s;
        bytes32 auctionId;
        uint256 amount;
        address buyer;
        address seller;
        uint256 deadline;
    }

    function _verifyOfferAttestation(OfferAttestation calldata packet) internal virtual returns (address) {
        return _verifySig(
            abi.encode(
                keccak256(
                    "OfferAttestation(bytes32 auctionId,uint256 amount,address buyer,address seller,uint256 deadline)"
                ),
                packet.auctionId,
                packet.amount,
                packet.buyer,
                packet.seller,
                packet.deadline
            ),
            packet.v,
            packet.r,
            packet.s
        );
    }
}
