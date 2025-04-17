// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.6.12;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

import "../interfaces/IRewardDistributor.sol";
import "../interfaces/IBEP20.sol";

import "../library/SafeToken.sol";

contract RewardDistributor is IRewardDistributor, Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeToken for address;

    /* ========== STATE VARIABLES ========== */

    mapping(address => uint256) public claimed;
    mapping(address => uint256) public userReward;

    address public paymentToken;

    // initializer
    bool public initialized;

    constructor() public {}

    function initialize(address _paymentToken) external onlyOwner {
        require(initialized == false, "already initialized");

        paymentToken = _paymentToken;

        initialized = true;
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function emergencyWithdraw() external onlyOwner {
        uint256 tokenBalance = IBEP20(paymentToken).balanceOf(address(this));
        paymentToken.safeTransfer(msg.sender, tokenBalance);
    }

    function setUserReward(address[] calldata _users, uint256[] calldata _reward) external onlyOwner {
        require(_users.length == _reward.length, "RewardDistributor: invalid reward length");
        for (uint256 i = 0; i < _users.length; i++) {
            userReward[_users[i]] = _reward[i];
        }
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function withdrawTokens() external override nonReentrant {
        uint256 _tokensToClaim = tokensClaimable(msg.sender);
        require(_tokensToClaim > 0, "RewardDistributor: No tokens to claim");

        claimed[msg.sender] = claimed[msg.sender].add(_tokensToClaim);

        paymentToken.safeTransfer(msg.sender, _tokensToClaim);
    }

    /* ========== VIEWS ========== */

    function tokensClaimable(address _user) public view override returns (uint256 claimableAmount) {
        if (userReward[_user] == 0) {
            return 0;
        }
        uint256 unclaimedTokens = IBEP20(paymentToken).balanceOf(address(this));
        claimableAmount = userReward[_user];
        claimableAmount = claimableAmount.sub(claimed[_user]);

        if (claimableAmount > unclaimedTokens) {
            claimableAmount = unclaimedTokens;
        }
    }
}
