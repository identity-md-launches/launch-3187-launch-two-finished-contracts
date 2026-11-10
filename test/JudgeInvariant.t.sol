// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {JudgePoolBase} from "./Judge.t.sol";
import {JudgeInvariantHandler, JudgedInvariantVault} from "./support/JudgeInvariantHandler.sol";
import {IJudge} from "src/interfaces/IJudge.sol";

/// @notice Random call sequences across payments, callbacks, deadlines and value-holding consumers.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
contract JudgeInvariantTest is JudgePoolBase {
    JudgeInvariantHandler internal handler;
    JudgedInvariantVault internal vault;
    uint256 internal initialPoolEth;
    uint256 internal initialPoolTokens;
    uint256 internal constant ACTOR_ETH = 1000 ether;
    uint256 internal constant ACTOR_TOKENS = 1000 ether;
    uint256 internal constant INITIAL_POT = 100 ether;

    function setUp() public {
        setUpPool();
        addLiquidity(1000 ether);
        initialPoolEth = address(manager).balance;
        initialPoolTokens = imd.balanceOf(address(manager));
        vault = new JudgedInvariantVault{value: INITIAL_POT}(address(judge), address(door));
        address[4] memory actors;
        for (uint256 i; i < actors.length; ++i) {
            actors[i] = makeAddr(string.concat("invariant actor ", vm.toString(i)));
            vm.deal(actors[i], ACTOR_ETH);
            imd.transfer(actors[i], ACTOR_TOKENS);
            vm.prank(actors[i]);
            imd.approve(address(judge), type(uint256).max);
        }
        handler = new JudgeInvariantHandler(judge, door, vault, owner, writer, treasury, ATTESTER_KEY, actors);
        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = handler.askToken.selector;
        selectors[1] = handler.askEther.selector;
        selectors[2] = handler.claimVault.selector;
        selectors[3] = handler.answer.selector;
        selectors[4] = handler.oracleFailure.selector;
        selectors[5] = handler.advanceTime.selector;
        selectors[6] = handler.settle.selector;
        selectors[7] = handler.badCallback.selector;
        selectors[8] = handler.rejectedAsk.selector;
        selectors[9] = handler.setPrice.selector;
        selectors[10] = handler.donate.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_accountingAndCaseLifecycles() public view {
        assertEq(handler.failure(), "");
        assertEq(judge.caseCount(), handler.count(), "successful asks and case count diverged");
        assertEq(intake.nonce(), handler.count(), "payment without case / case without payment");
        assertEq(imd.balanceOf(treasury), handler.totalFees(), "treasury must receive exactly successful prices");
        assertEq(imd.balanceOf(address(judge)), handler.judgeDonations(), "Judge retained/spent unrelated tokens");
        assertEq(imd.balanceOf(address(door)), handler.doorDonations(), "door retained/spent unrelated tokens");
        assertEq(imd.balanceOf(address(intake)), 0);
        assertEq(address(judge).balance, 0);
        assertEq(address(door).balance, 0, "door kept somebody's change");
        assertEq(imd.allowance(address(judge), address(intake)), 0);
        assertEq(imd.allowance(address(door), address(judge)), 0);
        assertEq(
            address(manager).balance, initialPoolEth + handler.poolEtherReceived(), "ETH conservation across swaps"
        );
        assertEq(
            address(vault).balance + handler.vaultPaid(),
            INITIAL_POT + handler.stakesKept() + handler.vaultDonations(),
            "vault conservation"
        );

        uint256 directTokenFees;
        for (uint256 i; i < 4; ++i) {
            address actor = handler.actors(i);
            assertEq(actor.balance + handler.etherSpent(i), ACTOR_ETH + handler.payouts(i), "actor ETH accounting");
            assertEq(imd.balanceOf(actor) + handler.tokenSpent(i), ACTOR_TOKENS, "actor token accounting");
            assertEq(vault.paid(actor), handler.payouts(i), "beneficiary accounting");
            directTokenFees += handler.tokenSpent(i);
        }
        directTokenFees -= handler.judgeDonations() + handler.doorDonations();
        assertEq(
            imd.balanceOf(address(manager)) + handler.totalFees() - directTokenFees,
            initialPoolTokens,
            "exact output token conservation"
        );

        for (uint256 i; i < handler.count(); ++i) {
            JudgeInvariantHandler.ModelCase memory c = handler.caseModel(i);
            (uint48 askedAt, IJudge.Verdict stored, bytes32 hash) = judge.cases(i + 1);
            assertEq(judge.caseOfRequest(c.request), i + 1);
            assertEq(askedAt, c.askedAt, "case timestamp changed");
            assertEq(hash, c.questionHash, "case question changed");
            assertEq(uint8(stored), c.result, "stored result changed after completion");
            assertEq(uint8(judge.verdict(i + 1)), handler.expectedVerdict(i), "verdict reopened or changed");
            assertEq(vault.hookCalls(i + 1), c.settled ? 1 : 0, "hook ran for unknown case or ran twice");
            assertEq(vault.ran(i + 1), c.settled ? handler.expectedVerdict(i) : 0);
            if (c.fromVault) assertEq(vault.beneficiary(i + 1), handler.actors(c.ownerIndex));
        }
        assertEq(uint8(judge.verdict(0)), PENDING);
        assertEq(uint8(judge.verdict(handler.count() + 1)), PENDING);
    }

    /// @dev A deterministic witness that every important handler branch can make progress.
    /// Random campaigns start empty and discover their own ordering independently.
    function test_handlerReachesPaymentSettlementFailureAndTimeout() public {
        handler.askToken(0);
        handler.askEther(1, 0);
        handler.claimVault(2, 1 ether, 0);
        handler.answer(2, true);
        handler.settle(2, 3);
        handler.settle(2, 0);
        handler.oracleFailure(0, true);
        handler.claimVault(3, 0, 1);
        handler.answer(3, false);
        handler.settle(3, 0);
        handler.claimVault(1, 10, 0);
        handler.advanceTime(1 days + 1);
        handler.settle(4, 0);
        handler.answer(1, true);
        handler.badCallback(0, 2);
        handler.rejectedAsk(1, false);
        handler.rejectedAsk(1, true);
        handler.donate(0, 10, 0);
        handler.donate(1, 10, 1);
        handler.donate(2, 10, 2);
        handler.setPrice(1);
        handler.askEther(0, 0);
        invariant_accountingAndCaseLifecycles();
        assertEq(handler.successfulTokenAsks(), 1);
        assertEq(handler.successfulDoorAsks(), 2);
        assertEq(handler.successfulVaultAsks(), 3);
        assertEq(handler.successfulAnswers(), 2);
        assertEq(handler.successfulFailures(), 1);
        assertEq(handler.successfulSettlements(), 3);
        assertGt(handler.rejectedCalls(), 0);
    }
}
