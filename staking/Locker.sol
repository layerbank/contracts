// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

import "../library/Whitelist.sol";
import "../library/SafeToken.sol";
import "../library/Constant.sol";

import "../interfaces/ILocker.sol";
import "../interfaces/IRebateDistributor.sol";
import "../interfaces/ILABDistributor.sol";

contract Locker is ILocker, Whitelist, ReentrancyGuard, Pausable {
    using SafeMath for uint256;
    using SafeToken for address;

    /* ========== CONSTANTS ============= */

    uint256 public constant LOCK_UNIT_BASE = 7 days;
    uint256 public constant LOCK_UNIT_MAX = 365 days;
    uint256 public constant LOCK_UNIT_MIN = 4 weeks;

    /* ========== STATE VARIABLES ========== */

    address public LAB;
    ILABDistributor public labDistributor;
    IRebateDistributor public rebateDistributor;

    mapping(address => uint256) public balances;
    mapping(address => uint256) public expires;

    uint256 public override totalBalance;

    uint256 private _lastTotalScore;
    uint256 private _lastSlope;
    uint256 private _lastTimestamp;
    mapping(uint256 => uint256) private _slopeChanges;
    mapping(address => Constant.LockInfo[]) private _lockHistory;
    mapping(address => uint256) private _firstLockTime;

    bool public initialized;

    /* ========== INITIALIZER ========== */

    constructor() public {
        _lastTimestamp = block.timestamp;
    }

    function initialize(address _labTokenAddress) external onlyOwner {
        require(initialized == false, "already initialized");

        require(
            _labTokenAddress != address(0),
            "Locker: LAB address can't be zero"
        );
        LAB = _labTokenAddress;

        initialized = true;
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function setLABDistributor(
        address _labDistributor
    ) external override onlyOwner {
        require(
            _labDistributor != address(0),
            "Locker: invalid labDistributor address"
        );
        labDistributor = ILABDistributor(_labDistributor);
        emit LABDistributorUpdated(_labDistributor);
    }

    function pause() external override onlyOwner {
        _pause();
        emit Pause();
    }

    function unpause() external override onlyOwner {
        _unpause();
        emit Unpause();
    }

    /* ========== VIEWS ========== */

    function balanceOf(
        address account
    ) external view override returns (uint256) {
        return balances[account];
    }

    function expiryOf(
        address account
    ) external view override returns (uint256) {
        return expires[account];
    }

    function availableOf(
        address account
    ) external view override returns (uint256) {
        return expires[account] < block.timestamp ? balances[account] : 0;
    }

    function getLockUnitMax() external view override returns (uint256) {
        return LOCK_UNIT_MAX;
    }

    function totalScore()
        public
        view
        override
        returns (uint256 score, uint256 slope)
    {
        score = _lastTotalScore;
        slope = _lastSlope;

        uint256 prevTimestamp = _lastTimestamp;
        uint256 nextTimestamp = _onlyTruncateExpiry(_lastTimestamp).add(
            LOCK_UNIT_BASE
        );
        while (nextTimestamp < block.timestamp) {
            uint256 deltaScore = nextTimestamp.sub(prevTimestamp).mul(slope);
            score = score < deltaScore ? 0 : score.sub(deltaScore);
            slope = slope.sub(_slopeChanges[nextTimestamp]);

            prevTimestamp = nextTimestamp;
            nextTimestamp = nextTimestamp.add(LOCK_UNIT_BASE);
        }
        uint256 deltaScore = block.timestamp > prevTimestamp
            ? block.timestamp.sub(prevTimestamp).mul(slope)
            : 0;
        score = score > deltaScore ? score.sub(deltaScore) : 0;
    }

    function scoreOf(address account) external view override returns (uint256) {
        if (expires[account] < block.timestamp) return 0;
        return
            expires[account].sub(block.timestamp).mul(
                balances[account].div(LOCK_UNIT_MAX)
            );
    }

    function remainExpiryOf(
        address account
    ) external view override returns (uint256) {
        if (expires[account] < block.timestamp) return 0;
        return expires[account].sub(block.timestamp);
    }

    function preRemainExpiryOf(
        uint256 expiry
    ) external view override returns (uint256) {
        if (expiry <= block.timestamp) return 0;
        expiry = _truncateExpiry(expiry);
        require(
            expiry > block.timestamp &&
                expiry <= _truncateExpiry(block.timestamp + LOCK_UNIT_MAX),
            "Locker: preRemainExpiryOf: invalid expiry"
        );
        return expiry.sub(block.timestamp);
    }

    function preScoreOf(
        address account,
        uint256 amount,
        uint256 expiry,
        Constant.EcoScorePreviewOption option
    ) external view override returns (uint256) {
        if (
            option == Constant.EcoScorePreviewOption.EXTEND &&
            expires[account] < block.timestamp
        ) return 0;
        uint256 expectedAmount = balances[account];
        uint256 expectedExpires = expires[account];

        if (option == Constant.EcoScorePreviewOption.LOCK) {
            expectedAmount = expectedAmount.add(amount);
            expectedExpires = _truncateExpiry(expiry);
        } else if (option == Constant.EcoScorePreviewOption.LOCK_MORE) {
            expectedAmount = expectedAmount.add(amount);
        } else if (option == Constant.EcoScorePreviewOption.EXTEND) {
            expectedExpires = _truncateExpiry(expiry);
        }
        if (expectedExpires <= block.timestamp) {
            return 0;
        }
        return
            expectedExpires.sub(block.timestamp).mul(
                expectedAmount.div(LOCK_UNIT_MAX)
            );
    }

    function scoreOfAt(
        address account,
        uint256 timestamp
    ) external view override returns (uint256) {
        uint256 count = _lockHistory[account].length;
        if (count == 0 || _lockHistory[account][count - 1].expiry <= timestamp)
            return 0;

        for (uint256 i = count - 1; i < uint256(-1); i--) {
            Constant.LockInfo storage lock = _lockHistory[account][i];

            if (lock.timestamp <= timestamp) {
                return
                    lock.expiry <= timestamp
                        ? 0
                        : lock.expiry.sub(timestamp).mul(lock.amount).div(
                            LOCK_UNIT_MAX
                        );
            }
        }
        return 0;
    }

    function lockInfoOf(
        address account
    ) external view override returns (Constant.LockInfo[] memory) {
        return _lockHistory[account];
    }

    function firstLockTimeInfoOf(
        address account
    ) external view override returns (uint256) {
        return _firstLockTime[account];
    }

    function truncateExpiry(
        uint256 time
    ) external view override returns (uint256) {
        return _truncateExpiry(time);
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function deposit(
        uint256 amount,
        uint256 expiry
    ) external override nonReentrant whenNotPaused {
        require(amount > 0, "Locker: invalid amount");
        expiry = balances[msg.sender] == 0
            ? _truncateExpiry(expiry)
            : expires[msg.sender];
        require(
            block.timestamp < expiry &&
                expiry <= _truncateExpiry(block.timestamp + LOCK_UNIT_MAX),
            "Locker: deposit: invalid expiry"
        );
        if (balances[msg.sender] == 0) {
            uint256 lockPeriod = expiry > block.timestamp
                ? expiry.sub(block.timestamp)
                : 0;
            require(
                lockPeriod >= LOCK_UNIT_MIN,
                "Locker: The expiry does not meet the minimum period"
            );
            _firstLockTime[msg.sender] = block.timestamp;
        }
        _slopeChanges[expiry] = _slopeChanges[expiry].add(
            amount.div(LOCK_UNIT_MAX)
        );
        _updateTotalScore(amount, expiry);

        LAB.safeTransferFrom(msg.sender, address(this), amount);
        totalBalance = totalBalance.add(amount);

        balances[msg.sender] = balances[msg.sender].add(amount);
        expires[msg.sender] = expiry;

        _updateLABDistributorBoostedInfo(msg.sender);

        _lockHistory[msg.sender].push(
            Constant.LockInfo({
                timestamp: block.timestamp,
                amount: balances[msg.sender],
                expiry: expires[msg.sender]
            })
        );

        emit Deposit(msg.sender, amount, expiry);
    }

    function extendLock(
        uint256 nextExpiry
    ) external override nonReentrant whenNotPaused {
        uint256 amount = balances[msg.sender];
        require(amount > 0, "Locker: zero balance");

        uint256 prevExpiry = expires[msg.sender];
        nextExpiry = _truncateExpiry(nextExpiry);
        require(block.timestamp < prevExpiry, "Locker: expired lock");
        require(
            Math.max(prevExpiry, block.timestamp) < nextExpiry &&
                nextExpiry <= _truncateExpiry(block.timestamp + LOCK_UNIT_MAX),
            "Locker: invalid expiry time"
        );

        uint256 slopeChange = (_slopeChanges[prevExpiry] <
            amount.div(LOCK_UNIT_MAX))
            ? _slopeChanges[prevExpiry]
            : amount.div(LOCK_UNIT_MAX);
        _slopeChanges[prevExpiry] = _slopeChanges[prevExpiry].sub(slopeChange);
        _slopeChanges[nextExpiry] = _slopeChanges[nextExpiry].add(slopeChange);
        _updateTotalScoreExtendingLock(amount, prevExpiry, nextExpiry);
        expires[msg.sender] = nextExpiry;

        _updateLABDistributorBoostedInfo(msg.sender);

        _lockHistory[msg.sender].push(
            Constant.LockInfo({
                timestamp: block.timestamp,
                amount: balances[msg.sender],
                expiry: expires[msg.sender]
            })
        );

        emit ExtendLock(msg.sender, nextExpiry);
    }

    function withdraw() external override nonReentrant whenNotPaused {
        require(
            balances[msg.sender] > 0 && block.timestamp >= expires[msg.sender],
            "Locker: invalid state"
        );
        _updateTotalScore(0, 0);

        uint256 amount = balances[msg.sender];
        totalBalance = totalBalance.sub(amount);
        delete balances[msg.sender];
        delete expires[msg.sender];
        delete _firstLockTime[msg.sender];
        LAB.safeTransfer(msg.sender, amount);

        _updateLABDistributorBoostedInfo(msg.sender);

        emit Withdraw(msg.sender);
    }

    function withdrawAndLock(
        uint256 expiry
    ) external override nonReentrant whenNotPaused {
        uint256 amount = balances[msg.sender];
        require(
            amount > 0 && block.timestamp >= expires[msg.sender],
            "Locker: invalid state"
        );

        expiry = _truncateExpiry(expiry);
        require(
            block.timestamp < expiry &&
                expiry <= _truncateExpiry(block.timestamp + LOCK_UNIT_MAX),
            "Locker: withdrawAndLock: invalid expiry"
        );

        _slopeChanges[expiry] = _slopeChanges[expiry].add(
            amount.div(LOCK_UNIT_MAX)
        );
        _updateTotalScore(amount, expiry);

        expires[msg.sender] = expiry;

        _updateLABDistributorBoostedInfo(msg.sender);
        _firstLockTime[msg.sender] = block.timestamp;

        _lockHistory[msg.sender].push(
            Constant.LockInfo({
                timestamp: block.timestamp,
                amount: balances[msg.sender],
                expiry: expires[msg.sender]
            })
        );

        emit WithdrawAndLock(msg.sender, expiry);
    }

    function depositBehalf(
        address account,
        uint256 amount,
        uint256 expiry
    ) external override onlyWhitelisted nonReentrant whenNotPaused {
        require(amount > 0, "Locker: invalid amount");

        expiry = balances[account] == 0
            ? _truncateExpiry(expiry)
            : expires[account];
        require(
            block.timestamp < expiry &&
                expiry <= _truncateExpiry(block.timestamp + LOCK_UNIT_MAX),
            "Locker: depositBehalf: invalid expiry"
        );

        if (balances[account] == 0) {
            uint256 lockPeriod = expiry > block.timestamp
                ? expiry.sub(block.timestamp)
                : 0;
            require(
                lockPeriod >= LOCK_UNIT_MIN,
                "Locker: The expiry does not meet the minimum period"
            );
            _firstLockTime[account] = block.timestamp;
        }

        _slopeChanges[expiry] = _slopeChanges[expiry].add(
            amount.div(LOCK_UNIT_MAX)
        );
        _updateTotalScore(amount, expiry);

        LAB.safeTransferFrom(msg.sender, address(this), amount);
        totalBalance = totalBalance.add(amount);

        balances[account] = balances[account].add(amount);
        expires[account] = expiry;

        _updateLABDistributorBoostedInfo(account);
        _lockHistory[account].push(
            Constant.LockInfo({
                timestamp: block.timestamp,
                amount: balances[account],
                expiry: expires[account]
            })
        );

        emit DepositBehalf(msg.sender, account, amount, expiry);
    }

    function withdrawBehalf(
        address account
    ) external override onlyWhitelisted nonReentrant whenNotPaused {
        require(
            balances[account] > 0 && block.timestamp >= expires[account],
            "Locker: invalid state"
        );
        _updateTotalScore(0, 0);

        uint256 amount = balances[account];
        totalBalance = totalBalance.sub(amount);
        delete balances[account];
        delete expires[account];
        delete _firstLockTime[account];
        LAB.safeTransfer(account, amount);

        _updateLABDistributorBoostedInfo(account);

        emit WithdrawBehalf(msg.sender, account);
    }

    function withdrawAndLockBehalf(
        address account,
        uint256 expiry
    ) external override onlyWhitelisted nonReentrant whenNotPaused {
        uint256 amount = balances[account];
        require(
            amount > 0 && block.timestamp >= expires[account],
            "Locker: invalid state"
        );

        expiry = _truncateExpiry(expiry);
        require(
            block.timestamp < expiry &&
                expiry <= _truncateExpiry(block.timestamp + LOCK_UNIT_MAX),
            "Locker: withdrawAndLockBehalf: invalid expiry"
        );

        _slopeChanges[expiry] = _slopeChanges[expiry].add(
            amount.div(LOCK_UNIT_MAX)
        );
        _updateTotalScore(amount, expiry);

        expires[account] = expiry;

        _updateLABDistributorBoostedInfo(account);
        _firstLockTime[account] = block.timestamp;

        _lockHistory[account].push(
            Constant.LockInfo({
                timestamp: block.timestamp,
                amount: balances[account],
                expiry: expires[account]
            })
        );

        emit WithdrawAndLockBehalf(msg.sender, account, expiry);
    }

    /* ========== PRIVATE FUNCTIONS ========== */

    function _updateTotalScore(uint256 newAmount, uint256 nextExpiry) private {
        (uint256 score, uint256 slope) = totalScore();

        if (newAmount > 0) {
            uint256 slopeChange = newAmount.div(LOCK_UNIT_MAX);
            uint256 newAmountDeltaScore = nextExpiry.sub(block.timestamp).mul(
                slopeChange
            );

            slope = slope.add(slopeChange);
            score = score.add(newAmountDeltaScore);
        }

        _lastTotalScore = score;
        _lastSlope = slope;
        _lastTimestamp = block.timestamp;
    }

    function _updateTotalScoreExtendingLock(
        uint256 amount,
        uint256 prevExpiry,
        uint256 nextExpiry
    ) private {
        (uint256 score, uint256 slope) = totalScore();

        uint256 deltaScore = nextExpiry.sub(prevExpiry).mul(
            amount.div(LOCK_UNIT_MAX)
        );
        score = score.add(deltaScore);

        _lastTotalScore = score;
        _lastSlope = slope;
        _lastTimestamp = block.timestamp;
    }

    function _updateLABDistributorBoostedInfo(address user) private {
        labDistributor.updateAccountBoostedInfo(user);
    }

    function _truncateExpiry(uint256 time) private view returns (uint256) {
        if (time > block.timestamp.add(LOCK_UNIT_MAX)) {
            time = block.timestamp.add(LOCK_UNIT_MAX);
        }
        return
            (time.div(LOCK_UNIT_BASE).mul(LOCK_UNIT_BASE)).add(LOCK_UNIT_BASE);
    }

    function _onlyTruncateExpiry(uint256 time) private pure returns (uint256) {
        return time.div(LOCK_UNIT_BASE).mul(LOCK_UNIT_BASE);
    }
}
