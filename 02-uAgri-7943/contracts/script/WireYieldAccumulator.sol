// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {IAgriModulesV1} from "../src/interfaces/v1/IAgriModulesV1.sol";

interface IAgriShareTokenAdmin is IAgriModulesV1 {
    function setModulesV1(IAgriModulesV1.ModulesV1 calldata modules_) external;
    function setDistributionHooksConfig(bool enabled, bool failOpen, uint32 gasLimit) external;
    function mint(address to, uint256 amount) external;
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IYieldAccumulatorAdmin {
    function hooksSeen() external view returns (bool);
    function setRequireHooks(bool enabled) external;
}

contract WireYieldAccumulator is Script {
    struct RunConfig {
        bool enableHooks;
        bool failOpen;
        uint32 hookGas;
        bool strict;
        bool doMint;
        address mintTo;
        uint256 mintAmount;
        bool doTransfer;
        address transferTo;
        uint256 transferAmount;
    }

    function run() external {
        address tokenAddr = vm.envAddress("TOKEN");
        address yieldAccAddr = vm.envAddress("YIELD_ACC");
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        RunConfig memory cfg = _readRunConfig();

        if (pk != 0) vm.startBroadcast(pk);
        else vm.startBroadcast();

        IAgriShareTokenAdmin token = IAgriShareTokenAdmin(tokenAddr);
        IYieldAccumulatorAdmin yAcc = IYieldAccumulatorAdmin(yieldAccAddr);

        _wireDistributionModule(token, yieldAccAddr);
        _configureHooks(token, cfg.enableHooks, cfg.failOpen, cfg.hookGas);
        _triggerHookOperation(token, cfg);

        bool seen = yAcc.hooksSeen();
        console2.log("YieldAccumulator hooksSeen =", seen);
        _configureStrictMode(yAcc, cfg.strict, seen);

        vm.stopBroadcast();
    }

    function _readRunConfig() internal view returns (RunConfig memory cfg) {
        cfg.enableHooks = vm.envOr("ENABLE_HOOKS", true);
        cfg.failOpen = vm.envOr("FAIL_OPEN", false);
        cfg.hookGas = uint32(vm.envOr("HOOK_GAS", uint256(200_000)));
        cfg.strict = vm.envOr("STRICT", false);

        cfg.doMint = vm.envOr("DO_MINT", false);
        cfg.mintTo = vm.envOr("MINT_TO", address(0));
        cfg.mintAmount = vm.envOr("MINT_AMOUNT", uint256(0));

        cfg.doTransfer = vm.envOr("DO_TRANSFER", false);
        cfg.transferTo = vm.envOr("TRANSFER_TO", address(0));
        cfg.transferAmount = vm.envOr("TRANSFER_AMOUNT", uint256(0));
    }

    function _wireDistributionModule(IAgriShareTokenAdmin token, address yieldAccAddr) internal {
        IAgriModulesV1.ModulesV1 memory mods = _buildModules(token, yieldAccAddr);
        console2.log("Setting modules.distribution -> YieldAccumulator:", yieldAccAddr);
        token.setModulesV1(mods);
    }

    function _configureHooks(IAgriShareTokenAdmin token, bool enableHooks, bool failOpen, uint32 hookGas) internal {
        if (!enableHooks) {
            console2.log("ENABLE_HOOKS=false (skipping setDistributionHooksConfig)");
            return;
        }

        console2.log("Config hooks: enabled=%s failOpen=%s gas=%s", enableHooks, failOpen, uint256(hookGas));
        token.setDistributionHooksConfig(true, failOpen, hookGas);
    }

    function _triggerHookOperation(IAgriShareTokenAdmin token, RunConfig memory cfg) internal {
        if (cfg.doMint) {
            require(cfg.mintTo != address(0), "MINT_TO missing");
            require(cfg.mintAmount != 0, "MINT_AMOUNT missing");
            console2.log("DO_MINT: minting", cfg.mintAmount, "to", cfg.mintTo);
            token.mint(cfg.mintTo, cfg.mintAmount);
            return;
        }

        if (cfg.doTransfer) {
            require(cfg.transferTo != address(0), "TRANSFER_TO missing");
            require(cfg.transferAmount != 0, "TRANSFER_AMOUNT missing");
            console2.log("DO_TRANSFER: transferring", cfg.transferAmount, "to", cfg.transferTo);
            bool ok = token.transfer(cfg.transferTo, cfg.transferAmount);
            require(ok, "TRANSFER_FAILED");
            return;
        }

        console2.log("No real op executed (set DO_MINT=true or DO_TRANSFER=true to flip hooksSeen).");
    }

    function _configureStrictMode(IYieldAccumulatorAdmin yAcc, bool strict, bool seen) internal {
        if (!strict) {
            console2.log("STRICT=false (skipping setRequireHooks)");
            return;
        }

        if (!seen) {
            console2.log("STRICT requested but hooksSeen==false. Skipping setRequireHooks(true).");
            console2.log("Do a mint/burn/transfer that triggers hooks, then rerun with STRICT=true.");
            return;
        }

        console2.log("Enabling YieldAccumulator requireHooks=true");
        yAcc.setRequireHooks(true);
    }

    function _buildModules(IAgriShareTokenAdmin token, address yieldAccAddr)
        internal
        view
        returns (IAgriModulesV1.ModulesV1 memory mods)
    {
        mods.compliance = token.complianceModule();
        mods.disaster = token.disasterModule();
        mods.freezeModule = token.freezeModule();
        mods.custody = token.custodyModule();
        mods.trace = token.traceModule();
        mods.documentRegistry = token.documentRegistry();
        mods.settlementQueue = token.settlementQueue();
        mods.treasury = token.treasury();
        mods.distribution = yieldAccAddr;
        mods.bridge = token.bridgeModule();
        mods.marketplace = token.marketplaceModule();
        mods.delivery = token.deliveryModule();
        mods.insurance = token.insuranceModule();
    }
}
