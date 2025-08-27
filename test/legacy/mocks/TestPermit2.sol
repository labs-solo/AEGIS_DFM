// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {IEIP712} from "permit2/src/interfaces/IEIP712.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

contract TestPermit2 is IAllowanceTransfer {
    bytes32 private constant _DOMAIN_SEPARATOR = keccak256("Mock Permit2 Domain Separator");

    function DOMAIN_SEPARATOR() external pure override returns (bytes32) {
        return _DOMAIN_SEPARATOR;
    }

    function approve(address token, address spender, uint160 amount, uint48 expiration) external override {}

    function permit(address owner, PermitSingle memory permitSingle, bytes calldata signature) external override {}

    function permit(address owner, PermitBatch memory permitBatch, bytes calldata signature) external override {}

    function transferFrom(address from, address to, uint160 amount, address token) external override {}

    function transferFrom(AllowanceTransferDetails[] calldata transferDetails) external override {}

    function allowance(address user, address token, address spender)
        external
        view
        override
        returns (uint160 amount, uint48 expiration, uint48 nonce)
    {
        return (type(uint160).max, type(uint48).max, 0);
    }

    function lockdown(TokenSpenderPair[] calldata approvals) external override {}

    function invalidateNonces(address token, address spender, uint48 newNonce) external override {}
}
