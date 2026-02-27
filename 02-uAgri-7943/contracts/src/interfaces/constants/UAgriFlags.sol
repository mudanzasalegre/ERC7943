// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

library UAgriFlags {
    uint256 internal constant PAUSE_TRANSFERS   = 1 << 0;
    uint256 internal constant PAUSE_FUNDING     = 1 << 1;
    uint256 internal constant PAUSE_REDEMPTIONS = 1 << 2;
    uint256 internal constant PAUSE_CLAIMS      = 1 << 3;
    uint256 internal constant PAUSE_ORACLES     = 1 << 4;

    // Optional helper masks (non-breaking additions)
    uint256 internal constant PAUSE_MASK =
        PAUSE_TRANSFERS |
        PAUSE_FUNDING |
        PAUSE_REDEMPTIONS |
        PAUSE_CLAIMS |
        PAUSE_ORACLES;

    uint256 internal constant ALL_PAUSE_FLAGS = PAUSE_MASK;
}
