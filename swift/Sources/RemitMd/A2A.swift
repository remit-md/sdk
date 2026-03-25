import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Agent Card types

/// A2A capability extension declared in an agent card.
public struct A2AExtension: Decodable, Sendable {
    public let uri: String
    public let description: String
    public let required: Bool
}

/// Capabilities block from an A2A agent card.
public struct A2ACapabilities: Decodable, Sendable {
    public let streaming: Bool
    public let pushNotifications: Bool
    public let stateTransitionHistory: Bool
    public let extensions: [A2AExtension]
}

/// A single skill declared in an A2A agent card.
public struct A2ASkill: Decodable, Sendable {
    public let id: String
    public let name: String
    public let description: String
    public let tags: [String]
}

/// Fee info block inside the x402 capability.
public struct A2AFees: Decodable, Sendable {
    public let standardBps: Int
    public let preferredBps: Int
    public let cliffUsd: Int
}

/// x402 payment capability block in an agent card.
public struct A2AX402: Decodable, Sendable {
    public let settleEndpoint: String
    public let assets: [String: String]
    public let fees: A2AFees
}

/// A2A agent card parsed from `/.well-known/agent-card.json`.
public struct AgentCard: Decodable, Sendable {
    public let protocolVersion: String
    public let name: String
    public let description: String
    /// A2A JSON-RPC endpoint URL (POST).
    public let url: String
    public let version: String
    public let documentationUrl: String
    public let capabilities: A2ACapabilities
    public let skills: [A2ASkill]
    public let x402: A2AX402

    /// Fetch and parse the A2A agent card from
    /// `baseURL/.well-known/agent-card.json`.
    ///
    /// ```swift
    /// let card = try await AgentCard.discover(baseURL: URL(string: "https://remit.md")!)
    /// print(card.name, card.url)
    /// ```
    public static func discover(baseURL: URL) async throws -> AgentCard {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = (components.path.hasSuffix("/")
            ? String(components.path.dropLast()) : components.path)
            + "/.well-known/agent-card.json"

        var request = URLRequest(url: components.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw RemitError(RemitError.serverError, "Agent card discovery failed: HTTP \(statusCode)")
        }

        let decoder = JSONDecoder()
        return try decoder.decode(AgentCard.self, from: data)
    }
}

// MARK: - A2A task types

/// Status of an A2A task.
public struct A2ATaskStatus: Codable, Sendable {
    /// One of "completed", "failed", "canceled", "working".
    public let state: String
    public let message: A2ATaskMessage?
}

/// Optional message in a task status.
public struct A2ATaskMessage: Codable, Sendable {
    public let text: String?
}

/// A part within an A2A artifact.
public struct A2AArtifactPart: Codable, Sendable {
    public let kind: String
    public let data: [String: AnyCodable]?
}

/// An artifact produced by an A2A task.
public struct A2AArtifact: Codable, Sendable {
    public let name: String?
    public let parts: [A2AArtifactPart]
}

/// An A2A task returned by JSON-RPC calls.
public struct A2ATask: Codable, Sendable {
    public let id: String
    public let status: A2ATaskStatus
    public let artifacts: [A2AArtifact]

    /// Extract `txHash` from task artifacts, if present.
    public func getTxHash() -> String? {
        for artifact in artifacts {
            for part in artifact.parts {
                if let data = part.data, let txHash = data["txHash"]?.stringValue {
                    return txHash
                }
            }
        }
        return nil
    }
}

// MARK: - IntentMandate

/// An intent mandate for authorized spending.
public struct IntentMandate: Codable, Sendable {
    public let mandateId: String
    public let expiresAt: String
    public let issuer: String
    public let allowance: IntentAllowance

    public init(mandateId: String, expiresAt: String, issuer: String, allowance: IntentAllowance) {
        self.mandateId = mandateId
        self.expiresAt = expiresAt
        self.issuer = issuer
        self.allowance = allowance
    }
}

/// Allowance within an IntentMandate.
public struct IntentAllowance: Codable, Sendable {
    public let maxAmount: String
    public let currency: String

    public init(maxAmount: String, currency: String) {
        self.maxAmount = maxAmount
        self.currency = currency
    }
}

// MARK: - A2A Client

/// Send options for A2A payments.
public struct A2ASendOptions: Sendable {
    public let to: String
    public let amount: Double
    public let memo: String
    public let mandate: IntentMandate?

    public init(to: String, amount: Double, memo: String = "", mandate: IntentMandate? = nil) {
        self.to = to
        self.amount = amount
        self.memo = memo
        self.mandate = mandate
    }
}

/// A2A JSON-RPC client -- send payments and manage tasks via the A2A protocol.
///
/// ```swift
/// let card = try await AgentCard.discover(baseURL: URL(string: "https://remit.md")!)
/// let signer = try PrivateKeySigner(privateKey: "0x...")
/// let client = A2AClient.fromCard(card, signer: signer)
/// let task = try await client.send(A2ASendOptions(to: "0xRecipient...", amount: 10))
/// print(task.status.state, task.getTxHash() ?? "no tx hash")
/// ```
public final class A2AClient: @unchecked Sendable {
    private let transport: any Transport
    private let path: String

    /// Construct an A2A client from an endpoint URL and a signer.
    public init(endpoint: String, signer: any Signer, chainId: UInt64, verifyingContract: String = "") {
        guard let url = URL(string: endpoint),
              let scheme = url.scheme,
              let host = url.host else {
            self.transport = HttpTransport(baseURL: endpoint, chainId: chainId, routerAddress: verifyingContract, signer: signer)
            self.path = "/a2a"
            return
        }
        let port = url.port.map { ":\($0)" } ?? ""
        let baseUrl = "\(scheme)://\(host)\(port)"
        self.path = url.path.isEmpty ? "/a2a" : url.path
        self.transport = HttpTransport(
            baseURL: baseUrl,
            chainId: chainId,
            routerAddress: verifyingContract,
            signer: signer
        )
    }

    /// Convenience constructor from an AgentCard and a signer.
    public static func fromCard(
        _ card: AgentCard,
        signer: any Signer,
        chain: String = "base",
        verifyingContract: String = ""
    ) -> A2AClient {
        let chainId: UInt64 = chain == "base-sepolia" ? 84532 : 8453
        return A2AClient(
            endpoint: card.url,
            signer: signer,
            chainId: chainId,
            verifyingContract: verifyingContract
        )
    }

    /// Send a direct USDC payment via `message/send`.
    public func send(_ opts: A2ASendOptions) async throws -> A2ATask {
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let messageId = UUID().uuidString.replacingOccurrences(of: "-", with: "")

        let partData = A2APartData(model: "direct", to: opts.to,
                                    amount: String(format: "%.2f", opts.amount),
                                    memo: opts.memo, nonce: nonce)
        let part = A2AMessagePart(kind: "data", data: partData)
        let message = A2AMessage(messageId: messageId, role: "user", parts: [part],
                                  metadata: opts.mandate.map { A2AMetadata(mandate: $0) })

        let rpcBody = A2ARpcSendBody(jsonrpc: "2.0", id: messageId,
                                      method: "message/send",
                                      params: A2ASendParams(message: message))
        let resp: A2ARpcResponse = try await transport.request(
            method: "POST", path: path, body: rpcBody
        )
        if let error = resp.error {
            throw RemitError(RemitError.serverError, "A2A error: \(error.message ?? "unknown")")
        }
        guard let result = resp.result else {
            throw RemitError(RemitError.serverError, "A2A response missing result")
        }
        return result
    }

    /// Fetch the current state of an A2A task by ID.
    public func getTask(taskId: String) async throws -> A2ATask {
        let rpcBody = A2ARpcIdBody(jsonrpc: "2.0", id: String(taskId.prefix(16)),
                                    method: "tasks/get",
                                    params: A2AIdParams(id: taskId))
        let resp: A2ARpcResponse = try await transport.request(
            method: "POST", path: path, body: rpcBody
        )
        if let error = resp.error {
            throw RemitError(RemitError.serverError, "A2A error: \(error.message ?? "unknown")")
        }
        guard let result = resp.result else {
            throw RemitError(RemitError.serverError, "A2A response missing result")
        }
        return result
    }

    /// Cancel an in-progress A2A task.
    public func cancelTask(taskId: String) async throws -> A2ATask {
        let rpcBody = A2ARpcIdBody(jsonrpc: "2.0", id: String(taskId.prefix(16)),
                                    method: "tasks/cancel",
                                    params: A2AIdParams(id: taskId))
        let resp: A2ARpcResponse = try await transport.request(
            method: "POST", path: path, body: rpcBody
        )
        if let error = resp.error {
            throw RemitError(RemitError.serverError, "A2A error: \(error.message ?? "unknown")")
        }
        guard let result = resp.result else {
            throw RemitError(RemitError.serverError, "A2A response missing result")
        }
        return result
    }
}

// MARK: - A2A JSON-RPC Codable bodies

private struct A2APartData: Codable {
    let model: String; let to: String; let amount: String; let memo: String; let nonce: String
}
private struct A2AMessagePart: Codable { let kind: String; let data: A2APartData }
private struct A2AMetadata: Codable { let mandate: IntentMandate }
private struct A2AMessage: Codable {
    let messageId: String; let role: String; let parts: [A2AMessagePart]; let metadata: A2AMetadata?
}
private struct A2ASendParams: Codable { let message: A2AMessage }
private struct A2ARpcSendBody: Codable { let jsonrpc: String; let id: String; let method: String; let params: A2ASendParams }
private struct A2AIdParams: Codable { let id: String }
private struct A2ARpcIdBody: Codable { let jsonrpc: String; let id: String; let method: String; let params: A2AIdParams }
private struct A2ARpcResponse: Codable {
    let result: A2ATask?
    let error: A2ARpcError?
}
private struct A2ARpcError: Codable { let message: String? }

// MARK: - AnyCodable helper

/// Type-erased Codable value for flexible JSON decoding.
public struct AnyCodable: Codable, Sendable {
    private let value: Any

    public var stringValue: String? { value as? String }
    public var intValue: Int? { value as? Int }
    public var doubleValue: Double? { value as? Double }
    public var boolValue: Bool? { value as? Bool }

    public init(_ value: Any) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(String.self) { value = v; return }
        if let v = try? container.decode(Int.self) { value = v; return }
        if let v = try? container.decode(Double.self) { value = v; return }
        if let v = try? container.decode(Bool.self) { value = v; return }
        if container.decodeNil() { value = "null"; return }
        value = "unknown"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let v = value as? String { try container.encode(v) }
        else if let v = value as? Int { try container.encode(v) }
        else if let v = value as? Double { try container.encode(v) }
        else if let v = value as? Bool { try container.encode(v) }
        else { try container.encodeNil() }
    }
}
