// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

import "../library/SafeToken.sol";

import "../interfaces/IRewardController.sol";
import "../interfaces/ILABDistributor.sol";
import "../interfaces/IxLAB.sol";

contract RewardController is IRewardController, Ownable, ReentrancyGuard, Pausable {
    using SafeMath for uint256;
    using SafeToken for address;

    uint256 public constant QUART = 25000; //  25%
    uint256 public constant HALF = 65000; //  65%
    uint256 public constant WHOLE = 100000; // 100%

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    /// @notice Proportion of burn amount
    uint256 public burn;

    /// @notice Duration of vesting LAB
    uint256 public vestDuration;

    address public LAB;
    address public treasury;

    IxLAB public xLAB;
    ILABDistributor public labDistributor;

    /********************** Lock & Earn Info ***********************/

    mapping(address => Balances) private balances;
    mapping(address => LockedBalance[]) private userEarnings;
    mapping(address => bool) public minters;

    bool public mintersAreSet;

    bool public initialized;

    constructor() public {}

    function initialize(
        address _lab,
        address _xlab,
        address _labDistributor,
        address _treasury,
        uint256 _vestDuration,
        uint256 _burnRatio
    ) external onlyOwner {
        require(initialized == false, "already initialized");
        require(_lab != address(0), "RewardController: lab address can't be zero");
        require(_xlab != address(0), "RewardController: xlab address can't be zero");
        require(_labDistributor != address(0), "RewardController: labDistributor can't be zero");
        require(_treasury != address(0), "RewardController: treasury address can't be zero");
        require(_vestDuration != uint256(0), "RewardController: vestDuration can't be zero");
        require(_burnRatio <= WHOLE, "RewardController: invalid burn");

        LAB = _lab;
        xLAB = IxLAB(_xlab);
        labDistributor = ILABDistributor(_labDistributor);
        treasury = _treasury;
        burn = _burnRatio;
        vestDuration = _vestDuration;

        _approveLAB(_xlab);

        initialized = true;
    }

    /* ========== RESTRICTED FUNCTIONS ========== */
    function setMinters(address[] memory _minters) external onlyOwner {
        require(!mintersAreSet, "minters set");
        for (uint256 i = 0; i < _minters.length; i++) {
            require(_minters[i] != address(0), "minter is 0 address");
            minters[_minters[i]] = true;
        }
        mintersAreSet = true;
    }

    function setVestDuration(uint256 _vestDuration) external onlyOwner {
        require(_vestDuration > 0, "RewardController: invalid vest duration");
        vestDuration = _vestDuration;
    }

    function setXLAB(address _xlab) external onlyOwner {
        if (address(xLAB) != address(0)) {
            _disapproveLAB(address(xLAB));
        }
        xLAB = IxLAB(_xlab);
        _approveLAB(_xlab);
    }

    function pause() public onlyOwner {
        _pause();
    }

    function unpause() public onlyOwner {
        _unpause();
    }

    /* ========== VIEWS ========== */

    function earnedBalances(
        address user
    ) public view override returns (uint256 total, uint256 unlocked, EarnedBalance[] memory earningsData) {
        unlocked = balances[user].unlocked;
        LockedBalance[] storage earnings = userEarnings[user];
        uint256 idx;
        for (uint256 i = 0; i < earnings.length; i++) {
            if (earnings[i].unlockTime > block.timestamp) {
                if (idx == 0) {
                    earningsData = new EarnedBalance[](earnings.length - i);
                }
                (, , uint256 penaltyAmount, ) = _penaltyInfo(userEarnings[user][i]);
                earningsData[idx].amount = earnings[i].amount;
                earningsData[idx].unlockTime = earnings[i].unlockTime;
                earningsData[idx].penalty = penaltyAmount;
                idx++;
                total = total.add(earnings[i].amount);
            } else {
                unlocked = unlocked.add(earnings[i].amount);
            }
        }
        return (total, unlocked, earningsData);
    }

    function withdrawableBalance(
        address user
    ) public view override returns (uint256 amount, uint256 penaltyAmount, uint256 burnAmount) {
        uint256 earned = balances[user].earned;
        if (earned > 0) {
            uint256 length = userEarnings[user].length;
            for (uint256 i = 0; i < length; i++) {
                uint256 earnedAmount = userEarnings[user][i].amount;
                if (earnedAmount == 0) continue;
                (, , uint256 newPenaltyAmount, uint256 newBurnAmount) = _penaltyInfo(userEarnings[user][i]);
                penaltyAmount = penaltyAmount.add(newPenaltyAmount);
                burnAmount = burnAmount.add(newBurnAmount);
            }
        }
        amount = balances[user].unlocked.add(earned).sub(penaltyAmount);
        return (amount, penaltyAmount, burnAmount);
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function mint(address user, uint256 amount, bool withPenalty) external override whenNotPaused nonReentrant {
        require(minters[msg.sender], "!minter");
        if (amount == 0) return;

        Balances storage bal = balances[user];
        bal.total = bal.total.add(amount);

        if (withPenalty) {
            bal.earned = bal.earned.add(amount);
            LockedBalance[] storage earnings = userEarnings[user];
            uint256 unlockTime = block.timestamp.add(vestDuration);
            earnings.push(LockedBalance({amount: amount, unlockTime: unlockTime, duration: vestDuration}));
        } else {
            bal.unlocked = bal.unlocked.add(amount);
        }
    }

    function withdraw(uint256 amount) external override nonReentrant {
        address _address = msg.sender;
        require(amount != 0, "amount cannot be 0");

        uint256 penaltyAmount;
        uint256 burnAmount;
        Balances storage bal = balances[_address];

        if (amount <= bal.unlocked) {
            bal.unlocked = bal.unlocked.sub(amount);
        } else {
            uint256 remaining = amount.sub(bal.unlocked);
            require(bal.earned >= remaining, "invalid earned");
            bal.unlocked = 0;
            uint256 sumEarned = bal.earned;
            uint256 i;
            for (i = 0; ; i++) {
                uint256 earnedAmount = userEarnings[_address][i].amount;
                if (earnedAmount == 0) continue;
                (, uint256 penaltyFactor, , ) = _penaltyInfo(userEarnings[_address][i]);

                // Amount required from this lock, taking into account the penalty
                uint256 requiredAmount = remaining.mul(WHOLE).div(WHOLE.sub(penaltyFactor));
                if (requiredAmount >= earnedAmount) {
                    requiredAmount = earnedAmount;
                    remaining = remaining.sub(earnedAmount.mul(WHOLE.sub(penaltyFactor)).div(WHOLE));
                    if (remaining == 0) i++;
                } else {
                    userEarnings[_address][i].amount = earnedAmount.sub(requiredAmount);
                    remaining = 0;
                }
                sumEarned = sumEarned.sub(requiredAmount);
                penaltyAmount = penaltyAmount.add(requiredAmount.mul(penaltyFactor).div(WHOLE));

                if (remaining == 0) {
                    break;
                } else {
                    require(sumEarned != 0, "0 earned");
                }
            }
            if (i > 0) {
                for (uint256 j = i; j < userEarnings[_address].length; j++) {
                    userEarnings[_address][j - i] = userEarnings[_address][j];
                }
                for (uint256 j = 0; j < i; j++) {
                    userEarnings[_address].pop();
                }
            }
            bal.earned = sumEarned;
        }

        bal.total = bal.total.sub(amount).sub(penaltyAmount);
        burnAmount = penaltyAmount.mul(burn).div(WHOLE);
        _withdrawTokens(amount, penaltyAmount, burnAmount);
    }

    // Withdraw individual earnings
    function individualEarlyExit(uint256 unlockTime) external override {
        require(unlockTime > block.timestamp, "!unlockTime");
        (uint256 amount, uint256 penaltyAmount, uint256 burnAmount, uint256 index) = _ieeWithdrawableBalances(
            msg.sender,
            unlockTime
        );

        if (index >= userEarnings[msg.sender].length) {
            return;
        }

        for (uint256 i = index + 1; i < userEarnings[msg.sender].length; i++) {
            userEarnings[msg.sender][i - 1] = userEarnings[msg.sender][i];
        }
        userEarnings[msg.sender].pop();

        Balances storage bal = balances[msg.sender];
        bal.total = bal.total.sub(amount).sub(penaltyAmount);
        bal.earned = bal.earned.sub(amount).sub(penaltyAmount);

        _withdrawTokens(amount, penaltyAmount, burnAmount);
    }

    // Withdraw full unlocked balance and earnings
    function exit() external override {
        (uint256 amount, uint256 penaltyAmount, uint256 burnAmount) = withdrawableBalance(msg.sender);

        delete userEarnings[msg.sender];

        Balances storage bal = balances[msg.sender];
        bal.total = bal.total.sub(bal.unlocked).sub(bal.earned);
        bal.unlocked = 0;
        bal.earned = 0;

        _withdrawTokens(amount, penaltyAmount, burnAmount);
    }

    function exitLock(uint256 lockDuration) external nonReentrant {
        require(lockDuration.add(block.timestamp) > _maxUnlockTime(msg.sender), "invalid lock duration");

        Balances storage bal = balances[msg.sender];
        _instantLock(msg.sender, bal.total, lockDuration);

        delete userEarnings[msg.sender];

        bal.total = 0;
        bal.unlocked = 0;
        bal.earned = 0;
    }

    /* ========== PRIVATE FUNCTIONS ========== */

    function _withdrawTokens(uint256 amount, uint256 penaltyAmount, uint256 burnAmount) internal {
        LAB.safeTransfer(msg.sender, amount);
        if (penaltyAmount > 0) {
            if (burnAmount > 0) {
                LAB.safeTransfer(DEAD, burnAmount);
            }
            LAB.safeTransfer(treasury, penaltyAmount.sub(burnAmount));
        }
    }

    function _instantLock(address user, uint256 amount, uint256 lockDuration) private {
        xLAB.lockBehalf(user, amount, lockDuration);
    }

    function _ieeWithdrawableBalances(
        address user,
        uint256 unlockTime
    ) internal view returns (uint256 amount, uint256 penaltyAmount, uint256 burnAmount, uint256 index) {
        index = uint256(-1);
        for (uint256 i = 0; i < userEarnings[user].length; i++) {
            if (userEarnings[user][i].unlockTime == unlockTime) {
                (amount, , penaltyAmount, burnAmount) = _penaltyInfo(userEarnings[user][i]);
                index = i;
                break;
            }
        }
    }

    function _penaltyInfo(
        LockedBalance memory earning
    ) internal view returns (uint256 amount, uint256 penaltyFactor, uint256 penaltyAmount, uint256 burnAmount) {
        if (earning.unlockTime > block.timestamp) {
            penaltyFactor = earning.unlockTime.sub(block.timestamp).mul(HALF).div(vestDuration).add(QUART);
        }
        penaltyAmount = earning.amount.mul(penaltyFactor).div(WHOLE);
        burnAmount = penaltyAmount.mul(burn).div(WHOLE);
        amount = earning.amount.sub(penaltyAmount);
    }

    function _maxUnlockTime(address user) public view returns (uint256 maxUnlockTime) {
        LockedBalance[] storage earnings = userEarnings[user];

        for (uint256 i = 0; i < earnings.length; i++) {
            if (maxUnlockTime < earnings[i].unlockTime) {
                maxUnlockTime = earnings[i].unlockTime;
            }
        }
    }

    function _approveLAB(address _spender) private {
        LAB.safeApprove(_spender, uint256(-1));
    }

    function _disapproveLAB(address _spender) private {
        LAB.safeApprove(_spender, 0);
    }
}
