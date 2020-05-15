// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.6.8;

import "./IFeeManager.sol";

/// @title Fee Interface
/// @author Melon Council DAO <security@meloncoucil.io>
interface IFee {
    function addFundSettings(bytes calldata) external;
    function feeHook() external view returns (IFeeManager.FeeHook);
    function identifier() external pure returns (string memory);
    function settleFeeForFund() external returns (uint256);
    function settleFeeForInvestor(address, uint256) external returns (uint256);
    function updateFundSettings(bytes calldata) external;
}
