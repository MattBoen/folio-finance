import Foundation

/// Errors the screens know how to show. Both apps throw these (Folio from its server, Folio Desktop from your Mac's feed).
enum APIError: LocalizedError {
    case invalidResponse
    case unauthorized
    case conflict
    case server(Int, String?)
    case network

    var errorDescription: String? {
        switch self {
        #if PERSONAL
        case .network: return "Couldn't reach your Mac. Check your connection and try again."
        case .unauthorized: return "Locked. Unlock with Face ID."
        case .conflict: return "That already exists."
        #else
        case .network: return "Couldn't reach Folio. Check your connection and try again."
        case .unauthorized: return "Session expired. Please log in again."
        case .conflict: return "That email is already registered."
        #endif
        case .invalidResponse: return "Invalid response."
        case .server(_, let msg): return msg ?? "Something went wrong."
        }
    }
}
