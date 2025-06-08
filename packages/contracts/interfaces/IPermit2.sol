// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {
    PermitBatchTransferFrom,
    SignatureTransferDetails,
    PermitTransferFrom
} from "./structs/SPermit2.sol"; // Adjust path if SPermit2.sol is elsewhere

interface IPermit2 {
    function permitTransferFrom(
        PermitBatchTransferFrom memory permit,
        SignatureTransferDetails[] calldata transferDetails,
        address owner,
        bytes calldata signature
    ) external;

    function permitTransferFrom(
        PermitTransferFrom memory permit,
        SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes calldata signature
    ) external;
}