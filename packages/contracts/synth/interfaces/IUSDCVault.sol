// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IUSDCVault {
    /// @notice User position data
    struct UserPosition {
        uint256 usdcCollateral;     // Total USDC deposited by the user
        mapping(address => SynthPositionData) synthSpecifics; // sAssetAddress => SynthPositionData
    }
    
    /// @notice Individual synth position data
    struct SynthPositionData {
        uint256 amountMinted;        // Total quantity of this sAsset minted by the user
        uint256 totalUsdValueAtMint; // Aggregate USD value of `amountMinted` at the time(s) of minting
    }

    /// @notice Emitted when collateral is deposited
    event CollateralDeposited(address indexed user, uint256 amountUsdc);
    
    /// @notice Emitted when collateral is withdrawn
    event CollateralWithdrawn(address indexed user, uint256 amountUsdc);
    
    /// @notice Emitted when synth is minted
    event SynthMinted(
        address indexed user,
        address indexed synthAddress,
        uint256 assetId,
        uint256 amountSynthMinted,
        uint256 usdValueMinted,
        uint256 usdcCollateralizedForMint,
        uint256 feePaid
    );
    
    /// @notice Emitted when synth is burned
    event SynthBurned(
        address indexed user,
        address indexed synthAddress,
        uint256 assetId,
        uint256 amountSynthBurned,
        uint256 usdValueRepaid,
        uint256 usdcReturned,
        uint256 feePaid
    );
    
    /// @notice Emitted when position health is updated
    event PositionHealthUpdated(address indexed user, uint256 newCollateralRatioBps);
    
    /// @notice Emitted when surplus is swept to treasury
    event SurplusSweptToTreasury(uint256 amountSwept);

    /// @notice Deposits USDC collateral for a user
    function depositCollateral(uint256 amountUsdc) external;
    
    /// @notice Withdraws USDC collateral for a user
    function withdrawCollateral(uint256 amountUsdc) external;
    
    /// @notice Mints synthetic assets against collateral
    function mintSynth(address synthAddress, uint256 amountSynthToMint) external;
    
    /// @notice Burns synthetic assets to reclaim collateral
    function burnSynth(address synthAddress, uint256 amountSynthToBurn) external;
    
    /// @notice Processes liquidation (only callable by liquidation engine)
    function processLiquidation(
        address user,
        address synthToRepayAddress,
        uint256 amountSynthToRepay,
        uint256 collateralToSeizeAmountUsdc
    ) external;
    
    /// @notice Transfers USDC from vault (only callable by liquidation engine)
    function transferUSDCFromVault(address to, uint256 amountUsdc) external;
    
    /// @notice Transfers USDC to surplus buffer (only callable by liquidation engine)
    function transferUSDCFromVaultToSurplus(uint256 amountUsdc) external;
    
    /// @notice Gets user's collateralization ratio
    function getCollateralizationRatio(address user) external view returns (uint256 crBps);
    
    /// @notice Checks if position is liquidatable
    function isPositionLiquidatable(address user) external view returns (bool);
    
    /// @notice Gets user's total debt value across all synths
    function getUserTotalDebtValue(address user) external view returns (uint256);
    
    /// @notice Gets user's synth position data
    function getUserSynthPosition(address user, address synthAddress) 
        external view returns (uint256 amountMinted, uint256 totalUsdValueAtMint);
    
    /// @notice Gets user's USDC collateral balance
    function getUserCollateral(address user) external view returns (uint256);
} 