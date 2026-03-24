import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Main entry point for remit.md payments.
public final class RemitWallet: @unchecked Sendable {
    private let transport: any Transport
    private let signer: (any Signer)?
    private let signerAddress: String
    private let chain: RemitChain
    private let chainName: String
    private let rpcUrl: String
    private var contractsCache: ContractAddresses?
    private let cacheLock = NSLock()

    /// Known USDC contract addresses per chain (EIP-2612 compatible).
    public static let usdcAddresses: [String: String] = [
        "base-sepolia": "0x2d846325766921935f37d5b4478196d3ef93707c",
        "base": "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
        "localhost": "0x5FbDB2315678afecb367f032d93F642f64180aa3",
    ]

    /// Default JSON-RPC URLs per chain (for nonce fetching).
    public static let defaultRpcUrls: [String: String] = [
        "base-sepolia": "https://sepolia.base.org",
        "base": "https://mainnet.base.org",
        "localhost": "http://127.0.0.1:8545",
    ]

    public init(privateKey: String, chain: RemitChain = .base, baseURL: String? = nil, routerAddress: String? = nil, rpcUrl: String? = nil) throws {
        let signer = try PrivateKeySigner(privateKey: privateKey)
        let envURL = ProcessInfo.processInfo.environment["REMITMD_API_URL"]
        self.transport = HttpTransport(
            baseURL: baseURL ?? envURL ?? chain.baseURL,
            chainId: UInt64(chain.rawValue),
            routerAddress: routerAddress ?? "",
            signer: signer
        )
        self.signer = signer
        self.signerAddress = signer.address
        self.chain = chain
        self.chainName = chain.chainName
        self.rpcUrl = rpcUrl
            ?? ProcessInfo.processInfo.environment["REMITMD_RPC_URL"]
            ?? RemitWallet.defaultRpcUrls[chain.chainName]
            ?? RemitWallet.defaultRpcUrls["base-sepolia"]!
    }

    public init(mock: MockRemit) {
        self.transport = MockTransport(mock: mock)
        self.signer = nil
        self.signerAddress = mock.walletAddress
        self.chain = .baseSepolia
        self.chainName = "base"
        self.rpcUrl = RemitWallet.defaultRpcUrls["base-sepolia"]!
    }

    public static func fromEnvironment() throws -> RemitWallet {
        let env = ProcessInfo.processInfo.environment
        let key: String
        if let k = env["REMITMD_KEY"] {
            key = k
        } else if let k = env["REMITMD_PRIVATE_KEY"] {
            print("[remitmd] Warning: REMITMD_PRIVATE_KEY is deprecated, use REMITMD_KEY instead")
            key = k
        } else {
            throw RemitError(RemitError.unauthorized, "REMITMD_KEY environment variable not set")
        }
        let chainStr = env["REMITMD_CHAIN"] ?? "base"
        let chain: RemitChain = chainStr == "base" ? .base : .baseSepolia
        let routerAddress = env["REMITMD_ROUTER_ADDRESS"]
        let rpcUrl = env["REMITMD_RPC_URL"]
        return try RemitWallet(privateKey: key, chain: chain, routerAddress: routerAddress, rpcUrl: rpcUrl)
    }

    /// The Ethereum address (0x-prefixed) of this wallet.
    public var address: String { signerAddress }

    // MARK: - Contracts

    /// Get deployed contract addresses. Cached for the lifetime of this client instance.
    public func getContracts() async throws -> ContractAddresses {
        cacheLock.lock()
        if let cached = contractsCache {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()
        let contracts: ContractAddresses = try await transport.request(
            method: "GET", path: "/api/v1/contracts", body: Optional<EmptyBody>.none
        )
        cacheLock.lock()
        contractsCache = contracts
        cacheLock.unlock()
        return contracts
    }

    // MARK: - Direct payment

    public func pay(to recipient: String, amount: Double, memo: String? = nil, permit: PermitSignature? = nil) async throws -> Transaction {
        try validateAddress(recipient)
        try validateAmount(amount)
        let resolved: PermitSignature?
        if let p = permit {
            resolved = p
        } else if signer != nil {
            resolved = try await autoPermit(contract: "router", amount: amount)
        } else {
            resolved = nil
        }
        return try await transport.request(
            method: "POST", path: "/api/v1/payments/direct",
            body: PayBody(to: recipient, amount: amount, memo: memo, permit: resolved)
        )
    }

    // MARK: - Escrow

    public func createEscrow(recipient: String, amount: Double, conditions: String? = nil, permit: PermitSignature? = nil) async throws -> Escrow {
        try validateAddress(recipient)
        try validateAmount(amount)
        let resolved: PermitSignature?
        if let p = permit {
            resolved = p
        } else if signer != nil {
            resolved = try await autoPermit(contract: "escrow", amount: amount)
        } else {
            resolved = nil
        }

        // Step 1: create invoice on server.
        let invoiceId = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(32).lowercased()
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(32).lowercased()
        let _: InvoiceResponse = try await transport.request(
            method: "POST", path: "/api/v1/invoices",
            body: InvoiceBody(
                id: String(invoiceId), chain: chainName,
                from_agent: signerAddress.lowercased(), to_agent: recipient.lowercased(),
                amount: String(format: "%.6f", amount), type: "escrow",
                task: conditions ?? "", nonce: String(nonce), signature: "0x"
            )
        )

        // Step 2: fund the escrow.
        return try await transport.request(
            method: "POST", path: "/api/v1/escrows",
            body: EscrowFundBody(invoice_id: String(invoiceId), permit: resolved)
        )
    }

    public func claimStart(id: String) async throws -> Escrow {
        return try await transport.request(
            method: "POST", path: "/api/v1/escrows/\(id)/claim-start", body: Optional<EmptyBody>.none
        )
    }

    public func getEscrow(id: String) async throws -> Escrow {
        return try await transport.request(
            method: "GET", path: "/api/v1/escrows/\(id)", body: Optional<EmptyBody>.none
        )
    }

    public func releaseEscrow(id: String) async throws -> Escrow {
        return try await transport.request(
            method: "POST", path: "/api/v1/escrows/\(id)/release", body: Optional<EmptyBody>.none
        )
    }

    public func cancelEscrow(id: String) async throws -> Escrow {
        return try await transport.request(
            method: "POST", path: "/api/v1/escrows/\(id)/cancel", body: Optional<EmptyBody>.none
        )
    }

    // MARK: - Metered tabs

    /// Open a metered payment tab. The payer pre-funds up to `limitAmount` USDC;
    /// the provider charges `perUnit` USDC per API call.
    public func openTab(provider: String, limitAmount: Double, perUnit: Double,
                        expiresIn: TimeInterval = 86400, permit: PermitSignature? = nil) async throws -> Tab {
        try validateAddress(provider)
        try validateAmount(limitAmount)
        let resolved: PermitSignature?
        if let p = permit {
            resolved = p
        } else if signer != nil {
            resolved = try await autoPermit(contract: "tab", amount: limitAmount)
        } else {
            resolved = nil
        }
        let expiry = Int(Date().timeIntervalSince1970) + Int(expiresIn)
        return try await transport.request(
            method: "POST", path: "/api/v1/tabs",
            body: TabBody(chain: chainName, provider: provider, limit_amount: limitAmount,
                          per_unit: perUnit, expiry: expiry, permit: resolved)
        )
    }

    /// Charge a tab using EIP-712 signed authorization from the provider.
    public func chargeTab(id: String, amount: Double, cumulative: Double,
                          callCount: Int, providerSig: String) async throws -> TabCharge {
        try validateAmount(amount)
        return try await transport.request(
            method: "POST", path: "/api/v1/tabs/\(id)/charge",
            body: ChargeTabBody(amount: amount, cumulative: cumulative,
                                call_count: callCount, provider_sig: providerSig)
        )
    }

    /// Close a tab with optional final settlement amount and provider signature.
    public func closeTab(id: String, finalAmount: Double = 0, providerSig: String = "0x") async throws -> Tab {
        return try await transport.request(
            method: "POST", path: "/api/v1/tabs/\(id)/close",
            body: CloseTabBody(final_amount: finalAmount, provider_sig: providerSig)
        )
    }

    // MARK: - Streaming

    /// Start a per-second USDC payment stream to a payee.
    public func startStream(payee: String, ratePerSecond: Double, maxTotal: Double,
                            permit: PermitSignature? = nil) async throws -> Stream {
        try validateAddress(payee)
        guard ratePerSecond > 0 else {
            throw RemitError(RemitError.invalidAmount, "ratePerSecond must be positive")
        }
        try validateAmount(maxTotal)
        let resolved: PermitSignature?
        if let p = permit {
            resolved = p
        } else if signer != nil {
            resolved = try await autoPermit(contract: "stream", amount: maxTotal)
        } else {
            resolved = nil
        }
        return try await transport.request(
            method: "POST", path: "/api/v1/streams",
            body: StreamBody(chain: chainName, payee: payee, rate_per_second: ratePerSecond,
                             max_total: maxTotal, permit: resolved)
        )
    }

    /// Close an active payment stream.
    public func closeStream(id: String) async throws -> Stream {
        return try await transport.request(
            method: "POST", path: "/api/v1/streams/\(id)/close",
            body: EmptyObject()
        )
    }

    // MARK: - Bounties

    /// Post a USDC bounty for task completion.
    public func postBounty(amount: Double, taskDescription: String, deadline: Int,
                           maxAttempts: Int = 10, permit: PermitSignature? = nil) async throws -> Bounty {
        try validateAmount(amount)
        guard !taskDescription.isEmpty else {
            throw RemitError(RemitError.serverError, "bounty task_description must not be empty")
        }
        let resolved: PermitSignature?
        if let p = permit {
            resolved = p
        } else if signer != nil {
            resolved = try await autoPermit(contract: "bounty", amount: amount)
        } else {
            resolved = nil
        }
        return try await transport.request(
            method: "POST", path: "/api/v1/bounties",
            body: BountyBody(chain: chainName, amount: amount, task_description: taskDescription,
                             deadline: deadline, max_attempts: maxAttempts, permit: resolved)
        )
    }

    /// Submit evidence to claim a bounty.
    public func submitBounty(id: String, evidenceHash: String) async throws -> BountySubmission {
        return try await transport.request(
            method: "POST", path: "/api/v1/bounties/\(id)/submit",
            body: SubmitBountyBody(evidence_hash: evidenceHash)
        )
    }

    /// Award a bounty to a specific submission.
    public func awardBounty(id: String, submissionId: Int) async throws -> Bounty {
        return try await transport.request(
            method: "POST", path: "/api/v1/bounties/\(id)/award",
            body: AwardBody(submission_id: submissionId)
        )
    }

    public func listBounties(
        status: String? = "open",
        poster: String? = nil,
        submitter: String? = nil,
        limit: Int = 20
    ) async throws -> [Bounty] {
        var params: [String] = ["limit=\(limit)"]
        if let s = status { params.append("status=\(s)") }
        if let p = poster { params.append("poster=\(p)") }
        if let s = submitter { params.append("submitter=\(s)") }
        let qs = params.joined(separator: "&")
        let resp: BountyListResponse = try await transport.request(
            method: "GET", path: "/api/v1/bounties?\(qs)",
            body: Optional<EmptyBody>.none
        )
        return resp.data
    }

    // MARK: - Deposits

    /// Place a security deposit with a provider. `expiresIn` is the duration in seconds.
    public func placeDeposit(provider: String, amount: Double, expiresIn: TimeInterval = 3600,
                             permit: PermitSignature? = nil) async throws -> Deposit {
        try validateAddress(provider)
        try validateAmount(amount)
        let resolved: PermitSignature?
        if let p = permit {
            resolved = p
        } else if signer != nil {
            resolved = try await autoPermit(contract: "deposit", amount: amount)
        } else {
            resolved = nil
        }
        let expiry = Int(Date().timeIntervalSince1970) + Int(expiresIn)
        return try await transport.request(
            method: "POST", path: "/api/v1/deposits",
            body: DepositBody(chain: chainName, provider: provider, amount: amount,
                              expiry: expiry, permit: resolved)
        )
    }

    /// Return a deposit to the payer (callable by provider).
    public func returnDeposit(id: String) async throws -> Transaction {
        return try await transport.request(
            method: "POST", path: "/api/v1/deposits/\(id)/return",
            body: EmptyObject()
        )
    }

    // MARK: - Intent

    public func expressIntent(to recipient: String, amount: Double, model: String = "direct") async throws -> Intent {
        try validateAddress(recipient)
        try validateAmount(amount)
        return try await transport.request(
            method: "POST", path: "/api/v1/intent",
            body: IntentBody(to: recipient, amount: amount, model: model)
        )
    }

    // MARK: - Analytics

    public func balance(of address: String? = nil) async throws -> Balance {
        let addr = address ?? signerAddress
        return try await transport.request(
            method: "GET", path: "/api/v1/balance/\(addr)", body: Optional<EmptyBody>.none
        )
    }

    public func reputation(of address: String? = nil) async throws -> Reputation {
        let addr = address ?? signerAddress
        return try await transport.request(
            method: "GET", path: "/api/v1/reputation/\(addr)", body: Optional<EmptyBody>.none
        )
    }

    public func spendingSummary(of address: String? = nil) async throws -> SpendingSummary {
        let addr = address ?? signerAddress
        return try await transport.request(
            method: "GET", path: "/api/v1/spending/\(addr)", body: Optional<EmptyBody>.none
        )
    }

    public func history(of address: String? = nil) async throws -> TransactionList {
        let addr = address ?? signerAddress
        return try await transport.request(
            method: "GET", path: "/api/v1/history/\(addr)", body: Optional<EmptyBody>.none
        )
    }

    public func budget(of address: String? = nil) async throws -> Budget {
        let addr = address ?? signerAddress
        return try await transport.request(
            method: "GET", path: "/api/v1/budget/\(addr)", body: Optional<EmptyBody>.none
        )
    }

    // MARK: - EIP-712 TabCharge Signing

    /// Sign a TabCharge EIP-712 struct for authorizing a tab charge.
    ///
    /// Domain: name="RemitTab", version="1", chainId=84532, verifyingContract=tabContract
    /// Type:   TabCharge(bytes32 tabId, uint96 totalCharged, uint32 callCount)
    ///
    /// `tabId` is the UUID string, ASCII-encoded as bytes32 (right-padded with zeroes).
    /// `totalCharged` is in USDC base units (6 decimals).
    public static func signTabCharge(
        signer: PrivateKeySigner,
        tabContract: String,
        tabId: String,
        totalCharged: UInt64,
        callCount: UInt32,
        chainId: UInt64 = 84532
    ) throws -> String {
        // Domain separator
        let domainTypeHash = keccak256(Data("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)".utf8))
        let nameHash = keccak256(Data("RemitTab".utf8))
        let versionHash = keccak256(Data("1".utf8))

        var domainData = Data()
        domainData.append(domainTypeHash)
        domainData.append(nameHash)
        domainData.append(versionHash)
        domainData.append(tabEncodeUint256(chainId))
        domainData.append(tabEncodeAddress(tabContract))
        let domainSep = keccak256(domainData)

        // Struct hash
        let typeHash = keccak256(Data("TabCharge(bytes32 tabId,uint96 totalCharged,uint32 callCount)".utf8))

        // Encode tabId as bytes32: ASCII chars padded to 32 bytes
        var tabIdBytes = Data(repeating: 0, count: 32)
        let ascii = Data(tabId.utf8)
        let copyLen = min(ascii.count, 32)
        tabIdBytes.replaceSubrange(0..<copyLen, with: ascii.prefix(copyLen))

        var structData = Data()
        structData.append(typeHash)
        structData.append(tabIdBytes)
        structData.append(tabEncodeUint256(totalCharged))
        structData.append(tabEncodeUint256(UInt64(callCount)))
        let structHash = keccak256(structData)

        // Final EIP-712 digest
        var finalData = Data([0x19, 0x01])
        finalData.append(domainSep)
        finalData.append(structHash)
        let digest = keccak256(finalData)

        return try signer.sign(digest: digest)
    }

    // MARK: - EIP-2612 Permit

    /// Sign an EIP-2612 permit for USDC approval.
    ///
    /// Domain: name="USD Coin", version="2", chainId, verifyingContract=USDC address
    /// Type: Permit(address owner, address spender, uint256 value, uint256 nonce, uint256 deadline)
    ///
    /// - Parameters:
    ///   - spender: Contract address that will be approved as spender (e.g. Router, Escrow).
    ///   - value: Amount in USDC base units (6 decimals).
    ///   - deadline: Permit deadline (Unix timestamp).
    ///   - nonce: Current permit nonce for this wallet (default: 0).
    ///   - usdcAddress: Override the USDC contract address. Defaults to the chain's known address.
    /// - Returns: A `PermitSignature` with value, deadline, v, r, s.
    public func signUsdcPermit(
        spender: String,
        value: UInt64,
        deadline: Int,
        nonce: Int = 0,
        usdcAddress: String? = nil
    ) throws -> PermitSignature {
        guard let signer = self.signer else {
            throw RemitError(RemitError.signatureInvalid, "Cannot sign permits in mock mode — no signer available")
        }

        let usdcAddr = usdcAddress ?? RemitWallet.usdcAddresses[chain.chainName]
        guard let usdcAddr, !usdcAddr.isEmpty else {
            throw RemitError(RemitError.chainUnavailable, "No USDC address known for chain '\(chain.chainName)' — provide usdcAddress explicitly")
        }

        // Domain separator for USDC (EIP-2612)
        let domainTypeHash = keccak256(Data("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)".utf8))
        let nameHash = keccak256(Data("USD Coin".utf8))
        let versionHash = keccak256(Data("2".utf8))

        var domainData = Data()
        domainData.append(domainTypeHash)
        domainData.append(nameHash)
        domainData.append(versionHash)
        domainData.append(permitEncodeUint256(UInt64(chain.rawValue)))
        domainData.append(permitEncodeAddress(usdcAddr))
        let domainSep = keccak256(domainData)

        // Permit struct hash
        let typeHash = keccak256(Data("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)".utf8))

        var structData = Data()
        structData.append(typeHash)
        structData.append(permitEncodeAddress(signerAddress))
        structData.append(permitEncodeAddress(spender))
        structData.append(permitEncodeUint256(value))
        structData.append(permitEncodeUint256(UInt64(nonce)))
        structData.append(permitEncodeUint256(UInt64(deadline)))
        let structHash = keccak256(structData)

        // Final EIP-712 digest
        var finalData = Data([0x19, 0x01])
        finalData.append(domainSep)
        finalData.append(structHash)
        let digest = keccak256(finalData)

        let sigHex = try signer.sign(digest: digest)

        // Parse r, s, v from 65-byte signature
        let sigStr = sigHex.hasPrefix("0x") ? String(sigHex.dropFirst(2)) : sigHex
        let r = "0x" + String(sigStr.prefix(64))
        let s = "0x" + String(sigStr.dropFirst(64).prefix(64))
        let vHex = String(sigStr.dropFirst(128).prefix(2))
        let v = Int(vHex, radix: 16) ?? 27

        return PermitSignature(value: Double(value), deadline: deadline, v: v, r: r, s: s)
    }

    /// Convenience: sign an EIP-2612 permit for USDC approval.
    /// Auto-fetches the on-chain nonce and sets a default deadline (1 hour from now).
    ///
    /// - Parameters:
    ///   - spender: Contract address that will call transferFrom (e.g. Router, Escrow).
    ///   - amount: Amount in USDC (e.g. 1.50 for $1.50).
    ///   - deadline: Optional Unix timestamp. Defaults to 1 hour from now.
    /// - Returns: A `PermitSignature`.
    public func signPermit(spender: String, amount: Double, deadline: Int? = nil) async throws -> PermitSignature {
        guard let usdcAddr = RemitWallet.usdcAddresses[chain.chainName], !usdcAddr.isEmpty else {
            throw RemitError(RemitError.chainUnavailable, "No USDC address known for chain '\(chain.chainName)'")
        }
        let nonce = try await fetchUsdcNonce(usdcAddress: usdcAddr)
        let dl = deadline ?? (Int(Date().timeIntervalSince1970) + 3600)
        let rawAmount = UInt64(round(amount * 1_000_000))
        return try signUsdcPermit(spender: spender, value: rawAmount, deadline: dl, nonce: nonce, usdcAddress: usdcAddr)
    }

    /// Internal: auto-sign a permit for the given contract type and amount.
    /// Used by payment methods when no explicit permit is provided.
    private func autoPermit(
        contract: String,
        amount: Double
    ) async throws -> PermitSignature {
        let contracts = try await getContracts()
        let spender: String
        switch contract {
        case "router":  spender = contracts.router
        case "escrow":  spender = contracts.escrow
        case "tab":     spender = contracts.tab
        case "stream":  spender = contracts.stream
        case "bounty":  spender = contracts.bounty
        case "deposit": spender = contracts.deposit
        case "relayer": spender = contracts.relayer ?? ""
        default:
            throw RemitError(RemitError.serverError, "No \(contract) contract address available")
        }
        guard !spender.isEmpty else {
            throw RemitError(RemitError.serverError, "No \(contract) contract address available")
        }
        return try await signPermit(spender: spender, amount: amount)
    }

    /// Fetch the current EIP-2612 nonce for this wallet from the USDC contract via JSON-RPC.
    private func fetchUsdcNonce(usdcAddress: String) async throws -> Int {
        // nonces(address) selector = 0x7ecebe00 + address padded to 32 bytes
        let paddedAddress = signerAddress.lowercased()
            .replacingOccurrences(of: "0x", with: "")
            .leftPad(toLength: 64, withPad: "0")
        let data = "0x7ecebe00\(paddedAddress)"

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "eth_call",
            "params": [["to": usdcAddress, "data": data], "latest"]
        ]

        guard let url = URL(string: rpcUrl) else {
            throw RemitError(RemitError.serverError, "Invalid RPC URL: \(rpcUrl)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (responseData, _) = try await URLSession.shared.data(for: request)

        guard let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw RemitError(RemitError.serverError, "Invalid JSON-RPC response")
        }

        if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
            throw RemitError(RemitError.serverError, "RPC error fetching nonce: \(message)")
        }

        guard let resultHex = json["result"] as? String else {
            throw RemitError(RemitError.serverError, "RPC returned null result for nonce query — is the USDC address correct?")
        }
        let hexStr = resultHex.hasPrefix("0x") ? String(resultHex.dropFirst(2)) : resultHex
        guard let nonce = Int(hexStr, radix: 16) else {
            throw RemitError(RemitError.serverError, "Failed to parse nonce hex '\(resultHex)' as integer")
        }
        return nonce
    }

    // MARK: - Validation

    private func validateAddress(_ address: String) throws {
        guard address.hasPrefix("0x"), address.count == 42,
              address.dropFirst(2).allSatisfy({ $0.isHexDigit }) else {
            throw RemitError.invalidAddress(address)
        }
    }

    // MARK: - Webhooks

    /// Registers a webhook endpoint to receive event notifications.
    /// - Parameters:
    ///   - url: The HTTPS endpoint that will receive POST notifications.
    ///   - events: Event types to subscribe to (e.g. ["payment.sent", "escrow.funded"]).
    ///   - chains: Optional chain names to filter by. Pass nil for all chains.
    public func registerWebhook(url: String, events: [String], chains: [String]? = nil) async throws -> Webhook {
        return try await transport.request(
            method: "POST", path: "/api/v1/webhooks",
            body: WebhookBody(url: url, events: events, chains: chains)
        )
    }

    // MARK: - One-time operator links

    /// Generate a one-time URL for the operator to fund this wallet.
    ///
    /// Non-custodial: auto-signs an EIP-2612 permit approving the server
    /// relayer to transfer USDC into the agent's wallet. If a permit is
    /// provided it is used as-is; otherwise one is signed automatically.
    ///
    /// - Parameters:
    ///   - messages: Optional chat-style messages shown on the funding page.
    ///   - agentName: Optional agent display name shown on the funding page.
    ///   - permit: Optional pre-signed permit. Auto-signed if omitted.
    public func createFundLink(messages: [LinkMessageBody]? = nil, agentName: String? = nil, permit: PermitSignature? = nil) async throws -> LinkResponse {
        let resolved: PermitSignature?
        if let p = permit {
            resolved = p
        } else if signer != nil {
            resolved = try? await autoPermit(contract: "relayer", amount: 999_999_999.0)
        } else {
            resolved = nil
        }
        let body = FundLinkBody(messages: messages, agent_name: agentName, permit: resolved)
        return try await transport.request(
            method: "POST", path: "/api/v1/links/fund", body: body
        )
    }

    /// Generate a one-time URL for the operator to withdraw funds.
    ///
    /// Non-custodial: auto-signs an EIP-2612 permit approving the server
    /// relayer to transfer USDC from the agent's wallet. If a permit is
    /// provided it is used as-is; otherwise one is signed automatically.
    ///
    /// - Parameters:
    ///   - messages: Optional chat-style messages shown on the withdraw page.
    ///   - agentName: Optional agent display name shown on the withdraw page.
    ///   - permit: Optional pre-signed permit. Auto-signed if omitted.
    public func createWithdrawLink(messages: [LinkMessageBody]? = nil, agentName: String? = nil, permit: PermitSignature? = nil) async throws -> LinkResponse {
        let resolved: PermitSignature?
        if let p = permit {
            resolved = p
        } else if signer != nil {
            resolved = try? await autoPermit(contract: "relayer", amount: 999_999_999.0)
        } else {
            resolved = nil
        }
        let body = WithdrawLinkBody(messages: messages, agent_name: agentName, permit: resolved)
        return try await transport.request(
            method: "POST", path: "/api/v1/links/withdraw", body: body
        )
    }

    // MARK: - Testnet

    /// Mint testnet USDC via POST /mint. Max $2,500 per call, once per hour per wallet.
    public func mint(amount: Double) async throws -> MintResponse {
        return try await transport.request(
            method: "POST", path: "/api/v1/mint",
            body: MintBody(wallet: signerAddress, amount: amount)
        )
    }

    private func validateAmount(_ amount: Double) throws {
        guard amount > 0 else {
            throw RemitError.invalidAmount(amount, reason: "amount must be positive")
        }
        guard amount <= 1_000_000 else {
            throw RemitError.invalidAmount(amount, reason: "amount exceeds per-transaction limit of 1,000,000 USDC")
        }
    }
}

// MARK: - Request body structs (private)

private struct EmptyBody: Codable {}
private struct EmptyObject: Codable {}

/// Chat-style message shown on a fund/withdraw page.
public struct LinkMessageBody: Codable, Sendable {
    /// "agent" or "system"
    public let role: String
    /// Message text
    public let text: String
    public init(role: String, text: String) { self.role = role; self.text = text }
}

private struct LinkBody: Codable {
    let messages: [LinkMessageBody]?
    let agent_name: String?
}
private struct FundLinkBody: Codable {
    let messages: [LinkMessageBody]?
    let agent_name: String?
    let permit: PermitSignature?
}
private struct WithdrawLinkBody: Codable {
    let messages: [LinkMessageBody]?
    let agent_name: String?
    let permit: PermitSignature?
}
private struct PayBody: Codable { let to: String; let amount: Double; let memo: String?; let permit: PermitSignature? }
private struct InvoiceBody: Codable { let id: String; let chain: String; let from_agent: String; let to_agent: String; let amount: String; let type: String; let task: String; let nonce: String; let signature: String }
private struct InvoiceResponse: Codable { let id: String? }
private struct EscrowFundBody: Codable { let invoice_id: String; let permit: PermitSignature? }
private struct TabBody: Codable {
    let chain: String; let provider: String; let limit_amount: Double
    let per_unit: Double; let expiry: Int; let permit: PermitSignature?
}
private struct ChargeTabBody: Codable {
    let amount: Double; let cumulative: Double; let call_count: Int; let provider_sig: String
}
private struct CloseTabBody: Codable { let final_amount: Double; let provider_sig: String }
private struct StreamBody: Codable {
    let chain: String; let payee: String; let rate_per_second: Double
    let max_total: Double; let permit: PermitSignature?
}
private struct BountyBody: Codable {
    let chain: String; let amount: Double; let task_description: String
    let deadline: Int; let max_attempts: Int; let permit: PermitSignature?
}
private struct BountyListResponse: Codable { let data: [Bounty] }
private struct SubmitBountyBody: Codable { let evidence_hash: String }
private struct AwardBody: Codable { let submission_id: Int }
private struct DepositBody: Codable {
    let chain: String; let provider: String; let amount: Double
    let expiry: Int; let permit: PermitSignature?
}
private struct IntentBody: Codable { let to: String; let amount: Double; let model: String }
private struct WebhookBody: Codable { let url: String; let events: [String]; let chains: [String]? }
private struct MintBody: Codable { let wallet: String; let amount: Double }

/// Response from POST /mint.
public struct MintResponse: Codable, Sendable {
    public let txHash: String
    public let balance: Double

    enum CodingKeys: String, CodingKey {
        case txHash = "tx_hash"
        case balance
    }
}

// MARK: - TabCharge EIP-712 helpers (file-level)

/// Encode a UInt64 as ABI uint256 (32-byte big-endian, zero-padded on the left).
private func tabEncodeUint256(_ value: UInt64) -> Data {
    var result = Data(repeating: 0, count: 32)
    var v = value
    for i in stride(from: 31, through: 24, by: -1) {
        result[i] = UInt8(v & 0xFF)
        v >>= 8
    }
    return result
}

/// Encode an Ethereum address as ABI bytes32 (12 zero bytes + 20 address bytes).
private func tabEncodeAddress(_ address: String) -> Data {
    var result = Data(repeating: 0, count: 32)
    let hex = address.hasPrefix("0x") ? String(address.dropFirst(2)) : address
    guard hex.count == 40, let addrData = Data(hexString: hex) else { return result }
    result.replaceSubrange(12..<32, with: addrData)
    return result
}

// MARK: - EIP-2612 Permit helpers (file-level)

/// Encode a UInt64 as ABI uint256 (32-byte big-endian, zero-padded on the left).
private func permitEncodeUint256(_ value: UInt64) -> Data {
    var result = Data(repeating: 0, count: 32)
    var v = value
    for i in stride(from: 31, through: 24, by: -1) {
        result[i] = UInt8(v & 0xFF)
        v >>= 8
    }
    return result
}

/// Encode an Ethereum address as ABI bytes32 (12 zero bytes + 20 address bytes).
private func permitEncodeAddress(_ address: String) -> Data {
    var result = Data(repeating: 0, count: 32)
    let hex = address.hasPrefix("0x") ? String(address.dropFirst(2)) : address
    guard hex.count == 40, let addrData = Data(hexString: hex) else { return result }
    result.replaceSubrange(12..<32, with: addrData)
    return result
}

// MARK: - String helpers

extension String {
    /// Left-pad a string to a specified length.
    func leftPad(toLength: Int, withPad pad: Character) -> String {
        let deficit = toLength - count
        guard deficit > 0 else { return self }
        return String(repeating: pad, count: deficit) + self
    }
}
