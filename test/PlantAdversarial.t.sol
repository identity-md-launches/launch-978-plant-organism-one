// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PlantOrganism} from "src/PlantOrganism.sol";
import {OracleAttestation} from "src/OracleAttestation.sol";
import {PlantFixture, MockHook, MockToken} from "./PlantOrganism.t.sol";

contract ReentryProbe {
    address private target;
    bytes private payload;
    bool public attempted;
    bool public succeeded;
    bytes public result;

    constructor(address target_, bytes memory payload_) {
        target = target_;
        payload = payload_;
    }

    function run() external {
        attempted = true;
        (succeeded, result) = target.call(payload);
    }
}

/// @dev Extends the accepted fixture; every address/key here is confined to local mocks.
contract PlantAdversarialTest is PlantFixture {
    function test_constructorRejectsMissingAuthorityAndInvalidFallback() public {
        address oracle = vm.addr(KEY);
        vm.expectRevert(PlantOrganism.InvalidConfiguration.selector);
        new PlantOrganism(address(0), oracle, LISBON, alice);
        vm.expectRevert(PlantOrganism.InvalidConfiguration.selector);
        new PlantOrganism(address(imd), address(0), LISBON, alice);
        vm.expectRevert(PlantOrganism.InvalidConfiguration.selector);
        new PlantOrganism(address(imd), oracle, LISBON, address(0));
        vm.expectRevert(PlantOrganism.InvalidCell.selector);
        new PlantOrganism(address(imd), oracle, 0, alice);
        vm.expectRevert(PlantOrganism.InvalidCell.selector);
        new PlantOrganism(address(imd), oracle, _cell(-361, 0), alice);
    }

    function test_invalidBindAttemptsLeaveAllBindingSlotsUnset() public {
        PlantOrganism other = new PlantOrganism(address(imd), vm.addr(KEY), LISBON, address(this));
        vm.expectRevert(PlantOrganism.InvalidConfiguration.selector);
        other.bind(alice, QUESTION);
        MockHook noTokenCode = new MockHook(address(other), bob);
        vm.expectRevert(PlantOrganism.InvalidConfiguration.selector);
        other.bind(address(noTokenCode), QUESTION);
        MockHook selfToken = new MockHook(address(other), address(other));
        vm.expectRevert(PlantOrganism.InvalidConfiguration.selector);
        other.bind(address(selfToken), QUESTION);
        assertFalse(other.bound());
        assertEq(other.hook(), address(0));
        assertEq(address(other.plant()), address(0));
        assertEq(other.plantSupply(), 0);
        assertEq(other.QUESTION_HASH(), bytes32(0));
        MockHook good = new MockHook(address(other), address(token));
        vm.expectEmit(true, true, false, true, address(other));
        emit PlantOrganism.Bound(address(good), address(token), QUESTION);
        other.bind(address(good), QUESTION);
    }

    function test_cellSignedBoundariesAndLisbonPacking() public view {
        assertEq(_cell(155, -37), LISBON);
        assertTrue(body.validCell(_cell(-360, -720)));
        assertTrue(body.validCell(_cell(360, 720)));
        assertFalse(body.validCell(_cell(-361, 0)));
        assertFalse(body.validCell(_cell(0, -721)));
        assertFalse(body.validCell(type(uint32).max - uint32(0x7fff)));
    }

    function test_nowhereCanBeParkedAndWithdrawnWithoutRunningWeather() public {
        park(alice, 0, 100 ether);
        imd.mint(address(body), 1000 ether);
        next(type(uint24).max, type(uint24).max, true, 0);
        assertEq(body.location(), 0);
        assertEq(body.water(), 50);
        assertEq(body.backing(), 0);
        assertEq(body.owed(), 0);
        vm.prank(alice);
        body.unpark(0, 100 ether);
        assertEq(token.balanceOf(alice), 600 ether);
        conservation();
    }

    function test_parkedSupportNeedsValidFlagAndThresholdEvenAfterBurns() public {
        vm.prank(alice);
        body.redeem(500 ether);
        park(bob, PARIS, 50 ether - 1);
        next(0, 0, true, PARIS);
        assertEq(body.location(), 0, "redemption must not reduce the supply threshold");
        park(bob, PARIS, 1);
        next(0, 0, false, PARIS);
        assertEq(body.location(), 0, "support alone cannot override an invalid challenger");
        next(0, 0, true, PARIS);
        assertEq(body.location(), PARIS);
    }

    function test_partialPendingWithdrawalCannotEarnBeforeActivation() public {
        birth();
        park(bob, LISBON, 90 ether);
        vm.prank(bob);
        body.unpark(LISBON, 30 ether);
        imd.mint(address(body), 9000 ether);
        next(1, 0, false, 0);
        assertEq(body.earned(LISBON, bob), 0);
        assertEq(body.earned(LISBON, alice), 300 ether);
        vm.prank(alice);
        body.unpark(LISBON, 100 ether);
        next(1, 0, false, 0);
        assertEq(body.earned(LISBON, bob), 267.3 ether);
        vm.prank(bob);
        assertEq(body.claim(), 267.3 ether);
        conservation();
    }

    function test_claimCannotTakeAnotherHoldersRewardsAndRepeatPaysZero() public {
        birth();
        imd.mint(address(body), 9000 ether);
        next(1, 0, false, 0);
        vm.prank(bob);
        assertEq(body.claim(LISBON), 0);
        assertEq(body.earned(LISBON, alice), 300 ether);
        vm.prank(alice);
        vm.expectEmit(true, false, false, true, address(body));
        emit PlantOrganism.Claimed(alice, 300 ether);
        assertEq(body.claim(), 300 ether);
        vm.prank(alice);
        assertEq(body.claim(), 0);
        assertEq(body.owed(), 0);
        conservation();
    }

    function test_oneWeiSipAndZeroSipRoundTowardBacking() public {
        birth();
        imd.mint(address(body), 10);
        next(1, 0, false, 0);
        assertEq(body.backing(), 1);
        assertEq(body.owed(), 0);
        assertEq(body.pot(), 9);
        next(1, 0, false, 0);
        assertEq(body.water(), 48);
        assertEq(body.backing(), 1);
        assertEq(body.pot(), 9);
        conservation();
    }

    function test_zeroAndOversizedWithdrawalsCannotTouchCustody() public {
        birth();
        bytes32 beforeState = _state();
        vm.startPrank(alice);
        vm.expectRevert(PlantOrganism.InvalidAmount.selector);
        body.unpark(LISBON, 0);
        vm.expectRevert(PlantOrganism.InvalidAmount.selector);
        body.unpark(LISBON, 100 ether + 1);
        vm.expectRevert(PlantOrganism.InvalidAmount.selector);
        body.redeem(0);
        vm.expectRevert(PlantOrganism.InvalidAmount.selector);
        body.redeem(type(uint256).max);
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert(PlantOrganism.InvalidAmount.selector);
        body.unpark(LISBON, 1);
        assertEq(_state(), beforeState);
    }

    function test_noAllowanceParkAndRedeemRevertAtomically() public {
        birth();
        imd.mint(address(body), 9000 ether);
        next(1, 0, false, 0);
        vm.prank(alice);
        token.approve(address(body), 0);
        bytes32 beforeState = _state();
        vm.startPrank(alice);
        vm.expectRevert(PlantOrganism.BadTokenTransfer.selector);
        body.park(LISBON, 1);
        vm.expectRevert(PlantOrganism.BadTokenTransfer.selector);
        body.redeem(1 ether);
        vm.stopPrank();
        assertEq(_state(), beforeState);
    }

    function test_failedUnparkKeepsPositionAndEarnedRewards() public {
        birth();
        imd.mint(address(body), 9000 ether);
        next(1, 0, false, 0);
        bytes32 beforeState = _state();
        token.configure(3, address(0), "");
        vm.prank(alice);
        vm.expectRevert(PlantOrganism.BadTokenTransfer.selector);
        body.unpark(LISBON, 100 ether);
        assertEq(_state(), beforeState);
        token.configure(0, address(0), "");
        vm.prank(alice);
        body.unpark(LISBON, 100 ether);
        assertEq(body.claimable(alice), 300 ether);
    }

    function test_failedRedemptionPayoutRollsBackBurnAndPlantTransfer() public {
        birth();
        imd.mint(address(body), 9000 ether);
        next(1, 0, false, 0);
        bytes32 beforeState = _state();
        imd.configure(3, address(0), "");
        vm.prank(alice);
        vm.expectRevert(PlantOrganism.BadTokenTransfer.selector);
        body.redeem(100 ether);
        assertEq(_state(), beforeState);
        imd.configure(0, address(0), "");
        vm.prank(alice);
        assertEq(body.redeem(100 ether), 54 ether);
        conservation();
    }

    function test_supplyMutationAlsoStopsSettleAndRedeemButAllowsExit() public {
        birth();
        token.mint(bob, 1);
        vm.warp(block.timestamp + 1 days);
        OracleAttestation.Attestation memory a = attestation(20002, 0, 0, false, 0);
        bytes memory sig = signed(a);
        vm.expectRevert(PlantOrganism.SupplyChanged.selector);
        body.settle(a, sig);
        vm.prank(alice);
        vm.expectRevert(PlantOrganism.SupplyChanged.selector);
        body.redeem(1);
        vm.prank(alice);
        body.unpark(LISBON, 100 ether);
        assertEq(token.balanceOf(alice), 600 ether);
        assertEq(body.totalParked(), 0);
    }

    function test_syncDeathIsPermissionlessIdempotentAndKeepsDebts() public {
        birth();
        imd.mint(address(body), 9000 ether);
        next(1, 0, false, 0);
        vm.expectRevert(PlantOrganism.Alive.selector);
        body.syncDeath();
        vm.warp(body.lastSuccessfulSettle() + 30 days);
        uint256 base = body.backing();
        uint256 debt = body.owed();
        vm.prank(bob);
        body.syncDeath();
        body.syncDeath();
        assertTrue(body.deathRecorded());
        assertEq(body.backing(), base);
        assertEq(body.owed(), debt);
        imd.mint(address(body), 1);
        body.syncDeath();
        assertEq(body.backing(), base + 1);
        vm.prank(alice);
        assertEq(body.claim(), debt);
        conservation();
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_everySignedFieldIsAuthenticated(uint8 rawField) public {
        OracleAttestation.Attestation memory a = attestation(20001, 0, 0, false, 0);
        bytes memory sig = signed(a);
        uint256 field = bound(rawField, 0, 16);
        if (field == 0) a.requestId ^= bytes32(uint256(1));
        else if (field == 1) a.chainId += 1;
        else if (field == 2) a.questionHash ^= bytes32(uint256(1));
        else if (field == 3) a.answerType = 3;
        else if (field <= 6) a.answer[64 + (field - 4) * 32] ^= bytes1(uint8(1));
        else if (field == 7) a.figure += 1;
        else if (field == 8) a.fromBlock += 1;
        else if (field == 9) a.toBlock += 1;
        else if (field == 10) a.blockHash ^= bytes32(uint256(1));
        else if (field == 11) a.panelJobId ^= bytes32(uint256(1));
        else if (field == 12) a.panelSize += 1;
        else if (field == 13) a.quorum += 1;
        else if (field == 14) a.agreed -= 1;
        else if (field == 15) a.issuedAt -= 1;
        else a.expiresAt += 1;
        vm.expectRevert(PlantOrganism.BadSignature.selector);
        body.verifyAttestation(a, sig);
    }

    function test_exactLengthPayloadStillRequiresCanonicalOffsetAndThreeWords() public {
        vm.warp(block.timestamp + 1 days);
        OracleAttestation.Attestation memory a = attestation(20001, 0, 0, false, 0);
        a.answer = abi.encode(uint256(32), uint256(2), bytes32(0), bytes32(0), bytes32(0));
        bytes memory sig = signed(a);
        vm.expectRevert(PlantOrganism.BadAttestation.selector);
        body.settle(a, sig);
        a.answer = abi.encode(bytes32(uint256(20001) << 96), bytes32(0), bytes32(0));
        sig = signed(a);
        vm.expectRevert(PlantOrganism.BadAttestation.selector);
        body.settle(a, sig);
        assertEq(body.lastSettledDay(), 20000);
    }

    function test_rotationIndependentTypedDataAndDomainReplayRejection() public {
        address successor = vm.addr(NEXT_KEY);
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("IdentityMD Oracle"),
                keccak256("2"),
                uint256(4663),
                address(body)
            )
        );
        bytes32 message = keccak256(
            abi.encode(
                keccak256("RotateSigner(address organism,address newSigner,uint256 nonce)"),
                address(body),
                successor,
                uint256(0)
            )
        );
        bytes memory sig = sign(keccak256(abi.encodePacked(hex"1901", domain, message)), KEY);
        PlantOrganism other = new PlantOrganism(address(imd), vm.addr(KEY), LISBON, address(this));
        vm.expectRevert(PlantOrganism.BadSignature.selector);
        other.rotateSigner(successor, sig);
        vm.expectRevert(PlantOrganism.BadSignature.selector);
        body.rotateSigner(bob, sig);
        vm.chainId(1);
        vm.expectRevert(PlantOrganism.BadSignature.selector);
        body.rotateSigner(successor, sig);
        vm.chainId(4663);
        vm.prank(bob);
        body.rotateSigner(successor, sig);
        assertEq(body.signer(), successor);
        assertEq(body.rotationNonce(), 1);
    }

    function test_rotationRejectsZeroSameAndUnsignedDeployerOrHolder() public {
        address initial = body.signer();
        vm.expectRevert(PlantOrganism.InvalidConfiguration.selector);
        body.rotateSigner(address(0), "");
        vm.expectRevert(PlantOrganism.InvalidConfiguration.selector);
        body.rotateSigner(initial, "");
        vm.expectRevert(PlantOrganism.BadSignature.selector);
        body.rotateSigner(alice, "");
        vm.prank(alice);
        vm.expectRevert(PlantOrganism.BadSignature.selector);
        body.rotateSigner(alice, "");
        assertEq(body.signer(), initial);
        assertEq(body.rotationNonce(), 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_callbacksHitGuardForEveryMutator(uint8 rawEntry, bool imdCallback) public {
        birth();
        imd.mint(address(body), 9000 ether);
        next(1, 0, false, 0);
        uint256 entry = bound(rawEntry, 0, 8);
        bytes memory payload;
        if (entry == 0) {
            payload = abi.encodeCall(body.park, (LISBON, 1));
        } else if (entry == 1) {
            payload = abi.encodeCall(body.unpark, (LISBON, 1));
        } else if (entry == 2) {
            payload = abi.encodeWithSignature("claim()");
        } else if (entry == 3) {
            payload = abi.encodeWithSignature("claim(uint32)", LISBON);
        } else if (entry == 4) {
            payload = abi.encodeCall(body.redeem, (1));
        } else if (entry == 5) {
            payload = abi.encodeCall(body.syncDeath, ());
        } else if (entry == 6) {
            payload = abi.encodeCall(body.bind, (address(hook), QUESTION));
        } else if (entry == 7) {
            payload = abi.encodeCall(body.rotateSigner, (bob, bytes("")));
        } else {
            OracleAttestation.Attestation memory a;
            payload = abi.encodeCall(body.settle, (a, bytes("")));
        }
        ReentryProbe probe = new ReentryProbe(address(body), payload);
        MockToken callbackToken = imdCallback ? imd : token;
        callbackToken.configure(0, address(probe), abi.encodeCall(probe.run, ()));
        vm.prank(alice);
        if (imdCallback) body.claim();
        else body.park(LISBON, 1);
        assertTrue(probe.attempted());
        assertFalse(probe.succeeded());
        assertEq(probe.result(), abi.encodeWithSelector(PlantOrganism.Reentrancy.selector));
        conservation();
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_pendingRoundTripsCannotExtractRewards(uint96 rawAmount, uint8 rawCycles) public {
        birth();
        imd.mint(address(body), 9000 ether);
        next(1, 0, false, 0);
        uint256 amount = bound(rawAmount, 1, 400 ether);
        uint256 cycles = bound(rawCycles, 1, 12);
        uint256 debt = body.owed();
        vm.startPrank(bob);
        for (uint256 i; i < cycles; ++i) {
            body.park(LISBON, amount);
            body.unpark(LISBON, amount);
            assertEq(body.claim(), 0);
        }
        vm.stopPrank();
        assertEq(token.balanceOf(bob), 400 ether);
        assertEq(body.owed(), debt);
        assertEq(body.earned(LISBON, alice), 300 ether);
        conservation();
    }

    function _cell(int16 lat, int16 lon) private pure returns (uint32) {
        return (uint32(uint16(lat)) << 16) | uint16(lon);
    }

    function _state() private view returns (bytes32) {
        bytes32 accounts = keccak256(
            abi.encode(
                body.parked(LISBON, alice),
                body.parkedTotal(LISBON),
                body.claimable(alice),
                body.earned(LISBON, alice),
                token.balanceOf(alice),
                token.balanceOf(address(body)),
                imd.balanceOf(alice),
                imd.balanceOf(address(body))
            )
        );
        return keccak256(
            abi.encode(
                accounts,
                body.backing(),
                body.pot(),
                body.owed(),
                body.burned(),
                body.totalParked(),
                body.floor(),
                body.lastSettledDay(),
                body.water()
            )
        );
    }
}
