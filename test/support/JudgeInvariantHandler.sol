// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Judge} from "src/Judge.sol";
import {JudgeEthDoor} from "src/JudgeEthDoor.sol";
import {Judged} from "src/Judged.sol";
import {IJudge} from "src/interfaces/IJudge.sol";
import {OracleAttestation} from "src/OracleAttestation.sol";
import {Intake} from "./Intake.sol";
import {MockERC20} from "./MockERC20.sol";

/// @dev A value-holding consumer exercising the actual base class, including its budget,
/// refund, open-case and reentrancy machinery. Only the routing and outcome hooks are supplied.
contract JudgedInvariantVault is Judged {
    address private immutable judgeAt;
    address private immutable doorAt;
    uint256 public constant REWARD = 0.01 ether;
    mapping(uint256 => address) public beneficiary;
    mapping(uint256 => uint256) public stake;
    mapping(uint256 => uint8) public ran;
    mapping(uint256 => uint256) public hookCalls;
    mapping(address => uint256) public paid;

    constructor(address judge_, address door_) payable {
        judgeAt = judge_;
        doorAt = door_;
    }

    function claim(uint256 budget) external payable returns (uint256 id) {
        string memory rule = string.concat("The proof must name Paris. Claimant ", Strings.toHexString(msg.sender));
        id = ask(rule, "Paris", budget);
        beneficiary[id] = msg.sender;
        stake[id] = msg.value - budget;
    }

    function _judge() internal view override returns (address, address) {
        return (judgeAt, doorAt);
    }

    function onYes(uint256 id) internal override {
        ran[id] = 1;
        ++hookCalls[id];
        uint256 amount = stake[id] + REWARD;
        paid[beneficiary[id]] += amount;
        pay(beneficiary[id], amount);
    }

    function onNo(uint256 id) internal override {
        ran[id] = 2;
        ++hookCalls[id];
    }

    function onNoAnswer(uint256 id) internal override {
        ran[id] = 3;
        ++hookCalls[id];
    }
}

/// @dev Four independently funded actors; no replenishing balances after setup. Unexpected
/// outcomes persist in `failure` so invariant fail_on_revert=false cannot hide an assertion.
contract JudgeInvariantHandler is Test {
    struct ModelCase {
        bytes32 request;
        bytes32 questionHash;
        uint256 askedAt;
        uint64 atBlock;
        uint256 ownerIndex;
        uint256 stake;
        uint8 result;
        bool fromVault;
        bool completed;
        bool settled;
    }

    Judge public immutable judge;
    JudgeEthDoor public immutable door;
    Intake public immutable intake;
    MockERC20 public immutable token;
    JudgedInvariantVault public immutable vault;
    address public immutable treasury;
    address public immutable priceOwner;
    address public immutable writer;
    uint256 private immutable signerKey;
    address[4] public actors;
    ModelCase[] private model;
    uint256[4] public etherSpent;
    uint256[4] public tokenSpent;
    uint256[4] public payouts;
    uint256 public totalFees;
    uint256 public poolEtherReceived;
    uint256 public stakesKept;
    uint256 public vaultPaid;
    uint256 public judgeDonations;
    uint256 public doorDonations;
    uint256 public vaultDonations;
    uint256 public successfulTokenAsks;
    uint256 public successfulDoorAsks;
    uint256 public successfulVaultAsks;
    uint256 public rejectedCalls;
    uint256 public successfulAnswers;
    uint256 public successfulFailures;
    uint256 public successfulSettlements;
    string public failure;

    constructor(
        Judge judge_,
        JudgeEthDoor door_,
        JudgedInvariantVault vault_,
        address owner_,
        address writer_,
        address treasury_,
        uint256 signerKey_,
        address[4] memory actors_
    ) {
        judge = judge_;
        door = door_;
        vault = vault_;
        intake = Intake(address(judge_.intake()));
        token = MockERC20(address(judge_.asset()));
        priceOwner = owner_;
        writer = writer_;
        treasury = treasury_;
        signerKey = signerKey_;
        actors = actors_;
    }

    function _check(bool ok, string memory message) internal {
        if (!ok && bytes(failure).length == 0) failure = message;
    }

    function count() external view returns (uint256) {
        return model.length;
    }

    function caseModel(uint256 index) external view returns (ModelCase memory) {
        return model[index];
    }

    function _record(uint256 id, uint256 actor, bool fromVault, uint256 stake, uint256 fee) internal {
        _check(id == model.length + 1, "case ids are not consecutive");
        (uint48 askedAt, IJudge.Verdict result, bytes32 hash) = judge.cases(id);
        _check(uint8(result) == 0 && askedAt == vm.getBlockTimestamp(), "new case not pending at current time");
        bytes32 request = keccak256(abi.encode(block.chainid, address(intake), intake.nonce()));
        _check(judge.caseOfRequest(request) == id, "request bound to wrong case");
        // All asks occur in different calls, so intake's nonce is the just-completed request.
        model.push(
            ModelCase(
                request,
                hash,
                vm.getBlockTimestamp(),
                uint64(vm.getBlockNumber() - 8),
                actor,
                stake,
                0,
                fromVault,
                false,
                false
            )
        );
        totalFees += fee;
    }

    function askToken(uint256 actorSeed) external {
        uint256 actor = actorSeed % 4;
        uint256 fee = judge.price();
        uint256 beforeToken = token.balanceOf(actors[actor]);
        if (beforeToken < fee) return;
        vm.prank(actors[actor]);
        try judge.ask("The proof must name Paris.", "Paris") returns (uint256 id) {
            _check(token.balanceOf(actors[actor]) + fee == beforeToken, "token payer charged wrong price");
            tokenSpent[actor] += fee;
            ++successfulTokenAsks;
            _record(id, actor, false, 0, fee);
        } catch {
            _check(false, "funded token ask unexpectedly reverted");
        }
    }

    function askEther(uint256 actorSeed, uint256 extraSeed) external {
        uint256 actor = actorSeed % 4;
        uint256 budget = 2 ether + bound(extraSeed, 0, 1 ether);
        uint256 beforeEth = actors[actor].balance;
        uint256 fee = judge.price();
        vm.prank(actors[actor]);
        try door.ask{value: budget}("The proof must name Paris.", "Paris") returns (uint256 id) {
            if (actors[actor].balance > beforeEth) {
                _check(false, "door minted payer ETH");
                return;
            }
            uint256 spent = beforeEth - actors[actor].balance;
            _check(spent > 0 && spent <= budget, "door overspent budget or created free output");
            etherSpent[actor] += spent;
            poolEtherReceived += spent;
            ++successfulDoorAsks;
            _record(id, actor, false, 0, fee);
        } catch {
            _check(false, "funded ETH ask unexpectedly reverted");
        }
    }

    function claimVault(uint256 actorSeed, uint256 stakeSeed, uint256 extraSeed) external {
        uint256 actor = actorSeed % 4;
        uint256 stake = bound(stakeSeed, 0, 0.1 ether);
        uint256 budget = 2 ether + bound(extraSeed, 0, 1 ether);
        // This path deliberately advances one block. Same-block collisions are exercised
        // separately, rather than filtering nearly every otherwise valid claim.
        vm.roll(vm.getBlockNumber() + 1);
        uint256 beforeEth = actors[actor].balance;
        uint256 beforePot = address(vault).balance;
        uint256 fee = judge.price();
        vm.prank(actors[actor]);
        try vault.claim{value: budget + stake}(budget) returns (uint256 id) {
            if (actors[actor].balance > beforeEth) {
                _check(false, "vault minted payer ETH");
                return;
            }
            uint256 spent = beforeEth - actors[actor].balance;
            _check(spent > stake && spent <= budget + stake, "vault claim spent wrong amount");
            if (spent < stake) return;
            _check(address(vault).balance == beforePot + stake, "ask spent existing vault funds");
            etherSpent[actor] += spent;
            poolEtherReceived += spent - stake;
            stakesKept += stake;
            ++successfulVaultAsks;
            _record(id, actor, true, stake, fee);
        } catch {
            _check(false, "funded vault claim unexpectedly reverted");
        }
    }

    function setPrice(uint256 seed) external {
        // Includes dust; high bounds keep the finite real pool liquid for every sequence.
        uint256 fee = bound(seed, 1, 0.5 ether);
        vm.prank(priceOwner);
        intake.setPrice(bytes32("oracle.request@oracle-1"), address(token), fee);
    }

    function advanceTime(uint256 seed) external {
        vm.warp(vm.getBlockTimestamp() + bound(seed, 0, 1 days + 1));
        vm.roll(vm.getBlockNumber() + 1);
    }

    function _attestation(uint256 index, bool yes) internal view returns (OracleAttestation.Attestation memory a) {
        ModelCase storage c = model[index];
        a.requestId = keccak256(abi.encode("oracle uuid", c.request));
        a.chainId = block.chainid;
        a.questionHash = c.questionHash;
        a.answer = abi.encode(yes);
        a.fromBlock = c.atBlock;
        a.toBlock = c.atBlock;
        a.panelSize = 100;
        a.quorum = 51;
        a.agreed = 51;
        a.issuedAt = uint64(vm.getBlockTimestamp());
        a.expiresAt = uint64(vm.getBlockTimestamp() + 1 days);
    }

    function _signature(OracleAttestation.Attestation memory a) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, judge.attestationDigest(a));
        return abi.encodePacked(r, s, v);
    }

    function answer(uint256 caseSeed, bool yes) external {
        if (model.length == 0) return;
        uint256 index = caseSeed % model.length;
        ModelCase storage c = model[index];
        OracleAttestation.Attestation memory a = _attestation(index, yes);
        bytes memory args = abi.encode(c.request, a, _signature(a));
        vm.prank(writer);
        (bool ok,) = address(intake).call(abi.encodeCall(intake.complete, (c.request, 0, bytes32(0), "", args)));
        if (c.completed) {
            _check(!ok, "intake completed a request twice");
            ++rejectedCalls;
            return;
        }
        _check(ok, "writer could not complete request");
        c.completed = true;
        if (vm.getBlockTimestamp() <= c.askedAt + 1 days) {
            c.result = yes ? 1 : 2;
            ++successfulAnswers;
        }
        // A late delivery is still attempted once but cannot reopen the timed-out case.
        _check(uint8(judge.verdict(index + 1)) == expectedVerdict(index), "signed callback produced wrong verdict");
    }

    function oracleFailure(uint256 caseSeed, bool refused) external {
        if (model.length == 0) return;
        uint256 index = caseSeed % model.length;
        ModelCase storage c = model[index];
        uint8 status = refused ? 1 : 2;
        bytes memory args = abi.encode(c.request, status, bytes32("disagreed"), uint16(40), uint16(100), bytes(""));
        vm.prank(writer);
        (bool ok,) = address(intake).call(abi.encodeCall(intake.complete, (c.request, status, bytes32(0), "", args)));
        if (c.completed) {
            _check(!ok, "failure overwrote completed intake request");
            ++rejectedCalls;
            return;
        }
        _check(ok, "writer failure delivery reverted");
        c.completed = true;
        c.result = 3;
        ++successfulFailures;
        _check(uint8(judge.verdict(index + 1)) == 3, "failure was not NoAnswer");
    }

    function expectedVerdict(uint256 index) public view returns (uint8) {
        ModelCase storage c = model[index];
        if (c.result != 0) return c.result;
        return vm.getBlockTimestamp() > c.askedAt + 1 days ? 3 : 0;
    }

    function settle(uint256 caseSeed, uint256 callerSeed) external {
        if (model.length == 0) return;
        uint256 index = caseSeed % model.length;
        ModelCase storage c = model[index];
        uint8 result = expectedVerdict(index);
        bool allowed = c.fromVault && !c.settled && result != 0;
        uint256 beforePot = address(vault).balance;
        vm.prank(actors[callerSeed % 4]);
        (bool ok,) = address(vault).call(abi.encodeCall(vault.settle, (index + 1)));
        _check(ok == allowed, "settlement did not obey own-case / final / one-shot checks");
        if (!allowed) {
            _check(address(vault).balance == beforePot, "rejected settlement moved funds");
            ++rejectedCalls;
            return;
        }
        c.settled = true;
        ++successfulSettlements;
        _check(vault.ran(index + 1) == result, "wrong outcome hook ran");
        if (result == 1) {
            uint256 amount = c.stake + vault.REWARD();
            vaultPaid += amount;
            payouts[c.ownerIndex] += amount;
            _check(address(vault).balance + amount == beforePot, "yes paid wrong amount");
        } else {
            _check(address(vault).balance == beforePot, "non-yes settlement spent the pot");
        }
    }

    function badCallback(uint256 caseSeed, uint8 attackSeed) external {
        if (model.length == 0) return;
        uint256 index = caseSeed % model.length;
        ModelCase storage c = model[index];
        OracleAttestation.Attestation memory a = _attestation(index, true);
        uint8 attack = attackSeed % 5;
        address sender = address(intake);
        bytes32 request = c.request;
        if (attack == 0) a.questionHash ^= bytes32(uint256(1));
        else if (attack == 1) a.agreed = 50;
        else if (attack == 2) sender = actors[0];
        else if (attack == 3) request = keccak256("not a request this judge made");
        bytes memory signature = _signature(a);
        if (attack == 4) a.answer = abi.encode(false);
        vm.prank(sender);
        (bool ok,) = address(judge).call(abi.encodeCall(judge.onOracleResult, (request, a, signature)));
        _check(!ok, "invalid callback accepted");
        ++rejectedCalls;
    }

    function rejectedAsk(uint256 actorSeed, bool badText) external {
        uint256 actor = actorSeed % 4;
        uint256 beforeEth = actors[actor].balance;
        uint256 beforeCases = judge.caseCount();
        uint256 beforeTreasury = token.balanceOf(treasury);
        vm.prank(actors[actor]);
        (bool ok,) =
            address(door).call{value: badText ? 2 ether : 0}(abi.encodeCall(door.ask, (badText ? "" : "rule", "proof")));
        _check(!ok, "bad text / zero-budget ask accepted");
        _check(actors[actor].balance == beforeEth, "failed swap charged caller");
        _check(judge.caseCount() == beforeCases, "failed swap opened case");
        _check(token.balanceOf(treasury) == beforeTreasury, "failed swap paid intake");
        ++rejectedCalls;
    }

    function donate(uint256 actorSeed, uint256 amountSeed, uint8 targetSeed) external {
        uint256 actor = actorSeed % 4;
        uint256 amount = bound(amountSeed, 1, 0.01 ether);
        uint8 target = targetSeed % 3;
        if (target == 2) {
            vm.prank(actors[actor]);
            (bool ok,) = address(vault).call{value: amount}("");
            _check(ok, "vault donation failed");
            vaultDonations += amount;
            etherSpent[actor] += amount;
        } else {
            vm.prank(actors[actor]);
            token.transfer(target == 0 ? address(judge) : address(door), amount);
            tokenSpent[actor] += amount;
            if (target == 0) judgeDonations += amount;
            else doorDonations += amount;
        }
    }
}
