// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;


interface IAgriOracleBaseV1 {
    event OracleReportSubmitted(bytes32 indexed campaignId, uint64 indexed epoch, bytes32 reportHash, uint64 asOf, uint64 validUntil);

    function latestEpoch(bytes32 campaignId) external view returns (uint64);
    function reportHash(bytes32 campaignId, uint64 epoch) external view returns (bytes32);
    function isReportValid(bytes32 campaignId, uint64 epoch) external view returns (bool);
}
