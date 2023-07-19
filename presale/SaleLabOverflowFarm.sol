// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.6.12;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "../interfaces/ISaleLabOverflowFarm.sol";
import "../interfaces/IBEP20.sol";

import "../library/SafeToken.sol";

contract SaleLabOverflowFarm is Ownable, ReentrancyGuard, ISaleLabOverflowFarm {
    using SafeMath for uint256;
    using SafeToken for address;

    IBEP20 public offeringToken;
    uint256 public override startTime;
    uint256 public override endTime;
    uint256 public override raisingAmount;
    uint256 public override offeringAmount;
    uint256 public override totalAmount;
    mapping(address => UserInfo) public override userInfo;
    address[] public addressList;

    bool public initialized;
    bool public adminClaimed;

    uint256 public lastRewardTimestamp;
    uint256 public accTokenPerShare;
    uint256 public override rewardPerSecond;
    IBEP20 public rewardToken;

    mapping(address => uint256) public rewardStored;

    mapping(address => bool) public override whitelist;

    constructor() public {}

    function initialize(
        IBEP20 _offeringToken,
        uint256 _startTime,
        uint256 _endTime,
        uint256 _offeringAmount,
        uint256 _raisingAmount,
        IBEP20 _rewardToken,
        uint256 _rewardPerSecond
    ) external onlyOwner {
        require(initialized == false, "already initialized");

        offeringToken = _offeringToken;
        startTime = _startTime;
        endTime = _endTime;
        offeringAmount = _offeringAmount;
        raisingAmount = _raisingAmount;
        totalAmount = 0;

        rewardToken = _rewardToken;
        rewardPerSecond = _rewardPerSecond;

        lastRewardTimestamp = startTime;

        initialized = true;
    }

    function setOfferingAmount(uint256 _offerAmount) external onlyOwner {
        require(block.timestamp < startTime, "no");
        offeringAmount = _offerAmount;
    }

    function setRaisingAmount(uint256 _raisingAmount) external onlyOwner {
        require(block.timestamp < startTime, "no");
        raisingAmount = _raisingAmount;
    }

    function setWhitelist(address _addr, bool isWhiteUser) external onlyOwner {
        whitelist[_addr] = isWhiteUser;
    }

    function setWhitelists(
        address[] calldata _addrs,
        bool isWhiteUser
    ) external onlyOwner {
        for (uint256 i = 0; i < _addrs.length; i++) {
            whitelist[_addrs[i]] = isWhiteUser;
        }
    }

    function withdrawRaisingToken(uint256 _amount) external onlyOwner {
        require(block.timestamp > endTime, "not withdraw time");
        require(_amount <= address(this).balance, "not enough token");
        require(
            _amount <= raisingAmount,
            "can not withdraw amount greater than raisingAmount"
        );
        _safeTransferETH(msg.sender, _amount);
    }

    function withdrawOfferingToken(uint256 _amount) external onlyOwner {
        require(block.timestamp > endTime, "not withdraw time");
        require(
            _amount <= offeringToken.balanceOf(address(this)),
            "not enough token"
        );
        address(offeringToken).safeTransfer(msg.sender, _amount);
    }

    function deposit(address _referral) external payable override nonReentrant {
        require(
            block.timestamp > startTime && block.timestamp < endTime,
            "not IDO time"
        );
        require(msg.value > 0, "msg.value must be higher than 0");

        _updatePool();

        uint256 _rewardStore = userInfo[msg.sender]
            .amount
            .mul(accTokenPerShare)
            .div(1e18)
            .sub(userInfo[msg.sender].rewardDebt);
        rewardStored[msg.sender] = rewardStored[msg.sender].add(_rewardStore);

        if (userInfo[msg.sender].amount == 0) {
            addressList.push(address(msg.sender));
        }
        userInfo[msg.sender].amount = userInfo[msg.sender].amount.add(
            msg.value
        );
        totalAmount = totalAmount.add(msg.value);

        userInfo[msg.sender].rewardDebt = userInfo[msg.sender]
            .amount
            .mul(accTokenPerShare)
            .div(1e18);
        emit Deposit(msg.sender, msg.value, _referral);
    }

    function harvest() external override nonReentrant {
        require(block.timestamp > endTime, "not harvest time");
        require(userInfo[msg.sender].amount > 0, "have you participated?");
        require(!userInfo[msg.sender].claimed, "nothing to harvest");
        _updatePool();

        uint256 offeringTokenAmount = getOfferingAmount(msg.sender);
        uint256 refundingTokenAmount = getRefundingAmount(msg.sender);

        if (refundingTokenAmount > 0) {
            _safeTransferETH(msg.sender, refundingTokenAmount);
        }

        address(offeringToken).safeTransfer(msg.sender, offeringTokenAmount);

        userInfo[msg.sender].claimed = true;
        emit Harvest(msg.sender, offeringTokenAmount, refundingTokenAmount);
    }

    function harvestOverflowReward() external override nonReentrant {
        require(block.timestamp > harvestTime(), "not harvest time");
        UserInfo storage user = userInfo[msg.sender];
        _updatePool();

        uint256 pending = 0;
        if (user.amount > 0) {
            pending = user.amount.mul(accTokenPerShare).div(1e18).sub(
                user.rewardDebt
            );
            pending = pending.add(rewardStored[msg.sender]);
            if (pending > 0) {
                address(rewardToken).safeTransfer(msg.sender, pending);
            }
            rewardStored[msg.sender] = 0;
        }
        user.rewardDebt = user.amount.mul(accTokenPerShare).div(1e18);
    }

    function hasHarvest(address _user) external view override returns (bool) {
        return userInfo[_user].claimed;
    }

    function harvestTime() public view override returns (uint256) {
        return endTime.add(30 days);
    }

    function getUserAllocation(
        address _user
    ) public view override returns (uint256) {
        return userInfo[_user].amount.mul(1e18).div(totalAmount);
    }

    function getOfferingAmount(
        address _user
    ) public view override returns (uint256) {
        if (totalAmount > raisingAmount) {
            uint256 allocation = getUserAllocation(_user);
            if (whitelist[_user]) {
                return
                    offeringAmount.mul(allocation).mul(105).div(1e18).div(100);
            } else {
                return offeringAmount.mul(allocation).div(1e18);
            }
        } else {
            if (whitelist[_user]) {
                return
                    userInfo[_user]
                        .amount
                        .mul(offeringAmount)
                        .mul(105)
                        .div(raisingAmount)
                        .div(100);
            } else {
                return
                    userInfo[_user].amount.mul(offeringAmount).div(
                        raisingAmount
                    );
            }
        }
    }

    function getRefundingAmount(
        address _user
    ) public view override returns (uint256) {
        if (totalAmount <= raisingAmount) {
            return 0;
        }
        uint256 allocation = getUserAllocation(_user);
        uint256 payAmount = raisingAmount.mul(allocation).div(1e18);
        return userInfo[_user].amount.sub(payAmount);
    }

    function pendingReward(
        address _user
    ) external view override returns (uint256) {
        UserInfo storage user = userInfo[_user];
        uint256 stakedTokenSupply = totalAmount;
        uint256 reward = 0;
        if (block.timestamp > lastRewardTimestamp && stakedTokenSupply != 0) {
            uint256 multiplier = _getMultiplier(
                lastRewardTimestamp,
                block.timestamp
            );
            uint256 rewardTokenReward = multiplier.mul(rewardPerSecond);
            uint256 _accTokenPerShare = rewardTokenReward.mul(1e18).div(
                stakedTokenSupply
            );
            uint256 adjustedTokenPerShare = accTokenPerShare.add(
                _accTokenPerShare
            );
            reward = user.amount.mul(adjustedTokenPerShare).div(1e18).sub(
                user.rewardDebt
            );
        } else {
            reward = user.amount.mul(accTokenPerShare).div(1e18).sub(
                user.rewardDebt
            );
        }
        return reward.add(rewardStored[_user]);
    }

    function getAddressListLength() external view override returns (uint256) {
        return addressList.length;
    }

    function _getMultiplier(
        uint256 _from,
        uint256 _to
    ) internal view returns (uint256) {
        if (_to <= endTime) {
            return _to.sub(_from);
        } else if (_from >= endTime) {
            return 0;
        } else {
            return endTime.sub(_from);
        }
    }

    function _updatePool() private {
        if (block.timestamp <= lastRewardTimestamp) {
            return;
        }

        uint256 stakedTokenSupply = totalAmount;

        if (stakedTokenSupply == 0) {
            lastRewardTimestamp = block.timestamp;
            return;
        }

        uint256 multiplier = _getMultiplier(
            lastRewardTimestamp,
            block.timestamp
        );

        uint256 rewardTokenReward = multiplier.mul(rewardPerSecond);
        uint256 _accTokenPerShare = rewardTokenReward.mul(1e18).div(
            stakedTokenSupply
        );
        accTokenPerShare = accTokenPerShare.add(_accTokenPerShare);
        lastRewardTimestamp = block.timestamp;
    }

    function _safeTransferETH(address to, uint256 value) private {
        (bool success, ) = to.call{value: value}(new bytes(0));
        require(success, "!safeTransferETH");
    }
}
