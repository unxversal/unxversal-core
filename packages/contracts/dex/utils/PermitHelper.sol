// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
// Corrected import path assuming IPermit2.sol is in "../../interfaces/" relative to this file
import "../../interfaces/IPermit2.sol"; 
import {
    PermitBatchTransferFrom,
    SignatureTransferDetails,
    PermitTransferFrom
} from "../../interfaces/structs/SPermit2.sol";

/**
 * @title PermitHelper
 * @author Unxversal Team
 * @notice Helper contract to facilitate ERC2612 (EIP-2612) and Uniswap Permit2 signatures.
 * @dev Allows users to approve token spending and execute an action (like creating or filling an order)
 *      in a single transaction by providing a signature.
 *      This contract itself should not hold tokens or approvals long-term.
 *      It acts as a temporary dispatcher for permitted actions.
 */
contract PermitHelper {
    IPermit2 public immutable permit2Contract;

    event ERC2612PermitUsed(
        address indexed owner,
        address indexed token,
        address indexed spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    );
    // An event for Permit2 could be useful, e.g., when permitTransferFrom is called via this helper
    event Permit2TransferExecuted(
        address indexed owner,
        address indexed token, // From permit.permitted[0].token or permit.permitted.token
        address indexed to,    // From transferDetails[0].to or transferDetails.to
        uint256 amount         // From transferDetails[0].requestedAmount or transferDetails.requestedAmount
    );


    constructor(address _permit2Address) {
        require(_permit2Address != address(0), "PermitHelper: Zero Permit2 address");
        permit2Contract = IPermit2(_permit2Address);
    }

    // Note: The internal `useERC2612Permit` function was primarily for illustration.
    // The external `erc2612PermitAndCall` directly uses `token.permit()`.
    // If you needed `useERC2612Permit` for other internal logic, it could be kept.
    // For now, it's not strictly necessary if only `erc2612PermitAndCall` is used.

    /**
     * @notice Executes an ERC2612 permit and then calls a target contract.
     * @param token The ERC20 token that supports EIP-2612.
     * @param owner The owner of the tokens.
     * @param spender The address to be approved (typically the targetContract or a related vault).
     * @param value The amount of tokens to approve.
     * @param deadline The deadline after which the EIP-2612 signature is invalid.
     * @param v v component of the EIP-2612 signature.
     * @param r r component of the EIP-2612 signature.
     * @param s s component of the EIP-2
     * @param targetContract The contract to call after the permit is processed.
     * @param callData The encoded function call data for the targetContract.
     * @return result The data returned by the targetContract call.
     */
    function erc2612PermitAndCall(
        IERC20Permit token,
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s,
        address targetContract,
        bytes calldata callData
    ) external returns (bytes memory result) {
        require(targetContract != address(0), "PermitHelper: Zero target contract");
        token.permit(owner, spender, value, deadline, v, r, s);
        emit ERC2612PermitUsed(owner, address(token), spender, value, deadline, v, r, s);

        (bool success, bytes memory returnedData) = targetContract.call(callData);
        require(success, "PermitHelper: Target call failed"); // Consider bubbling up revert reason
        return returnedData;
    }

    /**
     * @notice Executes a Permit2 permitTransferFrom (batch) and then calls a target contract.
     * @dev The `transferDetails[i].to` field specifies the recipient of each permitted transfer.
     * @param permit The PermitBatchTransferFrom data signed by the owner.
     * @param transferDetails Array of SignatureTransferDetails specifying destinations and amounts.
     * @param owner The owner of the tokens who signed the permit.
     * @param signature The EIP-712 signature from the owner.
     * @param targetContract The contract to call after the Permit2 transfers are processed.
     * @param callData The encoded function call data for the targetContract.
     * @return result The data returned by the targetContract call.
     */
    function permit2BatchTransferAndCall(
        PermitBatchTransferFrom memory permit, // Using IPermit2 scope for the struct
        SignatureTransferDetails[] calldata transferDetails, // Using IPermit2 scope
        address owner,
        bytes calldata signature,
        address targetContract,
        bytes calldata callData
    ) external returns (bytes memory result) {
        require(targetContract != address(0), "PermitHelper: Zero target contract");
        permit2Contract.permitTransferFrom(permit, transferDetails, owner, signature);

        // Emit an event for at least the first transfer for traceability
        if (transferDetails.length > 0 && permit.permitted.length > 0) {
            emit Permit2TransferExecuted(
                owner,
                permit.permitted[0].token,
                transferDetails[0].to,
                transferDetails[0].requestedAmount
            );
        }

        (bool success, bytes memory returnedData) = targetContract.call(callData);
        require(success, "PermitHelper: Target call failed"); // Consider bubbling up revert reason
        return returnedData;
    }

    /**
     * @notice Executes a Permit2 permitTransferFrom (single) and then calls a target contract.
     * @dev The `transferDetails.to` field specifies the recipient of the permitted transfer.
     * @param permit The PermitTransferFrom data signed by the owner.
     * @param transferDetails SignatureTransferDetails specifying destination and amount.
     * @param owner The owner of the tokens who signed the permit.
     * @param signature The EIP-712 signature from the owner.
     * @param targetContract The contract to call after the Permit2 transfer is processed.
     * @param callData The encoded function call data for the targetContract.
     * @return result The data returned by the targetContract call.
     */
    function permit2SingleTransferAndCall(
        PermitTransferFrom memory permit, // Using IPermit2 scope for the struct
        SignatureTransferDetails calldata transferDetails, // Using IPermit2 scope
        address owner,
        bytes calldata signature,
        address targetContract,
        bytes calldata callData
    ) external returns (bytes memory result) {
        require(targetContract != address(0), "PermitHelper: Zero target contract");
        permit2Contract.permitTransferFrom(permit, transferDetails, owner, signature);

        emit Permit2TransferExecuted(
            owner,
            permit.permitted.token,
            transferDetails.to,
            transferDetails.requestedAmount
        );

        (bool success, bytes memory returnedData) = targetContract.call(callData);
        require(success, "PermitHelper: Target call failed"); // Consider bubbling up revert reason
        return returnedData;
    }
}