// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PlantFixture} from "./PlantOrganism.t.sol";
import {OracleAttestation} from "src/OracleAttestation.sol";

contract PlantFractionalSettlementGasTest is PlantFixture {
    function setUp() public virtual override {
        super.setUp();
        park(alice, LISBON, 100 ether + 1);
        for (uint256 i; i < _extraHolders(); ++i) {
            address holder = makeAddr(string.concat("gas holder ", vm.toString(i)));
            vm.prank(alice);
            token.transfer(holder, 1);
            vm.startPrank(holder);
            token.approve(address(body), 1);
            body.park(LISBON, 1);
            vm.stopPrank();
        }
        next(0, 0, true, LISBON);
        park(bob, LISBON, 1 ether);
        park(bob, PARIS, 200 ether);
        imd.mint(address(body), 1_000_000 ether);
        vm.warp(block.timestamp + 1 days);
    }

    function _extraHolders() internal pure virtual returns (uint256) {
        return 0;
    }

    function test_coldSettlementBudgetWithFractionalDebtActivationAndMove() public {
        OracleAttestation.Attestation memory a = attestation(20002, type(uint24).max, 0, true, PARIS);
        bytes32[] memory words = abi.decode(a.answer, (bytes32[]));
        words[1] = bytes32(type(uint256).max);
        words[2] = bytes32(type(uint256).max);
        a.answer = abi.encode(words);
        bytes memory sig = signed(a);
        // Signature preparation and setup must not warm the measured contract/storage accesses.
        vm.cool(address(body));
        vm.cool(address(imd));
        vm.cool(address(token));
        vm.prank(caller);
        uint256 beforeGas = gasleft();
        body.settle(a, sig);
        uint256 used = beforeGas - gasleft();
        bytes memory data = abi.encodeCall(body.settle, (a, sig));
        uint256 intrinsic = 21_000;
        for (uint256 i; i < data.length; ++i) {
            intrinsic += data[i] == 0 ? 4 : 16;
        }
        emit log_named_uint("cold settlement gas including calldata and transaction base", used + intrinsic);
        assertLe(used + intrinsic, 400_000);
        assertEq(body.location(), PARIS);
        assertEq(body.water(), 26);
        assertGt(body.owed(), 0);
        (,,,,, uint256 fraction) = body.cellRewards(LISBON);
        assertGt(fraction, 0, "must exercise the extra fractional-liability storage write");
        conservation();
    }
}

/// @dev Same settlement and gas ceiling with 129 active holders; setup is outside the measurement.
contract PlantManyHoldersSettlementGasTest is PlantFractionalSettlementGasTest {
    function _extraHolders() internal pure override returns (uint256) {
        return 128;
    }
}
