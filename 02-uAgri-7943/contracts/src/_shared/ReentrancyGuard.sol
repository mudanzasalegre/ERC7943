// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

/// @notice Gas-efficient reentrancy guard.
/// @dev Use `nonReentrant` on external functions that move value / call out to untrusted contracts.
/// Pattern: CEI + pull-payments still recommended; this is a last line of defense.
abstract contract ReentrancyGuard {
    // 1 = NOT_ENTERED, 2 = ENTERED (non-zero to save some gas on SSTORE refunds rules)
    uint256 private _status = 1;

    error ReentrancyGuard__ReentrantCall();

    modifier nonReentrant() {
        if (_status == 2) revert ReentrancyGuard__ReentrantCall();
        _status = 2;
        _;
        _status = 1;
    }

    /// @notice For introspection/testing.
    function _reentrancyStatus() internal view returns (uint256) {
        return _status;
    }
}
