// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PlantFixture, MockHook} from "./PlantOrganism.t.sol";
import {PlantOrganism} from "../src/PlantOrganism.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";

contract PlantRevisionTest is PlantFixture {
    function test_oneWeiExternalBurnKeepsParkingSettlementAndLiveRedemptionAvailable() public {
        birth();
        imd.mint(address(body), 10_000 ether);
        next(1, 0, false, 0);
        uint256 quote = body.floor();
        vm.prank(bob);
        token.burn(1);
        assertEq(body.floor(), quote);
        assertEq(body.plantSupply(), 1000 ether);

        park(alice, PARIS, 10 ether);
        next(1, 0, false, 0);
        vm.prank(alice);
        body.unpark(LISBON, 100 ether);
        uint256 expected = 100 ether * body.backing() / 1000 ether * 9 / 10;
        quote = body.floor();
        vm.prank(alice);
        assertEq(body.redeem(100 ether), expected);
        assertGe(body.floor(), quote);
        assertEq(body.burned(), 100 ether);
        vm.prank(alice);
        body.claim(LISBON);
        assertEq(body.owed(), 0);
        conservation();
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_externalBurnKeepsDeadRedemptionAndGardenerClaimsAvailable(uint96 rawBurn) public {
        birth();
        imd.mint(address(body), 10_000 ether);
        next(1, 0, false, 0);
        uint256 amountBurned = bound(uint256(rawBurn), 1, 400 ether);
        vm.prank(bob);
        token.burn(amountBurned);
        vm.prank(alice);
        body.unpark(LISBON, 100 ether);
        vm.warp(body.lastSuccessfulSettle() + 30 days);
        assertTrue(body.isDead());
        uint256 quote = body.floor();
        uint256 debt = body.owed();
        uint256 expected = 100 ether * body.backing() / 1000 ether;
        vm.prank(alice);
        assertEq(body.redeem(100 ether), expected);
        assertGe(body.floor(), quote);
        assertEq(body.pot(), 0);
        assertEq(body.owed(), debt);
        vm.prank(alice);
        assertEq(body.claim(LISBON), debt);
        assertEq(token.balanceOf(address(body)), body.burned());
        conservation();
    }

    function test_supplyAboveBindingSnapshotStillBlocksParkSettleAndRedeem() public {
        birth();
        token.mint(bob, 1);
        vm.prank(alice);
        vm.expectRevert(PlantOrganism.SupplyChanged.selector);
        body.park(PARIS, 1);
        vm.prank(alice);
        vm.expectRevert(PlantOrganism.SupplyChanged.selector);
        body.redeem(1);
        vm.warp(block.timestamp + 1 days);
        OracleAttestation.Attestation memory a = attestation(20002, 0, 0, false, 0);
        bytes memory sig = signed(a);
        vm.expectRevert(PlantOrganism.SupplyChanged.selector);
        body.settle(a, sig);
        assertEq(body.lastSettledDay(), 20001);
        assertEq(body.burned(), 0);
        conservation();
    }

    function lateBind(uint256 delay, bool advanceCursor) internal {
        body = new PlantOrganism(address(imd), vm.addr(KEY), LISBON, address(this));
        hook = new MockHook(address(body), address(token));
        imd.mint(address(body), 1000 ether);
        vm.warp(block.timestamp + delay);
        if (advanceCursor) {
            OracleAttestation.Attestation memory blank;
            body.settle(blank, "");
        }
        body.bind(address(hook), QUESTION);
        assertFalse(body.isDead());
        assertEq(body.lastSuccessfulSettle(), block.timestamp);
        assertEq(body.pot(), 1000 ether);
        assertEq(body.backing(), 0);
        vm.prank(alice);
        token.approve(address(body), type(uint256).max);
    }

    function test_lateBindWithAdvancedCursorAcceptsNextDay() public {
        lateBind(365 days, true);
        assertEq(body.lastSettledDay(), 20365);
        birth();
        assertEq(body.lastSettledDay(), 20366);
        assertEq(body.lastSuccessfulSettle(), block.timestamp);
        conservation();
    }

    function test_lateBindWithoutCursorAdvancePreservesInOrderBacklog() public {
        lateBind(30 days, false);
        assertEq(body.lastSettledDay(), 20000);
        birth();
        assertEq(body.lastSettledDay(), 20001);
        assertEq(body.lastSuccessfulSettle(), block.timestamp);
        conservation();
    }

    function test_lateBindHasFullThirtyDaysAndCannotResetByRebinding() public {
        lateBind(30 days, true);
        uint256 boundAt = block.timestamp;
        vm.warp(boundAt + 30 days - 1);
        assertFalse(body.isDead());
        vm.expectRevert(PlantOrganism.AlreadyBound.selector);
        body.bind(address(hook), QUESTION);
        assertEq(body.lastSuccessfulSettle(), boundAt);
        vm.warp(boundAt + 30 days);
        assertTrue(body.isDead());
        assertEq(body.backing(), 1000 ether);
        assertEq(body.pot(), 0);
    }

    function test_nowhereSupportCannotVetoBirthAtFivePercent() public {
        park(bob, 0, 400 ether);
        park(alice, PARIS, 50 ether - 1);
        next(0, 0, true, PARIS);
        assertEq(body.location(), 0);
        assertEq(body.emptySettles(), 1);
        park(alice, PARIS, 1);
        next(type(uint24).max, 0, true, PARIS);
        assertEq(body.location(), PARIS);
        assertEq(body.water(), 50);
        next(0, 0, true, 0);
        assertEq(body.location(), PARIS);
        assertEq(body.earned(0, bob), 0);
        vm.prank(bob);
        body.unpark(0, 400 ether);
        conservation();
    }

    function test_subQuorumAttestationCannotSpendMoveOrAdvanceDay() public {
        birth();
        park(bob, PARIS, 200 ether);
        imd.mint(address(body), 9000 ether);
        vm.warp(block.timestamp + 1 days);
        OracleAttestation.Attestation memory a = attestation(20002, type(uint24).max, 0, true, PARIS);
        a.panelSize = 20;
        a.quorum = 15;
        a.agreed = 0;
        rejectSubQuorum(a);
        a.agreed = 14;
        rejectSubQuorum(a);
        assertEq(body.lastSettledDay(), 20001);
        assertEq(body.water(), 50);
        assertEq(body.location(), LISBON);
        assertEq(body.pot(), 9000 ether);
        assertEq(body.backing(), 0);
        assertEq(body.owed(), 0);

        a.agreed = 15; // Exactly quorum is sufficient.
        body.settle(a, signed(a));
        assertEq(body.lastSettledDay(), 20002);
        assertEq(body.location(), PARIS);
        assertGt(body.backing(), 0);
        conservation();
    }

    function rejectSubQuorum(OracleAttestation.Attestation memory a) internal {
        bytes memory sig = signed(a);
        vm.expectRevert(PlantOrganism.BadAttestation.selector);
        body.settle(a, sig);
    }

    function test_futureIssuedAtRejectsUntilExactTimestamp() public {
        vm.warp(block.timestamp + 1 days);
        OracleAttestation.Attestation memory a = attestation(20001, 0, 0, false, 0);
        a.issuedAt = uint64(block.timestamp + 1);
        bytes memory sig = signed(a);
        vm.expectRevert(PlantOrganism.InvalidWindow.selector);
        body.settle(a, sig);
        vm.warp(a.issuedAt);
        body.settle(a, sig);
        assertEq(body.lastSettledDay(), 20001);
    }

    function test_rotationNeedsOnlyCurrentSignerButCannotBeUndoneByRetiredKey() public {
        address replacement = vm.addr(NEXT_KEY);
        body.rotateSigner(replacement, sign(body.rotationDigest(replacement), KEY));
        bytes memory oldAuthorization = sign(body.rotationDigest(vm.addr(KEY)), KEY);
        vm.expectRevert(PlantOrganism.BadSignature.selector);
        body.rotateSigner(vm.addr(KEY), oldAuthorization);
        body.rotateSigner(vm.addr(KEY), sign(body.rotationDigest(vm.addr(KEY)), NEXT_KEY));
        assertEq(body.signer(), vm.addr(KEY));
    }

    function test_unusedRotationAuthorizationRemainsValidUntilNonceChanges() public {
        address replacement = vm.addr(NEXT_KEY);
        bytes memory authorization = sign(body.rotationDigest(replacement), KEY);
        vm.warp(block.timestamp + 365 days);
        vm.prank(bob);
        body.rotateSigner(replacement, authorization);
        assertEq(body.signer(), replacement);
        assertEq(body.rotationNonce(), 1);
        assertTrue(body.isDead()); // Rotation cannot revive a dead plant.
    }
}
