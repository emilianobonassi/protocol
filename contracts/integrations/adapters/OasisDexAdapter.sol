// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.6.8;

import "../../utils/MathHelpers.sol";
import "../interfaces/IOasisDex.sol";
import "../utils/AdapterBase.sol";

/// @title OasisDexAdapter Contract
/// @author Melon Council DAO <security@meloncoucil.io>
/// @notice Adapter for interacting with OasisDex
contract OasisDexAdapter is AdapterBase, MathHelpers {
    address immutable public EXCHANGE;

    constructor(address _registry, address _exchange) public AdapterBase(_registry) {
        EXCHANGE = _exchange;
    }

    // EXTERNAL FUNCTIONS

    /// @notice Provides a constant string identifier for an adapter
    /// @return An identifier string
    function identifier() external pure override returns (string memory) {
        return "OASIS_DEX";
    }

    /// @notice Parses the expected assets to receive from a call on integration 
    /// @param _selector The function selector for the callOnIntegration
    /// @param _encodedCallArgs The encoded parameters for the callOnIntegration
    /// @return spendAssets_ The assets to spend in the call
    /// @return spendAssetAmounts_ The max asset amounts to spend in the call
    /// @return incomingAssets_ The assets to receive in the call
    /// @return minIncomingAssetAmounts_ The min asset amounts to receive in the call
    function parseAssetsForMethod(bytes4 _selector, bytes calldata _encodedCallArgs)
        external
        view
        override
        returns (
            address[] memory spendAssets_,
            uint256[] memory spendAssetAmounts_,
            address[] memory incomingAssets_,
            uint256[] memory minIncomingAssetAmounts_
        )
    {
        if (_selector == TAKE_ORDER_SELECTOR) {
            (
                uint256 takerAssetFillAmount,
                uint256 orderIdentifier
            ) = __decodeTakeOrderCallArgs(_encodedCallArgs);

            (
                uint256 availableMakerAmount,
                address makerAsset,
                uint256 availableTakerAmount,
                address takerAsset
            ) = IOasisDex(EXCHANGE).getOffer(orderIdentifier);

            spendAssets_ = new address[](1);
            spendAssets_[0] = takerAsset;
            spendAssetAmounts_ = new uint256[](1);
            spendAssetAmounts_[0] = takerAssetFillAmount;

            incomingAssets_ = new address[](1);
            incomingAssets_[0] = makerAsset;
            minIncomingAssetAmounts_ = new uint256[](1);
            minIncomingAssetAmounts_[0] = __calcRelativeQuantity(
                availableTakerAmount,
                availableMakerAmount,
                takerAssetFillAmount
            ); // maker fill amount calculated relative to taker fill amount;
        }
        else {
            revert("parseIncomingAssets: _selector invalid");
        }
    }

    /// @notice Trades assets on OasisDex
    /// @param _encodedCallArgs Encoded order parameters
    /// @param _encodedAssetTransferArgs Encoded args for expected assets to spend and receive
    function takeOrder(bytes calldata _encodedCallArgs, bytes calldata _encodedAssetTransferArgs)
        external
        onlyVault
        fundAssetsTransferHandler(_encodedAssetTransferArgs)
    {
        (
            uint256 takerAssetFillAmount,
            uint256 orderIdentifier
        ) = __decodeTakeOrderCallArgs(_encodedCallArgs);
        
        (
            uint256 availableMakerAmount,
            ,
            uint256 availableTakerAmount,
            address takerAsset
        ) = IOasisDex(EXCHANGE).getOffer(orderIdentifier);

        require(
            takerAssetFillAmount <= availableTakerAmount,
            "takeOrder: Taker asset fill amount greater than available"
        );

        // Execute fill
        IERC20(takerAsset).approve(EXCHANGE, takerAssetFillAmount);
        IOasisDex(EXCHANGE).buy(
            orderIdentifier,
            __calcRelativeQuantity(
                availableTakerAmount,
                availableMakerAmount,
                takerAssetFillAmount
            ) // maker fill amount calculated relative to taker fill amount
        );
    }

    // PRIVATE FUNCTIONS

    /// @notice Decode the parameters of a takeOrder call
    /// @param _encodedCallArgs Encoded parameters passed from client side
    function __decodeTakeOrderCallArgs(bytes memory _encodedCallArgs)
        private
        pure
        returns (
            uint256 takerAssetFillAmount_,
            uint256 orderIdentifier_
        )
    {
        return abi.decode(
            _encodedCallArgs,
            (
                uint256,
                uint256
            )
        );
    }
}
