// SPDX-License-Identifier: AGPL-3.0-only

pragma solidity 0.8.12;

import "../interfaces/IEulerMarket.sol";

import "./BaseReactor.sol";

/// @title EulerReactor
/// @notice Reactor to mint agEUR and deposit them on Euler Finance (https://www.euler.finance/)
/// @notice Euler markets only work with token with decimal <= 18
/// @author Angle Core Team
contract EulerReactor is BaseReactor {
    using SafeERC20 for IERC20;

    IEulerEToken public euler;
    uint256 public lastBalance;
    uint256 public minInvest;

    // =============================== Events ======================================

    event MinInvestUpdated(uint256);

    /// @notice Initializes the `BaseReactor` contract and
    /// the underlying `VaultManager`
    /// @param _name Name of the ERC4626 token
    /// @param _symbol Symbol of the ERC4626 token
    /// @param _vaultManager Underlying `VaultManager` used to borrow stablecoin
    /// @param _lowerCF Lower Collateral Factor accepted without rebalancing
    /// @param _targetCF Target Collateral Factor
    /// @param _upperCF Upper Collateral Factor accepted without rebalancing
    function initialize(
        IEulerEToken _euler,
        uint256 minInvest_,
        string memory _name,
        string memory _symbol,
        IVaultManager _vaultManager,
        uint64 _lowerCF,
        uint64 _targetCF,
        uint64 _upperCF
    ) external {
        euler = _euler;
        minInvest = minInvest_;
        _initialize(_name, _symbol, _vaultManager, _lowerCF, _targetCF, _upperCF);
        IERC20(address(stablecoin)).safeApprove(address(euler), type(uint256).max);
    }

    /// @inheritdoc IERC4626
    /// @dev user address has no impact on the maxDeposit
    /// @dev Users are limited by the `debtCeiling` in the associated `VaultManager` and the `maxExternalAmount` defined on Euler
    /// @dev Contrary to maxWithdraw you don't need to check conditions on upperCF
    function maxDeposit(address) public view override returns (uint256 maxAssetDeposit) {
        (uint256 usedAssets, uint256 looseAssets) = _getAssets();
        uint256 debt = vaultManager.getVaultDebt(vaultID);
        uint256 debtCeiling = vaultManager.debtCeiling();
        uint256 availableStablecoins = debtCeiling - debt;
        // Angle stablecoins are in base 18 no scaling needed
        uint256 maxDepositEuler = euler.MAX_SANE_AMOUNT();
        // By default you can deposit maxUint if there are no restrictions
        maxAssetDeposit = type(uint256).max;
        // debtCeiling max value is `type(uint256).max / BASE_INTEREST` ( cf VaultManager.sol line 480)
        if (debtCeiling != (type(uint256).max / 10**27) || maxDepositEuler != type(uint112).max) {
            uint256 oracleRate = oracle.read();
            if (availableStablecoins >= maxDepositEuler) availableStablecoins = maxDepositEuler;
            uint256 newDebt = availableStablecoins + debt;
            maxAssetDeposit = (newDebt * _assetBase * BASE_PARAMS) / targetCF;
            uint256 collateralFactor = (debt * BASE_PARAMS * _assetBase * oracleRate) / (maxAssetDeposit * 10**18);
            // If CF is larger than lowerCF then no borrow will be made and user can deposit up until reaching a CF of  lowerCF
            if (collateralFactor > lowerCF) {
                maxAssetDeposit = (debt * _assetBase * BASE_PARAMS) / lowerCF;
            }
            maxAssetDeposit = (maxAssetDeposit / oracleRate) - usedAssets - looseAssets;
        }
    }

    /// @inheritdoc IERC4626
    /// @param user Address of the user who will interact with the contract
    /// @dev user address has no impact on the maxMint
    function maxMint(address user) public view override returns (uint256) {
        return convertToShares(maxDeposit(user));
    }

    /// @inheritdoc IERC4626
    /// @dev Users are limited in the amount to be withdrawn by liquidity on Euler contracts
    /// @dev We do not take into account the claim(amount) call in these computation - as it
    /// would asks to estimate
    function maxWithdraw(address user) public view virtual override returns (uint256) {
        uint256 toWithdraw = convertToAssets(balanceOf(user));
        (uint256 usedAssets, uint256 looseAssets) = _getAssets();
        if (toWithdraw <= looseAssets) return toWithdraw;
        else return looseAssets + _maxStablecoinsAvailable(toWithdraw, usedAssets, looseAssets);
    }

    /// @inheritdoc IERC4626
    /// @dev Users are limited in the amount to be withdrawn by liquidity on Euler contracts
    function maxRedeem(address user) public view virtual override returns (uint256) {
        return convertToShares(maxWithdraw(user));
    }

    function setMinInvest(uint256 minInvest_) public onlyGovernorOrGuardian {
        minInvest = minInvest_;
        emit MinInvestUpdated(minInvest_);
    }

    /// @notice Changes allowance of this contract to Euler deposit contract
    /// @param amount Amount allowed
    function changeAllowance(uint256 amount) external onlyGovernorOrGuardian {
        uint256 currentAllowance = IERC20(address(stablecoin)).allowance(address(this), address(euler));
        if (currentAllowance < amount) {
            IERC20(address(stablecoin)).safeIncreaseAllowance(address(euler), amount - currentAllowance);
        } else if (currentAllowance > amount) {
            IERC20(address(stablecoin)).safeDecreaseAllowance(address(euler), currentAllowance - amount);
        }
    }

    /// @notice Returns the maximum amount of assets that can be withdrawn considering current Euler liquidity
    /// @param amount Amount of assets wanted to be withdrawn
    /// @param usedAssets Amount of assets collateralizing the vault
    /// @param looseAssets Amount of assets directly accessible -- in the contract balance
    /// @dev If reaching the upperCF, users are limited in the amount to be withdrawn by liquidity on Euler contracts
    function _maxStablecoinsAvailable(
        uint256 amount,
        uint256 usedAssets,
        uint256 looseAssets
    ) internal view returns (uint256 maxAmount) {
        uint256 toWithdraw = amount - looseAssets;
        uint256 oracleRate = oracle.read();

        uint256 debt = vaultManager.getVaultDebt(vaultID);
        (uint256 futureStablecoinsInVault, uint256 collateralFactor) = _getFutureDebtAndCF(
            toWithdraw,
            usedAssets,
            looseAssets,
            debt,
            oracleRate
        );

        // Initialisation that users can withdraw it all, if it can't then maxAmount will be updated
        // This equality will stand if:
        //      1) collateralFactor < upperCF: contract does not need to repay debt and therefore do not need to remove Euler Liquidity
        //      2) looseStablecoins >= stablecoinsValueToRedeem : debt to be repaid is lower than the reactor stablecoin balance
        //      3) Euler liquidity available to the reactor is larger than the debt to be repaid
        maxAmount = toWithdraw;

        uint256 stablecoinsValueToRedeem;
        // If the new collateral factor is above upperCF, we need to repay stablecoins to free collateral,
        // and therefore we need to withdraw liquidity on Euler.
        // This is possible only if both the reactor balance on Euler and poolSize (available liquidity on Euler) is larger
        // than the needed stablecoins --> users can withdraw toWithdraw
        // Mimic the _rebalance() in a case of a withdraw
        if (collateralFactor >= upperCF) {
            stablecoinsValueToRedeem = debt - futureStablecoinsInVault;
            if (futureStablecoinsInVault <= vaultManagerDust) {
                stablecoinsValueToRedeem = type(uint256).max;
            }
            // take into account non invested stablecoins as they are at hand
            uint256 looseStablecoins = stablecoin.balanceOf(address(this));
            if (stablecoinsValueToRedeem > looseStablecoins) {
                stablecoinsValueToRedeem -= looseStablecoins;
                // Liquidity on Euler
                uint256 poolSize = stablecoin.balanceOf(address(euler));
                uint256 reactorBalanceEuler = euler.balanceOfUnderlying(address(this));
                uint256 maxEulerWithdrawal = poolSize > reactorBalanceEuler ? reactorBalanceEuler : poolSize;
                // if we can fully reimburse with Euler liquidity then users can withdraw hiw whole balance
                if (maxEulerWithdrawal < stablecoinsValueToRedeem) {
                    stablecoinsValueToRedeem = maxEulerWithdrawal;
                    maxAmount = (stablecoinsValueToRedeem * _assetBase * BASE_PARAMS) / (oracleRate * targetCF);
                    maxAmount = maxAmount > toWithdraw ? toWithdraw : maxAmount;
                }
            }
        }
    }

    /// @notice Function to invest stablecoins
    /// @param amount Amount of new stablecoins managed
    /// @return amountInvested Amount truly invested in the strategy
    /// @dev Amount should not be above maxExternalAmount defined in Euler otherwise it will revert
    function _push(uint256 amount) internal override returns (uint256 amountInvested) {
        (uint256 lentStablecoins, uint256 looseStablecoins) = _report(amount);

        if (looseStablecoins > minInvest) {
            euler.deposit(0, looseStablecoins);
            amountInvested = looseStablecoins;
            // as looseStablecoins should be null
            lastBalance = euler.balanceOfUnderlying(address(this));
        } else {
            lastBalance = lentStablecoins + looseStablecoins;
        }
        return amountInvested;
    }

    /// @notice Function to withdraw stablecoins
    /// @param amount Amount needed at the end of the call
    /// @return amountAvailable Amount available in the contracts, new `looseStablecoins`
    function _pull(uint256 amount) internal override returns (uint256 amountAvailable) {
        (uint256 lentStablecoins, uint256 looseStablecoins) = _report(0);

        if (looseStablecoins < amount) {
            uint256 amountWithdrawnFromEuler = (amount - looseStablecoins) > lentStablecoins
                ? type(uint256).max
                : (amount - looseStablecoins);
            euler.withdraw(0, amountWithdrawnFromEuler);
            amountAvailable = looseStablecoins + amountWithdrawnFromEuler;

            lastBalance = euler.balanceOfUnderlying(address(this));
        } else {
            lastBalance = lentStablecoins + looseStablecoins - amount;
            amountAvailable = amount;
        }
    }

    function _report(uint256 amountToAdd) internal returns (uint256 lentStablecoins, uint256 looseStablecoins) {
        lentStablecoins = euler.balanceOfUnderlying(address(this));
        looseStablecoins = stablecoin.balanceOf(address(this));

        // always positive otherwise we couldn't do the operation
        uint256 total = looseStablecoins + lentStablecoins - amountToAdd;
        uint256 lastBalance_ = lastBalance;

        if (total > lastBalance_) _handleGain(total - lastBalance_);
        else _handleLoss(lastBalance_ - total);
    }
}
