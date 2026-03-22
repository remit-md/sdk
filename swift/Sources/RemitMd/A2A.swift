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
