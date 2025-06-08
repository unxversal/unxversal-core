// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/* ──────────────── OpenZeppelin ──────────────── */
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

/* ──────────────── Project deps ──────────────── */
import "./structs/SOrder.sol";
import "../interfaces/dex/IOrderNFT.sol";
import "../interfaces/dex/IDexFeeSwitch.sol";
import "./utils/PermitHelper.sol";

/**
 * @title OrderNFT
 * @author Unxversal Team
 * @notice ERC-721 that escrows sell-tokens and represents limit/TWAP orders
 */
contract OrderNFT is IOrderNFT, ERC721, ERC721Enumerable, ERC721URIStorage, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;
    using Math for uint256;

    /* ──────────────── Storage ──────────────── */

    // Regular limit orders
    mapping(uint256 => OrderLayout) public orders;
    
    // TWAP orders with additional token fields
    struct TWAPOrderStorage {
        uint256 totalAmount;      // Total amount to sell
        uint256 amountPerPeriod;  // Amount to sell per period
        uint256 period;           // Time between executions (e.g. 1 hour)
        uint256 lastExecutionTime;// Last time the TWAP was executed
        uint256 executedAmount;   // Total amount executed so far
        uint256 minPrice;         // Minimum price to execute at
        address sellToken;        // Token being sold
        address buyToken;         // Token being bought
    }
    mapping(uint256 => TWAPOrderStorage) public twapOrders;
    
    uint256 private _nextTokenId;

    IDexFeeSwitch public immutable dexFeeSwitch;
    PermitHelper public immutable permitHelper;

    uint256 public constant PRICE_PRECISION = 1e18;
    uint256 public constant MAX_FEE_BPS = 1000; // 10%
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant MIN_TWAP_PERIOD = 5 minutes;
    uint256 public constant MAX_TWAP_PERIOD = 7 days;

    /* ──────────────── Constructor ──────────────── */
    constructor(
        string memory name_,
        string memory symbol_,
        address _dexFeeSwitch,
        address _permitHelper,
        address initialOwner
    ) ERC721(name_, symbol_) Ownable(initialOwner) {
        require(_dexFeeSwitch != address(0), "OrderNFT: fee switch 0");
        require(_permitHelper != address(0), "OrderNFT: permit helper 0");
        dexFeeSwitch = IDexFeeSwitch(_dexFeeSwitch);
        permitHelper = PermitHelper(_permitHelper);
    }

    /* ──────────────── External functions ──────────────── */

    /// @inheritdoc IOrderNFT
    function createOrder(
        address sellToken,
        address buyToken,
        uint256 price,
        uint256 amount,
        uint32 expiry,
        uint8 sellDecimals,
        uint24 feeBps
    ) external override nonReentrant returns (uint256 tokenId) {
        require(sellToken != address(0) && buyToken != address(0), "OrderNFT: zero token");
        require(sellToken != buyToken, "OrderNFT: same token");
        require(amount > 0, "OrderNFT: zero amount");
        require(price > 0, "OrderNFT: zero price");
        require(expiry > block.timestamp, "OrderNFT: expiry past");
        require(feeBps <= MAX_FEE_BPS, "OrderNFT: fee > max");

        // Pull sell token
        IERC20(sellToken).safeTransferFrom(msg.sender, address(this), amount);

        // Create order
        tokenId = ++_nextTokenId;
        orders[tokenId] = OrderLayout({
            maker: msg.sender,
            expiry: expiry,
            feeBps: feeBps,
            sellDecimals: sellDecimals,
            amountRemaining: amount,
            sellToken: sellToken,
            buyToken: buyToken,
            price: price
        });

        _safeMint(msg.sender, tokenId);

        emit OrderCreated(
            tokenId,
            msg.sender,
            sellToken,
            buyToken,
            price,
            amount,
            expiry,
            sellDecimals,
            feeBps
        );
    }

    /// @inheritdoc IOrderNFT
    function createTWAPOrder(
        address sellToken,
        address buyToken,
        uint256 totalAmount,
        uint256 amountPerPeriod,
        uint256 period,
        uint256 minPrice
    ) external override nonReentrant returns (uint256 tokenId) {
        require(sellToken != address(0) && buyToken != address(0), "OrderNFT: zero token");
        require(sellToken != buyToken, "OrderNFT: same token");
        require(totalAmount > 0, "OrderNFT: zero total");
        require(amountPerPeriod > 0, "OrderNFT: zero period amount");
        require(amountPerPeriod <= totalAmount, "OrderNFT: period > total");
        require(period >= MIN_TWAP_PERIOD, "OrderNFT: period too short");
        require(period <= MAX_TWAP_PERIOD, "OrderNFT: period too long");
        require(minPrice > 0, "OrderNFT: zero min price");

        // Pull sell token
        IERC20(sellToken).safeTransferFrom(msg.sender, address(this), totalAmount);

        // Create TWAP order
        tokenId = ++_nextTokenId;
        twapOrders[tokenId] = TWAPOrderStorage({
            totalAmount: totalAmount,
            amountPerPeriod: amountPerPeriod,
            period: period,
            lastExecutionTime: block.timestamp,
            executedAmount: 0,
            minPrice: minPrice,
            sellToken: sellToken,
            buyToken: buyToken
        });

        _safeMint(msg.sender, tokenId);

        emit TWAPOrderCreated(
            tokenId,
            msg.sender,
            totalAmount,
            amountPerPeriod,
            period,
            minPrice
        );
    }

    /// @inheritdoc IOrderNFT
    function fillOrders(
        uint256[] calldata tokenIds,
        uint256[] calldata fillAmounts,
        FillParams calldata params
    ) external override nonReentrant returns (uint256[] memory amountsBought) {
        require(tokenIds.length == fillAmounts.length && tokenIds.length > 0, "OrderNFT: length mismatch");
        require(block.timestamp <= params.deadline, "OrderNFT: deadline passed");
        require(tx.gasprice <= params.maxGasPrice, "OrderNFT: gas price too high");

        address taker = msg.sender;
        amountsBought = new uint256[](tokenIds.length);
        uint256 totalBuyAmount;

        // First pass - validate and calculate amounts
        for (uint256 i = 0; i < tokenIds.length; ++i) {
            uint256 tokenId = tokenIds[i];
            uint256 wantSell = fillAmounts[i];
            require(wantSell >= params.minFillAmount, "OrderNFT: fill < min");

            OrderLayout storage o = orders[tokenId];
            require(ownerOf(tokenId) == o.maker, "OrderNFT: maker no hold");
            require(block.timestamp < o.expiry, "OrderNFT: expired");
            require(o.amountRemaining > 0, "OrderNFT: no amount left");

            uint256 sellAmt = Math.min(wantSell, o.amountRemaining);
            uint256 buyGross = Math.mulDiv(sellAmt, o.price, PRICE_PRECISION);

            // Calculate fee based on taker's tier
            IDexFeeSwitch.FeeTier memory tier = dexFeeSwitch.getUserFeeTier(taker);
            uint256 fee = (buyGross * tier.feeBps) / BPS_DENOMINATOR;
            uint256 buyNet = buyGross - fee;

            require(buyNet >= params.minAmountOut, "OrderNFT: slippage");

            // Track amounts for second pass
            amountsBought[i] = buyNet;
            totalBuyAmount += buyGross;
        }

        // Second pass - execute trades
        for (uint256 i = 0; i < tokenIds.length; ++i) {
            uint256 tokenId = tokenIds[i];
            uint256 wantSell = fillAmounts[i];
            OrderLayout storage o = orders[tokenId];

            uint256 sellAmt = Math.min(wantSell, o.amountRemaining);
            uint256 buyGross = Math.mulDiv(sellAmt, o.price, PRICE_PRECISION);

            // Calculate and distribute fees
            IDexFeeSwitch.FeeTier memory tier = dexFeeSwitch.getUserFeeTier(taker);
            uint256 fee = (buyGross * tier.feeBps) / BPS_DENOMINATOR;
            
            // Handle buy token transfers
            IERC20(o.buyToken).safeTransferFrom(taker, address(this), buyGross);

            if (fee > 0) {
                IERC20(o.buyToken).approve(address(dexFeeSwitch), fee);
                dexFeeSwitch.depositFee(o.buyToken, taker, fee, params.relayer);
            }

            uint256 buyNet = buyGross - fee;
            if (buyNet > 0) {
                IERC20(o.buyToken).safeTransfer(o.maker, buyNet);
            }

            // Handle sell token transfer
            IERC20(o.sellToken).safeTransfer(taker, sellAmt);

            // Update state
            o.amountRemaining -= sellAmt;

            emit OrderFilled(
                tokenId,
                taker,
                o.maker,
                sellAmt,
                buyNet,
                fee,
                o.amountRemaining
            );
        }
    }

    /// @inheritdoc IOrderNFT
    function executeTWAPOrder(uint256 tokenId) external override nonReentrant returns (uint256) {
        TWAPOrderStorage storage twap = twapOrders[tokenId];
        require(twap.totalAmount > 0, "OrderNFT: not TWAP");
        require(block.timestamp >= twap.lastExecutionTime + twap.period, "OrderNFT: too early");
        require(twap.executedAmount < twap.totalAmount, "OrderNFT: complete");

        uint256 remaining = twap.totalAmount - twap.executedAmount;
        uint256 executeAmount = Math.min(twap.amountPerPeriod, remaining);

        // TODO: Implement market order execution logic here
        // This would typically involve:
        // 1. Getting current market price
        // 2. Checking against minPrice
        // 3. Executing the trade
        // 4. Updating state

        twap.lastExecutionTime = block.timestamp;
        twap.executedAmount += executeAmount;

        emit TWAPOrderExecuted(
            tokenId,
            executeAmount,
            0, // Received amount from market execution
            twap.totalAmount - twap.executedAmount
        );

        return executeAmount;
    }

    /// @inheritdoc IOrderNFT
    function cancelOrders(uint256[] calldata tokenIds) external override nonReentrant {
        for (uint256 i = 0; i < tokenIds.length; ++i) {
            uint256 tokenId = tokenIds[i];
        require(ownerOf(tokenId) == msg.sender, "OrderNFT: not owner");

            // Handle regular orders
            OrderLayout storage o = orders[tokenId];
            if (o.maker == msg.sender && o.amountRemaining > 0) {
        uint256 refund = o.amountRemaining;
        o.amountRemaining = 0;
                if (refund > 0) {
                    IERC20(o.sellToken).safeTransfer(msg.sender, refund);
                }
                emit OrderCancelled(tokenId, msg.sender, refund);
                continue;
            }

            // Handle TWAP orders
            TWAPOrderStorage storage twap = twapOrders[tokenId];
            if (twap.totalAmount > 0) {
                uint256 refund = twap.totalAmount - twap.executedAmount;
                if (refund > 0) {
                    IERC20(twap.sellToken).safeTransfer(msg.sender, refund);
                }
                delete twapOrders[tokenId];
                emit OrderCancelled(tokenId, msg.sender, refund);
            }
        }
    }

    /* ──────────────── View functions ──────────────── */

    /// @inheritdoc IOrderNFT
    function getOrder(uint256 tokenId) external view override returns (OrderLayout memory) {
        return orders[tokenId];
    }

    /// @inheritdoc IOrderNFT
    function getTWAPOrder(uint256 tokenId) external view override returns (TWAPOrder memory) {
        TWAPOrderStorage storage twap = twapOrders[tokenId];
        return TWAPOrder({
            totalAmount: twap.totalAmount,
            amountPerPeriod: twap.amountPerPeriod,
            period: twap.period,
            lastExecutionTime: twap.lastExecutionTime,
            executedAmount: twap.executedAmount,
            minPrice: twap.minPrice
        });
    }

    /* ──────────────── Metadata ──────────────── */
    function _baseURI() internal pure override returns (string memory) {
        return "https://metadata.unxversal.xyz/order/";
    }

    function tokenURI(uint256 tokenId)
        public view
        override(ERC721, ERC721URIStorage)
        returns (string memory)
    {
        _requireOwned(tokenId);
        return string(abi.encodePacked(_baseURI(), Strings.toString(tokenId)));
    }

    /* ──────────────── OpenZeppelin 5 hook reconciliation ──────────────── */
    function _increaseBalance(address account, uint128 value)
        internal
        override(ERC721, ERC721Enumerable)
    {
        super._increaseBalance(account, value); // Enumerable keeps its own counters
    }

    function _update(address to, uint256 tokenId, address auth)
        internal
        override(ERC721, ERC721Enumerable)
        returns (address from)
    {
        from = super._update(to, tokenId, auth); // each base updates its own state
    }

    /* ──────────────── Interface support ──────────────── */
    function supportsInterface(bytes4 interfaceId)
        public view
        override(ERC721, ERC721Enumerable, ERC721URIStorage)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
