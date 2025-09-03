#[test_only]
module unxversal::test_coins {
    /// Dummy collateral type for testing generic modules that require a 'store' type parameter.
    public struct TestBaseUSD has store {}
}

