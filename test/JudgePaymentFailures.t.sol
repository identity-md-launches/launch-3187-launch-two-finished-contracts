// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {JudgeBase} from "./Judge.t.sol";
import {Judge} from "src/Judge.sol";
import {IIntake} from "src/interfaces/IIntake.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MockERC20} from "./support/MockERC20.sol";

/// @dev Test-only ERC20 with selectable return conventions. Mutates before returning false,
/// so an ignored return value would leave an observable, partially completed payment.
contract PaymentPolicyToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    address public falseFrom;
    bool public falseApproval;
    bool public noReturn;
    bool public resetFirst;

    constructor() {
        balanceOf[msg.sender] = 1_000_000 ether;
    }

    function policy(address falseFrom_, bool falseApproval_, bool noReturn_, bool resetFirst_) external {
        falseFrom = falseFrom_;
        falseApproval = falseApproval_;
        noReturn = noReturn_;
        resetFirst = resetFirst_;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        if (falseApproval || (resetFirst && amount != 0 && allowance[msg.sender][spender] != 0)) return false;
        allowance[msg.sender][spender] = amount;
        if (noReturn) {
            assembly ("memory-safe") { return(0, 0) }
        }
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        if (noReturn) {
            assembly ("memory-safe") { return(0, 0) }
        }
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        if (noReturn) {
            assembly ("memory-safe") { return(0, 0) }
        }
        return from != falseFrom;
    }
}

contract JudgePaymentFailuresTest is JudgeBase {
    PaymentPolicyToken internal token;

    function setUp() public {
        setUpChain();
        token = new PaymentPolicyToken();
        imd = MockERC20(address(token));
        judge = new Judge(vm.addr(ATTESTER_KEY), IIntake(address(intake)), IERC20(address(token)), 100, 51);
        vm.prank(owner);
        intake.setPrice(ORACLE, address(token), PRICE);
        fund(alice);
    }

    function _unpaid() internal view {
        assertEq(judge.caseCount(), 0);
        assertEq(intake.nonce(), 0);
        assertEq(token.balanceOf(alice), 10 ether);
        assertEq(token.balanceOf(treasury), 0);
        assertEq(token.balanceOf(address(judge)), 0);
        assertEq(token.balanceOf(address(intake)), 0);
        assertEq(token.allowance(address(judge), address(intake)), 0);
    }

    function _expectTokenFailure() internal {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        judge.ask(RULE, PROOF);
        _unpaid();
        token.policy(address(0), false, false, false);
        assertEq(judge.caseOfRequest(askAs(alice)), 1, "reverted payment consumed case id");
    }

    function test_falseReturnOnFirstPullRevertsTheMutation() public {
        token.policy(alice, false, false, false);
        _expectTokenFailure();
    }

    function test_falseReturnOnIntakePullRevertsBothTransfers() public {
        token.policy(address(judge), false, false, false);
        _expectTokenFailure();
    }

    function test_failedApprovalRollsBackPayersTransfer() public {
        token.policy(address(0), true, false, false);
        _expectTokenFailure();
    }

    function test_tokensWithoutReturnDataCanPayThroughBothHops() public {
        token.policy(address(0), false, true, false);
        askAs(alice);
        assertEq(token.balanceOf(treasury), PRICE);
        assertEq(token.balanceOf(alice), 10 ether - PRICE);
        assertEq(token.balanceOf(address(judge)), 0);
        assertEq(token.balanceOf(address(intake)), 0);
        assertEq(token.allowance(address(judge), address(intake)), 0);
    }

    function test_forceApproveClearsAResidualAllowanceForResetFirstToken() public {
        vm.prank(address(judge));
        token.approve(address(intake), 7);
        token.policy(address(0), false, false, true);
        askAs(alice);
        assertEq(token.balanceOf(treasury), PRICE);
        assertEq(token.allowance(address(judge), address(intake)), 0);
    }

    function test_intakeRevertRollsBackPaymentApprovalAndCounter() public {
        bytes memory error = abi.encodeWithSignature("Error(string)", "intake unavailable");
        vm.mockCallRevert(address(intake), abi.encodeWithSelector(IIntake.requestWithFailure.selector), error);
        vm.prank(alice);
        vm.expectRevert(error);
        judge.ask(RULE, PROOF);
        _unpaid();
        vm.clearMockedCalls();
        assertEq(judge.caseOfRequest(askAs(alice)), 1);
    }
}
