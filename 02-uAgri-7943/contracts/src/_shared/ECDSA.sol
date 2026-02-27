// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

/// @notice Minimal ECDSA helpers (no external deps).
/// @dev - Supports recover for 65-byte and 64-byte (EIP-2098) signatures.
/// - Enforces "low-s" malleability rule and v ∈ {27,28}.
/// - Suitable for EIP-712 + attestations/oracles in uAgri.
library ECDSA {
    // --------------------------------- Errors ---------------------------------

    error ECDSA__InvalidSignatureLength();
    error ECDSA__InvalidSignatureS();
    error ECDSA__InvalidSignatureV();
    error ECDSA__InvalidSignature();

    // secp256k1n/2
    // 0x7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0
    bytes32 internal constant SECP256K1_N_DIV_2 =
        0x7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0;

    // ------------------------------ Public API --------------------------------

    function recover(bytes32 hash, bytes memory signature) internal pure returns (address signer) {
        uint256 len = signature.length;
        if (len == 65) {
            bytes32 r = _readBytes32(signature, 0);
            bytes32 s = _readBytes32(signature, 32);
            uint8 v = uint8(signature[64]);
            return recover(hash, v, r, s);
        }

        if (len == 64) {
            bytes32 r = _readBytes32(signature, 0);
            bytes32 vs = _readBytes32(signature, 32);
            return recover(hash, r, vs);
        }

        revert ECDSA__InvalidSignatureLength();
    }

    /// @notice Recover from standard (v,r,s).
    function recover(bytes32 hash, uint8 v, bytes32 r, bytes32 s) internal pure returns (address signer) {
        if (uint256(s) > uint256(SECP256K1_N_DIV_2)) revert ECDSA__InvalidSignatureS();
        if (v != 27 && v != 28) revert ECDSA__InvalidSignatureV();

        signer = ecrecover(hash, v, r, s);
        if (signer == address(0)) revert ECDSA__InvalidSignature();
    }

    /// @notice Recover from EIP-2098 short signatures: (r, vs).
    /// @dev `vs` contains `s` in low 255 bits and `v` in top bit.
    function recover(bytes32 hash, bytes32 r, bytes32 vs) internal pure returns (address signer) {
        bytes32 s = vs & bytes32(0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff);
        uint8 v = uint8((uint256(vs) >> 255) + 27);
        return recover(hash, v, r, s);
    }

    /// @notice Returns an Ethereum Signed Message hash (EIP-191) for a 32-byte message hash.
    function toEthSignedMessageHash(bytes32 messageHash) internal pure returns (bytes32) {
        // "\x19Ethereum Signed Message:\n32" + messageHash
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash));
    }

    /// @notice Returns an Ethereum Signed Message hash (EIP-191) for arbitrary length message bytes.
    function toEthSignedMessageHash(bytes memory message) internal pure returns (bytes32) {
        // "\x19Ethereum Signed Message:\n" + len(message) + message
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n", _toDecimal(message.length), message));
    }

    // ------------------------------- Internals --------------------------------

    function _readBytes32(bytes memory data, uint256 offset) private pure returns (bytes32 out) {
        // data length is validated by caller in recover()
        for (uint256 i = 0; i < 32; i++) {
            out |= bytes32(uint256(uint8(data[offset + i])) << ((31 - i) * 8));
        }
    }

    function _toDecimal(uint256 x) private pure returns (string memory) {
        if (x == 0) return "0";

        uint256 digits;
        uint256 tmp = x;
        while (tmp != 0) {
            unchecked {
                ++digits;
                tmp /= 10;
            }
        }

        bytes memory buf = new bytes(digits);
        while (x != 0) {
            unchecked {
                digits -= 1;
                buf[digits] = bytes1(uint8(48 + (x % 10)));
                x /= 10;
            }
        }
        return string(buf);
    }
}
