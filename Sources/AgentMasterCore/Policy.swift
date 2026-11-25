import Foundation

/// What a policy rule says about one tool call. Ordered so the strictest wins when rules are combined.
public enum PolicyVerdict: Int, Comparable, Sendable {
    /// AgentMaster does not object; the agent's own permission rules still decide.
    case allow
    case ask
    case deny

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum PolicyRule: String, Codable, Sendable {
    case cost, dangerousBash, maxToolCalls
}

/// One rule's objection to a tool call.
public struct PolicyFinding: Equatable, Sendable {
    public let rule: PolicyRule
    public let verdict: PolicyVerdict
    public let reason: String

    public init(rule: PolicyRule, verdict: PolicyVerdict, reason: String) {
        self.rule = rule
        self.verdict = verdict
        self.reason = reason
    }
}

/// The combined result for one tool call: DENY if any rule denies, else ASK if any asks, else ALLOW.
public struct PolicyCheck: Equatable, Sendable {
    public let findings: [PolicyFinding]

    public init(findings: [PolicyFinding]) {
        self.findings = findings
    }

    public var verdict: PolicyVerdict { findings.map(\.verdict).max() ?? .allow }

    /// The reasons of the rules that set the verdict, one per line.
    public var reason: String {
        findings.filter { $0.verdict == verdict }.map(\.reason).joined(separator: "\n")
    }

    /// The rules a user's "allow" answers, so they stop asking (see `PolicyReducer.approve`).
    public var askingRules: [PolicyRule] { findings.filter { $0.verdict == .ask }.map(\.rule) }
}

/// The user's rules, the same on the Mac and the server (`policies` in UserDefaults and settings.json).
/// Every field decodes when missing, so a file written before a field existed keeps the rest.
public struct PolicySettings: Codable, Equatable, Sendable {
    public struct Cost: Codable, Equatable, Sendable {
        /// Ask once when the session's cost first reaches this; nil turns it off.
        public var askAtUSD: Double?
        /// Deny every tool call from here on; nil turns it off.
        public var denyAtUSD: Double?

        public init(askAtUSD: Double? = nil, denyAtUSD: Double? = nil) {
            self.askAtUSD = askAtUSD
            self.denyAtUSD = denyAtUSD
        }
    }

    public struct DangerousBash: Codable, Equatable, Sendable {
        public var enabled: Bool
        /// The user's own case-insensitive regular expressions, checked on each simple command of a Bash call
        /// after the built-in checks (`DangerousCommand`); invalid ones are skipped.
        public var patterns: [String]

        public init(enabled: Bool = true, patterns: [String] = []) {
            self.enabled = enabled
            self.patterns = patterns
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
            patterns = try container.decodeIfPresent([String].self, forKey: .patterns) ?? []
        }
    }

    public var cost: Cost
    public var dangerousBash: DangerousBash
    /// Ask after this many tool calls in one session, then again after as many more; nil turns it off.
    public var maxToolCalls: Int?

    /// The dangerous-command rule on; the budget and the call limit off, as there is no sensible default amount.
    public init(cost: Cost = Cost(), dangerousBash: DangerousBash = DangerousBash(), maxToolCalls: Int? = nil) {
        self.cost = cost
        self.dangerousBash = dangerousBash
        self.maxToolCalls = maxToolCalls
    }

    /// A limit as typed on a settings page: `.some(nil)` (off) for blank or 0, `.some(value)` for a positive
    /// number, nil for text that is not a number yet, which leaves the saved limit as it was.
    public static func limit(fromText text: String) -> Double?? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .some(nil) }
        guard let value = Double(trimmed), value.isFinite, value >= 0 else { return nil }
        return .some(value > 0 ? value : nil)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cost = try container.decodeIfPresent(Cost.self, forKey: .cost) ?? Cost()
        dangerousBash = try container.decodeIfPresent(DangerousBash.self, forKey: .dangerousBash) ?? DangerousBash()
        maxToolCalls = try container.decodeIfPresent(Int.self, forKey: .maxToolCalls)
    }
}

/// One AgentMaster session's policy bookkeeping; lives in memory and goes with the session.
public struct PolicyState: Equatable, Sendable {
    /// Cost from before the agent's counter last started over (`/clear`, a resume).
    public var carriedCostUSD: Double = 0
    /// The agent's latest reported cost; nil until it reports one, and always for an agent that reports none.
    public var lastCostUSD: Double?
    /// Set once the user allows a call the budget asked about; the budget then only denies.
    public var budgetApproved = false
    public var toolCalls = 0
    /// Calls allowed before the call limit asks again; nil means `maxToolCalls`.
    public var toolCallAllowance: Int?
    /// Rules the user allowed for the rest of the session ("Allow for this session"): they no longer ask.
    /// A rule that denies (the cost limit) still denies.
    public var allowedRules: Set<PolicyRule> = []

    public init() {}

    /// The whole session's cost, nil when nothing was reported.
    public var costUSD: Double? { lastCostUSD.map { carriedCostUSD + $0 } }
}

/// The policy rules as pure functions over `PolicyState`, like `SessionState.apply`.
public enum PolicyReducer {
    /// A status line's `cost.total_cost_usd`. A smaller number than last time means the agent's counter
    /// started over, so the earlier total is carried and the budget covers the whole session.
    public static func observeCost(_ usd: Double, in state: inout PolicyState) {
        if let last = state.lastCostUSD, usd < last { state.carriedCostUSD += last }
        state.lastCostUSD = usd
    }

    /// Checks one PreToolUse and counts it toward the call limit. AskUserQuestion is the agent asking the
    /// user, not a tool doing something, so it is neither checked nor counted.
    public static func evaluate(toolName: String, input: JSONValue, settings: PolicySettings,
                                state: inout PolicyState) -> PolicyCheck {
        guard toolName != "AskUserQuestion" else { return PolicyCheck(findings: []) }
        var findings: [PolicyFinding] = []

        if let cost = state.costUSD {
            if let deny = settings.cost.denyAtUSD, cost >= deny {
                findings.append(PolicyFinding(rule: .cost, verdict: .deny, reason:
                    "This session has cost \(dollars(cost)), past its \(dollars(deny)) limit."))
            } else if let ask = settings.cost.askAtUSD, cost >= ask, !state.budgetApproved {
                findings.append(PolicyFinding(rule: .cost, verdict: .ask, reason:
                    "This session has cost \(dollars(cost)), past the \(dollars(ask)) budget."))
            }
        }

        if settings.dangerousBash.enabled, !state.allowedRules.contains(.dangerousBash), toolName == "Bash",
           let command = input["command"]?.stringValue,
           let reason = dangerousReason(command, patterns: settings.dangerousBash.patterns) {
            findings.append(PolicyFinding(rule: .dangerousBash, verdict: .ask, reason: reason))
        }

        state.toolCalls += 1
        if let max = settings.maxToolCalls, max > 0, state.toolCalls > (state.toolCallAllowance ?? max) {
            findings.append(PolicyFinding(rule: .maxToolCalls, verdict: .ask, reason: state.toolCallAllowance == nil
                ? "This session has made \(max) tool calls, its limit."
                : "This session has made another \(max) tool calls since you last allowed more."))
        }
        return PolicyCheck(findings: findings.filter { $0.verdict != .ask || !state.allowedRules.contains($0.rule) })
    }

    /// The user allowed a call the rules asked about: the budget stops asking, and the call limit lets this
    /// call and `maxToolCalls` more through. A dangerous command has no memory; the next one asks again,
    /// unless `forSession`, which stops every rule in `rules` asking for the rest of the session.
    public static func approve(_ rules: [PolicyRule], forSession: Bool = false, settings: PolicySettings,
                               state: inout PolicyState) {
        if forSession { state.allowedRules.formUnion(rules) }
        if rules.contains(.cost) { state.budgetApproved = true }
        if rules.contains(.maxToolCalls), let max = settings.maxToolCalls {
            state.toolCallAllowance = state.toolCalls + max
        }
    }

    /// Longer commands are not checked but asked about: every check is linear, this only bounds the work.
    public static let maxCommandLength = 1_000_000
    /// The user's own patterns run on simple commands up to this long; a longer one is asked about, since a
    /// regular expression can take exponential time.
    public static let maxPatternInputLength = 4_096
    /// How long the user's patterns may run on one call before it is asked about instead.
    public static let patternTimeout: TimeInterval = 0.1

    /// Why a Bash command needs the user's OK, or nil: the built-in checks, then the user's patterns.
    public static func dangerousReason(_ command: String, patterns: [String]) -> String? {
        guard command.utf8.count <= maxCommandLength else {
            return "The command is too long to check (\(command.utf8.count / 1000) KB)."
        }
        if let found = DangerousCommand.finding(in: command) { return "The command looks dangerous: \(found)." }
        guard !patterns.isEmpty else { return nil }
        let segments = DangerousCommand.split(command).map(\.text)
        if segments.contains(where: { $0.utf8.count > maxPatternInputLength }) {
            return "A command is too long for your dangerous-command patterns to check."
        }
        switch PatternMatcher.firstMatch(segments, patterns: patterns, timeout: patternTimeout) {
        case .match(let pattern): return "The command matches your dangerous-command pattern: \(pattern)"
        case .timedOut: return "Your dangerous-command patterns took too long to check this command."
        case .none: return nil
        }
    }

    static func dollars(_ value: Double) -> String { String(format: "$%.2f", value) }
}
