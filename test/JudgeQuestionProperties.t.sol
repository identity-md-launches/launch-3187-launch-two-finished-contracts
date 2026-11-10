// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Test.sol";
import {JudgeBase} from "./Judge.t.sol";
import {Intake} from "./support/Intake.sol";
import {OracleQuestion} from "src/OracleQuestion.sol";

/// @notice Generated ASCII is checked through Foundry's independent JSON parser.
/// forge-config: default.fuzz.runs = 256
contract JudgeQuestionPropertiesTest is JudgeBase {
    function setUp() public {
        setUpChain();
        fund(alice);
    }

    function _ascii(uint256 seed, uint256 length) internal pure returns (string memory) {
        bytes memory data = new bytes(length);
        bytes32 entropy;
        for (uint256 i; i < length; ++i) {
            if (i % 32 == 0) entropy = keccak256(abi.encode(seed, i));
            data[i] = bytes1(uint8(entropy[i % 32]) & 0x7f);
        }
        return string(data);
    }

    function _body(string memory rule, string memory proof) internal returns (string memory) {
        vm.recordLogs();
        vm.prank(alice);
        judge.ask(rule, proof);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(intake) && logs[i].topics[0] == Intake.Requested.selector) {
                (bytes memory body,,,,) = abi.decode(logs[i].data, (bytes, address, bytes4, address, uint256));
                return string(body);
            }
        }
        revert("missing intake request body");
    }

    function _checkRoundTrip(string memory rule, string memory proof) internal {
        string memory body = _body(rule, proof);
        OracleQuestion.Question memory question = judge.question(rule, proof, 1, 992);
        string memory decoded = vm.parseJsonString(body, ".question");
        assertEq(decoded, question.question, "JSON escaping changed the question");
        assertEq(vm.parseJsonUint(body, ".v"), 1);
        assertEq(vm.parseJsonString(body, ".answerType"), "bool");
        assertEq(vm.parseJsonString(body, ".evidence"), "panel");
        assertEq(vm.parseJsonUint(body, ".chainId"), 1);
        assertEq(vm.parseJsonUint(body, ".window.fromBlock"), 992);
        assertEq(vm.parseJsonUint(body, ".window.toBlock"), 992);
        assertEq(vm.parseJsonUint(body, ".panelSize"), 100);
        assertEq(vm.parseJsonUint(body, ".quorum"), 51);
        assertEq(vm.parseJsonUint(body, ".validForSeconds"), 86400);
        assertTrue(vm.parseJsonBool(body, ".allowAmbiguous"));
        assertFalse(vm.keyExistsJson(body, ".definitions"));
        assertLe(bytes(body).length, 16384);
        assertLe(bytes(decoded).length, 2000);
        bytes memory text = bytes(decoded);
        uint256 opens;
        uint256 closes;
        for (uint256 i; i < text.length; ++i) {
            uint8 c = uint8(text[i]);
            assertGe(c, 32, "control character escaped its untrusted text");
            assertLt(c, 127, "nonprintable character escaped its untrusted text");
            if (text[i] == "[") ++opens;
            if (text[i] == "]") ++closes;
        }
        assertEq(opens, 4, "user text introduced a panel delimiter");
        assertEq(closes, 4, "user text introduced a panel delimiter");
        // Separately verify that every printable, non-bracket byte was preserved at its
        // original position; normalization must not silently drop a claimant's evidence.
        _checkPreserved(bytes(rule), text, 6);
        _checkPreserved(bytes(proof), text, 21 + bytes(rule).length);
        (,, bytes32 hash) = judge.cases(1);
        assertEq(hash, OracleQuestion.hash(question));
    }

    function _checkPreserved(bytes memory input, bytes memory output, uint256 start) internal pure {
        for (uint256 i; i < input.length; ++i) {
            uint8 c = uint8(input[i]);
            if (c >= 32 && c < 127 && input[i] != "[" && input[i] != "]") {
                assertEq(uint8(output[start + i]), c, "printable evidence changed");
            }
        }
    }

    function testFuzz_asciiBodyRoundTrips(uint256 seed, uint256 ruleLength, uint256 proofLength) public {
        ruleLength = bound(ruleLength, 1, 500);
        proofLength = bound(proofLength, 1, 650);
        _checkRoundTrip(_ascii(seed, ruleLength), _ascii(seed ^ 1, proofLength));
    }

    function test_everyAsciiByteIncludingAllJsonEscapes() public {
        bytes memory everyByte = new bytes(128);
        for (uint256 i; i < 128; ++i) {
            everyByte[i] = bytes1(uint8(i));
        }
        _checkRoundTrip(string(everyByte), string(everyByte));
    }

    function test_maximumTextLengthAndMaximumEscaping() public {
        bytes memory rule = new bytes(500);
        bytes memory proof = new bytes(650);
        for (uint256 i; i < rule.length; ++i) {
            rule[i] = i % 2 == 0 ? bytes1('"') : bytes1("\\");
        }
        for (uint256 i; i < proof.length; ++i) {
            proof[i] = i % 2 == 0 ? bytes1("\\") : bytes1('"');
        }
        _checkRoundTrip(string(rule), string(proof));
    }
}
