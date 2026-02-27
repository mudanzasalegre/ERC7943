// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;


library UAgriTypes {
    enum CampaignState { FUNDING, ACTIVE, HARVESTED, SETTLED, CLOSED }
    enum RequestKind { Deposit, Redeem }
    enum RequestStatus { None, Requested, Cancelled, Processed }

    struct Campaign {
        bytes32 campaignId;
        bytes32 plotRef;
        bytes32 subPlotId;
        uint16  areaBps;
        uint64  startTs;
        uint64  endTs;
        address settlementAsset;
        uint256 fundingCap;
        bytes32 docsRootHash;
        bytes32 jurisdictionProfile;
        CampaignState state;
    }

    struct Request {
        address account;
        RequestKind kind;
        uint256 amount;
        uint256 minOut;
        uint256 maxIn;
        uint64  deadline;
        RequestStatus status;
    }

    struct ViewGasLimits {
        uint32 complianceGas;
        uint32 disasterGas;
        uint32 freezeGas;
        uint32 custodyGas;
        uint32 extraGas;
    }
}
