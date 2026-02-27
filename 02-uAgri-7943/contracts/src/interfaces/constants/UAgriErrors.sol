// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;


library UAgriErrors {
    error UAgri__Unauthorized();
    error UAgri__InvalidAddress();
    error UAgri__InvalidAmount();
    error UAgri__BadState();
    error UAgri__Paused();
    error UAgri__Restricted();
    error UAgri__HardFrozen();
    error UAgri__DeadlineExpired();
    error UAgri__RequestNotFound();
    error UAgri__RequestNotCancellable();
    error UAgri__AlreadyProcessed();
    error UAgri__InsufficientUnfrozen();
    error UAgri__ComplianceDenied();
    error UAgri__CustodyStale();
    error UAgri__OracleStale();
    error UAgri__InvalidSignature();
    error UAgri__Replay();
    error UAgri__FailClosed();
}
