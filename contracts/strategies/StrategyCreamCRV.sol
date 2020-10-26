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

interface Uniswap {
    function getAmountsOut(uint256 amountIn, address[] memory path) external view returns (uint256[] memory amounts);
}

interface UniswapPair {
    function token0() external view returns (address);

    function token1() external view returns (address);

    function getReserves()
        external
        view
        returns (
            uint112 reserve0,
            uint112 reserve1,
            uint32 blockTimestampLast
        );
}

/*
 * Strategy For CRV using Cream Finance
 */

contract StrategyCreamCRV is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    string public constant name = "StrategyCreamCRV";

    // want is CRV
    address public constant CRV = address(0xD533a949740bb3306d119CC777fa900bA034cd52);

    Creamtroller public constant creamtroller = Creamtroller(0x3d5BC3c8d13dcB8bF317092d84783c2697AE9258);

    address public constant crCRV = address(0xc7Fd8Dcee4697ceef5a2fd4608a7BD6A94C77480);
    address public constant cream = address(0x2ba592F78dB6436527729929AAf6c908497cB200);

    address public constant uni = address(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);
    address public constant weth = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2); // used for cream <> weth <> crv route

    uint256 public gasFactor = 10;

    constructor(address _vault) public BaseStrategy(_vault) {
        //only accept CRV vault
        require(vault.token() == CRV, "!NOT_CRV");
    }

    // ******** OVERRIDE METHODS FROM BASE CONTRACT ********************
    function expectedReturn() public override view returns (uint256) {
        //expected return = expected total assets (Total supplied CREAM + some want) - core postion (totalDebt)
        StrategyParams memory params = vault.strategies(address(this));

        return estimatedTotalAssets() - params.totalDebt;
    }

    // NOTE: deposit any outstanding want token into CREAM
    function adjustPosition() internal override {
        uint256 _want = IERC20(want).balanceOf(address(this));
        if (_want > 0) {
            IERC20(want).safeApprove(crCRV, 0);
            IERC20(want).safeApprove(crCRV, _want);
            cToken(crCRV).mint(_want);
        }
    }

    function harvestTrigger(uint256 gasCost) public override view returns (bool) {
        // NOTE: if the vault has creditAvailable we can pull funds in harvest
        uint256 _credit = vault.creditAvailable();
        if (_credit > 0) {
            uint256 _creditAvailable = quote(address(want), weth, _credit);
            // ethvalue of credit available is  greater than gas Cost * gas factor
            if (_creditAvailable > gasCost.mul(gasFactor)) {
                return true;
            }
        }
        uint256 _debtOutstanding = vault.debtOutstanding();
        if (_debtOutstanding > 0) {
            return true;
        }

        return false;
    }

    function estimatedTotalAssets() public override view returns (uint256) {
        return IERC20(want).balanceOf(address(this)).add(_balanceCInToken());
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

        uint256 _expectedReturnFromCream = expectedReturn();
        if (_expectedReturnFromCream > 0) {
            // realize profits from cream
            liquidatePosition(_expectedReturnFromCream);
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

    function quote(
        address token_in,
        address token_out,
        uint256 amount_in
    ) public view returns (uint256) {
        bool is_weth = token_in == weth || token_out == weth;
        address[] memory path = new address[](is_weth ? 2 : 3);
        path[0] = token_in;
        if (is_weth) {
            path[1] = token_out;
        } else {
            path[1] = weth;
            path[2] = token_out;
        }
        uint256[] memory amounts = Uniswap(uni).getAmountsOut(amount_in, path);
        return amounts[amounts.length - 1];
    }

    function setGasFactor(uint256 _gasFactor) external {
        require(msg.sender == strategist || msg.sender == governance(), "!governance");
        gasFactor = _gasFactor;
    }

    function _withdrawAll() internal {
        uint256 amount = _balanceC();
        if (amount > 0) {
            _withdrawSome(_balanceCInToken().sub(1));
        }
    }

    function _withdrawSome(uint256 _amount) internal returns (uint256) {
        uint256 b = _balanceC();
        uint256 bT = _balanceCInToken();
        // can have unintentional rounding errors
        uint256 amount = (b.mul(_amount)).div(bT).add(1);
        uint256 _before = IERC20(want).balanceOf(address(this));
        // 0=success else fails with error code
        require(cToken(crCRV).redeem(amount) == 0, "cToken redeem failed!");
        uint256 _after = IERC20(want).balanceOf(address(this));
        uint256 _withdrew = _after.sub(_before);
        return _withdrew;
    }

    // ******** BALANCE METHODS ********************
    function _balanceCInToken() internal view returns (uint256) {
        // Mantisa 1e18 to decimals
        uint256 b = _balanceC();
        if (b > 0) {
            b = b.mul(cToken(crCRV).exchangeRateStored()).div(1e18);
        }
        return b;
    }

    function _balanceC() internal view returns (uint256) {
        return IERC20(crCRV).balanceOf(address(this));
    }
}
