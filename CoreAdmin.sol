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
    address public override nftCore;
    address public override validator;
    address public override rebateDistributor;
    ILABDistributor public labDistributor;
    IPriceCalculator public priceCalculator;

    address[] public markets;
    mapping(address => Constant.MarketInfo) public marketInfos;

    uint256 public override closeFactor;
    uint256 public override liquidationIncentive;

    /* ========== MODIFIERS ========== */

    modifier onlyKeeper() {
        require(
            msg.sender == keeper || msg.sender == owner(),
            "Core: caller is not the owner or keeper"
        );
        _;
    }

    modifier onlyListedMarket(address gToken) {
        require(marketInfos[gToken].isListed, "Core: invalid market");
        _;
    }

    modifier onlyNftCore() {
        require(msg.sender == nftCore, "Core: caller is not the nft core");
        _;
    }

    /* ========== INITIALIZER ========== */

    function __Core_init() internal {
        closeFactor = 5e17;
        liquidationIncentive = 115e16;
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function setPriceCalculator(address _priceCalculator) external onlyKeeper {
        require(
            _priceCalculator != address(0),
            "Core: invalid calculator address"
        );
        priceCalculator = IPriceCalculator(_priceCalculator);
    }

    function setKeeper(address _keeper) external onlyKeeper {
        require(_keeper != address(0), "Core: invalid keeper address");
        keeper = _keeper;
        emit KeeperUpdated(_keeper);
    }

    function setNftCore(address _nftCore) external onlyKeeper {
        require(_nftCore != address(0), "Core: invalid nft core address");
        nftCore = _nftCore;
        emit NftCoreUpdated(_nftCore);
    }

    function setValidator(address _validator) external onlyKeeper {
        require(_validator != address(0), "Core: invalid validator address");
        validator = _validator;
        emit ValidatorUpdated(_validator);
    }

    function setLABDistributor(address _labDistributor) external onlyKeeper {
        require(
            _labDistributor != address(0),
            "Core: invalid labDistributor address"
        );
        labDistributor = ILABDistributor(_labDistributor);
        emit LABDistributorUpdated(_labDistributor);
    }

    function setRebateDistributor(
        address _rebateDistributor
    ) external onlyKeeper {
        require(
            _rebateDistributor != address(0),
            "Core: invalid rebateDistributor address"
        );
        rebateDistributor = _rebateDistributor;
        emit RebateDistributorUpdated(_rebateDistributor);
    }

    function setCloseFactor(uint256 newCloseFactor) external onlyKeeper {
        require(
            newCloseFactor >= Constant.CLOSE_FACTOR_MIN &&
                newCloseFactor <= Constant.CLOSE_FACTOR_MAX,
            "Core: invalid close factor"
        );
        closeFactor = newCloseFactor;
        emit CloseFactorUpdated(newCloseFactor);
    }

    function setCollateralFactor(
        address gToken,
        uint256 newCollateralFactor
    ) external onlyKeeper onlyListedMarket(gToken) {
        require(
            newCollateralFactor <= Constant.COLLATERAL_FACTOR_MAX,
            "Core: invalid collateral factor"
        );
        if (
            newCollateralFactor != 0 &&
            priceCalculator.getUnderlyingPrice(gToken) == 0
        ) {
            revert("Core: invalid underlying price");
        }

        marketInfos[gToken].collateralFactor = newCollateralFactor;
        emit CollateralFactorUpdated(gToken, newCollateralFactor);
    }

    function setLiquidationIncentive(
        uint256 newLiquidationIncentive
    ) external onlyKeeper {
        liquidationIncentive = newLiquidationIncentive;
        emit LiquidationIncentiveUpdated(newLiquidationIncentive);
    }

    function setMarketSupplyCaps(
        address[] calldata gTokens,
        uint256[] calldata newSupplyCaps
    ) external onlyKeeper {
        require(
            gTokens.length != 0 && gTokens.length == newSupplyCaps.length,
            "Core: invalid data"
        );

        for (uint256 i = 0; i < gTokens.length; i++) {
            marketInfos[gTokens[i]].supplyCap = newSupplyCaps[i];
            emit SupplyCapUpdated(gTokens[i], newSupplyCaps[i]);
        }
    }

    function setMarketBorrowCaps(
        address[] calldata gTokens,
        uint256[] calldata newBorrowCaps
    ) external onlyKeeper {
        require(
            gTokens.length != 0 && gTokens.length == newBorrowCaps.length,
            "Core: invalid data"
        );

        for (uint256 i = 0; i < gTokens.length; i++) {
            marketInfos[gTokens[i]].borrowCap = newBorrowCaps[i];
            emit BorrowCapUpdated(gTokens[i], newBorrowCaps[i]);
        }
    }

    function listMarket(
        address payable gToken,
        uint256 supplyCap,
        uint256 borrowCap,
        uint256 collateralFactor
    ) external onlyKeeper {
        require(!marketInfos[gToken].isListed, "Core: already listed market");
        for (uint256 i = 0; i < markets.length; i++) {
            require(markets[i] != gToken, "Core: already listed market");
        }

        marketInfos[gToken] = Constant.MarketInfo({
            isListed: true,
            supplyCap: supplyCap,
            borrowCap: borrowCap,
            collateralFactor: collateralFactor
        });
        markets.push(gToken);
        emit MarketListed(gToken);
    }

    function removeMarket(address payable gToken) external onlyKeeper {
        require(marketInfos[gToken].isListed, "Core: unlisted market");
        require(
            ILToken(gToken).totalSupply() == 0 &&
                ILToken(gToken).totalBorrow() == 0,
            "Core: cannot remove market"
        );

        uint256 length = markets.length;
        for (uint256 i = 0; i < length; i++) {
            if (markets[i] == gToken) {
                markets[i] = markets[length - 1];
                markets.pop();
                delete marketInfos[gToken];
                break;
            }
        }
    }

    function pause() external onlyKeeper {
        _pause();
    }

    function unpause() external onlyKeeper {
        _unpause();
    }
}
