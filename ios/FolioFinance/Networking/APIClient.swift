import Foundation

actor APIClient {
    static let shared = APIClient()

    private let baseURL = URL(string: "https://folio-finance-api.onrender.com")!

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 90
        config.waitsForConnectivity = true
        return URLSession(configuration: config)
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Free hosting sleeps when idle; a throwaway request at launch wakes it before the user taps Sign in.
    func warmUp() async {
        var req = URLRequest(url: baseURL.appendingPathComponent("health"))
        req.timeoutInterval = 90
        _ = try? await session.data(for: req)
    }

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

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch let error as URLError where error.code != .cancelled {
            throw APIError.network
        }

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
    case network

    var errorDescription: String? {
        switch self {
        case .network: return "Couldn't reach Folio. Check your connection and try again."
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
