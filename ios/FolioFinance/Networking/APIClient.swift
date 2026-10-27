import Foundation

actor APIClient {
    static let shared = APIClient()

    #if DEBUG
    private let baseURL = URL(string: "http://192.168.25.72:3000")!
    #else
    private let baseURL = URL(string: "https://api.foliofinance.app")!
    #endif

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    func request<T: Decodable>(
        _ endpoint: Endpoint,
        token: String? = nil
    ) async throws -> T {
        var req = URLRequest(url: baseURL.appendingPathComponent(endpoint.path))
        req.httpMethod = endpoint.method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        if let token {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = endpoint.body

        let (data, response) = try await session.data(for: req)

        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        switch http.statusCode {
        case 200...299:
            return try decoder.decode(T.self, from: data)
        case 401:
            throw APIError.unauthorized
        case 409:
            throw APIError.conflict
        default:
            let msg = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.error
            throw APIError.server(http.statusCode, msg)
        }
    }
}

enum APIError: LocalizedError {
    case invalidResponse
    case unauthorized
    case conflict
    case server(Int, String?)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid server response."
        case .unauthorized: return "Session expired. Please log in again."
        case .conflict: return "That email is already registered."
        case .server(_, let msg): return msg ?? "Something went wrong."
        }
    }
}

private struct ErrorResponse: Decodable {
    let error: String
}
