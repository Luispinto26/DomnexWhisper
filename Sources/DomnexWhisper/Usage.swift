import Combine
import Foundation

/// Public Claude API prices in USD per million tokens (October 2026). Thinking tokens are billed as output.
enum ClaudePricing {
    static let perMillionTokens: [String: (input: Double, output: Double)] = [
        "claude-opus-5-5": (4.00, 20.00),
        "claude-sonnet-5-5": (2.00, 10.00),
        "claude-haiku-5-5": (0.10, 0.50),
    ]

    static func cost(model: String, inputTokens: Int, outputTokens: Int) -> Double? {
        guard let price = perMillionTokens[model] else { return nil }
        return (Double(inputTokens) * price.input + Double(outputTokens) * price.output) / 1_000_000
    }
}

struct UsageTotals: Codable {
    var requests = 0
    var inputTokens = 0
    var outputTokens = 0
    var costUSD = 0.0

    var tokens: Int { inputTokens + outputTokens }
}

/// Counts the tokens the Claude API reports for each request and estimates what they cost.
/// The API offers no balance endpoint for normal keys, so the remaining credit is an estimate
/// based on the amount the user says they loaded.
final class UsageTracker: ObservableObject {
    static let shared = UsageTracker()

    struct State: Codable {
        var monthKey = ""
        var month = UsageTotals()
        var total = UsageTotals()
        var creditUSD: Double?
        var spentSinceCreditUSD = 0.0
    }

    @Published private(set) var state: State

    private let url = AppPaths.support.appendingPathComponent("usage.json")

    private init() {
        state = (try? JSONDecoder().decode(State.self, from: Data(contentsOf: url))) ?? State()
        rollMonthIfNeeded()
    }

    var estimatedRemainingUSD: Double? {
        state.creditUSD.map { $0 - state.spentSinceCreditUSD }
    }

    func record(model: String, inputTokens: Int, outputTokens: Int) {
        rollMonthIfNeeded()
        let cost = ClaudePricing.cost(model: model, inputTokens: inputTokens, outputTokens: outputTokens) ?? 0
        for keyPath in [\State.month, \State.total] {
            state[keyPath: keyPath].requests += 1
            state[keyPath: keyPath].inputTokens += inputTokens
            state[keyPath: keyPath].outputTokens += outputTokens
            state[keyPath: keyPath].costUSD += cost
        }
        if state.creditUSD != nil { state.spentSinceCreditUSD += cost }
        save()
    }

    /// Starts the remaining-credit estimate from `amount`; nil turns it off.
    func setCredit(_ amount: Double?) {
        state.creditUSD = amount
        state.spentSinceCreditUSD = 0
        save()
    }

    func resetCounters() {
        let credit = state.creditUSD
        let spent = state.spentSinceCreditUSD
        state = State()
        state.creditUSD = credit
        state.spentSinceCreditUSD = spent
        rollMonthIfNeeded()
        save()
    }

    private func rollMonthIfNeeded() {
        let components = Calendar.current.dateComponents([.year, .month], from: Date())
        let key = String(format: "%04d-%02d", components.year ?? 0, components.month ?? 0)
        if state.monthKey != key {
            state.monthKey = key
            state.month = UsageTotals()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

enum UsageFormat {
    private static let locale = Locale(identifier: "pt_PT")

    /// Where the real credit balance is shown.
    static let billingURL = URL(string: "https://platform.claude.com/settings/billing")!

    static func tokens(_ count: Int) -> String {
        count.formatted(.number.locale(locale))
    }

    /// Small amounts get more decimals, since one dictation costs a fraction of a cent.
    static func dollars(_ amount: Double) -> String {
        let digits = abs(amount) < 0.01 && amount != 0 ? 4 : 2
        return amount.formatted(.currency(code: "USD").locale(locale).precision(.fractionLength(digits)))
    }
}
