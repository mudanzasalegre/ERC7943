// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;


import {UAgriTypes} from "../constants/UAgriTypes.sol";

interface ISettlementQueueV1 {
    event RequestCreated(
        uint256 indexed id,
        address indexed account,
        UAgriTypes.RequestKind kind,
        uint256 amount,
        uint256 minOut,
        uint256 maxIn,
        uint64 deadline
    );
    event RequestCancelled(uint256 indexed id, address indexed account);
    event RequestProcessed(
        uint256 indexed id,
        address indexed account,
        UAgriTypes.RequestKind kind,
        uint256 amount,
        uint256 outAmount,
        uint64 epoch,
        bytes32 reportHash
    );

    function requestDeposit(uint256 amountIn, uint256 maxIn, uint64 deadline) external returns (uint256 id);
    function requestRedeem(uint256 shares, uint256 minOut, uint64 deadline) external returns (uint256 id);
    function cancel(uint256 id) external;

    function getRequest(uint256 id) external view returns (UAgriTypes.Request memory);

    function batchProcess(uint256[] calldata ids, uint64 epoch, bytes32 reportHash) external;
}
