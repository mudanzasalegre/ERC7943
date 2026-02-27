// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;


interface IAgriCustodyV1 {
    function isCustodyFresh(bytes32 campaignId) external view returns (bool);
    function lastCustodyEpoch(bytes32 campaignId) external view returns (uint64);
    function custodyValidUntil(bytes32 campaignId) external view returns (uint64);
}
