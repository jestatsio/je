import Foundation

public struct GatewayCheckReport: Codable, Equatable, Sendable {
    public let passed: Bool
    public let authenticated: Bool
    public let model: String
    public let modelAvailable: Bool

    enum CodingKeys: String, CodingKey {
        case passed
        case authenticated
        case model
        case modelAvailable = "model_available"
    }
}

public enum GatewayCheckError: Error, Equatable, Sendable {
    case httpStatus(Int)
    case deadline
    case sizeLimit
    case invalidListing
    case unreachable

    public var message: String {
        switch self {
        case .httpStatus(let status):
            return "Gateway connection failed with HTTP \(status)."
        case .deadline:
            return "The gateway model listing took too long."
        case .sizeLimit:
            return "The gateway model listing exceeded the supported size."
        case .invalidListing:
            return "The gateway did not return a valid model listing."
        case .unreachable:
            return "The gateway could not be reached or returned an invalid response."
        }
    }
}

public enum GatewayConnectionChecker {
    public static func check(
        profile: ResolvedConnectionProfile,
        transport: BoundedHTTPTransport
    ) throws -> GatewayCheckReport {
        guard let url = URL(string: profile.apiBase + "/models") else {
            throw GatewayCheckError.unreachable
        }
        let response: BoundedHTTPResponse
        do {
            response = try transport.get(url: url, bearerToken: profile.secret)
        } catch let error as OllamaCheckError {
            throw Self.mapTransportError(error)
        } catch let error as GatewayCheckError {
            throw error
        } catch {
            throw GatewayCheckError.unreachable
        }
        guard (200...299).contains(response.statusCode) else {
            throw GatewayCheckError.httpStatus(response.statusCode)
        }
        guard response.data.count <= OllamaConnectionChecker.maximumResponseBytes else {
            throw GatewayCheckError.sizeLimit
        }
        let available = try modelIsAvailable(in: response.data, model: profile.model)
        return GatewayCheckReport(
            passed: available,
            authenticated: true,
            model: profile.model,
            modelAvailable: available
        )
    }

    private static func modelIsAvailable(in data: Data, model: String) throws -> Bool {
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw GatewayCheckError.invalidListing
        }
        guard let root = parsed as? [String: Any],
              let models = root["data"] as? [Any] else {
            throw GatewayCheckError.invalidListing
        }
        return models.contains { item in
            guard let object = item as? [String: Any] else { return false }
            return (object["id"] as? String) == model
        }
    }

    private static func mapTransportError(_ error: OllamaCheckError) -> GatewayCheckError {
        switch error {
        case .httpStatus(let status):
            return .httpStatus(status)
        case .deadline:
            return .deadline
        case .sizeLimit:
            return .sizeLimit
        case .invalidListing:
            return .invalidListing
        case .unreachable:
            return .unreachable
        }
    }
}
