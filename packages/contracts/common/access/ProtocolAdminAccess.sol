// contracts/common/access/ProtocolAdminAccess.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";

/// @dev Base admin/owner helper for protocol contracts.
abstract contract ProtocolAdminAccess is Ownable {
    constructor(address initialOwner)
        Ownable(initialOwner)             // <-- forward the argument
    {
        require(initialOwner != address(0), "ProtocolAdminAccess: zero address");
        // Ownable already sets the owner, so no extra transfer needed.
        // _transferOwnership(initialOwner);   // <- remove (or keep; it’s harmless but redundant)
    }
}
