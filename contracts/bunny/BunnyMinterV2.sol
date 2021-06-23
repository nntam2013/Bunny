// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

/*
  ___                      _   _
 | _ )_  _ _ _  _ _ _  _  | | | |
 | _ \ || | ' \| ' \ || | |_| |_|
 |___/\_,_|_||_|_||_\_, | (_) (_)
                    |__/

*
* MIT License
* ===========
*
* Copyright (c) 2020 BunnyFinance
*
* Permission is hereby granted, free of charge, to any person obtaining a copy
* of this software and associated documentation files (the "Software"), to deal
* in the Software without restriction, including without limitation the rights
* to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
* copies of the Software, and to permit persons to whom the Software is
* furnished to do so, subject to the following conditions:
*
* The above copyright notice and this permission notice shall be included in all
* copies or substantial portions of the Software.
*
* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
* IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
* FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
* AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
* LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
* OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
*/

import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/BEP20.sol";
import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/SafeBEP20.sol";
import "@pancakeswap/pancake-swap-lib/contracts/math/SafeMath.sol";

import "../interfaces/IBunnyMinterV2.sol";
import "../interfaces/IStakingRewards.sol";
import "../interfaces/IPriceCalculator.sol";

import "../zap/ZapBSC.sol";
import "../library/SafeToken.sol";

contract BunnyMinterV2 is IBunnyMinterV2, OwnableUpgradeable {
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;

    /* ========== CONSTANTS ============= */

    address public constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address public constant BUNNY = 0xC9849E6fdB743d08fAeE3E34dd2D1bc69EA11a51;
    address public constant BUNNY_POOL =
        0xCADc8CB26c8C7cB46500E61171b5F27e9bd7889D;

    address public constant TREASURY =
        0x0989091F27708Bc92ea4cA60073e03592B94C0eE;
    address private constant TIMELOCK =
        0x85c9162A51E03078bdCd08D4232Bab13ed414cC3;
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;

    uint256 public constant FEE_MAX = 10000;

    IPriceCalculator public constant priceCalculator =
        IPriceCalculator(0xF5BF8A9249e3cc4cB684E3f23db9669323d4FB7d);
    ZapBSC private constant zap =
        ZapBSC(0xdC2bBB0D33E0e7Dea9F5b98F46EDBaC823586a0C);
    IPancakeRouter02 private constant router =
        IPancakeRouter02(0x10ED43C718714eb63d5aA57B78B54704E256024E);

    /* ========== STATE VARIABLES ========== */

    address public bunnyChef;
    mapping(address => bool) private _minters;
    address public _deprecated_helper; // deprecated

    uint256 public PERFORMANCE_FEE;
    uint256 public override WITHDRAWAL_FEE_FREE_PERIOD;
    uint256 public override WITHDRAWAL_FEE;

    uint256 public _deprecated_bunnyPerProfitBNB; // deprecated
    uint256 public _deprecated_bunnyPerBunnyBNBFlip; // deprecated

    uint256 private _floatingRateEmission;
    uint256 private _freThreshold;

    /* ========== MODIFIERS ========== */

    modifier onlyMinter {
        require(
            isMinter(msg.sender) == true,
            "BunnyMinterV2: caller is not the minter"
        );
        _;
    }

    modifier onlyBunnyChef {
        require(
            msg.sender == bunnyChef,
            "BunnyMinterV2: caller not the bunny chef"
        );
        _;
    }

    receive() external payable {}

    /* ========== INITIALIZER ========== */

    function initialize() external initializer {
        WITHDRAWAL_FEE_FREE_PERIOD = 3 days;
        WITHDRAWAL_FEE = 50;
        PERFORMANCE_FEE = 3000;

        _deprecated_bunnyPerProfitBNB = 5e18;
        _deprecated_bunnyPerBunnyBNBFlip = 6e18;

        IBEP20(BUNNY).approve(BUNNY_POOL, uint256(-1));
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function transferBunnyOwner(address _owner) external onlyOwner {
        Ownable(BUNNY).transferOwnership(_owner);
    }

    function setWithdrawalFee(uint256 _fee) external onlyOwner {
        require(_fee < 500, "wrong fee");
        // less 5%
        WITHDRAWAL_FEE = _fee;
    }

    function setPerformanceFee(uint256 _fee) external onlyOwner {
        require(_fee < 5000, "wrong fee");
        PERFORMANCE_FEE = _fee;
    }

    function setWithdrawalFeeFreePeriod(uint256 _period) external onlyOwner {
        WITHDRAWAL_FEE_FREE_PERIOD = _period;
    }

    function setMinter(address minter, bool canMint)
        external
        override
        onlyOwner
    {
        if (canMint) {
            _minters[minter] = canMint;
        } else {
            delete _minters[minter];
        }
    }

    function setBunnyChef(address _bunnyChef) external onlyOwner {
        require(
            bunnyChef == address(0),
            "BunnyMinterV2: setBunnyChef only once"
        );
        bunnyChef = _bunnyChef;
    }

    function setFloatingRateEmission(uint256 floatingRateEmission)
        external
        onlyOwner
    {
        require(
            floatingRateEmission > 1e18 && floatingRateEmission < 10e18,
            "BunnyMinterV2: floatingRateEmission wrong range"
        );
        _floatingRateEmission = floatingRateEmission;
    }

    function setFREThreshold(uint256 threshold) external onlyOwner {
        _freThreshold = threshold;
    }

    /* ========== VIEWS ========== */

    function isMinter(address account) public view override returns (bool) {
        if (IBEP20(BUNNY).getOwner() != address(this)) {
            return false;
        }
        return _minters[account];
    }

    function amountBunnyToMint(uint256 bnbProfit)
        public
        view
        override
        returns (uint256)
    {
        return
            bnbProfit
                .mul(priceCalculator.priceOfBNB())
                .div(priceCalculator.priceOfBunny())
                .mul(floatingRateEmission())
                .div(1e18);
    }

    function amountBunnyToMintForBunnyBNB(uint256 amount, uint256 duration)
        public
        view
        override
        returns (uint256)
    {
        return
            amount
                .mul(_deprecated_bunnyPerBunnyBNBFlip)
                .mul(duration)
                .div(365 days)
                .div(1e18);
    }

    function withdrawalFee(uint256 amount, uint256 depositedAt)
        external
        view
        override
        returns (uint256)
    {
        if (depositedAt.add(WITHDRAWAL_FEE_FREE_PERIOD) > block.timestamp) {
            return amount.mul(WITHDRAWAL_FEE).div(FEE_MAX);
        }
        return 0;
    }

    function performanceFee(uint256 profit)
        public
        view
        override
        returns (uint256)
    {
        return profit.mul(PERFORMANCE_FEE).div(FEE_MAX);
    }

    function floatingRateEmission() public view returns (uint256) {
        return _floatingRateEmission == 0 ? 120e16 : _floatingRateEmission;
    }

    function freThreshold() public view returns (uint256) {
        return _freThreshold == 0 ? 18e18 : _freThreshold;
    }

    function shouldMarketBuy() public view returns (bool) {
        return
            priceCalculator.priceOfBunny().mul(freThreshold()).div(
                priceCalculator.priceOfBNB()
            ) < 1e18;
    }

    /* ========== V1 FUNCTIONS ========== */

    function mintFor(
        address asset,
        uint256 _withdrawalFee,
        uint256 _performanceFee,
        address to,
        uint256
    ) public payable override onlyMinter {
        uint256 feeSum = _performanceFee.add(_withdrawalFee);
        _transferAsset(asset, feeSum);

        if (asset == BUNNY) {
            IBEP20(BUNNY).safeTransfer(DEAD, feeSum);
            return;
        }

        if (shouldMarketBuy() == false) {
            if (asset == address(0)) {
                // means BNB
                SafeToken.safeTransferETH(TREASURY, feeSum);
            } else {
                IBEP20(asset).safeTransfer(TREASURY, feeSum);
            }
        } else {
            if (_withdrawalFee > 0) {
                if (asset == address(0)) {
                    // means BNB
                    SafeToken.safeTransferETH(TREASURY, _withdrawalFee);
                } else {
                    IBEP20(asset).safeTransfer(TREASURY, _withdrawalFee);
                }
            }

            if (_performanceFee == 0) return;

            _marketBuy(asset, _performanceFee, to);
            _performanceFee = _performanceFee
                .mul(floatingRateEmission().sub(1e18))
                .div(floatingRateEmission());
        }

        (uint256 contribution, ) =
            priceCalculator.valueOfAsset(asset, _performanceFee);
        uint256 mintBunny = amountBunnyToMint(contribution);
        if (mintBunny == 0) return;
        _mint(mintBunny, to);
    }

    /* ========== PancakeSwap V2 FUNCTIONS ========== */

    function mintForV2(
        address asset,
        uint256 _withdrawalFee,
        uint256 _performanceFee,
        address to,
        uint256 timestamp
    ) external payable override onlyMinter {
        mintFor(asset, _withdrawalFee, _performanceFee, to, timestamp);
    }

    /* ========== BunnyChef FUNCTIONS ========== */

    function mint(uint256 amount) external override onlyBunnyChef {
        if (amount == 0) return;
        _mint(amount, address(this));
    }

    function safeBunnyTransfer(address _to, uint256 _amount)
        external
        override
        onlyBunnyChef
    {
        if (_amount == 0) return;

        uint256 bal = IBEP20(BUNNY).balanceOf(address(this));
        if (_amount <= bal) {
            IBEP20(BUNNY).safeTransfer(_to, _amount);
        } else {
            IBEP20(BUNNY).safeTransfer(_to, bal);
        }
    }

    // @dev should be called when determining mint in governance. Bunny is transferred to the timelock contract.
    function mintGov(uint256 amount) external override onlyOwner {
        if (amount == 0) return;
        _mint(amount, TIMELOCK);
    }

    /* ========== PRIVATE FUNCTIONS ========== */

    function _marketBuy(
        address asset,
        uint256 amount,
        address to
    ) private {
        uint256 _initBunnyAmount = IBEP20(BUNNY).balanceOf(address(this));

        if (asset == address(0)) {
            zap.zapIn{value: amount}(BUNNY);
        } else if (
            keccak256(abi.encodePacked(IPancakePair(asset).symbol())) ==
            keccak256("Cake-LP")
        ) {
            if (IBEP20(asset).allowance(address(this), address(router)) == 0) {
                IBEP20(asset).safeApprove(address(router), uint256(-1));
            }

            IPancakePair pair = IPancakePair(asset);
            address token0 = pair.token0();
            address token1 = pair.token1();

            // burn
            if (IPancakePair(asset).balanceOf(asset) > 0) {
                IPancakePair(asset).burn(address(zap));
            }

            (uint256 amountToken0, uint256 amountToken1) =
                router.removeLiquidity(
                    token0,
                    token1,
                    amount,
                    0,
                    0,
                    address(this),
                    block.timestamp
                );

            if (IBEP20(token0).allowance(address(this), address(zap)) == 0) {
                IBEP20(token0).safeApprove(address(zap), uint256(-1));
            }
            if (IBEP20(token1).allowance(address(this), address(zap)) == 0) {
                IBEP20(token1).safeApprove(address(zap), uint256(-1));
            }

            if (token0 != BUNNY) {
                zap.zapInToken(token0, amountToken0, BUNNY);
            }

            if (token1 != BUNNY) {
                zap.zapInToken(token1, amountToken1, BUNNY);
            }
        } else {
            if (IBEP20(asset).allowance(address(this), address(zap)) == 0) {
                IBEP20(asset).safeApprove(address(zap), uint256(-1));
            }

            zap.zapInToken(asset, amount, BUNNY);
        }

        uint256 bunnyAmount =
            IBEP20(BUNNY).balanceOf(address(this)).sub(_initBunnyAmount);
        IBEP20(BUNNY).safeTransfer(to, bunnyAmount);
    }

    function _transferAsset(address asset, uint256 amount) private {
        if (asset == address(0)) {
            // case) transferred BNB
            require(msg.value >= amount, "Must have assets to transfer");
        } else {
            IBEP20(asset).safeTransferFrom(msg.sender, address(this), amount);
        }
    }

    function _mint(uint256 amount, address to) private {
        BEP20(BUNNY).mint(amount);
        if (to != address(this)) {
            BEP20(BUNNY).transfer(to, amount);
        }

        uint256 bunnyForDev = amount.mul(15).div(100);
        BEP20(BUNNY).mint(bunnyForDev);
        BEP20(BUNNY).transfer(TREASURY, bunnyForDev);
    }
}
