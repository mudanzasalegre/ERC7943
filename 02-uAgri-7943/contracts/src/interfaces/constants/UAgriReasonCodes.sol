// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;


library UAgriReasonCodes {
    uint8 internal constant OK                    = 0;
    uint8 internal constant PAUSED                = 1;
    uint8 internal constant SENDER_RESTRICTED     = 2;
    uint8 internal constant RECIPIENT_RESTRICTED  = 3;
    uint8 internal constant INSUFFICIENT_UNFROZEN = 4;
    uint8 internal constant COMPLIANCE_DENY       = 5;
    uint8 internal constant DISASTER_RESTRICTED   = 6;
    uint8 internal constant LOCKUP_ACTIVE         = 7;
    uint8 internal constant CAP_EXCEEDED          = 8;
    uint8 internal constant ORACLE_STALE          = 9;
    uint8 internal constant CUSTODY_STALE         = 10;

    uint8 internal constant UNKNOWN_FAIL_CLOSED   = 255;
}
