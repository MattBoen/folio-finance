import Foundation

struct AskSettings: Decodable, Sendable {
    let enabled: Bool
    let dailyLimit: Int?
    let usedToday: Int?
}

struct AskFact: Decodable, Sendable, Identifiable, Hashable {
    let label: String
    let value: String
    var id: String { label + value }
}

struct AskProposal: Decodable, Sendable, Identifiable, Hashable {
    let id: String
    let kind: String
    let title: String
    let detail: String?
    let category: String?
    let currentAmount: Double?
    let newAmount: Double?
}

struct AskResponse: Decodable, Sendable {
    let answer: String
    let facts: [AskFact]?
    let proposal: AskProposal?
}

struct AskMessage: Identifiable, Hashable {
    enum Role: String { case user, assistant }
    let id = UUID()
    let role: Role
    var text: String
    var facts: [AskFact] = []
    var proposal: AskProposal?
    var proposalState: ProposalState = .open
    var isError = false

    enum ProposalState: Hashable { case open, confirming, confirmed(String), dismissed, failed(String) }
}
