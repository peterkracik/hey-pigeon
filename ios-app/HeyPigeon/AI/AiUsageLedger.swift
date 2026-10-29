// What each model provider cost: requests and tokens, per provider id,
// since the user last reset it. `response.usage` (iOS 27) feeds it after
// every answer; Settings › AI shows one line per provider under the rows.
// Apple's models are free of charge under the Small Business Program, so
// the line is tokens only; a third-party provider adds a cost estimate
// when its price per million tokens is known.

import Foundation
import FoundationModels
import Observation

struct TokenUsage: Codable, Equatable, Sendable {
    var requests = 0
    var inputTokens = 0
    var outputTokens = 0

    var isEmpty: Bool { requests == 0 }

    mutating func add(input: Int, output: Int) {
        requests += 1
        inputTokens += input
        outputTokens += output
    }
}

/// Price per million tokens (USD) for providers that bill; nil = free.
struct TokenPrice: Sendable {
    let inputPerMillion: Double
    let outputPerMillion: Double

    func cost(_ u: TokenUsage) -> Double {
        Double(u.inputTokens) / 1_000_000 * inputPerMillion + Double(u.outputTokens) / 1_000_000 * outputPerMillion
    }
}

@Observable
final class AiUsageLedger: @unchecked Sendable {
    static let shared = AiUsageLedger()

    private let defaults: UserDefaults
    private let key = "ai.usage"
    private let lock = NSLock()
    /// Written from the engine's threads (every AI answer), read by
    /// Settings on the main actor: always under `lock`. Observation is
    /// wired by hand through `byProvider`.
    @ObservationIgnored private var storage: [String: TokenUsage]

    /// Usage per provider id since the last reset.
    var byProvider: [String: TokenUsage] {
        access(keyPath: \.byProvider)
        return lock.withLock { storage }
    }
    /// Prices for providers that bill; the Apple models are not listed.
    nonisolated(unsafe) static var prices: [String: TokenPrice] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key), let saved = try? JSONDecoder().decode([String: TokenUsage].self, from: data) {
            storage = saved
        } else {
            storage = [:]
        }
    }

    /// Every answer passes through here. `usage` is the response's
    /// `usage`; nil (a model that reports none) still counts the request.
    func record(provider: String, _ usage: LanguageModelSession.Usage?) {
        record(provider: provider, input: usage?.input.totalTokenCount ?? 0, output: usage?.output.totalTokenCount ?? 0)
    }

    func record(provider: String, input: Int, output: Int) {
        withMutation(keyPath: \.byProvider) {
            lock.withLock {
                storage[provider, default: TokenUsage()].add(input: input, output: output)
                save()
            }
        }
    }

    func reset() {
        withMutation(keyPath: \.byProvider) {
            lock.withLock {
                storage = [:]
                save()
            }
        }
    }

    /// Callers hold `lock`.
    private func save() {
        defaults.set(try? JSONEncoder().encode(storage), forKey: key)
    }

    /// "12 requests · 8.4K in / 1.2K out" (+ " · $0.03" when billed).
    static func line(_ u: TokenUsage, price: TokenPrice?) -> String {
        func k(_ n: Int) -> String {
            n >= 10_000 ? String(format: "%.0fK", Double(n) / 1000)
                : n >= 1_000 ? String(format: "%.1fK", Double(n) / 1000) : "\(n)"
        }
        var s = "\(u.requests) request\(u.requests == 1 ? "" : "s") · \(k(u.inputTokens)) in / \(k(u.outputTokens)) out"
        if let price { s += String(format: " · $%.2f", price.cost(u)) }
        return s
    }
}
