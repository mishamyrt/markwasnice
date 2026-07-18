import Foundation

/// Severity buckets derived from a rule's 0–100 weight.
enum ProofreadingSeverity: Equatable {
    case low
    case medium
    case high
    case critical

    init(weight: Int) {
        switch weight {
        case ..<50: self = .low
        case ..<80: self = .medium
        case ..<100: self = .high
        default: self = .critical
        }
    }
}

/// A single editorial finding, positioned in UTF-16 text-storage coordinates.
struct ProofreadingIssue: Equatable {
    var range: NSRange
    let ruleID: Int
    let title: String
    let hint: String
    let weight: Int

    var severity: ProofreadingSeverity {
        ProofreadingSeverity(weight: weight)
    }
}
