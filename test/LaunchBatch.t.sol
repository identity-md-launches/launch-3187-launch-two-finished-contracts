// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Judge} from "src/Judge.sol";
import {JudgeEthDoor} from "src/JudgeEthDoor.sol";
import {IIntake} from "src/interfaces/IIntake.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

contract JudgeBatchDeploymentProbe {
    function deploy(bytes32 salt) external returns (Judge judge, JudgeEthDoor door) {
        judge = new Judge{salt: salt}(
            0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982,
            IIntake(0xa43e6F75ee006411F79Ac1C84120606C2330DE82),
            IERC20(0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7),
            100,
            51
        );
        door = new JudgeEthDoor{salt: salt}(
            judge,
            IERC20(0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7),
            IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90),
            10000,
            200
        );
    }
}

contract LaunchBatchTest is Test {
    function test_factoryDeploysExactlyTheTwoApplicationsInOneCall() public {
        vm.chainId(1);
        JudgeBatchDeploymentProbe factory = new JudgeBatchDeploymentProbe();
        bytes32 salt = keccak256("unit test launch salt");
        assertEq(address(0xa43e6F75ee006411F79Ac1C84120606C2330DE82).code.length, 0);
        assertEq(address(0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7).code.length, 0);
        assertEq(address(0x000000000004444c5dc75cB358380D2e3dE08A90).code.length, 0);

        // Both creations occur inside one EVM call, matching the launch transaction.
        (Judge judge, JudgeEthDoor door) = factory.deploy(salt);
        assertEq(address(door.judge()), address(judge));
        assertEq(address(door.asset()), address(judge.asset()));
        assertEq(judge.oracleSigner(), 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982);
        assertEq(judge.panelSize(), 100);
        assertEq(judge.quorum(), 51);
        assertEq(door.poolFee(), 10000);
        assertEq(door.poolTickSpacing(), 200);
        assertEq(address(judge).balance, 0);
        assertEq(address(door).balance, 0);
        assertEq(vm.getNonce(address(factory)), 3, "factory did not create exactly two contracts");
        assertEq(vm.getNonce(address(judge)), 1, "Judge created an extra contract");
        assertEq(vm.getNonce(address(door)), 1, "door created an extra contract");
    }
}
