// SPDX-License-Identifier: UNLICENSE
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

import "./library/Constant.sol";

import "./interfaces/ICore.sol";
import "./interfaces/ILABDistributor.sol";
import "./interfaces/IPriceCalculator.sol";
import "./interfaces/ILToken.sol";
import "./interfaces/IRebateDistributor.sol";

abstract contract CoreAdmin is ICore, Ownable, ReentrancyGuard, Pausable {
    /* ========== STATE VARIABLES ========== */

    address public keeper;
    address public leverager;
    address public override validator;
    address public override rebateDistributor;
    ILABDistributor public labDistributor;
    IPriceCalculator public priceCalculator;

    address[] public markets; // lTokenAddress[]
    mapping(address => Constant.MarketInfo) public marketInfos; // (lTokenAddress => MarketInfo)

    uint256 public override closeFactor;
    uint256 public override liquidationIncentive;

    /* ========== MODIFIERS ========== */

    modifier onlyKeeper() {
        require(msg.sender == keeper || msg.sender == owner(), "Core: caller is not the owner or keeper");
        _;
    }

    modifier onlyListedMarket(address lToken) {
        require(marketInfos[lToken].isListed, "Core: invalid market");
        _;
    }

    /* ========== INITIALIZER ========== */

    function __Core_init() internal {
        closeFactor = 5e17; // 0.5
        liquidationIncentive = 115e16; // 1.15
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function setPriceCalculator(address _priceCalculator) external onlyKeeper {
        require(_priceCalculator != address(0), "Core: invalid calculator address");
        priceCalculator = IPriceCalculator(_priceCalculator);
    }

    /// @notice keeper address 변경
    /// @dev keeper address 에서만 요청 가능
    /// @param _keeper 새로운 keeper address
    function setKeeper(address _keeper) external onlyKeeper {
        require(_keeper != address(0), "Core: invalid keeper address");
        keeper = _keeper;
        emit KeeperUpdated(_keeper);
    }

    /// @notice validator 변경
    /// @dev keeper address 에서만 요청 가능
    /// @param _validator 새로운 validator address
    function setValidator(address _validator) external onlyKeeper {
        require(_validator != address(0), "Core: invalid validator address");
        validator = _validator;
        emit ValidatorUpdated(_validator);
    }

    /// @notice labDistributor 변경
    /// @dev keeper address 에서만 요청 가능
    /// @param _labDistributor 새로운 labDistributor address
    function setLABDistributor(address _labDistributor) external onlyKeeper {
        require(_labDistributor != address(0), "Core: invalid labDistributor address");
        labDistributor = ILABDistributor(_labDistributor);
        emit LABDistributorUpdated(_labDistributor);
    }

    function setRebateDistributor(address _rebateDistributor) external onlyKeeper {
        require(_rebateDistributor != address(0), "Core: invalid rebateDistributor address");
        rebateDistributor = _rebateDistributor;
        emit RebateDistributorUpdated(_rebateDistributor);
    }

    function setLeverager(address _leverager) external onlyKeeper {
        require(_leverager != address(0), "Core: invalid leverager address");
        leverager = _leverager;
        emit LeveragerUpdated(_leverager);
    }

    /// @notice close factor 변경
    /// @dev keeper address 에서만 요청 가능
    /// @param newCloseFactor 새로운 close factor 값 (TBD)
    function setCloseFactor(uint256 newCloseFactor) external onlyKeeper {
        require(
            newCloseFactor >= Constant.CLOSE_FACTOR_MIN && newCloseFactor <= Constant.CLOSE_FACTOR_MAX,
            "Core: invalid close factor"
        );
        closeFactor = newCloseFactor;
        emit CloseFactorUpdated(newCloseFactor);
    }

    function setCollateralFactor(
        address lToken,
        uint256 newCollateralFactor
    ) external onlyKeeper onlyListedMarket(lToken) {
        require(newCollateralFactor <= Constant.COLLATERAL_FACTOR_MAX, "Core: invalid collateral factor");
        if (newCollateralFactor != 0 && priceCalculator.getUnderlyingPrice(lToken) == 0) {
            revert("Core: invalid underlying price");
        }

        marketInfos[lToken].collateralFactor = newCollateralFactor;
        emit CollateralFactorUpdated(lToken, newCollateralFactor);
    }

    function setLiquidationIncentive(uint256 newLiquidationIncentive) external onlyKeeper {
        liquidationIncentive = newLiquidationIncentive;
        emit LiquidationIncentiveUpdated(newLiquidationIncentive);
    }

    function setMarketSupplyCaps(address[] calldata lTokens, uint256[] calldata newSupplyCaps) external onlyKeeper {
        require(lTokens.length != 0 && lTokens.length == newSupplyCaps.length, "Core: invalid data");

        for (uint256 i = 0; i < lTokens.length; i++) {
            marketInfos[lTokens[i]].supplyCap = newSupplyCaps[i];
            emit SupplyCapUpdated(lTokens[i], newSupplyCaps[i]);
        }
    }

    function setMarketBorrowCaps(address[] calldata lTokens, uint256[] calldata newBorrowCaps) external onlyKeeper {
        require(lTokens.length != 0 && lTokens.length == newBorrowCaps.length, "Core: invalid data");

        for (uint256 i = 0; i < lTokens.length; i++) {
            marketInfos[lTokens[i]].borrowCap = newBorrowCaps[i];
            emit BorrowCapUpdated(lTokens[i], newBorrowCaps[i]);
        }
    }

    function listMarket(
        address payable lToken,
        uint256 supplyCap,
        uint256 borrowCap,
        uint256 collateralFactor
    ) external onlyKeeper {
        require(!marketInfos[lToken].isListed, "Core: already listed market");
        for (uint256 i = 0; i < markets.length; i++) {
            require(markets[i] != lToken, "Core: already listed market");
        }

        marketInfos[lToken] = Constant.MarketInfo({
            isListed: true,
            supplyCap: supplyCap,
            borrowCap: borrowCap,
            collateralFactor: collateralFactor
        });
        markets.push(lToken);
        emit MarketListed(lToken);
    }

    function removeMarket(address payable lToken) external onlyKeeper {
        require(marketInfos[lToken].isListed, "Core: unlisted market");
        require(ILToken(lToken).totalSupply() == 0 && ILToken(lToken).totalBorrow() == 0, "Core: cannot remove market");

        uint256 length = markets.length;
        for (uint256 i = 0; i < length; i++) {
            if (markets[i] == lToken) {
                markets[i] = markets[length - 1];
                markets.pop();
                delete marketInfos[lToken];
                break;
            }
        }
    }

    function claimLabBehalf(address[] calldata accounts) external onlyKeeper nonReentrant {
        labDistributor.claimBehalf(markets, accounts);
    }

    function pause() external onlyKeeper {
        _pause();
    }

    function unpause() external onlyKeeper {
        _unpause();
    }
}
