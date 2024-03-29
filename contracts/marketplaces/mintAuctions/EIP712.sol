// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.4;
import "../../shared/EIP712Base.sol";

abstract contract EIP712 is EIP712Base {
    struct MintOffer {
        uint8 v;
        bytes32 r;
        bytes32 s;
        bytes32 mintHash;
        uint256 amount;
        uint256 deadline;
        uint256 counter;
        uint256 nonce;
    }

    struct BuyerMintOffer {
        bytes32 mintHash;
        uint256 counter;
        uint256 nonce;
    }

    function _verifySellMintOffer(MintOffer memory packet) internal virtual returns (address) {
        return _verifySig(
            abi.encode(
                keccak256(
                    "SellOffer(bytes32 mintHash,uint256 amount,uint256 deadline,uint256 counter,uint256 nonce)"
                ),
                packet.mintHash,
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

    struct MintOfferAttestation {
        address seller;
        address nftContract;
        string uri;
    } // No nonce cause nonce is already applied to buyer and seller packets
}
