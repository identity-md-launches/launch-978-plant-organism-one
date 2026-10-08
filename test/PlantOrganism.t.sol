// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PlantOrganism} from "../src/PlantOrganism.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";

contract MockToken {
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public mode; // 1: false, 2: no return, 3: fee on transfer
    address public callbackTarget;
    bytes public callback;
    bool public callbackSucceeded;

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function burn(uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        totalSupply -= amount;
    }

    function configure(uint256 mode_, address target_, bytes calldata callback_) external {
        mode = mode_;
        callbackTarget = target_;
        callback = callback_;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        return _transfer(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        return _transfer(from, to, amount);
    }

    function _transfer(address from, address to, uint256 amount) private returns (bool) {
        if (mode == 1) return false;
        balanceOf[from] -= amount;
        uint256 fee = mode == 3 ? amount / 100 : 0;
        balanceOf[to] += amount - fee;
        balanceOf[address(this)] += fee;
        if (callbackTarget != address(0)) (callbackSucceeded,) = callbackTarget.call(callback);
        if (mode == 2) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        return true;
    }
}

contract MockHook {
    address public immutable organism;
    address public immutable plant;

    constructor(address organism_, address plant_) {
        organism = organism_;
        plant = plant_;
    }
}

abstract contract PlantFixture is Test {
    uint256 internal constant KEY = 0xA11CE;
    uint256 internal constant NEXT_KEY = 0xB0B;
    uint32 internal constant LISBON = 10223579;
    uint32 internal constant PARIS = (uint32(195) << 16) | 9;
    uint32 internal constant ROME = (uint32(168) << 16) | 50;
    bytes32 internal constant QUESTION = keccak256("frozen test weather question");
    address internal alice;
    address internal bob;
    address internal caller;
    MockToken internal imd;
    MockToken internal token;
    PlantOrganism internal body;
    MockHook internal hook;

    function setUp() public virtual {
        vm.chainId(4663);
        vm.warp(20000 days + 12 hours);
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        caller = makeAddr("settler");
        imd = new MockToken();
        token = new MockToken();
        token.mint(alice, 600 ether);
        token.mint(bob, 400 ether);
        body = new PlantOrganism(address(imd), vm.addr(KEY), LISBON, address(this));
        hook = new MockHook(address(body), address(token));
        body.bind(address(hook), QUESTION);
        vm.prank(alice);
        token.approve(address(body), type(uint256).max);
        vm.prank(bob);
        token.approve(address(body), type(uint256).max);
    }

    function attestation(uint256 day, uint24 sun, uint24 rain, bool valid, uint32 cell)
        internal
        view
        returns (OracleAttestation.Attestation memory a)
    {
        bytes32[] memory words = new bytes32[](3);
        words[0] = bytes32(
            uint256(sun) | (uint256(rain) << 24) | (uint256(valid ? 1 : 0) << 48) | (uint256(cell) << 64) | (day << 96)
        );
        words[1] = bytes32(uint256(123));
        words[2] = bytes32(uint256(456));
        a = OracleAttestation.Attestation({
            requestId: bytes32(day),
            chainId: 4663,
            questionHash: QUESTION,
            answerType: 5,
            answer: abi.encode(words),
            figure: 0,
            fromBlock: 100,
            toBlock: 200,
            blockHash: bytes32(uint256(7)),
            panelJobId: bytes32(uint256(8)),
            panelSize: 5,
            quorum: 4,
            agreed: 5,
            issuedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp + 1 days)
        });
    }

    function sign(bytes32 digest, uint256 key) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function signed(OracleAttestation.Attestation memory a) internal view returns (bytes memory) {
        return sign(body.attestationDigest(a), KEY);
    }

    function next(uint24 sun, uint24 rain, bool valid, uint32 cell) internal {
        uint256 day = body.lastSettledDay() + 1;
        if (block.timestamp / 1 days < day) vm.warp(day * 1 days + 12 hours);
        OracleAttestation.Attestation memory a = attestation(day, sun, rain, valid, cell);
        bytes memory sig = signed(a);
        vm.prank(caller);
        body.settle(a, sig);
    }

    function park(address who, uint32 cell, uint256 amount) internal {
        vm.prank(who);
        body.park(cell, amount);
    }

    function birth() internal {
        park(alice, LISBON, 100 ether);
        next(0, 0, true, LISBON);
        assertEq(body.location(), LISBON);
    }

    function conservation() internal view {
        assertEq(body.pot() + body.backing() + body.owed(), imd.balanceOf(address(body)));
        assertGe(token.balanceOf(address(body)), body.burned() + body.totalParked());
    }
}

contract PlantOrganismTest is PlantFixture {
    function test_runtimeBoundedAndHasNoEscapeOpcodes() public view {
        bytes memory code = address(body).code;
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
            } else {
                assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "escape opcode");
            }
        }
    }

    function test_initialStateAndFeeInflows() public {
        assertEq(body.water(), 50);
        assertEq(body.location(), 0);
        assertEq(body.lastSettledDay(), 20000);
        imd.mint(address(this), 100 ether);
        imd.transfer(address(body), 17 ether);
        imd.mint(address(body), 83 ether);
        assertEq(body.pot(), 100 ether);
        assertEq(body.backing(), 0);
        conservation();
    }

    function test_bindOnlyExplicitDeployerAndOnlyOnce() public {
        PlantOrganism other = new PlantOrganism(address(imd), vm.addr(KEY), LISBON, alice);
        MockHook otherHook = new MockHook(address(other), address(token));
        vm.expectRevert(PlantOrganism.NotDeployer.selector);
        other.bind(address(otherHook), QUESTION);
        vm.prank(alice);
        other.bind(address(otherHook), QUESTION);
        assertEq(address(other.plant()), address(token));
        assertEq(other.QUESTION_HASH(), QUESTION);
        vm.prank(alice);
        vm.expectRevert(PlantOrganism.AlreadyBound.selector);
        other.bind(address(otherHook), keccak256("replacement"));
    }

    function test_bindRejectsBadHookQuestionAndToken() public {
        PlantOrganism other = new PlantOrganism(address(imd), vm.addr(KEY), LISBON, address(this));
        vm.expectRevert(PlantOrganism.InvalidConfiguration.selector);
        other.bind(address(hook), QUESTION);
        MockHook otherHook = new MockHook(address(other), address(token));
        vm.expectRevert(PlantOrganism.InvalidConfiguration.selector);
        other.bind(address(otherHook), bytes32(0));
        MockHook imdHook = new MockHook(address(other), address(imd));
        vm.expectRevert(PlantOrganism.InvalidConfiguration.selector);
        other.bind(address(imdHook), QUESTION);
        MockToken emptyToken = new MockToken();
        MockHook emptyHook = new MockHook(address(other), address(emptyToken));
        vm.expectRevert(PlantOrganism.InvalidConfiguration.selector);
        other.bind(address(emptyHook), QUESTION);
    }

    function test_unboundOnlyAdvancesDay() public {
        PlantOrganism other = new PlantOrganism(address(imd), vm.addr(KEY), LISBON, address(this));
        imd.mint(address(other), 1 ether);
        vm.expectRevert(PlantOrganism.Unbound.selector);
        other.park(LISBON, 1);
        vm.expectRevert(PlantOrganism.Unbound.selector);
        other.redeem(1);
        vm.warp(block.timestamp + 4 days);
        OracleAttestation.Attestation memory blank;
        other.settle(blank, "");
        assertEq(other.lastSettledDay(), 20004);
        assertEq(other.lastSuccessfulSettle(), 20000 days + 12 hours);
        assertEq(other.pot(), 1 ether);
        assertEq(other.water(), 50);
        assertEq(other.emptySettles(), 0);
        vm.expectRevert(PlantOrganism.WrongDay.selector);
        other.settle(blank, "");
    }

    function test_birthHasNoHoursAndPaysBounty() public {
        park(alice, LISBON, 50 ether);
        imd.mint(address(body), 1000 ether);
        next(type(uint24).max, type(uint24).max, true, LISBON);
        assertEq(body.location(), LISBON);
        assertEq(body.water(), 50);
        assertEq(body.backing(), 0);
        assertEq(imd.balanceOf(caller), 10 ether);
        assertEq(body.pot(), 990 ether);
        conservation();
    }

    function test_fallbackAfterExactlyThreeEmptySettles() public {
        park(alice, PARIS, 50 ether - 1);
        next(0, 0, true, PARIS);
        next(0, 0, false, PARIS);
        assertEq(body.location(), 0);
        next(type(uint24).max, 0, true, 0);
        assertEq(body.location(), LISBON);
        assertEq(body.water(), 50);
        next(1, 0, false, 0);
        assertEq(body.water(), 49);
    }

    function test_syntheticDayAndProRataClaims() public {
        birth();
        park(bob, LISBON, 200 ether);
        next(0, 0, false, 0); // Bob is active for the following settlement.
        imd.mint(address(body), 9000 ether);
        next(1, 0, false, 0);
        assertEq(body.water(), 49);
        assertEq(body.backing(), 600 ether);
        assertEq(body.owed(), 300 ether);
        assertEq(body.earned(LISBON, alice), 100 ether);
        assertEq(body.earned(LISBON, bob), 200 ether);
        vm.prank(alice);
        body.claim();
        vm.prank(bob);
        body.claim(LISBON);
        assertEq(imd.balanceOf(alice), 100 ether);
        assertEq(imd.balanceOf(bob), 200 ether);
        assertEq(body.owed(), 0);
        assertEq(body.pot(), 8019 ether);
        conservation();
    }

    function test_pendingCannotEarnInNextSettleAndTopUpDoesNotDilute() public {
        birth();
        park(bob, LISBON, 100 ether);
        park(alice, LISBON, 100 ether);
        imd.mint(address(body), 9000 ether);
        next(1, 0, false, 0);
        assertEq(body.earned(LISBON, alice), 300 ether);
        assertEq(body.earned(LISBON, bob), 0);
        vm.prank(bob);
        body.claim();
        next(1, 0, false, 0);
        assertEq(body.earned(LISBON, bob), 89.1 ether);
        assertEq(body.earned(LISBON, alice), 478.2 ether);
        conservation();
    }

    function test_pendingOnlyGardenersGoToBacking() public {
        next(0, 0, false, 0);
        next(0, 0, false, 0);
        next(0, 0, false, 0);
        park(alice, LISBON, 100 ether);
        imd.mint(address(body), 9000 ether);
        next(1, 0, false, 0);
        assertEq(body.backing(), 900 ether);
        assertEq(body.owed(), 0);
        next(1, 0, false, 0);
        assertEq(body.earned(LISBON, alice), 267.3 ether);
    }

    function test_unparkDropsActiveImmediatelyAndPendingFirst() public {
        birth();
        park(alice, LISBON, 50 ether);
        vm.prank(alice);
        body.unpark(LISBON, 75 ether);
        (uint256 active, uint256 pending,,,,) = body.cellRewards(LISBON);
        assertEq(active, 75 ether);
        assertEq(pending, 0);
        imd.mint(address(body), 9000 ether);
        next(1, 0, false, 0);
        vm.prank(alice);
        body.unpark(LISBON, 75 ether);
        assertEq(body.claimable(alice), 300 ether);
        next(1, 0, false, 0);
        vm.prank(alice);
        body.claim();
        assertEq(imd.balanceOf(alice), 300 ether);
        assertEq(body.parkedTotal(LISBON), 0);
        conservation();
    }

    function test_moveStrictMajorityRewardsOldCellAndNoMinimumStay() public {
        birth();
        park(bob, PARIS, 100 ether);
        next(0, 0, true, PARIS);
        assertEq(body.location(), LISBON); // ties stay
        park(bob, PARIS, 1 ether);
        imd.mint(address(body), 9000 ether);
        next(1, 0, true, PARIS);
        assertEq(body.location(), PARIS);
        assertEq(body.earned(LISBON, alice), 300 ether);
        assertEq(body.earned(PARIS, bob), 0);
        park(alice, LISBON, 2 ether);
        next(1, 0, true, LISBON);
        assertEq(body.location(), LISBON);
        assertGt(body.earned(PARIS, bob), 0);
        vm.prank(bob);
        body.claim(PARIS);
        conservation();
    }

    function test_noncurrentCellLazyActivationAndRepeatedTopups() public {
        birth();
        park(bob, PARIS, 60 ether);
        next(0, 0, false, 0);
        park(bob, PARIS, 30 ether);
        next(0, 0, false, 0);
        park(bob, PARIS, 20 ether);
        next(0, 0, true, PARIS);
        imd.mint(address(body), 3300 ether);
        next(1, 0, false, 0);
        assertEq(body.earned(PARIS, bob), 110 ether);
        vm.prank(bob);
        body.claim();
        assertEq(imd.balanceOf(bob), 110 ether);
        conservation();
    }

    function test_rainPrecedenceCapWaterAndDrought() public {
        birth();
        next(type(uint24).max, type(uint24).max, false, 0);
        assertEq(body.water(), 100);
        for (uint256 i; i < 5; ++i) {
            next(type(uint24).max, 0, false, 0);
        }
        assertEq(body.water(), 0);
        imd.mint(address(body), 1000 ether);
        next(type(uint24).max, 0, false, 0);
        assertEq(body.backing(), 0);
        next(3, 1, false, 0); // hour 0 rains, hour 1 sips
        assertEq(body.water(), 2);
        assertGt(body.backing(), 0);
    }

    function test_missedDaysMustBeInOrderAndCannotReplayOrUseFuture() public {
        vm.warp(block.timestamp + 4 days);
        OracleAttestation.Attestation memory a = attestation(20002, 0, 0, false, 0);
        bytes memory sig = signed(a);
        vm.expectRevert(PlantOrganism.WrongDay.selector);
        body.settle(a, sig);
        next(0, 0, false, 0);
        body.settle(a, sig);
        vm.expectRevert(PlantOrganism.WrongDay.selector);
        body.settle(a, sig);
        next(0, 0, false, 0);
        next(0, 0, false, 0);
        a = attestation(20005, 0, 0, false, 0);
        sig = signed(a);
        vm.expectRevert(PlantOrganism.WrongDay.selector);
        body.settle(a, sig);
    }

    function test_expiredAndNotYetValidRejectIncludingOneSecond() public {
        OracleAttestation.Attestation memory a = attestation(20001, 0, 0, false, 0);
        a.issuedAt = uint64(block.timestamp + 1);
        bytes memory sig = signed(a);
        vm.expectRevert(PlantOrganism.InvalidWindow.selector);
        body.settle(a, sig);
        a.issuedAt = uint64(block.timestamp - 2);
        a.expiresAt = uint64(block.timestamp - 1);
        sig = signed(a);
        vm.expectRevert(PlantOrganism.InvalidWindow.selector);
        body.settle(a, sig);
    }

    function test_windowEndpointsAreInclusive() public {
        vm.warp(block.timestamp + 1 days);
        OracleAttestation.Attestation memory a = attestation(20001, 0, 0, false, 0);
        a.expiresAt = uint64(block.timestamp);
        body.settle(a, signed(a));
    }

    function test_rejectsWrongSignerTamperingAndMalformedSignature() public {
        vm.warp(block.timestamp + 1 days);
        OracleAttestation.Attestation memory a = attestation(20001, 0, 0, false, 0);
        bytes memory sig = sign(body.attestationDigest(a), NEXT_KEY);
        vm.expectRevert(PlantOrganism.BadSignature.selector);
        body.settle(a, sig);
        sig = signed(a);
        a.figure = 1;
        vm.expectRevert(PlantOrganism.BadSignature.selector);
        body.settle(a, sig);
        vm.expectRevert(PlantOrganism.BadSignature.selector);
        body.settle(a, hex"1234");
    }

    function test_rejectsMalleableHighSSignature() public {
        vm.warp(block.timestamp + 1 days);
        OracleAttestation.Attestation memory a = attestation(20001, 0, 0, false, 0);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(KEY, body.attestationDigest(a));
        uint256 curveOrder = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes memory sig = abi.encodePacked(r, bytes32(curveOrder - uint256(s)), uint8(v == 27 ? 28 : 27));
        vm.expectRevert(PlantOrganism.BadSignature.selector);
        body.settle(a, sig);
    }

    function test_temperatureAndWindAreEmittedUnchanged() public {
        birth();
        vm.warp(block.timestamp + 1 days);
        OracleAttestation.Attestation memory a = attestation(20002, 1, 0, false, 0);
        bytes memory sig = signed(a);
        bytes32[] memory decoded = abi.decode(a.answer, (bytes32[]));
        bytes32[3] memory words = [decoded[0], decoded[1], decoded[2]];
        vm.expectEmit(true, false, false, true, address(body));
        emit PlantOrganism.Settled(20002, words, 1, 0, 49, LISBON);
        body.settle(a, sig);
    }

    function test_rotatedSignerSettlesAndOldKeyCannotRotateEvenDuringGrace() public {
        body.rotateSigner(vm.addr(NEXT_KEY), sign(body.rotationDigest(vm.addr(NEXT_KEY)), KEY));
        vm.warp(block.timestamp + 1 days);
        OracleAttestation.Attestation memory a = attestation(20001, 0, 0, false, 0);
        body.settle(a, sign(body.attestationDigest(a), NEXT_KEY));
        next(0, 0, false, 0); // The initial key still settles during grace.
        bytes memory old = sign(body.rotationDigest(bob), KEY);
        vm.expectRevert(PlantOrganism.BadSignature.selector);
        body.rotateSigner(bob, old);
    }

    function test_failedClaimKeepsDebtAndFalseTransferCannotLoseTokens() public {
        birth();
        imd.mint(address(body), 9000 ether);
        next(1, 0, false, 0);
        imd.configure(1, address(0), "");
        vm.prank(alice);
        vm.expectRevert(PlantOrganism.BadTokenTransfer.selector);
        body.claim();
        assertEq(body.owed(), 300 ether);
        assertEq(body.earned(LISBON, alice), 300 ether);
        imd.configure(2, address(0), "");
        vm.prank(alice);
        body.claim();
        assertEq(imd.balanceOf(alice), 300 ether);
        conservation();
    }

    function test_wrongChainQuestionAnswerTypeAndLengthRejected() public {
        vm.warp(block.timestamp + 1 days);
        OracleAttestation.Attestation memory a = attestation(20001, 0, 0, false, 0);
        a.chainId = 1;
        expectBad(a);
        a.chainId = 4663;
        a.questionHash = keccak256("different request");
        expectBad(a);
        a.questionHash = QUESTION;
        a.answerType = 3;
        expectBad(a);
        a.answerType = 5;
        a.answer = abi.encode(new bytes32[](2));
        expectBad(a);
        a.answer = abi.encode(new bytes32[](4));
        expectBad(a);
        a.answer = abi.encode(uint256(64), uint256(3), uint256(0), uint256(0), uint256(0));
        expectBad(a);
        vm.chainId(1);
        a = attestation(20001, 0, 0, false, 0);
        expectBad(a);
    }

    function expectBad(OracleAttestation.Attestation memory a) internal {
        bytes memory sig = signed(a);
        vm.expectRevert(PlantOrganism.BadAttestation.selector);
        body.settle(a, sig);
    }

    function test_wrongDomainContractChainAndV1Rejected() public {
        vm.warp(block.timestamp + 1 days);
        OracleAttestation.Attestation memory a = attestation(20001, 0, 0, false, 0);
        PlantOrganism other = new PlantOrganism(address(imd), vm.addr(KEY), LISBON, address(this));
        bytes memory sig = sign(other.attestationDigest(a), KEY);
        vm.expectRevert(PlantOrganism.BadSignature.selector);
        body.settle(a, sig);
        vm.chainId(1);
        sig = signed(a);
        vm.chainId(4663);
        vm.expectRevert(PlantOrganism.BadSignature.selector);
        body.settle(a, sig);
        bytes32 v1Domain = keccak256(
            abi.encode(
                body.DOMAIN_TYPEHASH(), keccak256("IdentityMD Oracle"), keccak256("1"), uint256(4663), address(body)
            )
        );
        bytes32 hash = this.hashStruct(a);
        sig = sign(keccak256(abi.encodePacked(hex"1901", v1Domain, hash)), KEY);
        vm.expectRevert(PlantOrganism.BadSignature.selector);
        body.settle(a, sig);
    }

    function hashStruct(OracleAttestation.Attestation calldata a) external pure returns (bytes32) {
        return OracleAttestation.hashStruct(a);
    }

    function test_signerRotationOnlyCurrentWithThirtyDayGraceAndCycleReplayProtection() public {
        address nextSigner = vm.addr(NEXT_KEY);
        bytes memory first = sign(body.rotationDigest(nextSigner), KEY);
        vm.prank(bob); // Any relayer; authority comes exclusively from signature.
        body.rotateSigner(nextSigner, first);
        OracleAttestation.Attestation memory a = attestation(20001, 0, 0, false, 0);
        body.verifyAttestation(a, signed(a));
        body.verifyAttestation(a, sign(body.attestationDigest(a), NEXT_KEY));
        bytes memory unauthorized = sign(body.rotationDigest(alice), KEY);
        vm.expectRevert(PlantOrganism.BadSignature.selector);
        body.rotateSigner(alice, unauthorized);
        uint256 deadline = body.signerValidUntil(vm.addr(KEY));
        vm.warp(deadline);
        a = attestation(20001, 0, 0, false, 0);
        body.verifyAttestation(a, signed(a));
        vm.warp(deadline + 1);
        a = attestation(20001, 0, 0, false, 0);
        bytes memory oldSig = signed(a);
        vm.expectRevert(PlantOrganism.BadSignature.selector);
        body.verifyAttestation(a, oldSig);
        body.rotateSigner(vm.addr(KEY), sign(body.rotationDigest(vm.addr(KEY)), NEXT_KEY));
        vm.expectRevert(PlantOrganism.BadSignature.selector);
        body.rotateSigner(nextSigner, first);
    }

    function test_successiveRotationsKeepEachOldKeysGrace() public {
        body.rotateSigner(vm.addr(NEXT_KEY), sign(body.rotationDigest(vm.addr(NEXT_KEY)), KEY));
        vm.warp(block.timestamp + 1 days);
        body.rotateSigner(alice, sign(body.rotationDigest(alice), NEXT_KEY));
        OracleAttestation.Attestation memory a = attestation(20001, 0, 0, false, 0);
        body.verifyAttestation(a, signed(a));
        body.verifyAttestation(a, sign(body.attestationDigest(a), NEXT_KEY));
    }

    function test_redemptionRetainsTenPercentAndBurnedNeverLeaves() public {
        birth();
        imd.mint(address(body), 9000 ether);
        next(1, 0, false, 0);
        uint256 beforeFloor = body.floor();
        uint256 beforeBacking = body.backing();
        vm.prank(alice);
        uint256 payout = body.redeem(100 ether);
        assertEq(payout, beforeBacking / 10 * 9 / 10);
        assertEq(body.burned(), 100 ether);
        assertGe(body.floor(), beforeFloor);
        vm.prank(alice);
        body.unpark(LISBON, 100 ether);
        assertEq(token.balanceOf(address(body)), 100 ether);
        vm.prank(alice);
        vm.expectRevert(PlantOrganism.InvalidAmount.selector);
        body.unpark(LISBON, 1);
        conservation();
    }

    function test_mustUnparkBeforeRedeemingCustodiedTokens() public {
        park(alice, LISBON, 600 ether);
        vm.prank(alice);
        vm.expectRevert(PlantOrganism.BadTokenTransfer.selector);
        body.redeem(1);
        assertEq(body.burned(), 0);
        vm.prank(alice);
        body.unpark(LISBON, 600 ether);
        vm.prank(alice);
        body.redeem(600 ether);
        conservation();
    }

    function test_deadPlantMergesPotPaysFullFloorKeepsRewardsAndCannotRevive() public {
        birth();
        imd.mint(address(body), 9000 ether);
        next(1, 0, false, 0);
        uint256 gardenDebt = body.owed();
        uint256 held = imd.balanceOf(address(body));
        uint256 last = body.lastSuccessfulSettle();
        vm.warp(last + 30 days - 1);
        assertFalse(body.isDead());
        vm.warp(last + 30 days);
        assertTrue(body.isDead());
        assertEq(body.pot(), 0);
        assertEq(body.backing(), held - gardenDebt);
        vm.prank(bob);
        uint256 paid = body.redeem(100 ether);
        assertEq(paid, (held - gardenDebt) / 10);
        vm.prank(alice);
        body.claim();
        assertEq(imd.balanceOf(alice), gardenDebt);
        imd.mint(address(body), 100 ether);
        body.syncDeath();
        conservation();
        OracleAttestation.Attestation memory a = attestation(body.lastSettledDay() + 1, 0, 0, false, 0);
        bytes memory sig = signed(a);
        vm.expectRevert(PlantOrganism.Dead.selector);
        body.settle(a, sig);
    }

    function test_deadClockTracksSuccessTimestampNotBacklogDay() public {
        vm.warp(block.timestamp + 29 days);
        next(0, 0, false, 0);
        assertEq(body.lastSettledDay(), 20001);
        vm.warp(block.timestamp + 29 days);
        assertFalse(body.isDead());
        next(0, 0, false, 0);
        assertEq(body.lastSettledDay(), 20002);
    }

    function test_finalRedemptionHasDefinedNondecreasingFloor() public {
        imd.mint(address(body), 1000 ether);
        vm.warp(block.timestamp + 30 days);
        uint256 quote = body.floor();
        vm.prank(alice);
        body.redeem(600 ether);
        vm.prank(bob);
        body.redeem(400 ether);
        assertEq(body.floor(), quote);
        assertEq(body.burned(), 1000 ether);
        assertEq(body.backing(), 0);
        assertEq(token.balanceOf(address(body)), 1000 ether);
        conservation();
    }

    function test_rejectsChangedSupplyInvalidCellsAndZeroAmounts() public {
        vm.expectRevert(PlantOrganism.InvalidCell.selector);
        body.park(uint32(361) << 16, 1);
        vm.expectRevert(PlantOrganism.InvalidAmount.selector);
        body.park(LISBON, 0);
        assertTrue(body.validCell(LISBON));
        assertTrue(body.validCell(0));
        assertFalse(body.validCell(uint32(721)));
        token.mint(alice, 1);
        vm.expectRevert(PlantOrganism.SupplyChanged.selector);
        body.park(LISBON, 1);
    }

    function test_falseReturningAndFeeTokensRevertAtomicallyNoReturnWorks() public {
        token.configure(1, address(0), "");
        vm.prank(alice);
        vm.expectRevert(PlantOrganism.BadTokenTransfer.selector);
        body.park(LISBON, 100 ether);
        token.configure(3, address(0), "");
        vm.prank(alice);
        vm.expectRevert(PlantOrganism.BadTokenTransfer.selector);
        body.park(LISBON, 100 ether);
        assertEq(body.totalParked(), 0);
        token.configure(2, address(0), "");
        park(alice, LISBON, 100 ether);
        vm.prank(alice);
        body.unpark(LISBON, 100 ether);
        conservation();
    }

    function test_reentrancyBlockedOnPlantPullAndImdPayout() public {
        token.configure(0, address(body), abi.encodeWithSignature("claim()"));
        birth();
        assertFalse(token.callbackSucceeded());
        imd.mint(address(body), 9000 ether);
        imd.configure(0, address(body), abi.encodeWithSignature("redeem(uint256)", 1));
        next(1, 0, false, 0);
        assertFalse(imd.callbackSucceeded());
        vm.prank(alice);
        body.claim();
        assertFalse(imd.callbackSucceeded());
        conservation();
    }

    function test_failedBountyRollsBackEntireSettlement() public {
        birth();
        imd.mint(address(body), 9000 ether);
        imd.configure(1, address(0), "");
        vm.warp(block.timestamp + 1 days);
        OracleAttestation.Attestation memory a = attestation(20002, 1, 0, false, 0);
        bytes memory sig = signed(a);
        vm.expectRevert(PlantOrganism.BadTokenTransfer.selector);
        body.settle(a, sig);
        assertEq(body.lastSettledDay(), 20001);
        assertEq(body.water(), 50);
        assertEq(body.backing(), 0);
        assertEq(body.owed(), 0);
        conservation();
    }

    function testFuzz_maskSimulationAndConservation(uint24 sun, uint24 rain, uint96 funds) public {
        birth();
        imd.mint(address(body), funds);
        uint256 available = funds;
        uint256 moisture = 50;
        uint256 garden;
        uint256 base;
        for (uint256 h; h < 24; ++h) {
            if (uint256(rain) & (uint256(1) << h) != 0) {
                moisture = moisture + 3 > 100 ? 100 : moisture + 3;
            } else if (uint256(sun) & (uint256(1) << h) != 0 && moisture > 0) {
                --moisture;
                uint256 sip = available / 10;
                available -= sip;
                garden += sip / 3;
                base += sip - sip / 3;
            }
        }
        next(sun, rain, false, 0);
        assertEq(body.water(), moisture);
        assertEq(body.pot(), available - available / 100);
        assertEq(body.backing() + body.owed(), base + garden);
        assertLe(body.owed(), garden);
        vm.prank(alice);
        body.claim();
        assertEq(body.owed(), 0); // All allocation and holder dust returned to backing.
        conservation();
    }

    function testFuzz_redemptionFloorNeverDecreases(uint96 funds, uint96 rawAmount) public {
        birth();
        imd.mint(address(body), funds);
        next(type(uint24).max, 0, false, 0);
        uint256 amount = bound(uint256(rawAmount), 1, 400 ether);
        uint256 beforeFloor = body.floor();
        vm.prank(bob);
        body.redeem(amount);
        assertGe(body.floor(), beforeFloor);
        conservation();
    }
}

contract PlantGasTest is PlantFixture {
    function setUp() public override {
        super.setUp();
        birth();
        park(bob, LISBON, 1 ether);
        park(bob, PARIS, 200 ether);
        imd.mint(address(body), 1_000_000 ether);
        vm.warp(block.timestamp + 1 days);
    }

    function test_settleGasBoundIncludingFreshRewardsPendingActivationAndMove() public {
        OracleAttestation.Attestation memory a = attestation(20002, type(uint24).max, 0, true, PARIS);
        bytes memory sig = signed(a);
        vm.cool(address(body));
        vm.cool(address(imd));
        vm.cool(address(token));
        vm.prank(caller);
        uint256 gasBefore = gasleft();
        body.settle(a, sig);
        uint256 used = gasBefore - gasleft();
        emit log_named_uint("settle execution gas (cold, 24 sips, pending activation, move)", used);
        // Include transaction base cost and the exact calldata intrinsic cost.
        bytes memory data = abi.encodeCall(body.settle, (a, sig));
        uint256 intrinsic = 21_000;
        for (uint256 i; i < data.length; ++i) {
            intrinsic += data[i] == 0 ? 4 : 16;
        }
        emit log_named_uint("settle gas including intrinsic", used + intrinsic);
        assertLt(used + intrinsic, 400_000);
        conservation();
    }
}
