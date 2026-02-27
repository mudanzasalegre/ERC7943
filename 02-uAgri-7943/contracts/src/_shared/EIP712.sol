// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {ECDSA} from "./ECDSA.sol";

/// @notice Minimal EIP-712 base (domain separator caching + typed data hashing).
/// @dev - Pinned for Solidity 0.8.33.
/// - Caches domain separator with chainid; auto-rebuilds on chain forks.
/// - Leaves message schemas to inheritors.
/// - Use with ECDSA.recover(digest, sig).
abstract contract EIP712 {
    bytes32 private immutable _HASHED_NAME;
    bytes32 private immutable _HASHED_VERSION;

    // keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
    bytes32 private constant _TYPE_HASH =
        0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f;

    bytes32 private immutable _CACHED_DOMAIN_SEPARATOR;
    uint256 private immutable _CACHED_CHAIN_ID;
    address private immutable _CACHED_THIS;

    constructor(string memory name_, string memory version_) {
        _HASHED_NAME = keccak256(bytes(name_));
        _HASHED_VERSION = keccak256(bytes(version_));

        _CACHED_CHAIN_ID = block.chainid;
        _CACHED_THIS = address(this);
        _CACHED_DOMAIN_SEPARATOR = _buildDomainSeparator(_TYPE_HASH, _HASHED_NAME, _HASHED_VERSION);
    }

    /// @notice Returns current domain separator (recomputed if chainid/contract differs).
    function domainSeparatorV4() public view returns (bytes32) {
        if (address(this) == _CACHED_THIS && block.chainid == _CACHED_CHAIN_ID) {
            return _CACHED_DOMAIN_SEPARATOR;
        }
        return _buildDomainSeparator(_TYPE_HASH, _HASHED_NAME, _HASHED_VERSION);
    }

    /// @notice Hash typed data as per EIP-712: keccak256("\x19\x01" || domainSeparator || structHash)
    function _hashTypedDataV4(bytes32 structHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", domainSeparatorV4(), structHash));
    }

    /// @notice Recover signer from typed data digest using ECDSA helpers.
    function _recoverTypedDataSigner(bytes32 structHash, bytes memory signature) internal view returns (address) {
        bytes32 digest = _hashTypedDataV4(structHash);
        return ECDSA.recover(digest, signature);
    }

    function _buildDomainSeparator(bytes32 typeHash, bytes32 nameHash, bytes32 versionHash)
        private
        view
        returns (bytes32)
    {
        return keccak256(abi.encode(typeHash, nameHash, versionHash, block.chainid, address(this)));
    }
}
