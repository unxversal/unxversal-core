// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "../common/interfaces/IOracleRelayer.sol";
import "./interfaces/IOptionNFT.sol";
import "./interfaces/ICollateralVault.sol";

/**
 * @title OptionNFT
 * @author Unxversal Team
 * @notice ERC-721 representing crypto options with simplified logic and robust pricing
 * @dev Production-ready implementation with proper fee collection, collateral management, and DEX integration
 */
contract OptionNFT is ERC721, ERC721Enumerable, Ownable, ReentrancyGuard, Pausable, IOptionNFT {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // --- Constants ---
    uint256 public constant BPS_PRECISION = 10000;
    uint256 public constant PRICE_PRECISION = 1e18;
    uint256 public constant MAX_EXPIRY_DAYS = 365; // Max 1 year expiry
    uint256 public constant MIN_EXPIRY_HOURS = 1; // Min 1 hour expiry

    // --- State Variables ---
    IOracleRelayer public immutable oracle;
    ICollateralVault public immutable collateralVault;
    address public immutable treasuryAddress;
    
    uint256 private _nextTokenId = 1;
    
    // Option data
    mapping(uint256 => OptionDetails) public options;
    
    // Fee configuration
    uint256 public exerciseFeeBps = 50; // 0.5% exercise fee
    uint256 public protocolFeeBps = 25; // 0.25% protocol fee on premium
    
    // Asset oracle mappings  
    mapping(address => uint256) public assetToOracleId;
    
    // Events
    event AssetOracleSet(address indexed asset, uint256 oracleId);
    event ExerciseFeeSet(uint256 newFeeBps);
    event ProtocolFeeSet(uint256 newFeeBps);
    event OptionBought(uint256 indexed tokenId, address indexed buyer, uint256 premium);

    constructor(
        string memory name,
        string memory symbol,
        address _oracle,
        address _collateralVault,
        address _treasuryAddress,
        address _owner
    ) ERC721(name, symbol) Ownable(_owner) {
        require(_oracle != address(0), "OptionNFT: Zero oracle");
        require(_collateralVault != address(0), "OptionNFT: Zero vault");
        require(_treasuryAddress != address(0), "OptionNFT: Zero treasury");
        
        oracle = IOracleRelayer(_oracle);
        collateralVault = ICollateralVault(_collateralVault);
        treasuryAddress = _treasuryAddress;
    }

    // --- Admin Functions ---
    function setAssetOracle(address asset, uint256 oracleId) external onlyOwner {
        require(asset != address(0), "OptionNFT: Zero asset");
        assetToOracleId[asset] = oracleId;
        emit AssetOracleSet(asset, oracleId);
    }

    function setExerciseFeeBps(uint256 _feeBps) external onlyOwner {
        require(_feeBps <= 1000, "OptionNFT: Fee too high"); // Max 10%
        exerciseFeeBps = _feeBps;
        emit ExerciseFeeSet(_feeBps);
    }

    function setProtocolFeeBps(uint256 _feeBps) external onlyOwner {
        require(_feeBps <= 500, "OptionNFT: Fee too high"); // Max 5%
        protocolFeeBps = _feeBps;
        emit ProtocolFeeSet(_feeBps);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // --- Core Functions ---
    function writeOption(
        address underlying,
        address quote,
        uint256 strikePrice,
        uint64 expiry,
        OptionType optionType,
        uint256 premium
    ) external nonReentrant whenNotPaused returns (uint256 tokenId) {
        require(underlying != address(0) && quote != address(0), "OptionNFT: Zero address");
        require(strikePrice > 0, "OptionNFT: Zero strike");
        require(premium > 0, "OptionNFT: Zero premium");
        require(expiry > block.timestamp + MIN_EXPIRY_HOURS * 3600, "OptionNFT: Expiry too soon");
        require(expiry <= block.timestamp + MAX_EXPIRY_DAYS * 86400, "OptionNFT: Expiry too far");
        require(assetToOracleId[underlying] > 0, "OptionNFT: Underlying not supported");
        require(assetToOracleId[quote] > 0, "OptionNFT: Quote not supported");

        // Calculate required collateral
        uint256 collateralRequired = getRequiredCollateral(underlying, quote, strikePrice, optionType);
        
        tokenId = _nextTokenId++;
        
        // Create option
        options[tokenId] = OptionDetails({
            underlying: underlying,
            quote: quote,
            strikePrice: strikePrice,
            expiry: expiry,
            optionType: optionType,
            writer: msg.sender,
            premium: premium,
            state: OptionState.Active,
            collateralLocked: collateralRequired
        });

        // Lock collateral
        address collateralToken = (optionType == OptionType.Call) ? underlying : quote;
        IERC20(collateralToken).safeTransferFrom(msg.sender, address(collateralVault), collateralRequired);
        collateralVault.lockCollateral(msg.sender, collateralToken, collateralRequired, tokenId);

        // Mint NFT to writer
        _safeMint(msg.sender, tokenId);

        emit OptionWritten(
            tokenId,
            msg.sender,
            underlying,
            quote,
            strikePrice,
            expiry,
            optionType,
            premium
        );
    }

    function buyOption(uint256 tokenId) external nonReentrant whenNotPaused {
        OptionDetails storage option = options[tokenId];
        require(option.state == OptionState.Active, "OptionNFT: Option not active");
        require(block.timestamp < option.expiry, "OptionNFT: Option expired");
        require(ownerOf(tokenId) == option.writer, "OptionNFT: Not writer owned");

        address buyer = msg.sender;
        uint256 premium = option.premium;
        uint256 protocolFee = (premium * protocolFeeBps) / BPS_PRECISION;
        uint256 writerPayment = premium - protocolFee;

        // Buyer pays premium
        IERC20(option.quote).safeTransferFrom(buyer, option.writer, writerPayment);
        
        if (protocolFee > 0) {
            IERC20(option.quote).safeTransferFrom(buyer, treasuryAddress, protocolFee);
        }

        // Transfer NFT to buyer
        _transfer(option.writer, buyer, tokenId);

        emit OptionBought(tokenId, buyer, premium);
    }

    function exerciseOption(uint256 tokenId) external nonReentrant whenNotPaused returns (uint256 payout) {
        require(ownerOf(tokenId) == msg.sender, "OptionNFT: Not owner");
        
        OptionDetails storage option = options[tokenId];
        require(option.state == OptionState.Active, "OptionNFT: Option not active");
        require(block.timestamp < option.expiry, "OptionNFT: Option expired");
        require(isInTheMoney(tokenId), "OptionNFT: Not in the money");

        address holder = msg.sender;
        uint256 exerciseValue = getExerciseValue(tokenId);
        uint256 exerciseFee = (exerciseValue * exerciseFeeBps) / BPS_PRECISION;
        payout = exerciseValue - exerciseFee;

        option.state = OptionState.Exercised;

        if (option.optionType == OptionType.Call) {
            // Call: holder pays strike, gets underlying
            uint256 strikePayment = _normalizeAmount(option.strikePrice, option.quote);
            
            // Holder pays strike + fee
            IERC20(option.quote).safeTransferFrom(holder, option.writer, strikePayment);
            if (exerciseFee > 0) {
                // Fee paid in quote asset (converted from underlying value)
                uint256 feeInQuote = _convertToQuoteAsset(exerciseFee, option.underlying, option.quote);
                IERC20(option.quote).safeTransferFrom(holder, treasuryAddress, feeInQuote);
            }

            // Release underlying collateral to holder
            uint256 underlyingAmount = _normalizeAmount(PRICE_PRECISION, option.underlying);
            collateralVault.releaseCollateral(option.writer, option.underlying, underlyingAmount, tokenId);
            IERC20(option.underlying).safeTransfer(holder, underlyingAmount);
            
            payout = underlyingAmount;
        } else {
            // Put: holder pays underlying, gets strike value
            uint256 underlyingAmount = _normalizeAmount(PRICE_PRECISION, option.underlying);
            
            // Holder pays underlying
            IERC20(option.underlying).safeTransferFrom(holder, option.writer, underlyingAmount);
            
            // Release quote collateral to holder (minus fee)
            uint256 strikeAmount = _normalizeAmount(option.strikePrice, option.quote);
            uint256 feeInQuote = _convertToQuoteAsset(exerciseFee, option.underlying, option.quote);
            uint256 netPayout = strikeAmount - feeInQuote;
            
            collateralVault.releaseCollateral(option.writer, option.quote, strikeAmount, tokenId);
            IERC20(option.quote).safeTransfer(holder, netPayout);
            if (feeInQuote > 0) {
                IERC20(option.quote).safeTransfer(treasuryAddress, feeInQuote);
            }
            
            payout = netPayout;
        }

        // Burn the exercised option
        _burn(tokenId);

        uint256 profit = exerciseValue - 
            ((option.optionType == OptionType.Call) ? 
                _normalizeAmount(option.strikePrice, option.quote) : 
                _convertToQuoteAsset(_normalizeAmount(PRICE_PRECISION, option.underlying), option.underlying, option.quote)
            );

        emit OptionExercised(tokenId, holder, payout, profit);
    }

    function claimExpiredCollateral(uint256 tokenId) external nonReentrant returns (uint256 collateral) {
        OptionDetails storage option = options[tokenId];
        require(option.writer == msg.sender, "OptionNFT: Not writer");
        require(option.state == OptionState.Active, "OptionNFT: Option not active");
        require(block.timestamp >= option.expiry, "OptionNFT: Not expired");

        option.state = OptionState.Expired;
        collateral = option.collateralLocked;

        // Release collateral back to writer
        address collateralToken = (option.optionType == OptionType.Call) ? option.underlying : option.quote;
        collateralVault.releaseCollateral(option.writer, collateralToken, collateral, tokenId);
        IERC20(collateralToken).safeTransfer(option.writer, collateral);

        emit OptionExpired(tokenId, option.writer, collateral);
    }

    // --- View Functions ---
    function getOptionDetails(uint256 tokenId) external view returns (OptionDetails memory) {
        return options[tokenId];
    }

    function isInTheMoney(uint256 tokenId) public view returns (bool) {
        OptionDetails memory option = options[tokenId];
        uint256 currentPrice = _getCurrentPrice(option.underlying, option.quote);
        
        if (option.optionType == OptionType.Call) {
            return currentPrice > option.strikePrice;
        } else {
            return currentPrice < option.strikePrice;
        }
    }

    function getExerciseValue(uint256 tokenId) public view returns (uint256) {
        OptionDetails memory option = options[tokenId];
        
        if (!isInTheMoney(tokenId)) {
            return 0;
        }

        uint256 currentPrice = _getCurrentPrice(option.underlying, option.quote);
        
        if (option.optionType == OptionType.Call) {
            // Call value = (current price - strike price) * amount
            return ((currentPrice - option.strikePrice) * PRICE_PRECISION) / PRICE_PRECISION;
        } else {
            // Put value = (strike price - current price) * amount  
            return ((option.strikePrice - currentPrice) * PRICE_PRECISION) / PRICE_PRECISION;
        }
    }

    function getRequiredCollateral(
        address underlying,
        address quote,
        uint256 strikePrice,
        OptionType optionType
    ) public view returns (uint256) {
        if (optionType == OptionType.Call) {
            // Call: lock 1 unit of underlying
            return _normalizeAmount(PRICE_PRECISION, underlying);
        } else {
            // Put: lock strike value in quote asset
            return _normalizeAmount(strikePrice, quote);
        }
    }

    // --- Internal Functions ---
    function _getCurrentPrice(address underlying, address quote) internal view returns (uint256) {
        uint256 underlyingPrice = oracle.getPrice(assetToOracleId[underlying]);
        uint256 quotePrice = oracle.getPrice(assetToOracleId[quote]);
        
        require(underlyingPrice > 0 && quotePrice > 0, "OptionNFT: Invalid oracle price");
        
        // Return price as underlying/quote in 1e18 precision
        return (underlyingPrice * PRICE_PRECISION) / quotePrice;
    }

    function _normalizeAmount(uint256 amount, address token) internal view returns (uint256) {
        uint8 decimals = IERC20Metadata(token).decimals();
        return (amount * (10 ** decimals)) / PRICE_PRECISION;
    }

    function _convertToQuoteAsset(uint256 amount, address fromAsset, address toAsset) internal view returns (uint256) {
        uint256 fromPrice = oracle.getPrice(assetToOracleId[fromAsset]);
        uint256 toPrice = oracle.getPrice(assetToOracleId[toAsset]);
        
        uint8 toDecimals = IERC20Metadata(toAsset).decimals();
        
        return (amount * fromPrice * (10 ** toDecimals)) / (toPrice * PRICE_PRECISION);
    }

    // --- Required Overrides ---
    function _update(address to, uint256 tokenId, address auth) 
        internal 
        override(ERC721, ERC721Enumerable) 
        returns (address) 
    {
        return super._update(to, tokenId, auth);
    }

    function _increaseBalance(address account, uint128 value) 
        internal 
        override(ERC721, ERC721Enumerable) 
    {
        super._increaseBalance(account, value);
    }

    function supportsInterface(bytes4 interfaceId) 
        public 
        view 
        override(ERC721, ERC721Enumerable) 
        returns (bool) 
    {
        return super.supportsInterface(interfaceId);
    }
} 