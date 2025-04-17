// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

interface ISbSale {
    struct MarketInfo {
        uint256 startTime;
        uint256 endTime;
        uint256 totalTokens;
        uint256 commitmentCap;
    }

    struct MarketStatus {
        uint256 commitmentsTotal;
        bool finalized;
    }

    event SaleTokenDeposited(uint256 amount);
    event SaleFinalized();
    event SaleCancelled();
    event SaleStarted();
    event SaleTreasuryUpdated(address treasury);
    event TokenPriceUpdated(uint _tokenPrice);

    event AddedCommitment(address addr, uint256 commitment, address referral);

    function MINIMUM_COMMIT_ETH() external view returns (uint256);

    function marketStatus() external view returns (uint256, bool);
    function marketInfo() external view returns (uint256, uint256, uint256, uint256);

    function saleToken() external view returns (address);
    function tokenPrice() external view returns (uint256);

    function commitments(address user) external view returns (uint256);
    function claimed(address user) external view returns (uint256);
    function locked(address user) external view returns (uint256);

    function limitCommitPeriod() external view returns (bool);
    function saleStarted() external view returns (bool);
    function saleEnded() external view returns (bool);
    function tokensClaimable(address _user) external view returns (uint256 claimerCommitment);
    function tokensLockable(address _user) external view returns (uint256 claimerCommitment);
    function unlockTime() external view returns (uint256);

    function getTotalTokens() external view returns (uint256);
    function getBaseInformation() external view returns (uint256 startTime, uint256 endTime, bool marketFinalized);

    function finalized() external view returns (bool);

    function commitETH(address _referral) external payable;
    function withdrawTokens() external;
    function withdrawLockedTokens() external;
}
