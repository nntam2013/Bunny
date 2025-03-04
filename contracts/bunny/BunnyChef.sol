// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

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

import "@pancakeswap/pancake-swap-lib/contracts/math/SafeMath.sol";
import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/IBEP20.sol";
import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/SafeBEP20.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import "../interfaces/IBunnyMinterV2.sol";
import "../interfaces/IBunnyChef.sol";
import "../interfaces/IStrategy.sol";
import "./BunnyToken.sol";

contract BunnyChef is IBunnyChef, OwnableUpgradeable {
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;

    /* ========== CONSTANTS ============= */

    BunnyToken public constant BUNNY =
        BunnyToken(0x459f989E5BA5899BAEf98c5a1DfDa34dD3E8D0d7);

    /* ========== STATE VARIABLES ========== */

    address[] private _vaultList;
    mapping(address => VaultInfo) vaults;
    mapping(address => mapping(address => UserInfo)) vaultUsers;

    IBunnyMinterV2 public minter;

    uint256 public startBlock;
    uint256 public override bunnyPerBlock;
    uint256 public override totalAllocPoint;

    /* ========== MODIFIERS ========== */

    modifier onlyVaults {
        require(
            vaults[msg.sender].token != address(0),
            "BunnyChef: caller is not on the vault"
        );
        _;
    }

    modifier updateRewards(address vault) {
        VaultInfo storage vaultInfo = vaults[vault];
        if (block.number > vaultInfo.lastRewardBlock) {
            uint256 tokenSupply = tokenSupplyOf(vault);
            if (tokenSupply > 0) {
                uint256 multiplier =
                    timeMultiplier(vaultInfo.lastRewardBlock, block.number);
                uint256 rewards =
                    multiplier.mul(bunnyPerBlock).mul(vaultInfo.allocPoint).div(
                        totalAllocPoint
                    );
                vaultInfo.accBunnyPerShare = vaultInfo.accBunnyPerShare.add(
                    rewards.mul(1e12).div(tokenSupply)
                );
            }
            vaultInfo.lastRewardBlock = block.number;
        }
        _;
    }

    /* ========== EVENTS ========== */

    event NotifyDeposited(
        address indexed user,
        address indexed vault,
        uint256 amount
    );
    event NotifyWithdrawn(
        address indexed user,
        address indexed vault,
        uint256 amount
    );
    event BunnyRewardPaid(
        address indexed user,
        address indexed vault,
        uint256 amount
    );

    /* ========== INITIALIZER ========== */

    function initialize(uint256 _startBlock, uint256 _bunnyPerBlock)
        external
        initializer
    {
        __Ownable_init();

        startBlock = _startBlock;
        bunnyPerBlock = _bunnyPerBlock;
    }

    /* ========== VIEWS ========== */

    function timeMultiplier(uint256 from, uint256 to)
        public
        pure
        returns (uint256)
    {
        return to.sub(from);
    }

    function tokenSupplyOf(address vault) public view returns (uint256) {
        return IStrategy(vault).totalSupply();
    }

    function vaultInfoOf(address vault)
        external
        view
        override
        returns (VaultInfo memory)
    {
        return vaults[vault];
    }

    function vaultUserInfoOf(address vault, address user)
        external
        view
        override
        returns (UserInfo memory)
    {
        return vaultUsers[vault][user];
    }

    function pendingBunny(address vault, address user)
        public
        view
        override
        returns (uint256)
    {
        UserInfo storage userInfo = vaultUsers[vault][user];
        VaultInfo storage vaultInfo = vaults[vault];

        uint256 accBunnyPerShare = vaultInfo.accBunnyPerShare;
        uint256 tokenSupply = tokenSupplyOf(vault);
        if (block.number > vaultInfo.lastRewardBlock && tokenSupply > 0) {
            uint256 multiplier =
                timeMultiplier(vaultInfo.lastRewardBlock, block.number);
            uint256 bunnyRewards =
                multiplier.mul(bunnyPerBlock).mul(vaultInfo.allocPoint).div(
                    totalAllocPoint
                );
            accBunnyPerShare = accBunnyPerShare.add(
                bunnyRewards.mul(1e12).div(tokenSupply)
            );
        }
        return
            userInfo.pending.add(
                userInfo.balance.mul(accBunnyPerShare).div(1e12).sub(
                    userInfo.rewardPaid
                )
            );
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function addVault(
        address vault,
        address token,
        uint256 allocPoint
    ) public onlyOwner {
        require(
            vaults[vault].token == address(0),
            "BunnyChef: vault is already set"
        );
        bulkUpdateRewards();

        uint256 lastRewardBlock =
            block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(allocPoint);
        vaults[vault] = VaultInfo(token, allocPoint, lastRewardBlock, 0);
        _vaultList.push(vault);
    }

    function updateVault(address vault, uint256 allocPoint) public onlyOwner {
        require(
            vaults[vault].token != address(0),
            "BunnyChef: vault must be set"
        );
        bulkUpdateRewards();

        uint256 lastAllocPoint = vaults[vault].allocPoint;
        if (lastAllocPoint != allocPoint) {
            totalAllocPoint = totalAllocPoint.sub(lastAllocPoint).add(
                allocPoint
            );
        }
        vaults[vault].allocPoint = allocPoint;
    }

    function setMinter(address _minter) external onlyOwner {
        require(
            address(minter) == address(0),
            "BunnyChef: setMinter only once"
        );
        minter = IBunnyMinterV2(_minter);
    }

    function setBunnyPerBlock(uint256 _bunnyPerBlock) external onlyOwner {
        bulkUpdateRewards();
        bunnyPerBlock = _bunnyPerBlock;
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function notifyDeposited(address user, uint256 amount)
        external
        override
        onlyVaults
        updateRewards(msg.sender)
    {
        UserInfo storage userInfo = vaultUsers[msg.sender][user];
        VaultInfo storage vaultInfo = vaults[msg.sender];

        uint256 pending =
            userInfo.balance.mul(vaultInfo.accBunnyPerShare).div(1e12).sub(
                userInfo.rewardPaid
            );
        userInfo.pending = userInfo.pending.add(pending);
        userInfo.balance = userInfo.balance.add(amount);
        userInfo.rewardPaid = userInfo
            .balance
            .mul(vaultInfo.accBunnyPerShare)
            .div(1e12);
        emit NotifyDeposited(user, msg.sender, amount);
    }

    function notifyWithdrawn(address user, uint256 amount)
        external
        override
        onlyVaults
        updateRewards(msg.sender)
    {
        UserInfo storage userInfo = vaultUsers[msg.sender][user];
        VaultInfo storage vaultInfo = vaults[msg.sender];

        uint256 pending =
            userInfo.balance.mul(vaultInfo.accBunnyPerShare).div(1e12).sub(
                userInfo.rewardPaid
            );
        userInfo.pending = userInfo.pending.add(pending);
        userInfo.balance = userInfo.balance.sub(amount);
        userInfo.rewardPaid = userInfo
            .balance
            .mul(vaultInfo.accBunnyPerShare)
            .div(1e12);
        emit NotifyWithdrawn(user, msg.sender, amount);
    }

    function safeBunnyTransfer(address user)
        external
        override
        onlyVaults
        updateRewards(msg.sender)
        returns (uint256)
    {
        UserInfo storage userInfo = vaultUsers[msg.sender][user];
        VaultInfo storage vaultInfo = vaults[msg.sender];

        uint256 pending =
            userInfo.balance.mul(vaultInfo.accBunnyPerShare).div(1e12).sub(
                userInfo.rewardPaid
            );
        uint256 amount = userInfo.pending.add(pending);
        userInfo.pending = 0;
        userInfo.rewardPaid = userInfo
            .balance
            .mul(vaultInfo.accBunnyPerShare)
            .div(1e12);

        minter.mint(amount);
        minter.safeBunnyTransfer(user, amount);
        emit BunnyRewardPaid(user, msg.sender, amount);
        return amount;
    }

    function bulkUpdateRewards() public {
        for (uint256 idx = 0; idx < _vaultList.length; idx++) {
            if (
                _vaultList[idx] != address(0) &&
                vaults[_vaultList[idx]].token != address(0)
            ) {
                updateRewardsOf(_vaultList[idx]);
            }
        }
    }

    function updateRewardsOf(address vault) public updateRewards(vault) {}

    /* ========== SALVAGE PURPOSE ONLY ========== */

    function recoverToken(address _token, uint256 amount)
        external
        virtual
        onlyOwner
    {
        require(
            _token != address(BUNNY),
            "BunnyChef: cannot recover BUNNY token"
        );
        IBEP20(_token).safeTransfer(owner(), amount);
    }
}
