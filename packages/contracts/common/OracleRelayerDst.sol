// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol"; // For managing assetIds if needed
import "./access/ProtocolAdminAccess.sol";
import "../interfaces/ILayerZeroEndpoint.sol";
import "../interfaces/ILayerZeroUserApplicationConfig.sol";
import "./interfaces/IOracleRelayer.sol";
import "../interfaces/ILayerZeroReceiver.sol";

/**
 * @title OracleRelayerDst
 * @author Unxversal Team
 * @notice Receives price data from a trusted LayerZero source (OracleRelayerSrc) and stores it.
 * @dev Implements IOracleRelayer for other Peaq contracts (Synth, Lend, Perps, Options) to consume prices.
 *      The owner (Admin) can manually set prices in emergencies or adjust stale tolerance.
 *      This contract is a LayerZero User Application (UA).
 */
contract OracleRelayerDst is ProtocolAdminAccess, ILayerZeroUserApplicationConfig, IOracleRelayer, ILayerZeroReceiver {
    using EnumerableSet for EnumerableSet.UintSet;

    ILayerZeroEndpoint public immutable lzEndpoint;

    uint16 public trustedSrcChainId;    // LayerZero chain ID of the source (e.g., Polygon)
    bytes public trustedSrcAppAddress; // OracleRelayerSrc address on source chain (LayerZero bytes format)

    struct PriceInfo {
        uint256 price;        // Price with implied decimals (e.g., 18 for USD value)
        uint32 lastUpdatedAt; // Unix timestamp from the original oracle source (e.g., Chainlink round)
    }
    mapping(uint256 => PriceInfo) internal _priceInfos; // assetId => PriceInfo
    EnumerableSet.UintSet private _supportedAssetIds; // To keep track of assets with configured prices

    uint32 public override staleToleranceSec;

    // Payload structure expected from OracleRelayerSrc: { assetId, price, timestamp }
    // Defined here for clarity, though only used for decoding.
    struct PriceMsg {
        uint256 assetId;
        uint256 price;
        uint32 ts;
    }

    event PriceReceivedAndStored(
        uint256 indexed assetId,
        uint256 price,
        uint32 timestamp,
        uint16 indexed srcChainId,
        bytes srcAddress
    );
    event TrustedRemoteSet(uint16 newSrcChainId, bytes newSrcAppAddress);
    event StaleToleranceSet(uint32 newStaleToleranceSec);
    event ManualPriceForced(uint256 indexed assetId, uint256 price, uint32 timestamp);
    event AssetSupported(uint256 indexed assetId, bool isSupported);


    /**
     * @param _lzEndpointAddress The address of the LayerZero Endpoint on Peaq.
     * @param _initialOwner The initial owner (multisig/DAO Timelock) of this contract.
     * @param _initialTrustedSrcChainId Initial trusted source LayerZero chain ID (e.g., Polygon's L0 ID).
     * @param _initialTrustedSrcAppAddress Initial trusted OracleRelayerSrc address on source chain (L0 bytes).
     * @param _initialStaleToleranceSec Initial stale tolerance in seconds (e.g., 3600 for 1 hour).
     */
    constructor(
        address _lzEndpointAddress,
        address _initialOwner,
        uint16 _initialTrustedSrcChainId,
        bytes memory _initialTrustedSrcAppAddress,
        uint32 _initialStaleToleranceSec
    ) ProtocolAdminAccess(_initialOwner) {
        require(_lzEndpointAddress != address(0), "ORD: Zero L0 endpoint");
        lzEndpoint = ILayerZeroEndpoint(_lzEndpointAddress);

        setTrustedRemote(_initialTrustedSrcChainId, _initialTrustedSrcAppAddress); // Emits event
        setStaleTolerance(_initialStaleToleranceSec); // Emits event
    }

    /**
     * @notice Sets the trusted remote source chain ID and application address for LayerZero messages.
     * @dev Only callable by the owner.
     * @param _newSrcChainId The LayerZero chain ID of the source network (e.g., Polygon).
     * @param _newSrcAppAddress The address of OracleRelayerSrc on the source chain, in LayerZero bytes format.
     */
    function setTrustedRemote(uint16 _newSrcChainId, bytes memory _newSrcAppAddress) public onlyOwner {
        require(_newSrcChainId != 0, "ORD: Zero srcChainId");
        require(_newSrcAppAddress.length > 0, "ORD: Empty srcAppAddress");
        trustedSrcChainId = _newSrcChainId;
        trustedSrcAppAddress = _newSrcAppAddress;
        emit TrustedRemoteSet(_newSrcChainId, _newSrcAppAddress);
    }

    /**
     * @notice Sets the duration after which a price is considered stale.
     * @dev Only callable by the owner.
     * @param _newStaleToleranceSec The new stale tolerance in seconds. Must be greater than zero.
     */
    function setStaleTolerance(uint32 _newStaleToleranceSec) public onlyOwner {
        require(_newStaleToleranceSec > 0, "ORD: Stale tolerance must be > 0");
        staleToleranceSec = _newStaleToleranceSec;
        emit StaleToleranceSet(_newStaleToleranceSec);
    }

    /**
     * @notice Internal handler for LayerZero messages. Called by `lzReceive`.
     * @dev Verifies the source and stores the received price data.
     * @param _srcChainId The source chain ID of the message.
     * @param _srcAddress The source application address of the message.
     * @param _payload The price data payload.
     */
    function _handleLzMessage(
        uint16 _srcChainId,
        bytes calldata _srcAddress,
        // uint64 _nonce, // Nonce is available from lzReceive if needed
        bytes calldata _payload
    ) internal {
        require(_srcChainId == trustedSrcChainId, "ORD: Invalid source chain");
        require(
            keccak256(_srcAddress) == keccak256(trustedSrcAppAddress),
            "ORD: Invalid source address"
        );

        PriceMsg memory decodedMsg = abi.decode(_payload, (PriceMsg));
        require(decodedMsg.price > 0, "ORD: Decoded price is zero");
        require(decodedMsg.ts > 0 && decodedMsg.ts <= block.timestamp, "ORD: Invalid decoded timestamp");


        _priceInfos[decodedMsg.assetId] = PriceInfo({
            price: decodedMsg.price,
            lastUpdatedAt: decodedMsg.ts
        });

        if (!_supportedAssetIds.contains(decodedMsg.assetId)) {
            _supportedAssetIds.add(decodedMsg.assetId);
            emit AssetSupported(decodedMsg.assetId, true);
        }

        emit PriceReceivedAndStored(
            decodedMsg.assetId,
            decodedMsg.price,
            decodedMsg.ts,
            _srcChainId,
            _srcAddress
        );
    }

    /**
     * @notice Owner can manually set/update a price for an asset.
     * @dev Use cautiously, e.g., for assets not relayed via L0 or in emergencies.
     *      The timestamp should be the current block.timestamp or a recent, verifiable time.
     * @param assetId The assetId to update.
     * @param price The price to set (with appropriate decimals).
     * @param timestamp The timestamp to associate with this manual update.
     */
    function forcePrice(uint256 assetId, uint256 price, uint32 timestamp) external onlyOwner {
        require(price > 0, "ORD: Forced price is zero");
        require(timestamp > 0 && timestamp <= block.timestamp, "ORD: Invalid forced timestamp");

        _priceInfos[assetId] = PriceInfo({
            price: price,
            lastUpdatedAt: timestamp
        });

        if (!_supportedAssetIds.contains(assetId)) {
            _supportedAssetIds.add(assetId);
            emit AssetSupported(assetId, true);
        }
        emit ManualPriceForced(assetId, price, timestamp);
    }

    /**
     * @notice Allows the owner to explicitly mark an assetId as supported or unsupported
     *         for price queries, independent of whether a price has been received.
     * @dev Useful for pre-configuring assets or disabling a problematic one.
     * @param assetId The assetId to configure.
     * @param isSupported True to mark as supported, false to mark as unsupported.
     */
    function setAssetSupport(uint256 assetId, bool isSupported) external onlyOwner {
        if (isSupported) {
            _supportedAssetIds.add(assetId);
        } else {
            _supportedAssetIds.remove(assetId);
            // Consider if also clearing _priceInfos[assetId] is desired when unsupporting.
            // delete _priceInfos[assetId]; // This would make it unavailable immediately.
        }
        emit AssetSupported(assetId, isSupported);
    }


    // --- IOracleRelayer Implementation ---

    /**
     * @inheritdoc IOracleRelayer
     */
    function getPrice(uint256 assetId) external view override returns (uint256) {
        PriceInfo storage info = _priceInfos[assetId];
        require(_supportedAssetIds.contains(assetId), "ORD: Asset not supported");
        require(info.lastUpdatedAt > 0, "ORD: Price not available");
        require(block.timestamp - info.lastUpdatedAt <= staleToleranceSec, "ORD: Price is stale");
        return info.price;
    }

    /**
     * @inheritdoc IOracleRelayer
     */
    function getPriceData(uint256 assetId) external view override returns (uint256 price, uint32 lastUpdatedAt) {
        PriceInfo storage info = _priceInfos[assetId];
        require(_supportedAssetIds.contains(assetId), "ORD: Asset not supported");
        require(info.lastUpdatedAt > 0, "ORD: Price not available for asset");
        return (info.price, info.lastUpdatedAt);
    }

    /**
     * @inheritdoc IOracleRelayer
     */
    function isPriceStale(uint256 assetId) external view override returns (bool) {
        if (!_supportedAssetIds.contains(assetId)) return true; // Not supported is stale
        PriceInfo storage info = _priceInfos[assetId];
        if (info.lastUpdatedAt == 0) return true; // Not available is stale
        return (block.timestamp - info.lastUpdatedAt > staleToleranceSec);
    }

    // staleToleranceSec() is already public and part of IOracleRelayer

    // --- ILayerZeroUserApplicationConfig Implementation ---

    /**
     * @inheritdoc ILayerZeroUserApplicationConfig
     * @dev Delegates to the LayerZero Endpoint. Only callable by the owner.
     */
    function setConfig(uint16 _version, uint16 _chainId, uint _configType, bytes calldata _config) external override onlyOwner {
        lzEndpoint.setConfig(_version, _chainId, _configType, _config);
    }

    /**
     * @inheritdoc ILayerZeroUserApplicationConfig
     * @dev Delegates to the LayerZero Endpoint. Only callable by the owner.
     */
    function setSendVersion(uint16 _version) external override onlyOwner {
        lzEndpoint.setSendVersion(_version);
    }

    /**
     * @inheritdoc ILayerZeroUserApplicationConfig
     * @dev Delegates to the LayerZero Endpoint. Only callable by the owner.
     */
    function setReceiveVersion(uint16 _version) external override onlyOwner {
        lzEndpoint.setReceiveVersion(_version);
    }

    /**
     * @inheritdoc ILayerZeroReceiver
     * @dev Main LayerZero message handler. Must be called by the LayerZero Endpoint.
     */
    function lzReceive(uint16 _srcChainId, bytes calldata _srcAddress, uint64 _nonce, bytes calldata _payload) external override {
        require(msg.sender == address(lzEndpoint), "ORD: Caller is not LZ Endpoint");
        _handleLzMessage(_srcChainId, _srcAddress, _payload); // Pass nonce if _handleLzMessage uses it
    }

    /**
     * @inheritdoc ILayerZeroUserApplicationConfig
     * @dev Delegates to the LayerZero Endpoint. Only callable by the owner.
     */
    function forceResumeReceive(uint16 _srcChainId, bytes calldata _srcAddress) external override onlyOwner {
        lzEndpoint.forceResumeReceive(_srcChainId, _srcAddress);
    }

    // --- View functions for supported assets ---
    function isAssetSupported(uint256 assetId) external view returns (bool) {
        return _supportedAssetIds.contains(assetId);
    }

    function getSupportedAssetIdsCount() external view returns (uint256) {
        return _supportedAssetIds.length();
    }

    function getSupportedAssetIdAtIndex(uint256 index) external view returns (uint256) {
        return _supportedAssetIds.at(index);
    }
}