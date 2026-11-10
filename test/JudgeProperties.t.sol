// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {JudgeBase} from "./Judge.t.sol";
import {Judge} from "src/Judge.sol";
import {OracleAttestation, OracleAttestationConsumer} from "src/OracleAttestation.sol";
import {OracleQuestion} from "src/OracleQuestion.sol";
import {IIntake} from "src/interfaces/IIntake.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Boundary and adversarial properties complementing the existing scenario tests.
/// forge-config: default.fuzz.runs = 1000
contract JudgePropertiesTest is JudgeBase {
    function setUp() public {
        setUpChain();
        fund(alice);
        fund(bob);
    }

    function _callback(bytes32 request, OracleAttestation.Attestation memory a, bytes memory signature) internal {
        vm.prank(address(intake));
        judge.onOracleResult(request, a, signature);
    }

    function _expectRejected(
        bytes32 request,
        OracleAttestation.Attestation memory a,
        bytes memory signature,
        bytes memory error
    ) internal {
        vm.expectRevert(error);
        _callback(request, a, signature);
        assertEq(verdictOf(request), PENDING);
    }

    function test_answerAtTheExactCaseDeadlineIsAccepted() public {
        bytes32 request = askAs(alice);
        (uint48 started,,) = judge.cases(1);
        vm.warp(uint256(started) + 1 days);
        assertTrue(deliver(request, attestation(hashOf(request), true)));
        assertEq(verdictOf(request), YES);
    }

    function test_expiryAndClockToleranceAreInclusive() public {
        bytes32 request = askAs(alice);
        OracleAttestation.Attestation memory a = attestation(hashOf(request), true);
        a.expiresAt = uint64(vm.getBlockTimestamp());
        // Test each endpoint independently: avoid an issuedAt after expiresAt.
        a.issuedAt = uint64(vm.getBlockTimestamp());
        assertTrue(deliver(request, a));

        request = askAs(bob);
        a = attestation(hashOf(request), false);
        a.issuedAt = uint64(vm.getBlockTimestamp() + 300);
        assertTrue(deliver(request, a));
        assertEq(verdictOf(request), NO);
    }

    function test_futureAttestationOneSecondBeyondToleranceIsRejected() public {
        bytes32 request = askAs(alice);
        OracleAttestation.Attestation memory a = attestation(hashOf(request), true);
        a.issuedAt = uint64(vm.getBlockTimestamp() + 301);
        _expectRejected(
            request,
            a,
            signed(a),
            abi.encodeWithSelector(OracleAttestationConsumer.AttestationNotYetValid.selector, a.issuedAt)
        );
    }

    function test_expiredAttestationDoesNotConsumeTheCase() public {
        bytes32 request = askAs(alice);
        OracleAttestation.Attestation memory a = attestation(hashOf(request), true);
        a.expiresAt = uint64(vm.getBlockTimestamp() - 1);
        _expectRejected(
            request,
            a,
            signed(a),
            abi.encodeWithSelector(OracleAttestationConsumer.AttestationExpired.selector, a.expiresAt)
        );
        a.expiresAt = uint64(vm.getBlockTimestamp() + 60);
        _callback(request, a, signed(a));
        assertEq(verdictOf(request), YES);
    }

    function testFuzz_caseDeadlineCannotReopen(uint256 delay, bool yes) public {
        delay = bound(delay, 1 days + 1, 365 days);
        bytes32 request = askAs(alice);
        (uint48 started,,) = judge.cases(1);
        vm.warp(uint256(started) + delay);
        OracleAttestation.Attestation memory a = attestation(hashOf(request), yes);
        bytes memory signature = signed(a);
        vm.expectRevert(abi.encodeWithSelector(Judge.TooLate.selector, 1));
        _callback(request, a, signature);
        assertEq(verdictOf(request), NO_ANSWER);
        // Another user's fresh case remains usable after an earlier case timed out.
        bytes32 fresh = askAs(bob);
        assertTrue(deliver(fresh, attestation(hashOf(fresh), yes)));
        assertEq(verdictOf(fresh), yes ? YES : NO);
        assertEq(verdictOf(request), NO_ANSWER);
    }

    function testFuzz_allSignedFieldsAreAuthenticated(uint8 field) public {
        bytes32 request = askAs(alice);
        OracleAttestation.Attestation memory a = attestation(hashOf(request), true);
        a.agreed = 60;
        bytes memory signature = signed(a);
        field = uint8(bound(field, 0, 14));
        // Mutations preserve all pre-signature checks except questionHash. Each signed word
        // and the dynamic answer must invalidate the old signature, even if otherwise valid.
        if (field == 0) a.requestId ^= bytes32(uint256(1));
        else if (field == 1) ++a.chainId;
        else if (field == 2) a.questionHash ^= bytes32(uint256(1));
        else if (field == 3) a.answerType = 3;
        else if (field == 4) a.answer = abi.encode(false);
        else if (field == 5) ++a.figure;
        else if (field == 6) --a.fromBlock;
        else if (field == 7) ++a.toBlock;
        else if (field == 8) a.blockHash ^= bytes32(uint256(1));
        else if (field == 9) a.panelJobId ^= bytes32(uint256(1));
        else if (field == 10) ++a.panelSize;
        else if (field == 11) ++a.quorum;
        else if (field == 12) ++a.agreed;
        else if (field == 13) ++a.issuedAt;
        else ++a.expiresAt;
        bytes memory error = field == 2
            ? abi.encodeWithSelector(Judge.WrongQuestion.selector, hashOf(request), a.questionHash)
            : abi.encodeWithSelector(OracleAttestationConsumer.BadSignature.selector);
        _expectRejected(request, a, signature, error);
    }

    function test_signatureForAnotherChainIsRejected() public {
        bytes32 request = askAs(alice);
        OracleAttestation.Attestation memory a = attestation(hashOf(request), true);
        vm.chainId(11155111);
        bytes memory signature = signed(a);
        vm.chainId(1);
        _expectRejected(request, a, signature, abi.encodeWithSelector(OracleAttestationConsumer.BadSignature.selector));
    }

    function test_highSSignatureIsRejected() public {
        bytes32 request = askAs(alice);
        OracleAttestation.Attestation memory a = attestation(hashOf(request), true);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ATTESTER_KEY, judge.attestationDigest(a));
        uint256 curveOrder = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141;
        bytes memory malleable = abi.encodePacked(r, bytes32(curveOrder - uint256(s)), v == 27 ? uint8(28) : uint8(27));
        _expectRejected(request, a, malleable, abi.encodeWithSelector(OracleAttestationConsumer.BadSignature.selector));
    }

    function test_emptyAndTruncatedSignaturesAreRejected() public {
        bytes32 request = askAs(alice);
        OracleAttestation.Attestation memory a = attestation(hashOf(request), true);
        _expectRejected(request, a, "", abi.encodeWithSelector(OracleAttestationConsumer.BadSignature.selector));
        _expectRejected(request, a, hex"01", abi.encodeWithSelector(OracleAttestationConsumer.BadSignature.selector));
        _expectRejected(
            request, a, new bytes(65), abi.encodeWithSelector(OracleAttestationConsumer.BadSignature.selector)
        );
    }

    function test_signedMalformedBooleanDoesNotConsumeCase() public {
        bytes32 request = askAs(alice);
        OracleAttestation.Attestation memory a = attestation(hashOf(request), true);
        a.answer = abi.encode(uint256(2));
        bytes memory signature = signed(a);
        vm.expectRevert();
        _callback(request, a, signature);
        assertEq(verdictOf(request), PENDING);
        a.answer = hex"01";
        signature = signed(a);
        vm.expectRevert();
        _callback(request, a, signature);
        assertEq(verdictOf(request), PENDING);
        a.answer = abi.encode(false);
        _callback(request, a, signed(a));
        assertEq(verdictOf(request), NO);
    }

    function testFuzz_minimumPanelIsRequired(uint16 seats, uint16 threshold, uint16 agreement) public {
        bytes32 request = askAs(alice);
        OracleAttestation.Attestation memory a = attestation(hashOf(request), true);
        a.panelSize = uint16(bound(seats, 2, 200));
        a.quorum = uint16(bound(threshold, 1, a.panelSize));
        a.agreed = uint16(bound(agreement, 0, a.panelSize));
        bool enough = a.panelSize >= 100 && a.quorum >= 51 && a.agreed >= a.quorum;
        if (enough) {
            _callback(request, a, signed(a));
            assertEq(verdictOf(request), YES);
        } else {
            _expectRejected(
                request,
                a,
                signed(a),
                abi.encodeWithSelector(Judge.PanelTooWeak.selector, a.panelSize, a.quorum, a.agreed)
            );
        }
    }

    function test_failedDeliveryCanTimeOutWithoutBlockingNewCases() public {
        bytes32 request = askAs(alice);
        OracleAttestation.Attestation memory a = attestation(hashOf(request), true);
        assertFalse(complete(request, abi.encode(request, a, bytes("invalid"))));
        // Intake completion is one-shot even when the consumer rejected its payload.
        bytes memory args = abi.encode(request, a, signed(a));
        vm.prank(writer);
        vm.expectRevert(abi.encodeWithSignature("AlreadyCompleted(bytes32)", request));
        intake.complete(request, 0, bytes32(0), "", args);
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        assertEq(verdictOf(request), NO_ANSWER);
        assertEq(judge.caseOfRequest(askAs(alice)), 2);
    }

    function testFuzz_nonAsciiAtEveryPositionRevertsBeforePayment(uint256 position, uint8 invalid, bool inRule) public {
        uint256 limit = inRule ? 500 : 650;
        position = bound(position, 0, limit - 1);
        bytes memory text = new bytes(position + 1);
        for (uint256 i; i < position; ++i) {
            text[i] = "a";
        }
        text[position] = bytes1(uint8(bound(invalid, 128, 255)));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Judge.NotAscii.selector, position));
        judge.ask(inRule ? string(text) : RULE, inRule ? PROOF : string(text));
        assertEq(imd.balanceOf(alice), 10 ether);
        assertEq(imd.balanceOf(treasury), 0);
        assertEq(intake.nonce(), 0);
        assertEq(judge.caseCount(), 0);
    }

    function testFuzz_failedTokenPullDoesNotLeaveAGhostCase(uint256 allowance) public {
        allowance = bound(allowance, 0, PRICE - 1);
        vm.prank(alice);
        imd.approve(address(judge), allowance);
        vm.prank(alice);
        vm.expectRevert();
        judge.ask(RULE, PROOF);
        assertEq(judge.caseCount(), 0);
        assertEq(intake.nonce(), 0);
        assertEq(imd.balanceOf(alice), 10 ether);
        assertEq(imd.balanceOf(treasury), 0);
        assertEq(imd.allowance(alice, address(judge)), allowance);
        vm.prank(alice);
        imd.approve(address(judge), PRICE);
        assertEq(judge.caseOfRequest(askAs(alice)), 1);
    }

    function testFuzz_priceIsPaidExactlyIncludingOneWei(uint256 price) public {
        price = bound(price, 1, 10 ether);
        vm.prank(owner);
        intake.setPrice(ORACLE, address(imd), price);
        askAs(alice);
        assertEq(imd.balanceOf(treasury), price);
        assertEq(imd.balanceOf(alice), 10 ether - price);
        assertEq(imd.balanceOf(address(judge)), 0);
        assertEq(imd.allowance(address(judge), address(intake)), 0);
    }

    function test_oneWeiPriceAndFullBalancePayment() public {
        vm.prank(owner);
        intake.setPrice(ORACLE, address(imd), 1);
        askAs(alice);
        assertEq(imd.balanceOf(treasury), 1);
        vm.prank(owner);
        intake.setPrice(ORACLE, address(imd), 10 ether);
        askAs(bob);
        assertEq(imd.balanceOf(bob), 0);
        assertEq(imd.balanceOf(treasury), 10 ether + 1);
    }

    function test_zeroSignerCannotBeDeployed() public {
        // Capture dependencies before expectRevert; getters are external calls too.
        IIntake intake_ = judge.intake();
        IERC20 asset_ = judge.asset();
        vm.expectRevert(OracleAttestationConsumer.ZeroSigner.selector);
        new Judge(address(0), intake_, asset_, 100, 51);
    }
}

/// @notice The question hash vector comes from the supplied protocol, not from Judge itself.
contract OracleQuestionProtocolVectorTest is Test {
    function test_questionHashMatchesProtocolVector() public pure {
        OracleQuestion.Question memory q;
        q.question = "Which Uniswap v4 pool did the most WETH volume in the last day?";
        q.chainId = 1;
        q.fromBlock = 100;
        q.toBlock = 200;
        q.answerType = OracleAttestation.ANSWER_BYTES32_LIST;
        q.head = 1;
        q.definitions = new OracleQuestion.Definition[](1);
        q.definitions[0] =
            OracleQuestion.Definition("denomination", "WETH, summed as the absolute swapped amount on the WETH side");
        assertEq(OracleQuestion.hash(q), 0x2117f4362ebfa37aa8a8c0fed548604fe09ac46faf8ae7559cd64780f26a46fb);
    }
}
