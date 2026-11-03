import Foundation

public struct RunningLocalModel: Decodable, Sendable {
    public let name: String
    public let digest: String
    public let size: Int64
    public let expiresAt: Date
    public let gpuBytes: Int64?
    public let contextLength: Int?
    enum CodingKeys: String, CodingKey {
        case name, digest, size
        case expiresAt = "expires_at", gpuBytes = "size_vram", contextLength = "context_length"
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        digest = try values.decode(String.self, forKey: .digest)
        size = try values.decode(Int64.self, forKey: .size)
        gpuBytes = try values.decodeIfPresent(Int64.self, forKey: .gpuBytes)
        contextLength = try values.decodeIfPresent(Int.self, forKey: .contextLength)
        let expiry = try values.decode(String.self, forKey: .expiresAt)
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = fractional.date(from: expiry) ?? ISO8601DateFormatter().date(from: expiry) else {
            throw DecodingError.dataCorruptedError(forKey: .expiresAt, in: values, debugDescription: "Invalid running-model expiry")
        }
        expiresAt = date
    }
}

/// A server observation, not a guarantee that another client cannot unload it.
public struct LocalModelPreparation: Codable, Equatable, Sendable {
    public let endpoint: String
    public let requestedModel: String
    public let model: String
    public let digest: String
    public let observedAt: Date
    public let serverExpiresAt: Date
    public let residentBytes: Int64
    public let gpuBytes: Int64?
    public let contextLength: Int?
    public let serverLoadNanoseconds: UInt64?
    public let elapsedSeconds: Double
    public var observationExpiresAt: Date { min(serverExpiresAt, observedAt.addingTimeInterval(300)) }
}
