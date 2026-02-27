// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

/// @notice Safe staticcall helper for ERC-7943 "no-revert views" + fail-closed semantics.
/// @dev Goals:
///  - Never revert (defensive): returns (ok=false, empty/zero) on any failure condition.
///  - Gas-stipend staticcall to hostile/untrusted modules.
///  - Strict decode helpers that DO NOT revert on short/malformed returndata.
///  - Optional max-returndata cap to avoid pathological memory expansion.
///
/// Typical usage (token views):
///  - (ok, val) = SafeStaticCall.tryStaticCallBool(target, 50_000, abi.encodeCall(...), 64);
///  - if (!ok) return false; // fail-closed
library SafeStaticCall {
    // Reasonable defaults for view/staticcall contexts
    uint256 internal constant DEFAULT_GAS_STIPEND = 50_000;
    uint256 internal constant DEFAULT_MAX_RETURNDATA = 96; // enough for (bool,uint8) or (bool,uint256)

    // ----------------------------- Raw call -----------------------------

    /// @notice Low-level staticcall with gas stipend and capped returndatacopy.
    /// @dev Never reverts. If target has no code, returns (false,"").
    /// @param target Target contract
    /// @param gasStipend Gas forwarded (0 => DEFAULT_GAS_STIPEND)
    /// @param callData ABI-encoded selector+args
    /// @param maxRetBytes Max bytes to copy from returndata (0 => DEFAULT_MAX_RETURNDATA)
    function staticcallRaw(
        address target,
        uint256 gasStipend,
        bytes memory callData,
        uint256 maxRetBytes
    ) internal view returns (bool ok, bytes memory ret) {
        if (target == address(0)) return (false, bytes(""));
        if (target.code.length == 0) return (false, bytes(""));

        if (gasStipend == 0) gasStipend = DEFAULT_GAS_STIPEND;
        if (maxRetBytes == 0) maxRetBytes = DEFAULT_MAX_RETURNDATA;

        // Defensive: cap maxRetBytes to something sane to reduce accidental memory blow-ups.
        // (If the caller wants more, they can pass it explicitly but we still hard-cap to uint32 max.)
        if (maxRetBytes > type(uint32).max) maxRetBytes = type(uint32).max;

        (ok, ret) = target.staticcall{gas: gasStipend}(callData);

        uint256 len = ret.length;
        if (len > maxRetBytes) {
            bytes memory truncated = new bytes(maxRetBytes);
            for (uint256 i = 0; i < maxRetBytes; i++) {
                truncated[i] = ret[i];
            }
            ret = truncated;
        }
    }

    // ------------------------- Strict decoders -------------------------

    function _tryDecodeBool(bytes memory ret) private pure returns (bool ok, bool value) {
        if (ret.length < 32) return (false, false);
        uint256 w = abi.decode(ret, (uint256));
        value = (w != 0);
        return (true, value);
    }

    function _tryDecodeUint256(bytes memory ret) private pure returns (bool ok, uint256 value) {
        if (ret.length < 32) return (false, 0);
        value = abi.decode(ret, (uint256));
        return (true, value);
    }

    function _tryDecodeBytes32(bytes memory ret) private pure returns (bool ok, bytes32 value) {
        if (ret.length < 32) return (false, bytes32(0));
        value = abi.decode(ret, (bytes32));
        return (true, value);
    }

    function _tryDecodeBoolUint8(bytes memory ret) private pure returns (bool ok, bool a, uint8 b) {
        if (ret.length < 64) return (false, false, 0);
        (uint256 w0, uint256 w1) = abi.decode(ret, (uint256, uint256));
        a = (w0 != 0);
        b = uint8(w1);
        return (true, a, b);
    }

    function _tryDecodeBoolBytes32(bytes memory ret) private pure returns (bool ok, bool a, bytes32 b) {
        if (ret.length < 64) return (false, false, bytes32(0));
        uint256 w0;
        (w0, b) = abi.decode(ret, (uint256, bytes32));
        a = (w0 != 0);
        return (true, a, b);
    }

    // ------------------------- Convenience wrappers -------------------------

    /// @notice Try staticcall returning (bool). Never reverts.
    function tryStaticCallBool(
        address target,
        uint256 gasStipend,
        bytes memory callData,
        uint256 maxRetBytes
    ) internal view returns (bool ok, bool value) {
        bytes memory ret;
        (ok, ret) = staticcallRaw(target, gasStipend, callData, maxRetBytes);
        if (!ok) return (false, false);
        return _tryDecodeBool(ret);
    }

    /// @notice Try staticcall returning (uint256). Never reverts.
    function tryStaticCallUint256(
        address target,
        uint256 gasStipend,
        bytes memory callData,
        uint256 maxRetBytes
    ) internal view returns (bool ok, uint256 value) {
        bytes memory ret;
        (ok, ret) = staticcallRaw(target, gasStipend, callData, maxRetBytes);
        if (!ok) return (false, 0);
        return _tryDecodeUint256(ret);
    }

    /// @notice Try staticcall returning (bytes32). Never reverts.
    function tryStaticCallBytes32(
        address target,
        uint256 gasStipend,
        bytes memory callData,
        uint256 maxRetBytes
    ) internal view returns (bool ok, bytes32 value) {
        bytes memory ret;
        (ok, ret) = staticcallRaw(target, gasStipend, callData, maxRetBytes);
        if (!ok) return (false, bytes32(0));
        return _tryDecodeBytes32(ret);
    }

    /// @notice Try staticcall returning (bool,uint8) e.g. transferStatus/ReasonCode patterns. Never reverts.
    function tryStaticCallBoolUint8(
        address target,
        uint256 gasStipend,
        bytes memory callData,
        uint256 maxRetBytes
    ) internal view returns (bool ok, bool a, uint8 b) {
        bytes memory ret;
        (ok, ret) = staticcallRaw(target, gasStipend, callData, maxRetBytes);
        if (!ok) return (false, false, 0);
        return _tryDecodeBoolUint8(ret);
    }

    /// @notice Try staticcall returning (bool,bytes32). Never reverts.
    function tryStaticCallBoolBytes32(
        address target,
        uint256 gasStipend,
        bytes memory callData,
        uint256 maxRetBytes
    ) internal view returns (bool ok, bool a, bytes32 b) {
        bytes memory ret;
        (ok, ret) = staticcallRaw(target, gasStipend, callData, maxRetBytes);
        if (!ok) return (false, false, bytes32(0));
        return _tryDecodeBoolBytes32(ret);
    }

    // ------------------------- Fail-closed helpers -------------------------

    /// @notice Fail-closed boolean call: returns false on any failure/malformed return.
    function staticCallBoolFailClosed(address target, bytes memory callData) internal view returns (bool) {
        (bool ok, bool v) = tryStaticCallBool(target, DEFAULT_GAS_STIPEND, callData, DEFAULT_MAX_RETURNDATA);
        return ok ? v : false;
    }

    /// @notice Fail-closed uint256 call: returns 0 on failure/malformed return.
    function staticCallUint256FailClosed(address target, bytes memory callData) internal view returns (uint256) {
        (bool ok, uint256 v) = tryStaticCallUint256(target, DEFAULT_GAS_STIPEND, callData, DEFAULT_MAX_RETURNDATA);
        return ok ? v : 0;
    }
}
