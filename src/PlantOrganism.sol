// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {OracleAttestation} from "./OracleAttestation.sol";

interface IPlantToken {
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IPlantHook {
    function organism() external view returns (address);
    function plant() external view returns (address);
}

/// @notice Immutable weather-driven body; the separate launch supplies PLANT and its hook.
contract PlantOrganism {
    uint256 public constant CHAIN_ID = 4663;
    uint256 public constant DAY = 1 days;
    uint256 public constant DEATH_DELAY = 30 days;
    uint256 public constant SIGNER_GRACE = 30 days;
    uint256 public constant PRECISION = 1e27;
    uint256 public constant FLOOR_SCALE = 1e18;
    bytes32 public constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 public constant ROTATE_TYPEHASH =
        keccak256("RotateSigner(address organism,address newSigner,uint256 nonce)");

    IPlantToken public immutable IMD;
    address public immutable deployer;
    uint32 public immutable FALLBACK_CELL;
    address public signer;
    mapping(address => uint256) public signerValidUntil;
    uint256 public rotationNonce;
    IPlantToken public plant;
    address public hook;
    bytes32 public QUESTION_HASH;
    uint256 public plantSupply;

    uint32 public location;
    uint256 public water = 50;
    uint256 private _backing;
    uint256 public owed;
    uint256 public burned;
    uint256 public totalParked;
    uint256 public lastSettledDay;
    uint256 public lastSuccessfulSettle;
    uint256 public emptySettles;
    bool public deathRecorded;
    uint256 public terminalFloor;
    uint256 private _guard = 1;

    mapping(uint32 => mapping(address => uint256)) public parked;
    mapping(uint32 => uint256) public parkedTotal;

    struct CellRewards {
        uint256 active;
        uint256 pending;
        uint256 pendingAt;
        uint256 acc;
        // Exact scaled liability = (reserved - (fraction != 0)) * PRECISION + fraction.
        // This permits all rounding dust to return to backing without visiting holders.
        uint256 reserved;
        uint256 fraction;
    }

    struct Position {
        uint256 pending;
        uint256 pendingAt;
        uint256 checkpoint;
    }

    mapping(uint32 => CellRewards) public cellRewards;
    mapping(uint32 => mapping(address => Position)) public positions;
    mapping(uint32 => mapping(uint256 => uint256)) public activationAcc;
    mapping(address => uint256) public claimable;

    error InvalidConfiguration();
    error NotDeployer();
    error AlreadyBound();
    error Unbound();
    error Reentrancy();
    error InvalidAmount();
    error InvalidCell();
    error BadTokenTransfer();
    error SupplyChanged();
    error BadAttestation();
    error BadSignature();
    error InvalidWindow();
    error WrongDay();
    error Dead();
    error Alive();

    event Bound(address indexed hook, address indexed plant, bytes32 questionHash);
    event Parked(address indexed holder, uint32 indexed cell, uint256 amount);
    event Unparked(address indexed holder, uint32 indexed cell, uint256 amount);
    event Checkpointed(address indexed holder, uint32 indexed cell, uint256 reward);
    event Claimed(address indexed holder, uint256 amount);
    event Redeemed(address indexed holder, uint256 amount, uint256 imd, bool dead);
    event Moved(uint32 indexed from, uint32 indexed to, uint256 indexed day);
    event Settled(uint256 indexed day, bytes32[3] words, uint256 sips, uint256 backing, uint256 water, uint32 location);
    event Bounty(address indexed caller, uint256 amount);
    event UnboundAdvanced(uint256 day);
    event Died(uint256 lastSuccessfulSettle);
    event DeadPotMerged(uint256 amount);
    event SignerRotated(address indexed previous, address indexed current, uint256 nonce, uint256 previousValidUntil);

    modifier nonReentrant() {
        if (_guard != 1) revert Reentrancy();
        _guard = 2;
        _;
        _guard = 1;
    }

    constructor(address imd_, address signer_, uint32 fallbackCell_, address deployer_) {
        if (imd_ == address(0) || signer_ == address(0) || deployer_ == address(0)) revert InvalidConfiguration();
        if (fallbackCell_ == 0 || !validCell(fallbackCell_)) revert InvalidCell();
        IMD = IPlantToken(imd_);
        signer = signer_;
        FALLBACK_CELL = fallbackCell_;
        deployer = deployer_;
        lastSettledDay = block.timestamp / DAY;
        lastSuccessfulSettle = block.timestamp;
    }

    function bound() public view returns (bool) {
        return hook != address(0);
    }

    /// @dev This is the deployer's only power. Neither address nor question can subsequently change.
    function bind(address hook_, bytes32 questionHash) external nonReentrant {
        if (msg.sender != deployer) revert NotDeployer();
        if (bound()) revert AlreadyBound();
        if (hook_.code.length == 0 || questionHash == bytes32(0)) revert InvalidConfiguration();
        if (IPlantHook(hook_).organism() != address(this)) revert InvalidConfiguration();
        address token = IPlantHook(hook_).plant();
        if (token.code.length == 0 || token == address(IMD) || token == address(this)) revert InvalidConfiguration();
        uint256 supply = IPlantToken(token).totalSupply();
        if (supply == 0) revert InvalidConfiguration();
        hook = hook_;
        plant = IPlantToken(token);
        plantSupply = supply;
        QUESTION_HASH = questionHash;
        emit Bound(hook_, token, questionHash);
    }

    /// @notice Signed quarter-degree latitude [-360,360], longitude [-720,720]. Zero is nowhere.
    function validCell(uint32 cell) public pure returns (bool) {
        int16 lat = int16(uint16(cell >> 16));
        int16 lon = int16(uint16(cell));
        return lat >= -360 && lat <= 360 && lon >= -720 && lon <= 720;
    }

    function isDead() public view returns (bool) {
        return bound() && block.timestamp >= lastSuccessfulSettle + DEATH_DELAY;
    }

    /// @notice Death is reflected immediately in reads; storage is materialized by syncDeath/redeem.
    function backing() public view returns (uint256) {
        return isDead() ? IMD.balanceOf(address(this)) - owed : _backing;
    }

    function pot() public view returns (uint256) {
        return isDead() ? 0 : IMD.balanceOf(address(this)) - _backing - owed;
    }

    /// @notice IMD base units per PLANT base unit, scaled by 1e18; final redemption preserves this quote.
    function floor() public view returns (uint256) {
        if (!bound()) return 0;
        uint256 remaining = plantSupply - burned;
        return remaining == 0 ? terminalFloor : Math.mulDiv(backing(), FLOOR_SCALE, remaining);
    }

    function park(uint32 cell, uint256 amount) external nonReentrant {
        _checkSupply();
        if (!validCell(cell)) revert InvalidCell();
        if (amount == 0) revert InvalidAmount();
        _checkpoint(cell, msg.sender);
        Position storage p = positions[cell][msg.sender];
        CellRewards storage c = cellRewards[cell];
        p.pending += amount;
        p.pendingAt = lastSettledDay;
        c.pending += amount;
        c.pendingAt = lastSettledDay;
        parked[cell][msg.sender] += amount;
        parkedTotal[cell] += amount;
        totalParked += amount;
        _pullExact(plant, msg.sender, amount);
        emit Parked(msg.sender, cell, amount);
    }

    function unpark(uint32 cell, uint256 amount) external nonReentrant {
        if (amount == 0 || amount > parked[cell][msg.sender]) revert InvalidAmount();
        _checkpoint(cell, msg.sender);
        Position storage p = positions[cell][msg.sender];
        CellRewards storage c = cellRewards[cell];
        uint256 pendingOut = Math.min(amount, p.pending);
        p.pending -= pendingOut;
        c.pending -= pendingOut;
        c.active -= amount - pendingOut;
        parked[cell][msg.sender] -= amount;
        parkedTotal[cell] -= amount;
        totalParked -= amount;
        _sendExact(plant, msg.sender, amount);
        emit Unparked(msg.sender, cell, amount);
    }

    /// @notice Claims the current cell and any previously checkpointed credits. No proposal list exists.
    function claim() external nonReentrant returns (uint256) {
        _checkpoint(location, msg.sender);
        return _claim(msg.sender);
    }

    /// @notice Claim a specified cell, including a location the organism has left.
    function claim(uint32 cell) external nonReentrant returns (uint256) {
        _checkpoint(cell, msg.sender);
        return _claim(msg.sender);
    }

    function _claim(address holder) private returns (uint256 amount) {
        amount = claimable[holder];
        claimable[holder] = 0;
        owed -= amount;
        if (amount != 0) _sendExact(IMD, holder, amount);
        emit Claimed(holder, amount);
    }

    function redeem(uint256 amount) external nonReentrant returns (uint256 payout) {
        _checkSupply();
        uint256 remaining = plantSupply - burned;
        if (amount == 0 || amount > remaining) revert InvalidAmount();
        bool dead = isDead();
        if (dead) _mergeDeadPot();
        // Evaluate the ratio in full precision, rather than rounding the per-token quote first.
        payout = Math.mulDiv(amount, _backing, remaining);
        if (!dead) payout = Math.mulDiv(payout, 9, 10);
        if (amount == remaining) terminalFloor = floor();
        burned += amount;
        _backing -= payout;
        _pullExact(plant, msg.sender, amount);
        if (payout != 0) _sendExact(IMD, msg.sender, payout);
        emit Redeemed(msg.sender, amount, payout, dead);
    }

    function syncDeath() external nonReentrant {
        if (!isDead()) revert Alive();
        _mergeDeadPot();
    }

    function _mergeDeadPot() private {
        if (!deathRecorded) {
            deathRecorded = true;
            emit Died(lastSuccessfulSettle);
        }
        uint256 extra = IMD.balanceOf(address(this)) - owed - _backing;
        _backing += extra;
        emit DeadPotMerged(extra);
    }

    function settle(OracleAttestation.Attestation calldata a, bytes calldata sig) external nonReentrant {
        if (!bound()) {
            uint256 today = block.timestamp / DAY;
            if (today <= lastSettledDay) revert WrongDay();
            lastSettledDay = today;
            emit UnboundAdvanced(today);
            return;
        }
        if (isDead()) revert Dead();
        _checkSupply();
        if (block.chainid != CHAIN_ID || a.chainId != CHAIN_ID || a.questionHash != QUESTION_HASH) {
            revert BadAttestation();
        }
        // Canonical abi.encode(bytes32[dynamic]) has offset, length and exactly three words.
        if (a.answerType != OracleAttestation.ANSWER_BYTES32_LIST || a.answer.length != 160) revert BadAttestation();
        (uint256 offset, uint256 length) = abi.decode(a.answer, (uint256, uint256));
        if (offset != 32 || length != 3) revert BadAttestation();
        verifyAttestation(a, sig);
        bytes32[] memory decoded = abi.decode(a.answer, (bytes32[]));
        bytes32[3] memory words = [decoded[0], decoded[1], decoded[2]];
        uint256 packed = uint256(words[0]);
        uint256 day = uint32(packed >> 96);
        if (day != lastSettledDay + 1 || day > block.timestamp / DAY) revert WrongDay();
        uint32 current = location;
        _rollCell(current);
        uint256 available = pot();
        uint256 sips;
        uint256 gardeners;
        uint256 moisture = water;
        if (current != 0) {
            for (uint256 hour; hour < 24; ++hour) {
                if ((packed >> (24 + hour)) & 1 != 0) {
                    moisture = Math.min(100, moisture + 3);
                } else if ((packed >> hour) & 1 != 0 && moisture != 0) {
                    --moisture;
                    uint256 sip = available / 10;
                    available -= sip;
                    gardeners += sip / 3;
                    _backing += sip - sip / 3;
                    ++sips;
                }
            }
        }
        water = moisture;
        _reward(current, gardeners);
        uint32 challenger = uint32(packed >> 64);
        bool valid = ((packed >> 48) & 1) != 0;
        uint256 threshold = plantSupply / 20 + (plantSupply % 20 == 0 ? 0 : 1);
        if (
            valid && challenger != 0 && validCell(challenger) && challenger != current
                && parkedTotal[challenger] > parkedTotal[current] && parkedTotal[challenger] >= threshold
        ) {
            location = challenger;
        } else if (current == 0) {
            ++emptySettles;
            if (emptySettles == 3) location = FALLBACK_CELL;
        }
        lastSettledDay = day;
        lastSuccessfulSettle = block.timestamp;
        // Activation is AFTER this day's allocation, including when no tokens were active.
        _rollCell(current);
        if (location != current) {
            _rollCell(location);
            emit Moved(current, location, day);
        }
        uint256 bounty = available / 100;
        if (bounty != 0) _sendExact(IMD, msg.sender, bounty);
        emit Bounty(msg.sender, bounty);
        emit Settled(day, words, sips, _backing, water, location);
    }

    function domainSeparator() public view returns (bytes32) {
        return keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256(bytes(OracleAttestation.DOMAIN_NAME)),
                keccak256(bytes(OracleAttestation.DOMAIN_VERSION)),
                block.chainid,
                address(this)
            )
        );
    }

    function attestationDigest(OracleAttestation.Attestation calldata a) public view returns (bytes32) {
        return _typedDigest(OracleAttestation.hashStruct(a));
    }

    /// @notice Cryptographic verification only; settle additionally pins chain, question, shape and day.
    function verifyAttestation(OracleAttestation.Attestation calldata a, bytes calldata sig) public view {
        if (a.issuedAt > block.timestamp || block.timestamp > a.expiresAt) revert InvalidWindow();
        address recovered = _recover(attestationDigest(a), sig);
        if (recovered != signer && (signerValidUntil[recovered] == 0 || block.timestamp > signerValidUntil[recovered]))
        {
            revert BadSignature();
        }
    }

    function rotationDigest(address newSigner) public view returns (bytes32) {
        return _typedDigest(keccak256(abi.encode(ROTATE_TYPEHASH, address(this), newSigner, rotationNonce)));
    }

    function rotateSigner(address newSigner, bytes calldata sig) external nonReentrant {
        if (newSigner == address(0) || newSigner == signer) revert InvalidConfiguration();
        if (_recover(rotationDigest(newSigner), sig) != signer) revert BadSignature();
        address previous = signer;
        uint256 until = block.timestamp + SIGNER_GRACE;
        signerValidUntil[previous] = until;
        signer = newSigner;
        emit SignerRotated(previous, newSigner, rotationNonce++, until);
    }

    function _typedDigest(bytes32 structHash) private view returns (bytes32) {
        return keccak256(abi.encodePacked(hex"1901", domainSeparator(), structHash));
    }

    function _recover(bytes32 digest, bytes calldata sig) private pure returns (address recovered) {
        (address account, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, sig);
        if (err != ECDSA.RecoverError.NoError || account == address(0)) revert BadSignature();
        return account;
    }

    function _checkSupply() private view {
        if (!bound()) revert Unbound();
        if (plant.totalSupply() != plantSupply) revert SupplyChanged();
    }

    function _rollCell(uint32 cell) private {
        CellRewards storage c = cellRewards[cell];
        if (c.pending != 0 && c.pendingAt < lastSettledDay) {
            activationAcc[cell][c.pendingAt] = c.acc;
            c.active += c.pending;
            c.pending = 0;
        }
    }

    function _reward(uint32 cell, uint256 amount) private {
        if (amount == 0) return;
        CellRewards storage c = cellRewards[cell];
        if (c.active == 0) {
            _backing += amount;
            return;
        }
        uint256 increment = Math.mulDiv(amount, PRECISION, c.active);
        uint256 whole = Math.mulDiv(increment, c.active, PRECISION);
        uint256 remainder = mulmod(increment, c.active, PRECISION);
        uint256 sum = c.fraction + remainder;
        uint256 fraction = sum % PRECISION;
        uint256 reserved = whole + sum / PRECISION + (fraction == 0 ? 0 : 1) - (c.fraction == 0 ? 0 : 1);
        c.fraction = fraction;
        c.reserved += reserved;
        c.acc += increment;
        owed += reserved;
        _backing += amount - reserved;
    }

    function _checkpoint(uint32 cell, address holder) private {
        _rollCell(cell);
        CellRewards storage c = cellRewards[cell];
        Position storage p = positions[cell][holder];
        uint256 active = parked[cell][holder] - p.pending;
        uint256 delta = c.acc - p.checkpoint;
        uint256 whole = Math.mulDiv(active, delta, PRECISION);
        uint256 remainder = mulmod(active, delta, PRECISION);
        if (p.pending != 0 && p.pendingAt < lastSettledDay) {
            delta = c.acc - activationAcc[cell][p.pendingAt];
            whole += Math.mulDiv(p.pending, delta, PRECISION);
            remainder += mulmod(p.pending, delta, PRECISION);
            whole += remainder / PRECISION;
            remainder %= PRECISION;
            p.pending = 0;
        }
        p.checkpoint = c.acc;
        if (whole != 0 || remainder != 0) {
            uint256 fraction = (c.fraction + PRECISION - remainder) % PRECISION;
            uint256 released =
                whole + (c.fraction < remainder ? 1 : 0) + (c.fraction == 0 ? 0 : 1) - (fraction == 0 ? 0 : 1);
            c.fraction = fraction;
            c.reserved -= released;
            uint256 dust = released - whole;
            owed -= dust;
            _backing += dust;
            claimable[holder] += whole;
        }
        emit Checkpointed(holder, cell, whole);
    }

    function earned(uint32 cell, address holder) external view returns (uint256 reward) {
        CellRewards storage c = cellRewards[cell];
        Position storage p = positions[cell][holder];
        uint256 active = parked[cell][holder] - p.pending;
        uint256 delta = c.acc - p.checkpoint;
        reward = Math.mulDiv(active, delta, PRECISION);
        uint256 remainder = mulmod(active, delta, PRECISION);
        if (p.pending != 0 && p.pendingAt < lastSettledDay) {
            // If the cell hasn't been rolled since activation, its accumulator cannot have changed.
            uint256 start = c.pending != 0 && c.pendingAt == p.pendingAt ? c.acc : activationAcc[cell][p.pendingAt];
            delta = c.acc - start;
            reward += Math.mulDiv(p.pending, delta, PRECISION);
            reward += (remainder + mulmod(p.pending, delta, PRECISION)) / PRECISION;
        }
    }

    function _pullExact(IPlantToken token, address from, uint256 amount) private {
        uint256 beforeBalance = token.balanceOf(address(this));
        _tokenCall(address(token), abi.encodeCall(token.transferFrom, (from, address(this), amount)));
        if (token.balanceOf(address(this)) != beforeBalance + amount) revert BadTokenTransfer();
    }

    function _sendExact(IPlantToken token, address to, uint256 amount) private {
        uint256 beforeBalance = token.balanceOf(address(this));
        uint256 recipientBefore = token.balanceOf(to);
        _tokenCall(address(token), abi.encodeCall(token.transfer, (to, amount)));
        if (token.balanceOf(address(this)) != beforeBalance - amount || token.balanceOf(to) != recipientBefore + amount)
        {
            revert BadTokenTransfer();
        }
    }

    function _tokenCall(address token, bytes memory data) private {
        (bool ok, bytes memory result) = token.call(data);
        if (!ok || (result.length != 0 && (result.length != 32 || !abi.decode(result, (bool))))) {
            revert BadTokenTransfer();
        }
    }
}
