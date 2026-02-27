// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;


import {UAgriTypes} from "../constants/UAgriTypes.sol";

interface IAgriCampaignRegistryV1 {
    event CampaignCreated(bytes32 indexed campaignId, bytes32 plotRef, address settlementAsset);
    event CampaignStateUpdated(bytes32 indexed campaignId, UAgriTypes.CampaignState state);

    function getCampaign(bytes32 campaignId) external view returns (UAgriTypes.Campaign memory);
    function state(bytes32 campaignId) external view returns (UAgriTypes.CampaignState);
}
