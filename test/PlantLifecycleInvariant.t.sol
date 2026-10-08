// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PlantOrganism} from "src/PlantOrganism.sol";
import {OracleAttestation} from "src/OracleAttestation.sol";
import {MockHook, MockToken} from "./PlantOrganism.t.sol";

/// @dev Small, indivisible balances deliberately exercise dust and non-integral 5% thresholds.
/// Ghost custody and cash-flow totals change only after successful operations, never from getters.
contract PlantLifecycleHandler is Test {
    PlantOrganism public body;
    MockToken public imd;
    MockToken public token;
    address[4] public actors;
    uint32[4] public cells = [uint32(0), uint32(10223579), uint32(12779529), uint32(11010100)];
    mapping(uint32 => mapping(address => uint256)) public deposits;
    mapping(address => uint256) public receipts;
    uint256 public fundsIn;
    uint256 public claimsOut;
    uint256 public redemptionsOut;
    uint256 public bountiesOut;
    uint256 public burned;
    uint256 public externallyBurned;
    uint256 public donatedPlant;
    uint256 public maxFloor;
    uint256 public expectedDay;
    uint256 public lastSuccess;
    uint32 public expectedLocation;
    uint256 public emptyDays;
    uint256 public signerKey = 0xA11CE;
    uint256 public rotations;
    uint256 public settlements;
    bool public sawDeath;
    bytes32 private constant QUESTION = keccak256("lifecycle test weather");

    constructor() {
        imd = new MockToken();
        token = new MockToken();
        for (uint256 i; i < 4; ++i) {
            actors[i] = makeAddr(string.concat("lifecycle holder ", vm.toString(i)));
            token.mint(actors[i], i == 0 ? 401 : (4 - i) * 100);
        }
        body = new PlantOrganism(address(imd), vm.addr(signerKey), cells[1], address(this));
        MockHook hook = new MockHook(address(body), address(token));
        body.bind(address(hook), QUESTION);
        for (uint256 i; i < 4; ++i) {
            vm.prank(actors[i]);
            token.approve(address(body), type(uint256).max);
        }
        expectedDay = block.timestamp / 1 days;
        lastSuccess = block.timestamp;
    }

    function fund(uint96 raw) external {
        // Real transfers into the body, including the one-base-unit edge.
        uint256 amount = bound(raw, 1, 1e24);
        imd.mint(address(this), amount);
        imd.transfer(address(body), amount);
        fundsIn += amount;
        check();
    }

    function park(uint8 who, uint8 where, uint256 raw) external {
        address actor = actors[who % 4];
        uint32 cell = cells[where % 4];
        uint256 balance = token.balanceOf(actor);
        if (balance == 0) return;
        uint256 amount = bound(raw, 1, balance);
        vm.prank(actor);
        body.park(cell, amount);
        deposits[cell][actor] += amount;
        check();
    }

    function unpark(uint8 who, uint8 where, uint256 raw) external {
        address actor = actors[who % 4];
        uint32 cell = cells[where % 4];
        uint256 balance = deposits[cell][actor];
        if (balance == 0) return;
        _withdraw(actor, cell, bound(raw, 1, balance));
        check();
    }

    function claim(uint8 who, uint8 where) external {
        _claim(actors[who % 4], cells[where % 4]);
        check();
    }

    function redeem(uint8 who, uint256 raw) external {
        address actor = actors[who % 4];
        uint256 balance = token.balanceOf(actor);
        if (balance == 0) return;
        _redeem(actor, bound(raw, 1, balance));
        check();
    }

    function donatePlant(uint8 who, uint256 raw) external {
        address actor = actors[who % 4];
        uint256 balance = token.balanceOf(actor);
        if (balance == 0) return;
        uint256 amount = bound(raw, 1, balance);
        vm.prank(actor);
        token.transfer(address(body), amount);
        donatedPlant += amount;
        check();
    }

    function burnOutsideOrganism(uint8 who, uint256 raw) external {
        address actor = actors[who % 4];
        uint256 balance = token.balanceOf(actor);
        if (balance == 0) return;
        uint256 amount = bound(raw, 1, balance);
        uint256 beforeFloor = body.floor();
        uint256 beforeDebt = body.owed();
        vm.prank(actor);
        token.burn(amount);
        externallyBurned += amount;
        assertEq(body.floor(), beforeFloor, "external burn changed the redemption quote");
        assertEq(body.owed(), beforeDebt, "external burn changed gardener debt");
        check();
    }

    function elapse(uint32 raw) external {
        // Most jumps permit recovery; occasional long gaps exercise irreversible death.
        uint256 seconds_ = raw % 16 == 0 ? 30 days : bound(raw, 0, 2 days);
        vm.warp(block.timestamp + seconds_);
        check();
    }

    function syncDeath() external {
        if (block.timestamp >= lastSuccess + 30 days) {
            uint256 beforeBacking = body.backing();
            uint256 beforeDebt = body.owed();
            body.syncDeath();
            body.syncDeath();
            assertEq(body.backing(), beforeBacking, "death sync changed entitlement");
            assertEq(body.owed(), beforeDebt, "death consumed garden debt");
        } else {
            vm.expectRevert(PlantOrganism.Alive.selector);
            body.syncDeath();
        }
        check();
    }

    function settle(uint24 sun, uint24 rain, uint8 where, bool valid) external {
        uint256 day = expectedDay + 1;
        if (block.timestamp / 1 days < day) vm.warp(day * 1 days + 17);
        OracleAttestation.Attestation memory a = _attestation(day, sun, rain, valid, cells[where % 4]);
        bytes memory sig = _sign(body.attestationDigest(a), signerKey);
        if (block.timestamp >= lastSuccess + 30 days) {
            vm.expectRevert(PlantOrganism.Dead.selector);
            body.settle(a, sig);
        } else {
            _settleAndCheck(a, sig, cells[where % 4], valid);
        }
        check();
    }

    function rotate(uint8 relayer) external {
        uint256 newKey = signerKey + 1;
        address newSigner = vm.addr(newKey);
        bytes memory sig = _sign(body.rotationDigest(newSigner), signerKey);
        address oldSigner = vm.addr(signerKey);
        vm.prank(actors[relayer % 4]);
        body.rotateSigner(newSigner, sig);
        assertEq(body.signerValidUntil(oldSigner), block.timestamp + 30 days);
        // The retired key can still attest, but cannot authorize another rotation.
        OracleAttestation.Attestation memory a = _attestation(expectedDay + 1, 0, 0, false, 0);
        body.verifyAttestation(a, _sign(body.attestationDigest(a), signerKey));
        sig = _sign(body.rotationDigest(oldSigner), signerKey);
        vm.expectRevert(PlantOrganism.BadSignature.selector);
        body.rotateSigner(oldSigner, sig);
        signerKey = newKey;
        ++rotations;
        check();
    }

    function _settleAndCheck(OracleAttestation.Attestation memory a, bytes memory sig, uint32 candidate, bool valid)
        private
    {
        uint256 callerBefore = imd.balanceOf(address(this));
        uint256 waterBefore = body.water();
        uint256 fundsBefore = imd.balanceOf(address(body));
        uint256 allocatedBefore = body.backing() + body.owed();
        bool nowhere = expectedLocation == 0;
        uint256 support;
        uint256 incumbent;
        for (uint256 i; i < 4; ++i) {
            support += deposits[candidate][actors[i]];
            incumbent += deposits[expectedLocation][actors[i]];
        }
        // Birth has no incumbent: parking at nowhere cannot veto a qualifying first location.
        if (
            valid && candidate != 0 && candidate != expectedLocation && (nowhere || support > incumbent)
                && support * 20 >= 1001
        ) {
            expectedLocation = candidate;
        } else if (nowhere && ++emptyDays == 3) {
            expectedLocation = cells[1];
        }
        body.settle(a, sig);
        uint256 bounty = imd.balanceOf(address(this)) - callerBefore;
        bountiesOut += bounty;
        ++settlements;
        ++expectedDay;
        lastSuccess = block.timestamp;
        // The remainder pot determines the bounty without duplicating the hourly loop.
        uint256 grossRemainder = body.pot() + bounty;
        assertLe(bounty * 100, grossRemainder);
        assertLt(grossRemainder - bounty * 100, 100);
        assertEq(imd.balanceOf(address(body)) + bounty, fundsBefore);
        assertGe(body.backing() + body.owed(), allocatedBefore);
        if (nowhere) {
            assertEq(body.water(), waterBefore);
            assertEq(body.backing() + body.owed(), allocatedBefore);
        }
    }

    function _withdraw(address actor, uint32 cell, uint256 amount) private {
        uint256 beforeBalance = token.balanceOf(actor);
        vm.prank(actor);
        body.unpark(cell, amount);
        deposits[cell][actor] -= amount;
        assertEq(token.balanceOf(actor) - beforeBalance, amount);
    }

    function _claim(address actor, uint32 cell) private {
        uint256 beforeBalance = imd.balanceOf(actor);
        uint256 expected = body.claimable(actor) + body.earned(cell, actor);
        vm.prank(actor);
        uint256 paid = body.claim(cell);
        assertEq(paid, expected, "claim differs from exposed earned credit");
        assertEq(imd.balanceOf(actor) - beforeBalance, paid);
        claimsOut += paid;
        receipts[actor] += paid;
    }

    function _redeem(address actor, uint256 amount) private {
        uint256 beforeBacking = body.backing();
        uint256 remaining = 1001 - burned;
        uint256 beforeBalance = imd.balanceOf(actor);
        bool dead = block.timestamp >= lastSuccess + 30 days;
        vm.prank(actor);
        uint256 paid = body.redeem(amount);
        assertEq(imd.balanceOf(actor) - beforeBalance, paid);
        // Rational payout bounds, independent of mulDiv and the implementation's floor quote.
        uint256 numerator = amount * beforeBacking * (dead ? 10 : 9);
        uint256 denominator = remaining * 10;
        assertLe(paid * denominator, numerator, "redeem overpaid");
        // Two downward divisions cost less than two units (one division when dead).
        assertLt(numerator - paid * denominator, denominator * (dead ? 1 : 2), "redeem underpaid");
        burned += amount;
        redemptionsOut += paid;
        receipts[actor] += paid;
    }

    function check() public {
        assertEq(body.burned(), burned, "burn counter diverged from deposits");
        assertEq(body.location(), expectedLocation, "location violates vote model");
        assertEq(body.lastSettledDay(), expectedDay);
        assertEq(body.lastSuccessfulSettle(), lastSuccess);
        assertEq(body.signer(), vm.addr(signerKey));
        assertEq(body.rotationNonce(), rotations);
        assertLe(body.water(), 100);
        assertGe(body.floor(), maxFloor, "floor decreased");
        maxFloor = body.floor();
        bool dead = block.timestamp >= lastSuccess + 30 days;
        assertEq(body.isDead(), dead);
        if (sawDeath) assertTrue(dead, "dead plant revived");
        sawDeath = dead;
        if (dead) assertEq(body.pot(), 0);
        uint256 held = imd.balanceOf(address(body));
        assertEq(held + claimsOut + redemptionsOut + bountiesOut, fundsIn, "independent cash-flow ledger");
        assertEq(body.pot() + body.backing() + body.owed(), held);
        assertEq(imd.balanceOf(address(this)), bountiesOut);
        uint256 parked;
        uint256 earned;
        uint256 walletSupply;
        for (uint256 i; i < 4; ++i) {
            walletSupply += token.balanceOf(actors[i]);
            assertEq(imd.balanceOf(actors[i]), receipts[actors[i]]);
            earned += body.claimable(actors[i]);
            uint256 cellTotal;
            for (uint256 j; j < 4; ++j) {
                assertEq(body.parked(cells[i], actors[j]), deposits[cells[i]][actors[j]]);
                cellTotal += deposits[cells[i]][actors[j]];
                earned += body.earned(cells[i], actors[j]);
            }
            assertEq(body.parkedTotal(cells[i]), cellTotal);
            parked += cellTotal;
        }
        assertLe(earned, body.owed(), "garden rewards are under-reserved");
        assertEq(body.totalParked(), parked);
        assertEq(token.balanceOf(address(body)), parked + burned + donatedPlant, "burned/donated tokens escaped");
        assertEq(walletSupply + parked + burned + donatedPlant + externallyBurned, 1001);
        assertEq(token.totalSupply() + externallyBurned, 1001);
        assertEq(body.plantSupply(), 1001, "binding supply snapshot changed");
    }

    function exitAll() external {
        for (uint256 i; i < 4; ++i) {
            for (uint256 j; j < 4; ++j) {
                uint256 amount = deposits[cells[j]][actors[i]];
                if (amount != 0) _withdraw(actors[i], cells[j], amount);
                _claim(actors[i], cells[j]);
            }
            uint256 balance = token.balanceOf(actors[i]);
            if (balance != 0) _redeem(actors[i], balance);
        }
        check();
        assertEq(body.owed(), 0, "exit stranded gardener funds");
        assertEq(body.totalParked(), 0);
        assertEq(burned + donatedPlant + externallyBurned, 1001);
    }

    function _attestation(uint256 day, uint24 sun, uint24 rain, bool valid, uint32 cell)
        private
        view
        returns (OracleAttestation.Attestation memory a)
    {
        bytes32[] memory words = new bytes32[](3);
        words[0] = bytes32(
            uint256(sun) | (uint256(rain) << 24) | (uint256(valid ? 1 : 0) << 48) | (uint256(cell) << 64) | (day << 96)
        );
        a.requestId = bytes32(day);
        a.chainId = 4663;
        a.questionHash = QUESTION;
        a.answerType = 5;
        a.answer = abi.encode(words);
        a.panelSize = 5;
        a.quorum = 4;
        a.agreed = 5;
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp + 1 days);
    }

    function _sign(bytes32 digest, uint256 key) private pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }
}

contract PlantLifecycleInvariantTest is Test {
    PlantLifecycleHandler private handler;

    function setUp() public {
        vm.chainId(4663);
        vm.warp(20000 days + 12 hours);
        handler = new PlantLifecycleHandler();
        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = handler.fund.selector;
        selectors[1] = handler.park.selector;
        selectors[2] = handler.unpark.selector;
        selectors[3] = handler.claim.selector;
        selectors[4] = handler.redeem.selector;
        selectors[5] = handler.donatePlant.selector;
        selectors[6] = handler.elapse.selector;
        selectors[7] = handler.syncDeath.selector;
        selectors[8] = handler.settle.selector;
        selectors[9] = handler.rotate.selector;
        selectors[10] = handler.burnOutsideOrganism.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 96
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_custodyCashFlowFloorAndLifecycle() public {
        handler.check();
    }

    function afterInvariant() public {
        handler.exitAll();
    }

    function test_handlerBirthIgnoresNowhereSupportButLaterMovesRequireMoreSupport() public {
        handler.park(0, 0, 401);
        handler.park(1, 2, 50);
        handler.settle(0, 0, 2, true);
        assertEq(handler.body().location(), 0, "50 of 1001 is below five percent");
        handler.park(1, 2, 1);
        handler.settle(type(uint24).max, 0, 2, true);
        assertEq(handler.body().location(), handler.cells(2));
        assertEq(handler.body().water(), 50, "birth must not consume water");

        handler.park(2, 3, 51);
        handler.settle(0, 0, 3, true);
        assertEq(handler.body().location(), handler.cells(2), "a tie cannot move an existing plant");
        handler.park(2, 3, 1);
        handler.settle(0, 0, 3, true);
        assertEq(handler.body().location(), handler.cells(3));
        handler.exitAll();
    }

    function test_handlerExternalBurnsKeepClaimsSettlementAndBothRedemptionModesAvailable() public {
        handler.park(0, 1, 51);
        handler.settle(0, 0, 1, true);
        handler.fund(9000);
        handler.settle(1, 0, 1, false);
        uint256 reward = handler.body().earned(handler.cells(1), handler.actors(0));
        assertGt(reward, 0);
        handler.burnOutsideOrganism(1, 1);
        handler.claim(0, 1);
        assertEq(handler.claimsOut(), reward);
        assertEq(handler.body().owed(), 0, "claim must also release fractional reserve dust");

        handler.park(1, 2, 60);
        handler.settle(1, 0, 2, true);
        assertEq(handler.body().location(), handler.cells(2));
        handler.redeem(2, 10);
        uint256 livePaid = handler.redemptionsOut();
        assertGt(livePaid, 0);
        handler.burnOutsideOrganism(3, 100); // Entire wallet, while other holders remain parked.
        handler.elapse(0);
        handler.syncDeath();
        handler.redeem(2, 10);
        assertGt(handler.redemptionsOut(), livePaid);
        handler.exitAll();
        assertEq(handler.externallyBurned(), 101);
        assertEq(handler.burned(), 900);
        assertEq(handler.token().balanceOf(address(handler.body())), 900);
    }

    function test_handlerExternalBurnDoesNotLowerFivePercentBirthThreshold() public {
        handler.burnOutsideOrganism(0, 401);
        handler.burnOutsideOrganism(2, 200);
        handler.burnOutsideOrganism(3, 100);
        handler.park(1, 2, 50); // More than 5% of live supply, below 5% of binding supply.
        handler.settle(0, 0, 2, true);
        assertEq(handler.body().location(), 0);
        handler.park(1, 2, 1);
        handler.settle(0, 0, 2, true);
        assertEq(handler.body().location(), handler.cells(2));
        handler.exitAll();
        assertEq(handler.burned(), 300);
    }

    function test_handlerExercisesBirthRewardsMoveRotationDeathAndFullExit() public {
        handler.park(0, 1, 51); // ceil(1001 / 20), with indivisible units
        handler.settle(0, 0, 1, true);
        handler.fund(9000);
        handler.settle(1, 0, 1, false);
        handler.claim(0, 1);
        assertGt(handler.claimsOut(), 0);
        handler.park(1, 2, 100);
        handler.settle(1, 0, 2, true);
        handler.rotate(3);
        handler.settle(1, 0, 2, false);
        handler.claim(1, 2);
        handler.donatePlant(2, 1);
        handler.elapse(0); // Explicit long-gap branch.
        assertTrue(handler.sawDeath());
        handler.syncDeath();
        handler.settle(1, 0, 1, true); // Must fail without changing the day or reviving.
        handler.fund(1);
        handler.exitAll();
        assertEq(handler.settlements(), 4);
        assertEq(handler.rotations(), 1);
        assertGt(handler.redemptionsOut(), 0);
        assertGt(handler.bountiesOut(), 0);
    }
}
