// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.4;

abstract contract EIP712Base {
    /// -----------------------------------------------------------------------
    /// Structs
    /// -----------------------------------------------------------------------

    /// -----------------------------------------------------------------------
    /// Immutable parameters
    /// -----------------------------------------------------------------------

    /// @notice The chain ID used by EIP-712
    uint256 internal immutable INITIAL_CHAIN_ID;

    /// @notice The domain separator used by EIP-712
    bytes32 internal immutable INITIAL_DOMAIN_SEPARATOR;

    /// -----------------------------------------------------------------------
    /// Constructor
    /// -----------------------------------------------------------------------

    constructor() {
        INITIAL_CHAIN_ID = block.chainid;
        INITIAL_DOMAIN_SEPARATOR = _computeDomainSeparator();
    }

    /// -----------------------------------------------------------------------
    /// Packet verification
    /// -----------------------------------------------------------------------

    function _verifySig(bytes memory data, uint8 v, bytes32 r, bytes32 s) internal virtual returns (address) {
        // verify signature
        address recoveredAddress =
            ecrecover(keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), keccak256(data))), v, r, s);
        return recoveredAddress;
    }

    /// -----------------------------------------------------------------------
    /// EIP-712 compliance
    /// -----------------------------------------------------------------------

    /// @notice The domain separator used by EIP-712
    function DOMAIN_SEPARATOR() public view virtual returns (bytes32) {
        return block.chainid == INITIAL_CHAIN_ID ? INITIAL_DOMAIN_SEPARATOR : _computeDomainSeparator();
    }

    /// @notice Computes the domain separator used by EIP-712
    function _computeDomainSeparator() internal view virtual returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("SealedArtMarket"),
                keccak256("1"),
                block.chainid,
                address(this)
            )
        );
    }
}
