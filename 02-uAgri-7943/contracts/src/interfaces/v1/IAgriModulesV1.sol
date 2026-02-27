// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {UAgriTypes} from "../constants/UAgriTypes.sol";

interface IAgriModulesV1 {
    /// @notice Canonical module wiring for V1.
    /// @dev Adding this struct is non-breaking; it's only a type container unless used in new function signatures.
    struct ModulesV1 {
        address compliance;
        address disaster;
        address freezeModule;
        address custody;

        address trace;
        address documentRegistry;

        address settlementQueue;
        address treasury;
        address distribution;

        address bridge;
        address marketplace;
        address delivery;
        address insurance;
    }

    event ModulesUpdated(
        address compliance,
        address disaster,
        address freezeModule,
        address custody,
        address trace,
        address documentRegistry,
        address settlementQueue,
        address treasury,
        address distribution,
        address bridge,
        address marketplace,
        address delivery,
        address insurance
    );

    event ViewGasLimitsUpdated(UAgriTypes.ViewGasLimits limits);

    function complianceModule() external view returns (address);
    function disasterModule() external view returns (address);
    function freezeModule() external view returns (address);
    function custodyModule() external view returns (address);

    function traceModule() external view returns (address);
    function documentRegistry() external view returns (address);

    function settlementQueue() external view returns (address);
    function treasury() external view returns (address);
    function distribution() external view returns (address);

    function bridgeModule() external view returns (address);
    function marketplaceModule() external view returns (address);
    function deliveryModule() external view returns (address);
    function insuranceModule() external view returns (address);

    function viewGasLimits() external view returns (UAgriTypes.ViewGasLimits memory);
    function setViewGasLimits(UAgriTypes.ViewGasLimits calldata limits) external;
}
