// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {PlantOrganism} from "../src/PlantOrganism.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";
import {PlantFixture, MockToken} from "./PlantOrganism.t.sol";

/// @dev Eager per-holder reference model, independent of the implementation's lazy epochs.
contract PlantHandler is Test {
    uint256 private constant KEY = 0xA11CE;
    uint256 private constant SCALE = 1e27;
    PlantOrganism public body;
    MockToken public imd;
    MockToken public token;
    address[2] public actors;
    uint32[3] public cells;
    mapping(uint32 => mapping(address => uint256)) public amounts;
    mapping(uint32 => mapping(address => uint256)) public eligible;
    mapping(uint32 => mapping(address => uint256)) public scaledRewards;
    mapping(address => uint256) public credits;
    uint256 public previousFloor;
    uint256 public fundsIn;
    uint256 public previousBurned;

    constructor(PlantOrganism body_, MockToken imd_, MockToken token_, address alice, address bob) {
        body = body_;
        imd = imd_;
        token = token_;
        actors = [alice, bob];
        cells = [uint32(10223579), (uint32(195) << 16) | 9, (uint32(168) << 16) | 50];
        amounts[cells[0]][alice] = 100 ether;
        eligible[cells[0]][alice] = 100 ether;
    }

    function fund(uint96 raw) external {
        uint256 amount = uint256(raw) % 1e27;
        imd.mint(address(body), amount);
        fundsIn += amount;
        check();
    }

    function park(uint8 who, uint8 where, uint96 raw) external {
        address actor = actors[who % 2];
        uint32 cell = cells[where % 3];
        uint256 balance = token.balanceOf(actor);
        if (balance == 0) return;
        uint256 amount = uint256(raw) % balance + 1;
        checkpoint(cell, actor);
        amounts[cell][actor] += amount;
        vm.prank(actor);
        body.park(cell, amount);
        check();
    }

    function unpark(uint8 who, uint8 where, uint96 raw) external {
        address actor = actors[who % 2];
        uint32 cell = cells[where % 3];
        uint256 balance = amounts[cell][actor];
        if (balance == 0) return;
        uint256 amount = uint256(raw) % balance + 1;
        withdraw(cell, actor, amount);
        check();
    }

    function withdraw(uint32 cell, address actor, uint256 amount) private {
        checkpoint(cell, actor);
        uint256 pending = amounts[cell][actor] - eligible[cell][actor];
        if (amount > pending) eligible[cell][actor] -= amount - pending;
        amounts[cell][actor] -= amount;
        vm.prank(actor);
        body.unpark(cell, amount);
    }

    function claim(uint8 who, uint8 where) external {
        pay(cells[where % 3], actors[who % 2]);
        check();
    }

    function checkpoint(uint32 cell, address actor) private {
        credits[actor] += scaledRewards[cell][actor] / SCALE;
        scaledRewards[cell][actor] = 0;
    }

    function pay(uint32 cell, address actor) private {
        checkpoint(cell, actor);
        uint256 balance = imd.balanceOf(actor);
        uint256 expected = credits[actor];
        credits[actor] = 0;
        vm.prank(actor);
        uint256 paid = body.claim(cell);
        assertEq(paid, expected, "model claim mismatch");
        assertEq(imd.balanceOf(actor) - balance, expected);
    }

    function settle(uint24 sun, uint24 rain, uint8 where, bool valid) external {
        if (body.isDead()) return;
        uint256 day = body.lastSettledDay() + 1;
        if (block.timestamp / 1 days < day) vm.warp(day * 1 days + 12 hours);
        uint32 current = body.location();
        uint32 challenger = cells[where % 3];
        uint256 garden;
        uint256 pot = body.pot();
        uint256 water = body.water();
        for (uint256 h; h < 24; ++h) {
            if ((uint256(rain) >> h) & 1 != 0) {
                water = water + 3 > 100 ? 100 : water + 3;
            } else if ((uint256(sun) >> h) & 1 != 0 && water > 0) {
                --water;
                uint256 sip = pot / 10;
                pot -= sip;
                garden += sip / 3;
            }
        }
        uint256 active = eligible[current][actors[0]] + eligible[current][actors[1]];
        if (active != 0) {
            uint256 delta = garden * SCALE / active;
            for (uint256 i; i < 2; ++i) {
                scaledRewards[current][actors[i]] += delta * eligible[current][actors[i]];
            }
        }
        bytes32[] memory words = new bytes32[](3);
        words[0] = bytes32(
            uint256(sun) | (uint256(rain) << 24) | (uint256(valid ? 1 : 0) << 48) | (uint256(challenger) << 64)
                | (day << 96)
        );
        OracleAttestation.Attestation memory a;
        a.requestId = bytes32(day);
        a.chainId = 4663;
        a.questionHash = body.QUESTION_HASH();
        a.answerType = 5;
        a.answer = abi.encode(words);
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp + 1 days);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(KEY, body.attestationDigest(a));
        body.settle(a, abi.encodePacked(r, s, v));
        assertEq(body.water(), water);
        for (uint256 c; c < 3; ++c) {
            for (uint256 i; i < 2; ++i) {
                eligible[cells[c]][actors[i]] = amounts[cells[c]][actors[i]];
            }
        }
        check();
    }

    function redeem(uint8 who, uint96 raw) external {
        address actor = actors[who % 2];
        uint256 balance = token.balanceOf(actor);
        if (balance == 0) return;
        uint256 amount = uint256(raw) % balance + 1;
        uint256 beforeBacking = body.backing();
        uint256 expected = amount * beforeBacking / (body.plantSupply() - body.burned());
        if (!body.isDead()) expected = expected * 9 / 10;
        vm.prank(actor);
        uint256 paid = body.redeem(amount);
        assertEq(paid, expected);
        check();
    }

    function elapse(uint8 days_) external {
        vm.warp(block.timestamp + (uint256(days_) % 3) * 1 days);
        check();
    }

    function check() public {
        assertGe(body.floor(), previousFloor, "floor fell");
        previousFloor = body.floor();
        assertGe(body.burned(), previousBurned, "burned left");
        previousBurned = body.burned();
        assertEq(body.pot() + body.backing() + body.owed(), imd.balanceOf(address(body)));
        assertEq(
            fundsIn,
            imd.balanceOf(address(body)) + imd.balanceOf(address(this)) + imd.balanceOf(actors[0])
                + imd.balanceOf(actors[1]),
            "IMD inflow/outflow mismatch"
        );
        uint256 parked;
        uint256 reserve;
        for (uint256 c; c < 3; ++c) {
            uint256 scaled;
            for (uint256 i; i < 2; ++i) {
                assertEq(body.parked(cells[c], actors[i]), amounts[cells[c]][actors[i]]);
                assertEq(body.earned(cells[c], actors[i]), scaledRewards[cells[c]][actors[i]] / SCALE);
                scaled += scaledRewards[cells[c]][actors[i]];
                parked += amounts[cells[c]][actors[i]];
            }
            reserve += scaled / SCALE + (scaled % SCALE == 0 ? 0 : 1);
        }
        for (uint256 i; i < 2; ++i) {
            assertEq(body.claimable(actors[i]), credits[actors[i]]);
            reserve += credits[actors[i]];
        }
        assertEq(reserve, body.owed(), "exact outstanding liability mismatch");
        assertEq(parked, body.totalParked());
        assertEq(token.balanceOf(address(body)), body.burned() + parked);
    }

    function exitAll() external {
        for (uint256 c; c < 3; ++c) {
            for (uint256 i; i < 2; ++i) {
                uint256 amount = amounts[cells[c]][actors[i]];
                if (amount != 0) withdraw(cells[c], actors[i], amount);
                pay(cells[c], actors[i]);
            }
        }
        check();
        assertEq(body.owed(), 0, "stranded reward dust");
        assertEq(body.totalParked(), 0);
    }
}

contract PlantInvariantTest is PlantFixture {
    PlantHandler private handler;

    function setUp() public override {
        super.setUp();
        birth();
        handler = new PlantHandler(body, imd, token, alice, bob);
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.fund.selector;
        selectors[1] = handler.park.selector;
        selectors[2] = handler.unpark.selector;
        selectors[3] = handler.claim.selector;
        selectors[4] = handler.settle.selector;
        selectors[5] = handler.redeem.selector;
        selectors[6] = handler.elapse.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 96
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_accountingAndEagerRewardModelAgree() public {
        handler.check();
    }

    function afterInvariant() public {
        handler.exitAll();
    }
}
