// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.4;
import "../shared/EIP712Base.sol";

abstract contract EIP712 is EIP712Base {
    struct WithdrawalPacket {
        uint8 v;
        bytes32 r;
        bytes32 s;
        uint256 deadline;
        uint256 amount;
        uint256 nonce;
        address account;
    }

    function _verifyWithdrawal(WithdrawalPacket calldata packet) internal virtual returns (address) {
        // verify deadline
        require(block.timestamp < packet.deadline, ">deadline");

        // verify signature
        address recoveredAddress = _verifySig(
            abi.encode(
                keccak256("VerifyWithdrawal(uint256 deadline,uint256 amount,uint256 nonce,address account)"),
                packet.deadline,
                packet.amount,
                packet.nonce,
                packet.account
            ),
            packet.v,
            packet.r,
            packet.s
        );
        return recoveredAddress; // Invariant: sequencer != address(0), we maintain this every time sequencer is set
    }

    struct Action {
        uint8 v;
        bytes32 r;
        bytes32 s;
        uint256 maxAmount;
        address operator;
        bytes4 sigHash;
        bytes data;
    }

    function _verifyAction(Action calldata packet) internal virtual returns (address) {
        address recoveredAddress = _verifySig(
            abi.encode(keccak256("Action(address operator,bytes data,uint256 maxAmount)"), packet.maxAmount, packet.operator, packet.data),
            packet.v,
            packet.r,
            packet.s
        );
        require(recoveredAddress != address(0), "sig");
        return recoveredAddress;
    }

    struct ActionAttestation {
        uint8 v;
        bytes32 r;
        bytes32 s;
        uint256 deadline;
        uint256 amount;
        uint256 nonce;
        address account;
        bytes32 callHash;
        bytes attestationData;
    }

    function _verifyActionAttestation(ActionAttestation calldata packet) internal virtual returns (address) {
        require(block.timestamp < packet.deadline, ">deadline");
        address recoveredAddress = _verifySig(
            abi.encode(keccak256("ActionAttestation(uint256 deadline,uint256 amount,uint256 nonce,address account,bytes32 callHash,bytes attestationData)"), 
                packet.deadline,
                packet.amount,
                packet.nonce,
                packet.account,
                packet.callHash,
                keccak256(packet.attestationData)
            ),
            packet.v,
            packet.r,
            packet.s
        );
        return recoveredAddress;
    }
}
