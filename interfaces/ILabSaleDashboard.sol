// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

interface ISbSaleDashboard {
    struct WhitelistSaleData {
        uint256 capEndTime;
        uint256 perCommitmentCap;
        uint256 whaleCommitmentCap;
        uint256 minimumCommitmentCap;
        uint256 commitmentCap;
        uint256 commitmentsTotal;
        uint256 commitmentAmount;
        uint256 receiveAmount;
        uint256 exchangeRate;
        uint256 tokenPrice;
        uint256 launchPrice;
        uint256 startDate;
        uint256 endDate;
        uint256 totalTokens;
        uint256 currentTimestamp;
        bool finalized;
        bool isWhale;
        bool isWhitelist;
        bool isLimitCommitPeriod;
        bool saleStarted;
        bool saleEnded;
    }

    struct PublicSaleData {
        uint256 commitmentCap;
        uint256 minimumCommitmentCap;
        uint256 commitmentsTotal;
        uint256 commitmentAmount;
        uint256 receiveAmount;
        uint256 exchangeRate;
        uint256 tokenPrice;
        uint256 launchPrice;
        uint256 startDate;
        uint256 endDate;
        uint256 totalTokens;
        uint256 currentTimestamp;
        bool finalized;
        bool saleStarted;
        bool saleEnded;
    }

    struct VestingData {
        uint256 totalPurchaseAmount;
        uint256 commitmentAmount;
        uint256 claimedAmount;
        uint256 claimableAmount;
        uint256 lockedAmount;
        uint256 lockableAmount;
        uint256 unlockTime;
        bool isUnlockToken;
    }

    function getWlSaleInfo(address _user) external view returns (WhitelistSaleData memory);
    function getPublicSaleInfo(address _user) external view returns (PublicSaleData memory);

    function getWlVestingInfo(address _user) external view returns (VestingData memory);
    function getPublicVestingInfo(address _user) external view returns (VestingData memory);

    function receiveWlSbAmount(uint256 _amount) external view returns (uint256);
    function receivePublicSbAmount(uint256 _amount) external view returns (uint256);
}
