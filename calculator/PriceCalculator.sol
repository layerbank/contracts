// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "../library/HomoraMath.sol";
import "../interfaces/AggregatorV3Interface.sol";
import "../interfaces/IBEP20.sol";
import "../interfaces/IPriceCalculator.sol";
import "../interfaces/ILToken.sol";

contract PriceCalculator is IPriceCalculator, Ownable {
    using SafeMath for uint256;
    using HomoraMath for uint256;

    // Min price setting interval
    address internal constant ETH = 0x0000000000000000000000000000000000000000;
    uint256 private constant THRESHOLD = 5 minutes;

    /* ========== STATE VARIABLES ========== */

    address public keeper;
    mapping(address => ReferenceData) public references;
    mapping(address => address) private tokenFeeds;

    /* ========== MODIFIERS ========== */

    /// @dev `msg.sender` 가 keeper 또는 owner 인지 검증
    modifier onlyKeeper() {
        require(msg.sender == keeper || msg.sender == owner(), "PriceCalculator: caller is not the owner or keeper");
        _;
    }

    /* ========== INITIALIZER ========== */

    constructor() public {}

    /* ========== RESTRICTED FUNCTIONS ========== */

    /// @notice Keeper address 변경
    /// @dev Keeper address 에서만 요청 가능
    /// @param _keeper New keeper address
    function setKeeper(address _keeper) external onlyKeeper {
        require(_keeper != address(0), "PriceCalculator: invalid keeper address");
        keeper = _keeper;
    }

    /// @notice Chainlink oracle feed 설정
    /// @param asset Asset address to be used as a key
    /// @param feed Chainlink oracle feed contract address
    function setTokenFeed(address asset, address feed) external onlyKeeper {
        tokenFeeds[asset] = feed;
    }

    /// @notice Set price by keeper
    /// @dev Keeper address 에서만 요청 가능
    /// @param assets Array of asset addresses to set
    /// @param prices Array of asset prices to set
    /// @param timestamp Timstamp of price information
    function setPrices(address[] memory assets, uint256[] memory prices, uint256 timestamp) external onlyKeeper {
        require(
            timestamp <= block.timestamp && block.timestamp.sub(timestamp) <= THRESHOLD,
            "PriceCalculator: invalid timestamp"
        );

        for (uint256 i = 0; i < assets.length; i++) {
            references[assets[i]] = ReferenceData({lastData: prices[i], lastUpdated: block.timestamp});
        }
    }

    /* ========== VIEWS ========== */

    function priceOf(address asset) public view override returns (uint256 priceInUSD) {
        if (asset == address(0)) {
            return priceOfETH();
        }
        uint256 decimals = uint256(IBEP20(asset).decimals());
        uint256 unitAmount = 10 ** decimals;
        return _oracleValueInUSDOf(asset, unitAmount, decimals);
    }

    function pricesOf(address[] memory assets) public view override returns (uint256[] memory) {
        uint256[] memory prices = new uint256[](assets.length);
        for (uint256 i = 0; i < assets.length; i++) {
            prices[i] = priceOf(assets[i]);
        }
        return prices;
    }

    function getUnderlyingPrice(address lToken) public view override returns (uint256) {
        return priceOf(ILToken(lToken).underlying());
    }

    function getUnderlyingPrices(address[] memory lTokens) public view override returns (uint256[] memory) {
        uint256[] memory prices = new uint256[](lTokens.length);
        for (uint256 i = 0; i < lTokens.length; i++) {
            prices[i] = priceOf(ILToken(lTokens[i]).underlying());
        }
        return prices;
    }

    function priceOfETH() public view override returns (uint256 valueInUSD) {
        valueInUSD = 0;
        if (tokenFeeds[ETH] != address(0)) {
            (, int256 price, , , ) = AggregatorV3Interface(tokenFeeds[ETH]).latestRoundData();
            return uint256(price).mul(1e10);
        } else if (references[ETH].lastUpdated > block.timestamp.sub(1 days)) {
            return references[ETH].lastData;
        } else {
            revert("PriceCalculator: invalid oracle value");
        }
    }

    /* ========== PRIVATE FUNCTIONS ========== */

    function _oracleValueInUSDOf(
        address asset,
        uint256 amount,
        uint256 decimals
    ) private view returns (uint256 valueInUSD) {
        valueInUSD = 0;
        uint256 assetDecimals = asset == address(0) ? 1e18 : 10 ** decimals;
        if (tokenFeeds[asset] != address(0)) {
            (, int256 price, , , ) = AggregatorV3Interface(tokenFeeds[asset]).latestRoundData();
            valueInUSD = uint256(price).mul(1e10).mul(amount).div(assetDecimals);
        } else if (references[asset].lastUpdated > block.timestamp.sub(1 days)) {
            valueInUSD = references[asset].lastData.mul(amount).div(assetDecimals);
        } else {
            revert("PriceCalculator: invalid oracle value");
        }
    }
}
