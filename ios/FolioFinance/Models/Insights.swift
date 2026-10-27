import Foundation

/// Everything the Budget tab and setup flow show. All money values are plain dollars (Double); the server computes them.
struct Insights: Decodable, Sendable {
    let income: Income
    let outflow: Outflow
    let budget: SuggestedBudget
    let health: Health
    let investing: Investing
    let dataQuality: DataQuality

    struct Income: Decodable, Sendable {
        let monthly: Double
        let source: String        // "detected" | "manual" | "none"
        let confidence: String    // "high" | "medium" | "low" | "none"
        let sources: [IncomeSource]
    }

    struct IncomeSource: Decodable, Sendable, Identifiable {
        let name: String
        let monthly: Double
        let frequency: String     // "weekly" | "biweekly" | "semimonthly" | "monthly" | "irregular"
        var id: String { name }
    }

    struct Outflow: Decodable, Sendable {
        let monthlyAverage: Double
        let fixed: Double
        let variable: Double
        let byCategory: [CategoryOutflow]
    }

    struct CategoryOutflow: Decodable, Sendable, Identifiable {
        let category: String
        let monthlyAverage: Double
        let isFixed: Bool
        var id: String { category }
    }

    struct SuggestedBudget: Decodable, Sendable {
        let total: Double
        let items: [BudgetItem]
    }

    struct BudgetItem: Decodable, Sendable, Identifiable {
        let category: String
        let amount: Double
        var id: String { category }
    }

    /// Ratios are fractions (0.18 = 18%). Nil means there isn't enough data to say.
    struct Health: Decodable, Sendable {
        let savingsRate: Double?
        let emergencyFundMonths: Double?
        let creditUtilization: Double?
        let debtPaymentRatio: Double?
    }

    struct Investing: Decodable, Sendable {
        let totalInvested: Double
        let allocation: [Slice]
        let notes: [Note]
    }

    struct Slice: Decodable, Sendable, Identifiable {
        let label: String
        let amount: Double
        let percent: Double       // 0-100
        var id: String { label }
    }

    struct Note: Decodable, Sendable, Identifiable {
        let id: String
        let title: String
        let detail: String
        let tone: String          // "good" | "info" | "attention"
    }

    struct DataQuality: Decodable, Sendable {
        let monthsOfData: Int
        let transactionCount: Int
    }
}

struct BudgetsResponse: Decodable, Sendable {
    let month: String             // "2026-10"
    let budgets: [BudgetLine]
}

struct BudgetLine: Decodable, Identifiable, Sendable {
    let id: String
    let category: String
    let monthlyAmount: Double
    let spent: Double             // spent so far this month in this category
}

struct VehicleLookup: Decodable, Sendable {
    let vin: String
    let year: Int
    let make: String
    let model: String
    let trim: String?
    let miles: Int
    let estimatedValue: Double
    let lowValue: Double
    let highValue: Double
    let source: String            // "estimate" | provider name

    var title: String { [String(year), make, model].joined(separator: " ") }
}
