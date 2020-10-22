// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import {BaseStrategy, StrategyParams} from "@yearnvaultsV2/contracts/BaseStrategy.sol";
import "@openzeppelinV3/contracts/token/ERC20/IERC20.sol";
import "@openzeppelinV3/contracts/math/SafeMath.sol";
import "@openzeppelinV3/contracts/utils/Address.sol";
import "@openzeppelinV3/contracts/token/ERC20/SafeERC20.sol";

import "../../interfaces/cream/Controller.sol";
import "../../interfaces/compound/cToken.sol";
import "../../interfaces/uniswap/Uni.sol";

import "../../interfaces/yearn/IController.sol";

/*
 * Strategy For CRV using Cream Finance
 */

contract StrategyCreamCRV is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    // want is CRV

    Creamtroller public constant creamtroller = Creamtroller(0x3d5BC3c8d13dcB8bF317092d84783c2697AE9258);

    address public constant crCRV = address(0xc7Fd8Dcee4697ceef5a2fd4608a7BD6A94C77480);
    address public constant cream = address(0x2ba592F78dB6436527729929AAf6c908497cB200);

    address public constant uni = address(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);
    address public constant weth = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2); // used for cream <> weth <> crv route

    uint256 public performanceFee = 500;
    uint256 public constant performanceMax = 10000;

    uint256 public withdrawalFee = 50;
    uint256 public constant withdrawalMax = 10000;

    constructor(address _vault) public BaseStrategy(_vault) {}

    // ******** OVERRIDE METHODS FROM BASE CONTRACT ********************
    function expectedReturn() public override view returns (uint256) {
        // TODO: what should this be the value to return in expectedReturn for this strat?
        return balanceOf();
    }

    function adjustPosition() internal override {
        uint256 _want = IERC20(want).balanceOf(address(this));
        if (_want > 0) {
            IERC20(want).safeApprove(crCRV, 0);
            IERC20(want).safeApprove(crCRV, _want);
            cToken(crCRV).mint(_want);
        }
    }

    function harvestTrigger(uint256 gasCost) public override view returns (bool) {
        gasCost; // Shh
        if (vault.creditAvailable() > 0) {
            return true;
        }

        return false;
    }

    function estimatedTotalAssets() public override view returns (uint256) {
        return balanceOf();
    }

    function exitPosition() internal override {
        _withdrawAll();
    }

    function prepareReturn() internal override {
        // Note: in case of CREAM liquidity mining
        Creamtroller(creamtroller).claimComp(address(this));
        // NOTE: in case of CREAM liquidity mining
        uint256 _cream = IERC20(cream).balanceOf(address(this));
        if (_cream > 0) {
            IERC20(cream).safeApprove(uni, 0);
            IERC20(cream).safeApprove(uni, _cream);

            address[] memory path = new address[](3);
            path[0] = cream;
            path[1] = weth;
            // NOTE: need to cast it since BaseStrategy wraps IERC20 interface
            path[2] = address(want);

            Uni(uni).swapExactTokensForTokens(_cream, uint256(0), path, address(this), now.add(1800));
        }
    }

    function tendTrigger(uint256 gasCost) public override view returns (bool) {
        // NOTE: this strategy does not need tending

        gasCost; // Shh

        return false;
    }

    function liquidatePosition(uint256 _amount) internal override {
        _withdrawSome(_amount);
    }

    function prepareMigration(address _newStrategy) internal override {
        exitPosition();
        want.transfer(_newStrategy, want.balanceOf(address(this)));
    }

    // ******* HELPER METHODS *********

    function _withdrawC(uint256 amount) internal {
        // 0=success else fails with error code
        require(cToken(crCRV).redeem(amount) == 0, "cToken redeem failed!");
    }

    function _withdrawAll() internal {
        uint256 amount = balanceC();
        if (amount > 0) {
            _withdrawSome(balanceCInToken().sub(1));
        }
    }

    function _withdrawSome(uint256 _amount) internal returns (uint256) {
        uint256 b = balanceC();
        uint256 bT = balanceCInToken();
        // can have unintentional rounding errors
        uint256 amount = (b.mul(_amount)).div(bT).add(1);
        uint256 _before = IERC20(want).balanceOf(address(this));
        _withdrawC(amount);
        uint256 _after = IERC20(want).balanceOf(address(this));
        uint256 _withdrew = _after.sub(_before);
        return _withdrew;
    }

    // ******** BALANCE METHODS ********************
    function balanceCInToken() public view returns (uint256) {
        // Mantisa 1e18 to decimals
        uint256 b = balanceC();
        if (b > 0) {
            b = b.mul(cToken(crCRV).exchangeRateStored()).div(1e18);
        }
        return b;
    }

    function balanceC() public view returns (uint256) {
        return IERC20(crCRV).balanceOf(address(this));
    }

    function balanceOf() public view returns (uint256) {
        return balanceOfWant().add(balanceCInToken());
    }

    function balanceOfWant() public view returns (uint256) {
        return IERC20(want).balanceOf(address(this));
    }
}
