// SPDX-License-Identifier: BlueOak-1.0.0
pragma solidity 0.8.9;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "contracts/p0/interfaces/IAsset.sol";
import "contracts/p0/interfaces/IMain.sol";
import "contracts/p0/libraries/Basket.sol";
import "contracts/p0/main/Mixin.sol";
import "contracts/p0/main/RevenueDistributor.sol";
import "contracts/p0/main/SettingsHandler.sol";
import "contracts/libraries/Fixed.sol";
import "contracts/Pausable.sol";

struct BackupConfig {
    uint256 maxCollateral; // Maximum number of backup collateral elements to use in a basket
    ICollateral[] collateral; // Ordered list of backup collateral
}

struct BasketConfig {
    // The collateral in the prime (explicitly governance-set) basket
    ICollateral[] collateral;
    // An enumeration of the target names in collateral
    bytes32[] targetNames;
    // Amount of target units per basket for each prime collateral. {target/BU}
    mapping(ICollateral => Fix) targetAmts;
    // Backup configurations, one per target name.
    mapping(bytes32 => BackupConfig) backups;
}

/**
 * @title BasketHandler
 * @notice Tries to ensure the current vault is valid at all times.
 */
contract BasketHandlerP0 is
    Pausable,
    Mixin,
    SettingsHandlerP0,
    RevenueDistributorP0,
    IBasketHandler
{
    using BasketLib for Basket;
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using FixLib for Fix;

    BasketConfig private basketConf;

    Basket internal basket;
    uint256 public override blockBasketLastChanged; // {block number}

    function init(ConstructorArgs calldata args)
        public
        virtual
        override(Mixin, SettingsHandlerP0, RevenueDistributorP0)
    {
        super.init(args);
    }

    function poke() public virtual override notPaused {
        super.poke();
        tryEnsureValidBasket();
    }

    /// Set the prime basket in the basket configuration.
    /// @param collateral The collateral for the new prime basket
    /// @param targetAmts The target amounts (in) {target/BU} for the new prime basket
    function setPrimeBasket(ICollateral[] memory collateral, Fix[] memory targetAmts)
        public
        override
        onlyOwner
    {
        require(collateral.length == targetAmts.length, "must be same length");
        // Ensure collateral all have unique erc20 tokens
        delete basketConf.collateral;
        delete basketConf.targetNames;

        for (uint256 i = 0; i < collateral.length; i++) {
            ICollateral coll = collateral[i];
            basketConf.collateral.push(coll);
            basketConf.targetAmts[coll] = targetAmts[i];

            // Add coll's target name to basketConf.targetNames if it's not already there.
            bytes32 targetName = coll.targetName();
            uint256 j;
            for (j = 0; j < basketConf.targetNames.length; j++) {
                if (basketConf.targetNames[j] == targetName) break;
            }
            if (j >= basketConf.targetNames.length) {
                basketConf.targetNames.push(targetName);
            }
        }

        // Revert if we introduced a token-collateral conflict!
        requireUniqueTokens();
        emit PrimeBasketSet(collateral, targetAmts);
    }

    /// Set the backup configuration for some target name.
    function setBackupConfig(
        bytes32 targetName,
        uint256 maxCollateral,
        ICollateral[] memory collateral
    ) public override onlyOwner {
        BackupConfig storage conf = basketConf.backups[targetName];
        conf.maxCollateral = maxCollateral;

        delete conf.collateral;
        for (uint256 i = 0; i < collateral.length; i++) {
            conf.collateral.push(collateral[i]);
        }
        // Revert if we introduced a token-collateral conflict!
        requireUniqueTokens();
        emit BackupConfigSet(targetName, maxCollateral, collateral);
    }

    /// @return true if we registered a change in the underlying basket
    function switchBasket() public override onlyOwner returns (bool) {
        return _switchBasket();
    }

    /// @return Whether it holds enough basket units of collateral
    function fullyCapitalized() public view override returns (bool) {
        return basketsHeld().gte(rToken().basketsNeeded());
    }

    /// @return status The maximum CollateralStatus among basket collateral
    function worstCollateralStatus() public view override returns (CollateralStatus status) {
        for (uint256 i = 0; i < basket.size; i++) {
            if (!_assets.contains(address(basket.collateral[i]))) {
                return CollateralStatus.DISABLED;
            }
            if (uint256(basket.collateral[i].status()) > uint256(status)) {
                status = basket.collateral[i].status();
            }
        }
    }

    /// @return p {UoA} An estimate at the total value of all assets held, in the unit of account
    function totalAssetValue() public view override returns (Fix p) {
        for (uint256 i = 0; i < _assets.length(); i++) {
            IAsset a = IAsset(_assets.at(i));
            ICollateral c = ICollateral(_assets.at(i));

            // Exclude collateral that has defaulted
            if (!a.isCollateral() || c.status() != CollateralStatus.DISABLED) {
                uint256 bal = a.erc20().balanceOf(address(this));

                // {UoA} = {UoA} + {UoA/tok} * {qTok} / {qTok/tok}
                p = p.plus(a.price().mulu(bal).shiftLeft(-int8(a.erc20().decimals())));
            }
        }
    }

    // ==== Internal ====

    /// @return {BU} The equivalent of the current holdings in BUs without considering trading
    function basketsHeld() internal view returns (Fix) {
        return basket.balanceOf(address(this));
    }

    // Check collateral statuses; Select a new basket if needed.
    function tryEnsureValidBasket() internal {
        for (uint256 i = 0; i < basket.size; i++) {
            basket.collateral[i].forceUpdates();
        }

        if (worstCollateralStatus() == CollateralStatus.DISABLED) {
            _switchBasket();
        }
    }

    /// Return an array list (with possible duplicates) of a
    function collateralInConfig() private view returns (ICollateral[] memory collaterals) {
        uint256 arrSize = basketConf.collateral.length;
        for (uint256 i = 0; i < basketConf.targetNames.length; i++) {
            arrSize += basketConf.backups[basketConf.targetNames[i]].collateral.length;
        }
        collaterals = new ICollateral[](arrSize);
        uint256 length = 0;
        for (uint256 i = 0; i < basketConf.collateral.length; i++) {
            collaterals[i] = basketConf.collateral[i];
            length++;
        }
        for (uint256 i = 0; i < basketConf.targetNames.length; i++) {
            ICollateral[] storage backupColl = basketConf
                .backups[basketConf.targetNames[i]]
                .collateral;
            for (uint256 j = 0; j < backupColl.length; j++) {
                collateral[length] = backupColl[j];
                length++;
            }
        }
        return collaterals;
    }

    /// Require that each token pointed to by all assets in the entire basket configuration is
    /// pointed to by only one Collateral. (erc20 addresses may recur in the basket configuration if
    /// and only if they're all pointed to by the same Collateral contract)
    function requireUniqueTokens() private view {
        ICollateral[] collaterals = collateralsInConfig();
        uint256 length = 0;

        for (uint256 i = 0; i < basketConf.collateral.length; i++) {
            for (uint256 searchI = 0; searchI < length; searchI++) {
                if (collaterals[searchI] == collaterals[i]) break;
                require(
                    collaterals[searchI].erc20() != collaterals[i].erc20(),
                    "Different Collaterals in the basket config refer to the same erc20."
                );
            }
        }
    }

    // newBasket is effectively a local variable of _switchBasket. Nothing should use its value
    // from a previous transaction.
    Basket private newBasket;

    /// Select and save the next basket, based on the BasketConfig and Collateral statuses
    /// @return whether or not a new basket was derived from templates
    function _switchBasket() private returns (bool) {
        newBasket.empty();

        // Here, "good" collateral is non-defaulted collateral; any status other than DISABLED
        // goodWeights and totalWeights are in index-correspondence with basketConf.targetNames

        // {target/BU} total target weight of good, prime collateral with target i
        Fix[] memory goodWeights = new Fix[](basketConf.targetNames.length);

        // {target/BU} total target weight of all prime collateral with target i
        Fix[] memory totalWeights = new Fix[](basketConf.targetNames.length);

        // For each prime collateral:
        for (uint256 i = 0; i < basketConf.collateral.length; i++) {
            ICollateral coll = basketConf.collateral[i];

            // Find coll's targetName index
            uint256 targetIndex;
            for (targetIndex = 0; targetIndex < basketConf.targetNames.length; targetIndex++) {
                if (basketConf.targetNames[targetIndex] == coll.targetName()) break;
            }
            assert(targetIndex < basketConf.targetNames.length);

            // Set basket weights for good, prime collateral,
            // and accumulate the values of goodWeights and targetWeights
            Fix targetWeight = basketConf.targetAmts[coll];
            totalWeights[targetIndex] = totalWeights[targetIndex].plus(targetWeight);

            if (coll.status() != CollateralStatus.DISABLED) {
                goodWeights[targetIndex] = goodWeights[targetIndex].plus(targetWeight);
                newBasket.add(coll, targetWeight.div(coll.targetPerRef()));
            }
        }

        // For each target i, if we still need more weight for target i then try to add the backup
        // basket for target i to make up that weight:
        for (uint256 i = 0; i < basketConf.targetNames.length; i++) {
            if (totalWeights[i].lte(goodWeights[i])) continue; // Don't need backup weight

            uint256 size = 0; // backup basket size
            BackupConfig storage backup = basketConf.backups[basketConf.targetNames[i]];

            // Find the backup basket size: max(1, maxCollateral, # of good backup collateral)
            for (uint256 j = 0; j < backup.collateral.length; j++) {
                if (backup.collateral[j].status() != CollateralStatus.DISABLED) {
                    size++;
                    if (size >= backup.maxCollateral) break;
                }
            }

            // If we need backup collateral, but there's no good backup collateral, it's a bad case!
            // Do not set the basket; the protocol will stay issuance-paused until governance acts.
            if (size == 0) return false;

            // Set backup basket weights
            uint256 assigned = 0;
            for (uint256 j = 0; j < backup.collateral.length && assigned < size; j++) {
                ICollateral coll = backup.collateral[j];
                if (coll.status() != CollateralStatus.DISABLED) {
                    newBasket.add(coll, totalWeights[i].minus(goodWeights[i]).divu(size));
                    assigned++;
                }
            }
        }

        // If we haven't already given up, then commit the new basket!
        basket.copy(newBasket);

        // Activate the basket's assets in the AssetRegistry
        activateBasketAssets(basket);

        // Keep records, emit event
        blockBasketLastChanged = block.number;
        ICollateral[] memory collateral = new ICollateral[](basket.size);
        Fix[] memory refAmts = new Fix[](basket.size);
        for (uint256 i = 0; i < basket.size; i++) {
            collateral[i] = basket.collateral[i];
            refAmts[i] = basket.refAmts[collateral[i]];
        }
        emit BasketSet(collateral, refAmts);

        return true;
    }
}
