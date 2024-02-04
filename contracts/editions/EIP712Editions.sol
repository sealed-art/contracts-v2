// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.4;
import "../shared/EIP712Base.sol";

abstract contract EIP712Editions is EIP712Base {
    struct MintOffer {
        uint8 v;
        bytes32 r;
        bytes32 s;
        address nftContract;
        string uri;
        uint256 cost;
        uint256 startDate;
        uint256 endDate;
        uint256 maxToMint;
        uint256 maxPerWallet;
        address paymentReceiver;
        bytes32 merkleRoot;
        uint256 deadline;
        uint256 counter;
        uint256 nonce;
    }

    function _verifySellMintOffer(MintOffer calldata packet) internal virtual returns (address) {
        return _verifySig(
            abi.encode(
                keccak256(
                    "SellOffer(address nftContract,string uri,uint256 cost,uint256 startDate,uint256 endDate,uint256 maxToMint,uint256 maxPerWallet,address paymentReceiver,bytes32 merkleRoot,uint256 deadline,uint256 counter,uint256 nonce)"
                ),
                packet.nftContract,
                keccak256(abi.encodePacked(packet.uri)),
                packet.cost,
                packet.startDate,
                packet.endDate,
                packet.maxToMint,
                packet.maxPerWallet,
                packet.paymentReceiver,
                packet.merkleRoot,
                packet.deadline,
                packet.counter,
                packet.nonce
            ),
            packet.v,
            packet.r,
            packet.s
        );
    }

    struct MintOfferAttestation {
        uint8 v;
        bytes32 r;
        bytes32 s;
        uint256 deadline;
        bytes32 offerHash;
    }

    function _verifyAttestation(MintOfferAttestation calldata packet) internal virtual returns (address) {
        return _verifySig(
            abi.encode(
                keccak256(
                    "MintOfferAttestation(uint256 deadline,bytes32 offerHash)"
                ),
                packet.deadline,
                packet.offerHash
            ),
            packet.v,
            packet.r,
            packet.s
        );
    }
}
