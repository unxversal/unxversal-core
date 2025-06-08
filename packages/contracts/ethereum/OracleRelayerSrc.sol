// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Strings.sol"; // For error messages
import "../interfaces/ILayerZeroEndpoint.sol"; // Assumes ILayerZeroEndpoint.sol is in packages/contracts/interfaces/
import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title OracleRelayerSrc
 * @author Unxversal Team
 * @notice Relays price data from Chainlink on a source chain (e.g., Polygon)
 *         to a destination chain (Peaq) via LayerZero.
 * @dev Manages Chainlink aggregators, price update thresholds, and LayerZero communication.
 *      The contract expects to be funded with native currency (e.g., MATIC on Polygon)
 *      by keepers to pay for LayerZero messaging fees.
 */
contract OracleRelayerSrc is Ownable, ReentrancyGuard {
    ILayerZeroEndpoint public immutable lzEndpoint;

    uint16 public dstChainId;           // LayerZero chain ID of the destination (Peaq)
    bytes public dstAppAddress;        // OracleRelayerDst address on Peaq (LayerZero packed bytes format)

    struct OracleConfig {
        AggregatorV3Interface aggregator;
        uint256 priceDeviationThresholdBps; // Basis points, e.g., 50 for 0.5%
        uint32 timeUpdateThresholdSec;    // Seconds, e.g., 3600 for 1 hour
        uint256 lastSentPrice;            // Last price sent for this asset
        uint32 lastSentTimestamp;         // Block timestamp when the last price was sent
        bool isActive;                    // Flag to enable/disable updates for this oracle
    }

    mapping(uint256 => OracleConfig) public oracleConfigs; // assetId => OracleConfig
    // To iterate over configured assets if needed by off-chain services (optional)
    uint256[] public configuredAssetIds;
    mapping(uint256 => uint256) private _assetIdToIndex; // For O(1) removal from configuredAssetIds

    bytes public defaultAdapterParams; // Default adapter parameters for LayerZero send

    uint256 public constant BPS_DENOMINATOR = 10000;

    event PriceSent(
        uint256 indexed assetId,
        uint256 price,
        uint32 oracleTimestamp, // Timestamp from Chainlink
        uint16 indexed dstChainId,
        uint256 lzNativeFeePaidByCaller
    );
    event OracleConfigured(
        uint256 indexed assetId,
        address aggregator,
        uint256 priceDeviationThresholdBps,
        uint32 timeUpdateThresholdSec,
        bool isActive
    );
    event OracleActivationChanged(uint256 indexed assetId, bool isActive);
    event DstAppSet(uint16 newDstChainId, bytes newDstAppAddress);
    event DefaultAdapterParamsSet(bytes params);
    event FundsWithdrawn(address indexed to, uint256 amount);

    modifier onlyActiveOracle(uint256 assetId) {
        require(oracleConfigs[assetId].isActive, "ORS: Oracle for assetId is not active");
        _;
    }

    /**
     * @param _lzEndpointAddress The address of the LayerZero Endpoint on the source chain (e.g., Polygon).
     * @param _initialOwner The initial owner (multisig/DAO Timelock) of this contract.
     */
    constructor(address _lzEndpointAddress, address _initialOwner) Ownable(_initialOwner) { // Ownable constructor
        require(_lzEndpointAddress != address(0), "ORS: Zero L0 endpoint");
        lzEndpoint = ILayerZeroEndpoint(_lzEndpointAddress);
        // dstChainId and dstAppAddress must be set later via setDstApp
        // defaultAdapterParams can also be set later
    }

    /**
     * @notice Sets the destination LayerZero chain ID and application address.
     * @dev Only callable by the owner.
     * @param _dstChainId The LayerZero chain ID of the Peaq network.
     * @param _dstAppAddress The address of OracleRelayerDst on Peaq, in LayerZero bytes format.
     */
    function setDstApp(uint16 _dstChainId, bytes calldata _dstAppAddress) external onlyOwner {
        require(_dstChainId != 0, "ORS: Zero dstChainId");
        require(_dstAppAddress.length > 0, "ORS: Empty dstAppAddress");
        dstChainId = _dstChainId;
        dstAppAddress = _dstAppAddress;
        emit DstAppSet(_dstChainId, _dstAppAddress);
    }

    /**
     * @notice Configures or updates an oracle for a specific asset.
     * @dev Only callable by the owner. If assetId is new, it's added.
     * @param assetId The unique identifier for the asset (e.g., keccak256("BTC")).
     * @param aggregatorAddress The address of the Chainlink AggregatorV3Interface.
     * @param priceDeviationThresholdBps Price change (in BPS) from lastSentPrice to trigger an update. (e.g., 50 for 0.5%).
     * @param timeUpdateThresholdSec Time (in seconds) since lastSentTimestamp to trigger an update (e.g., 3600 for 1 hr).
     * @param isActive Sets the oracle to active or inactive. Inactive oracles won't send updates.
     */
    function configureOracle(
        uint256 assetId,
        address aggregatorAddress,
        uint256 priceDeviationThresholdBps,
        uint32 timeUpdateThresholdSec,
        bool isActive
    ) external onlyOwner {
        require(aggregatorAddress != address(0), "ORS: Zero aggregator address");
        require(priceDeviationThresholdBps < BPS_DENOMINATOR, "ORS: Invalid deviation threshold");

        OracleConfig storage config = oracleConfigs[assetId];
        bool isNewAsset = (address(config.aggregator) == address(0));

        config.aggregator = AggregatorV3Interface(aggregatorAddress);
        config.priceDeviationThresholdBps = priceDeviationThresholdBps;
        config.timeUpdateThresholdSec = timeUpdateThresholdSec;
        config.isActive = isActive;
        // lastSentPrice and lastSentTimestamp remain or are 0 if new/reset

        if (isNewAsset) {
            configuredAssetIds.push(assetId);
            _assetIdToIndex[assetId] = configuredAssetIds.length - 1;
        }
        // If re-configuring, index remains. If deactivating then reactivating, it's already tracked.

        emit OracleConfigured(assetId, aggregatorAddress, priceDeviationThresholdBps, timeUpdateThresholdSec, isActive);
    }

    /**
     * @notice Activates or deactivates an existing oracle configuration.
     * @dev Only callable by the owner.
     * @param assetId The assetId of the oracle to modify.
     * @param isActive True to activate, false to deactivate.
     */
    function setOracleActive(uint256 assetId, bool isActive) external onlyOwner {
        OracleConfig storage config = oracleConfigs[assetId];
        require(address(config.aggregator) != address(0), "ORS: Oracle not configured for assetId");
        config.isActive = isActive;
        emit OracleActivationChanged(assetId, isActive);
    }

    // Function to remove an oracle config (optional, consider implications for configuredAssetIds array)
    // function removeOracleConfig(uint256 assetId) external onlyOwner { ... }


    /**
     * @notice Sets the default adapter parameters for LayerZero send calls.
     * @dev Used for specifying gas airdrops or other relayer instructions for `lzReceive` on Peaq.
     *      Example: `abi.encodePacked(uint16(1), uint256(250000))` for version 1, 250k gas airdrop.
     * @param _params The encoded adapter parameters.
     */
    function setDefaultAdapterParams(bytes calldata _params) external onlyOwner {
        // Basic validation: often params start with uint16 version.
        // require(_params.length >= 2, "ORS: Adapter params too short");
        defaultAdapterParams = _params;
        emit DefaultAdapterParamsSet(_params);
    }

    /**
     * @notice Fetches the current price from Chainlink for an asset and sends it via LayerZero if thresholds are met.
     * @dev This function is payable; msg.value is used for LayerZero fees. Called by keepers.
     * @param assetId The assetId to update.
     * @param adapterParams Custom adapter parameters for this send, overrides defaultAdapterParams if provided.
     */
    function updateAndSendPrice(uint256 assetId, bytes calldata adapterParams)
        external
        payable
        nonReentrant
        onlyActiveOracle(assetId)
    {
        require(dstChainId != 0 && dstAppAddress.length > 0, "ORS: Destination not set");

        OracleConfig storage config = oracleConfigs[assetId]; // Already checked for existence by onlyActiveOracle

        // Chainlink data fetching
        (
            /*uint80 roundId*/,
            int256 currentPriceInt,
            /*uint256 startedAt*/,
            uint256 updatedAtChainlinkTimestamp, // This is uint256 from Chainlink
            /*uint80 answeredInRound*/
        ) = config.aggregator.latestRoundData();

        require(currentPriceInt > 0, "ORS: Chainlink price is not positive");
        uint256 currentPrice = uint256(currentPriceInt);
        // Ensure Chainlink timestamp is reasonable; convert to uint32
        require(updatedAtChainlinkTimestamp <= block.timestamp, "ORS: Chainlink timestamp in future");
        require(updatedAtChainlinkTimestamp > 0, "ORS: Chainlink timestamp is zero");
        uint32 currentOracleTimestamp = uint32(updatedAtChainlinkTimestamp);


        bool shouldUpdate = false;
        if (config.lastSentTimestamp == 0) { // First time sending for this config
            shouldUpdate = true;
        } else {
            // Time threshold check (based on last *sent* time)
            if (config.timeUpdateThresholdSec > 0 &&
                (block.timestamp - config.lastSentTimestamp >= config.timeUpdateThresholdSec)) {
                shouldUpdate = true;
            }
            // Price deviation check (based on last *sent* price)
            if (!shouldUpdate && config.priceDeviationThresholdBps > 0 && config.lastSentPrice > 0) {
                uint256 priceDiff = currentPrice > config.lastSentPrice
                    ? currentPrice - config.lastSentPrice
                    : config.lastSentPrice - currentPrice;
                if ((priceDiff * BPS_DENOMINATOR) / config.lastSentPrice >= config.priceDeviationThresholdBps) {
                    shouldUpdate = true;
                }
            }
        }

        if (!shouldUpdate) {
            if (msg.value > 0) { // Refund if no update needed
                payable(msg.sender).transfer(msg.value);
            }
            return;
        }

        // Prepare LayerZero payload: { assetId, price, oracleTimestamp }
        bytes memory payload = abi.encode(assetId, currentPrice, currentOracleTimestamp);
        bytes memory chosenAdapterParams;
        if (adapterParams.length > 0) {
            chosenAdapterParams = adapterParams;          // calldata → memory copy
        } else {
            chosenAdapterParams = defaultAdapterParams;   // storage  → memory copy
        }

        // Estimate LayerZero fees
        (uint256 nativeFee, /*uint256 zroFee*/) = lzEndpoint.estimateFees(
            dstChainId,
            address(this), // This contract is the UA on the source chain
            payload,
            false,         // Pay L0 protocol fee in native currency (e.g., MATIC)
            chosenAdapterParams
        );

        require(msg.value >= nativeFee, string.concat(
                "ORS: Insufficient fee. Provided: ", Strings.toString(msg.value),
                ", Required: ", Strings.toString(nativeFee)
            )
        );

        // Send LayerZero message
        lzEndpoint.send{value: msg.value}(
            dstChainId,
            dstAppAddress,
            payload,
            payable(msg.sender), // Refund address for L0 overpayment of gas specified in msg.value
            address(0x0),        // ZRO payment address (if paying in ZRO, otherwise address(0))
            chosenAdapterParams
        );

        // Update last sent status
        config.lastSentPrice = currentPrice;
        config.lastSentTimestamp = uint32(block.timestamp); // Record our contract's send time

        emit PriceSent(assetId, currentPrice, currentOracleTimestamp, dstChainId, msg.value);
    }

    /**
     * @notice Allows the owner to withdraw any native currency (e.g., MATIC) balance from this contract.
     * @dev Useful for retrieving excess funds not used for LayerZero fees.
     */
    function withdrawNative(address payable _to) external onlyOwner nonReentrant {
        require(_to != address(0), "ORS: Withdraw to zero address");
        uint256 balance = address(this).balance;
        require(balance > 0, "ORS: No balance to withdraw");
        (bool success, ) = _to.call{value: balance}("");
        require(success, "ORS: Native withdrawal failed");
        emit FundsWithdrawn(_to, balance);
    }

    // Fallback function to receive native currency (e.g., ETH, MATIC) for L0 fees
    receive() external payable {}

    // --- View functions for off-chain services ---
    function getConfiguredAssetCount() external view returns (uint256) {
        return configuredAssetIds.length;
    }

    function getOracleConfig(uint256 assetId)
        external
        view
        returns (
            address aggregator,
            uint256 priceDeviationThresholdBps,
            uint32 timeUpdateThresholdSec,
            uint256 lastSentPrice,
            uint32 lastSentTimestamp,
            bool isActive
        )
    {
        OracleConfig storage config = oracleConfigs[assetId];
        return (
            address(config.aggregator),
            config.priceDeviationThresholdBps,
            config.timeUpdateThresholdSec,
            config.lastSentPrice,
            config.lastSentTimestamp,
            config.isActive
        );
    }
}