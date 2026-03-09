/// remit.md Swift SDK
///
/// Universal payment protocol for AI agents using USDC on EVM L2 chains.
///
/// ## Quick start
///
/// ```swift
/// import RemitMd
///
/// // Production
/// let wallet = try RemitWallet(privateKey: "0x...", chain: .base)
/// let tx = try await wallet.pay(to: "0xAgent...", amount: 1.00)
///
/// // Testing (no network, no real USDC)
/// let mock = MockRemit()
/// let wallet = RemitWallet(mock: mock)
/// ```
///
/// ## Documentation
/// https://remit.md/docs/getting-started/quickstart-swift
///
/// ## Source
/// https://github.com/remit-md/sdk

// All public types are defined in their respective files:
// Errors.swift, Models.swift, Wallet.swift, Mock.swift, Signer.swift
