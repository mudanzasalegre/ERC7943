// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

/// @notice Minimal, robust ERC20 helpers that handle non-standard tokens safely.
/// @dev - Works with tokens that return no bool (assume success if no revert and no return data).
/// - Works with tokens that return a bool.
/// - Uses low-level call; NEVER assumes compliance.
/// - Reverts with custom errors for clarity.
/// - No external dependencies; suitable for Foundry + pinned compiler.
library SafeERC20 {
    // --------------------------------- Errors ---------------------------------

    error SafeERC20__CallFailed();
    error SafeERC20__BadReturnValue();
    error SafeERC20__PermitFailed();
    error SafeERC20__InvalidAddress();

    // --------------------------------- IERC20 ---------------------------------

    function safeTransfer(address token, address to, uint256 amount) internal {
        if (token == address(0) || to == address(0)) revert SafeERC20__InvalidAddress();
        _callOptionalReturn(token, abi.encodeWithSelector(0xa9059cbb, to, amount)); // transfer(address,uint256)
    }

    function safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        if (token == address(0) || from == address(0) || to == address(0)) revert SafeERC20__InvalidAddress();
        _callOptionalReturn(token, abi.encodeWithSelector(0x23b872dd, from, to, amount)); // transferFrom(address,address,uint256)
    }

    function safeApprove(address token, address spender, uint256 amount) internal {
        if (token == address(0) || spender == address(0)) revert SafeERC20__InvalidAddress();
        _callOptionalReturn(token, abi.encodeWithSelector(0x095ea7b3, spender, amount)); // approve(address,uint256)
    }

    /// @notice Safer pattern to change allowances for tokens that require zero-first.
    /// @dev If direct approve fails, attempts approve(0) then approve(amount).
    function forceApprove(address token, address spender, uint256 amount) internal {
        if (token == address(0) || spender == address(0)) revert SafeERC20__InvalidAddress();

        (bool ok, bytes memory ret) = token.call(abi.encodeWithSelector(0x095ea7b3, spender, amount));
        if (ok && _isReturnOk(ret)) return;

        // fallback: zero then set
        _callOptionalReturn(token, abi.encodeWithSelector(0x095ea7b3, spender, 0));
        _callOptionalReturn(token, abi.encodeWithSelector(0x095ea7b3, spender, amount));
    }

    function safeIncreaseAllowance(address token, address spender, uint256 increment) internal {
        uint256 current = allowance(token, address(this), spender);
        forceApprove(token, spender, current + increment);
    }

    function safeDecreaseAllowance(address token, address spender, uint256 decrement) internal {
        uint256 current = allowance(token, address(this), spender);
        uint256 next = current > decrement ? (current - decrement) : 0;
        forceApprove(token, spender, next);
    }

    // --------------------------------- Views ----------------------------------

    function balanceOf(address token, address account) internal view returns (uint256 bal) {
        (bool ok, bytes memory ret) = token.staticcall(abi.encodeWithSelector(0x70a08231, account)); // balanceOf(address)
        if (!ok || ret.length < 32) return 0;
        bal = abi.decode(ret, (uint256));
    }

    function allowance(address token, address owner, address spender) internal view returns (uint256 a) {
        (bool ok, bytes memory ret) =
            token.staticcall(abi.encodeWithSelector(0xdd62ed3e, owner, spender)); // allowance(address,address)
        if (!ok || ret.length < 32) return 0;
        a = abi.decode(ret, (uint256));
    }

    // ------------------------------ Permit (optional) -------------------------

    /// @notice Try EIP-2612 permit. Reverts if token reverts or returns failure.
    /// @dev Signature must be produced off-chain. If a token doesn't support permit it will likely revert.
    function safePermit(
        address token,
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal {
        if (token == address(0) || owner == address(0) || spender == address(0)) revert SafeERC20__InvalidAddress();

        (bool ok, ) = token.call(
            abi.encodeWithSelector(
                0xd505accf, // permit(address,address,uint256,uint256,uint8,bytes32,bytes32)
                owner,
                spender,
                value,
                deadline,
                v,
                r,
                s
            )
        );
        if (!ok) revert SafeERC20__PermitFailed();
    }

    // ------------------------------ Internals ---------------------------------

    function _callOptionalReturn(address token, bytes memory data) private {
        (bool ok, bytes memory ret) = token.call(data);
        if (!ok) revert SafeERC20__CallFailed();
        if (!_isReturnOk(ret)) revert SafeERC20__BadReturnValue();
    }

    /// @dev Return data rules:
    /// - empty => success (non-standard ERC20)
    /// - 32 bytes => must decode to true (standard)
    /// - other => treat as failure (strict)
    function _isReturnOk(bytes memory ret) private pure returns (bool) {
        if (ret.length == 0) return true;
        if (ret.length < 32) return false;
        return abi.decode(ret, (uint256)) != 0;
    }
}
