// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {JudgePoolBase} from "./Judge.t.sol";
import {JudgedInvariantVault} from "./support/JudgeInvariantHandler.sol";

contract JudgedAdversarialReceiver {
    JudgedInvariantVault private immutable vault;
    bool public refuse;
    bool public attack;
    bool private entered;
    uint256 public otherId;
    uint256 public attempts;
    uint256 public successfulReentries;
    bytes public askError;
    bytes public settleError;

    constructor(JudgedInvariantVault vault_) {
        vault = vault_;
    }

    function configure(bool refuse_, bool attack_, uint256 otherId_) external {
        refuse = refuse_;
        attack = attack_;
        otherId = otherId_;
    }

    function claim(uint256 budget) external payable returns (uint256) {
        return vault.claim{value: msg.value}(budget);
    }

    receive() external payable {
        require(!refuse, "recipient refuses ETH");
        if (!attack || entered) return;
        entered = true;
        ++attempts;
        (bool ok, bytes memory data) = address(vault).call{value: 2 ether}(abi.encodeCall(vault.claim, (2 ether)));
        if (ok) ++successfulReentries;
        askError = data;
        (ok, data) = address(vault).call(abi.encodeCall(vault.settle, (otherId)));
        if (ok) ++successfulReentries;
        settleError = data;
        entered = false;
    }
}

/// @notice Run adversarial ETH receivers through the actual Judge/Intake/v4 stack.
/// forge-config: default.fuzz.runs = 1000
contract JudgedAdversarialTest is JudgePoolBase {
    JudgedInvariantVault internal vault;
    JudgedAdversarialReceiver internal receiver;

    function setUp() public {
        setUpPool();
        addLiquidity(1000 ether);
        vault = new JudgedInvariantVault{value: 100 ether}(address(judge), address(door));
        receiver = new JudgedAdversarialReceiver(vault);
        vm.deal(address(receiver), 100 ether);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    function _yes(uint256 id) internal {
        bytes32 request = lastRequest();
        assertEq(judge.caseOfRequest(request), id);
        assertTrue(deliver(request, attestation(hashOf(request), true)));
    }

    function _checkBlocked() internal view {
        assertGt(receiver.attempts(), 0);
        assertEq(receiver.successfulReentries(), 0);
        assertEq(
            receiver.askError(),
            abi.encodeWithSignature("Error(string)", "Judged: can't ask from inside another Judged call")
        );
        assertEq(
            receiver.settleError(),
            abi.encodeWithSignature("Error(string)", "Judged: can't settle from inside another Judged call")
        );
    }

    function test_refundCannotSettleAnOlderYesOrOpenAnotherQuestion() public {
        vm.prank(alice);
        uint256 older = vault.claim{value: 2 ether}(2 ether);
        _yes(older);
        receiver.configure(false, true, older);
        vm.prank(bob);
        uint256 newer = receiver.claim{value: 2 ether}(2 ether);
        _checkBlocked();
        assertEq(newer, older + 1);
        assertEq(vault.hookCalls(older), 0);
        assertEq(address(vault).balance, 100 ether);
        // The rejected reentries must not leave the guard stuck.
        vault.settle(older);
        assertEq(vault.hookCalls(older), 1);
    }

    function test_payoutCannotOpenACaseOrSettleAnotherYes() public {
        uint256 first = receiver.claim{value: 2 ether}(2 ether);
        _yes(first);
        vm.roll(vm.getBlockNumber() + 1);
        uint256 second = receiver.claim{value: 2 ether}(2 ether);
        _yes(second);
        receiver.configure(false, true, second);
        vault.settle(first);
        _checkBlocked();
        assertEq(judge.caseCount(), 2);
        assertEq(vault.hookCalls(first), 1);
        assertEq(vault.hookCalls(second), 0);
        receiver.configure(false, false, 0);
        vault.settle(second);
        assertEq(vault.paid(address(receiver)), 2 * vault.REWARD());
    }

    function test_rejectingWinnerCanRetryAndCannotBlockAnotherWinner() public {
        uint256 first = receiver.claim{value: 2 ether}(2 ether);
        _yes(first);
        vm.prank(alice);
        uint256 second = vault.claim{value: 2 ether}(2 ether);
        _yes(second);
        receiver.configure(true, false, 0);
        vm.expectRevert("Judged: payment failed");
        vault.settle(first);
        assertEq(address(vault).balance, 100 ether);
        assertEq(vault.hookCalls(first), 0, "failed payout consumed hook");
        assertEq(vault.paid(address(receiver)), 0);
        vault.settle(second);
        assertEq(vault.hookCalls(second), 1);
        receiver.configure(false, false, 0);
        vault.settle(first);
        assertEq(vault.hookCalls(first), 1);
        assertEq(address(vault).balance, 100 ether - 2 * vault.REWARD());
        vm.expectRevert("Judged: not an open question of this contract");
        vault.settle(first);
    }

    function test_refusedChangeRollsBackCaseStakeAndPoolAndCanRetrySameBlock() public {
        receiver.configure(true, false, 0);
        uint256 poolBefore = address(manager).balance;
        uint256 receiverBefore = address(receiver).balance;
        vm.expectRevert("Judged: payment failed");
        receiver.claim{value: 2.1 ether}(2 ether);
        assertEq(address(vault).balance, 100 ether);
        assertEq(address(receiver).balance, receiverBefore);
        assertEq(address(manager).balance, poolBefore);
        assertEq(judge.caseCount(), 0);
        assertEq(intake.nonce(), 0);
        assertEq(imd.balanceOf(treasury), 0);
        receiver.configure(false, false, 0);
        uint256 id = receiver.claim{value: 2.1 ether}(2 ether);
        assertEq(id, 1, "reverted refund consumed the same-block ask guard");
        assertEq(address(vault).balance, 100.1 ether);
    }

    function testFuzz_onlyTheExplicitStakeStaysAndRelayerCannotStealReward(uint256 stake, uint256 budget) public {
        stake = bound(stake, 0, 10 ether);
        budget = bound(budget, 2 ether, 3 ether);
        uint256 poolBefore = address(manager).balance;
        vm.prank(alice);
        uint256 id = vault.claim{value: budget + stake}(budget);
        assertEq(address(vault).balance, 100 ether + stake);
        uint256 spent = address(manager).balance - poolBefore;
        assertEq(alice.balance, 100 ether - stake - spent);
        _yes(id);
        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        vault.settle(id);
        assertEq(bob.balance, bobBefore, "permissionless settler took beneficiary's payment");
        assertEq(alice.balance, 100 ether - spent + vault.REWARD());
        assertEq(address(vault).balance, 100 ether - vault.REWARD());
    }
}
