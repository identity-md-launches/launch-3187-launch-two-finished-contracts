// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {JudgePoolBase, JudgeNoReceive} from "./Judge.t.sol";
import {JudgeEthDoor} from "src/JudgeEthDoor.sol";
import {Judge} from "src/Judge.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";

/// @dev Every recursive ask spends only the previous ask's refund. Preexisting ETH must survive.
contract RepeatedDoorCaller {
    JudgeEthDoor private immutable door;
    uint256 private remaining;
    uint256 public asks;

    constructor(JudgeEthDoor door_) {
        door = door_;
    }

    function start(uint256 count) external payable {
        remaining = count - 1;
        ++asks;
        door.ask{value: msg.value}("The proof must name Paris.", "Paris");
    }

    receive() external payable {
        if (remaining != 0) {
            --remaining;
            ++asks;
            door.ask{value: msg.value}("The proof must name Paris.", "Paris");
        }
    }
}

/// forge-config: default.fuzz.runs = 1000
contract JudgeEthDoorPropertiesTest is JudgePoolBase {
    using PoolIdLibrary for *;

    struct PoolSnapshot {
        uint256 eth;
        uint256 tokens;
        uint160 sqrtPrice;
        int24 tick;
        uint256 nonce;
        uint256 cases;
    }

    function setUp() public {
        setUpPool();
    }

    function _snapshot() internal view returns (PoolSnapshot memory s) {
        s.eth = address(manager).balance;
        s.tokens = imd.balanceOf(address(manager));
        (s.sqrtPrice, s.tick,,) = StateLibrary.getSlot0(manager, key.toId());
        s.nonce = intake.nonce();
        s.cases = judge.caseCount();
    }

    function _assertRolledBack(PoolSnapshot memory s) internal view {
        PoolSnapshot memory after_ = _snapshot();
        assertEq(after_.eth, s.eth, "failed ask changed pool ETH");
        assertEq(after_.tokens, s.tokens, "failed ask changed pool tokens");
        assertEq(after_.sqrtPrice, s.sqrtPrice, "failed ask moved price");
        assertEq(after_.tick, s.tick, "failed ask moved tick");
        assertEq(after_.nonce, s.nonce, "failed ask paid for an intake request");
        assertEq(after_.cases, s.cases, "failed ask created a case");
        assertEq(imd.allowance(address(door), address(judge)), 0);
        assertEq(imd.allowance(address(judge), address(intake)), 0);
        assertEq(imd.balanceOf(address(judge)), 0);
    }

    function testFuzz_exactOutputAndRefundConserveBothAssets(uint256 price, uint256 liquidity, uint256 budget) public {
        price = bound(price, 1, 1 ether);
        liquidity = bound(liquidity, 10 ether, 500 ether);
        budget = bound(budget, 2 ether, 10 ether);
        addLiquidity(int256(liquidity));
        vm.prank(owner);
        intake.setPrice(ORACLE, address(imd), price);
        PoolSnapshot memory s = _snapshot();
        vm.prank(alice);
        uint256 id = door.ask{value: budget}(RULE, PROOF);
        uint256 spent = 10 ether - alice.balance;
        assertGt(spent, 0);
        assertLe(spent, budget);
        assertEq(address(manager).balance - s.eth, spent, "refund differs from actual pool debit");
        assertEq(s.tokens - imd.balanceOf(address(manager)), price, "swap output is not exact");
        assertEq(imd.balanceOf(treasury), price);
        assertEq(id, 1);
        assertEq(imd.balanceOf(address(door)), 0);
        assertEq(address(door).balance, 0);
        assertEq(imd.allowance(address(door), address(judge)), 0);
    }

    function testFuzz_oneWeiBelowTheQuoteRollsBackEverything(uint256 price) public {
        price = bound(price, 1, 1 ether);
        addLiquidity(100 ether);
        vm.prank(owner);
        intake.setPrice(ORACLE, address(imd), price);
        uint256 snapshot = vm.snapshotState();
        vm.prank(alice);
        door.ask{value: 2 ether}(RULE, PROOF);
        uint256 cost = 10 ether - alice.balance;
        assertTrue(vm.revertToState(snapshot));
        PoolSnapshot memory s = _snapshot();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(JudgeEthDoor.EthShort.selector, cost, cost - 1));
        door.ask{value: cost - 1}(RULE, PROOF);
        _assertRolledBack(s);
        assertEq(alice.balance, 10 ether);
        assertEq(imd.balanceOf(treasury), 0);

        // The identical swap succeeds at the exact threshold, without any refund call.
        JudgeNoReceive caller = new JudgeNoReceive();
        vm.prank(alice);
        caller.ask{value: cost}(door, RULE, PROOF);
        assertEq(alice.balance, 10 ether - cost);
        assertEq(address(caller).balance, 0);
        assertEq(imd.balanceOf(treasury), price);
    }

    function test_donatedEthAndTokensDoNotSubsidizeTheNextAsker() public {
        addLiquidity(100 ether);
        vm.deal(address(door), 50 ether); // Models ETH forced in without a receive call.
        imd.transfer(address(door), 7 ether);
        PoolSnapshot memory s = _snapshot();
        vm.prank(alice);
        vm.expectPartialRevert(JudgeEthDoor.EthShort.selector);
        door.ask(RULE, PROOF);
        _assertRolledBack(s);
        vm.prank(alice);
        door.ask{value: 1 ether}(RULE, PROOF);
        assertEq(address(door).balance, 50 ether, "forced ETH went to another payer");
        assertEq(imd.balanceOf(address(door)), 7 ether, "donated tokens paid another case");
        assertEq(10 ether - alice.balance, address(manager).balance - s.eth);
        assertEq(imd.balanceOf(treasury), PRICE);
    }

    function test_refundFailureRevertsPoolPriceAndPaymentThenAnotherUserSucceeds() public {
        addLiquidity(100 ether);
        JudgeNoReceive caller = new JudgeNoReceive();
        PoolSnapshot memory s = _snapshot();
        vm.prank(alice);
        vm.expectRevert(JudgeEthDoor.RefundFailed.selector);
        caller.ask{value: 2 ether}(door, RULE, PROOF);
        _assertRolledBack(s);
        assertEq(alice.balance, 10 ether);
        assertEq(imd.balanceOf(treasury), 0);
        vm.prank(bob);
        assertEq(door.ask{value: 2 ether}(RULE, PROOF), 1);
        assertEq(imd.balanceOf(treasury), PRICE);
    }

    function test_invalidTextAfterTheSwapRevertsPoolState() public {
        addLiquidity(100 ether);
        PoolSnapshot memory s = _snapshot();
        bytes memory invalid = hex"ff";
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Judge.NotAscii.selector, 0));
        door.ask{value: 2 ether}(RULE, string(invalid));
        _assertRolledBack(s);
        assertEq(imd.balanceOf(treasury), 0);
        assertEq(alice.balance, 10 ether);
    }

    function test_partialOutputCannotSpendDustOrChargeForACase() public {
        addLiquidity(0.01 ether);
        imd.transfer(address(door), 7 ether);
        PoolSnapshot memory s = _snapshot();
        vm.prank(alice);
        vm.expectRevert(JudgeEthDoor.IncompleteSwap.selector);
        door.ask{value: 5 ether}(RULE, PROOF);
        _assertRolledBack(s);
        assertEq(imd.balanceOf(address(door)), 7 ether);
        assertEq(imd.balanceOf(treasury), 0);
        assertEq(alice.balance, 10 ether);
    }

    function testFuzz_nestedRefundsAreFundedByTheirOwnCaller(uint8 count) public {
        count = uint8(bound(count, 1, 5));
        addLiquidity(100 ether);
        RepeatedDoorCaller caller = new RepeatedDoorCaller(door);
        vm.deal(address(caller), 30 ether);
        vm.deal(address(door), 17 ether);
        imd.transfer(address(door), 3 ether);
        uint256 poolBefore = address(manager).balance;
        vm.prank(alice);
        caller.start{value: 5 ether}(count);
        uint256 poolCost = address(manager).balance - poolBefore;
        assertEq(caller.asks(), count);
        assertEq(judge.caseCount(), count);
        assertEq(imd.balanceOf(treasury), uint256(count) * PRICE);
        assertEq(address(caller).balance + poolCost, 35 ether);
        assertGe(address(caller).balance, 30 ether);
        assertEq(address(door).balance, 17 ether);
        assertEq(imd.balanceOf(address(door)), 3 ether);
        assertEq(imd.allowance(address(door), address(judge)), 0);
    }
}
