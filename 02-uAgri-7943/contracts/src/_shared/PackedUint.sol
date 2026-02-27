// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

/// @title PackedUint
/// @notice Helpers to pack/unpack multiple small integers/flags into a single uint256 word.
/// @dev Designed as a low-level utility. Reverts on invalid field definitions or overflows.
///
/// Conventions:
/// - A "field" is defined by (offset,bits), where offset is the LSB position and bits is width.
/// - Valid field: bits in [1..256] and offset+bits <= 256.
/// - For bits == 256, offset must be 0 (whole word).
library PackedUint {
    // ------------------------------- Errors ----------------------------------

    error PackedUint__InvalidField(uint8 offset, uint8 bits);
    error PackedUint__ValueOverflow(uint256 value, uint8 bits);
    error PackedUint__SignedOverflow(int256 value, uint8 bits);

    // ------------------------------ Field type --------------------------------

    struct Field {
        uint8 offset;
        uint8 bits;
    }

    function field(uint8 offset, uint8 bits) internal pure returns (Field memory f) {
        _checkField(offset, bits);
        f = Field({offset: offset, bits: bits});
    }

    // ------------------------------ Read ops ----------------------------------

    function get(uint256 word, Field memory f) internal pure returns (uint256) {
        return getAt(word, f.offset, f.bits);
    }

    function getAt(uint256 word, uint8 offset, uint8 bits) internal pure returns (uint256) {
        _checkField(offset, bits);
        if (bits == 256) return word; // offset must be 0 by _checkField
        return (word >> offset) & _max(bits);
    }

    function getBool(uint256 word, uint8 bit) internal pure returns (bool) {
        if (bit >= 256) revert PackedUint__InvalidField(bit, 1);
        return ((word >> bit) & 1) == 1;
    }

    /// @notice Read a signed int stored in two's complement in a (offset,bits) field.
    function getIntAt(uint256 word, uint8 offset, uint8 bits) internal pure returns (int256) {
        _checkField(offset, bits);
        if (bits == 256) {
            return int256(word);
        }

        uint256 u = getAt(word, offset, bits);
        uint256 signBit = uint256(1) << (bits - 1);

        // If sign bit set => negative, sign-extend to 256 bits.
        if ((u & signBit) != 0) {
            uint256 extMask = ~_max(bits);
            uint256 uExt = u | extMask;
            return int256(uExt);
        }

        return int256(u);
    }

    function getInt(uint256 word, Field memory f) internal pure returns (int256) {
        return getIntAt(word, f.offset, f.bits);
    }

    // ------------------------------ Write ops ---------------------------------

    function set(uint256 word, Field memory f, uint256 value) internal pure returns (uint256) {
        return setAt(word, f.offset, f.bits, value);
    }

    function setAt(uint256 word, uint8 offset, uint8 bits, uint256 value) internal pure returns (uint256) {
        _checkField(offset, bits);

        if (bits == 256) {
            // offset is 0 by _checkField
            return value;
        }

        uint256 maxV = _max(bits);
        if (value > maxV) revert PackedUint__ValueOverflow(value, bits);

        uint256 m = maxV << offset;
        // clear field, then OR-in new value
        return (word & ~m) | (value << offset);
    }

    function clearAt(uint256 word, uint8 offset, uint8 bits) internal pure returns (uint256) {
        _checkField(offset, bits);
        if (bits == 256) return 0;
        uint256 m = _max(bits) << offset;
        return word & ~m;
    }

    function clear(uint256 word, Field memory f) internal pure returns (uint256) {
        return clearAt(word, f.offset, f.bits);
    }

    function setBool(uint256 word, uint8 bit, bool value) internal pure returns (uint256) {
        if (bit >= 256) revert PackedUint__InvalidField(bit, 1);
        uint256 m = uint256(1) << bit;
        return value ? (word | m) : (word & ~m);
    }

    /// @notice Store a signed int (two's complement) into a (offset,bits) field.
    function setIntAt(uint256 word, uint8 offset, uint8 bits, int256 value) internal pure returns (uint256) {
        _checkField(offset, bits);

        (int256 minV, int256 maxV) = _signedBounds(bits);
        if (value < minV || value > maxV) revert PackedUint__SignedOverflow(value, bits);

        uint256 u = _asUint256(value);

        if (bits == 256) {
            // offset is 0 by _checkField
            return u;
        }

        // Keep only low `bits`
        u &= _max(bits);
        return setAt(word, offset, bits, u);
    }

    function setInt(uint256 word, Field memory f, int256 value) internal pure returns (uint256) {
        return setIntAt(word, f.offset, f.bits, value);
    }

    // ---------------------------- Arithmetic ops ------------------------------

    function addAt(uint256 word, uint8 offset, uint8 bits, uint256 delta) internal pure returns (uint256) {
        _checkField(offset, bits);
        uint256 cur = getAt(word, offset, bits);
        unchecked {
            uint256 next = cur + delta;
            uint256 maxV = _max(bits);
            if (next > maxV) revert PackedUint__ValueOverflow(next, bits);
            return setAt(word, offset, bits, next);
        }
    }

    function subAt(uint256 word, uint8 offset, uint8 bits, uint256 delta) internal pure returns (uint256) {
        _checkField(offset, bits);
        uint256 cur = getAt(word, offset, bits);
        if (delta > cur) revert PackedUint__ValueOverflow(delta, bits); // underflow
        unchecked {
            return setAt(word, offset, bits, cur - delta);
        }
    }

    function add(uint256 word, Field memory f, uint256 delta) internal pure returns (uint256) {
        return addAt(word, f.offset, f.bits, delta);
    }

    function sub(uint256 word, Field memory f, uint256 delta) internal pure returns (uint256) {
        return subAt(word, f.offset, f.bits, delta);
    }

    // ------------------------------ Masks -------------------------------------

    function maxValue(uint8 bits) internal pure returns (uint256) {
        if (bits == 0 || bits > 256) revert PackedUint__InvalidField(0, bits);
        return _max(bits);
    }

    function maskAt(uint8 offset, uint8 bits) internal pure returns (uint256) {
        _checkField(offset, bits);
        if (bits == 256) return type(uint256).max;
        return _max(bits) << offset;
    }

    // ------------------------------ Internals ---------------------------------

    // Isolated helper to keep stack pressure low in setIntAt under coverage builds.
    function _asUint256(int256 x) private pure returns (uint256 u) {
        return uint256(x);
    }

    function _checkField(uint8 offset, uint8 bits) private pure {
        if (bits == 0 || bits > 256) revert PackedUint__InvalidField(offset, bits);
        if (bits == 256) {
            if (offset != 0) revert PackedUint__InvalidField(offset, bits);
            return;
        }
        if (uint256(offset) + uint256(bits) > 256) revert PackedUint__InvalidField(offset, bits);
    }

    function _max(uint8 bits) private pure returns (uint256) {
        // bits in 1..256
        if (bits == 256) return type(uint256).max;
        return (uint256(1) << bits) - 1;
    }

    function _signedBounds(uint8 bits) private pure returns (int256 minV, int256 maxV) {
        // bits validated by _checkField before call, but keep it robust:
        if (bits == 0 || bits > 256) revert PackedUint__InvalidField(0, bits);

        if (bits == 256) {
            return (type(int256).min, type(int256).max);
        }

        // half = 2^(bits-1) fits in uint256 for bits<=255
        uint256 half = uint256(1) << (bits - 1);

        // max =  2^(bits-1) - 1
        // min = -2^(bits-1)
        maxV = int256(half - 1);
        minV = -int256(half);
    }
}
