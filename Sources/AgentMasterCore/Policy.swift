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
        /// Case-insensitive regular expressions matched against a Bash call's command; invalid ones are skipped.
        public var patterns: [String]

        public init(enabled: Bool = true, patterns: [String] = PolicySettings.defaultPatterns) {
            self.enabled = enabled
            self.patterns = patterns
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
            patterns = try container.decodeIfPresent([String].self, forKey: .patterns) ?? PolicySettings.defaultPatterns
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

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cost = try container.decodeIfPresent(Cost.self, forKey: .cost) ?? Cost()
        dangerousBash = try container.decodeIfPresent(DangerousBash.self, forKey: .dangerousBash) ?? DangerousBash()
        maxToolCalls = try container.decodeIfPresent(Int.self, forKey: .maxToolCalls)
    }

    /// Text matching, so `bash -c`, variables or a script file get past them; they are a guard rail.
    /// `[^|;&]*` keeps a match inside one command of a pipeline or list.
    public static let defaultPatterns = [
        // rm -rf, -fr, -Rf, and the flags written apart (-r … -f, --recursive … --force)
        #"\brm\s+(?:[^|;&]*\s)?-[a-z]*(?:r[a-z]*f|f[a-z]*r)"#,
        #"\brm(?=\s)[^|;&]*(?:\s-[a-z]*r[a-z]*|--recursive)\b[^|;&]*(?:\s-[a-z]*f[a-z]*|--force)\b"#,
        #"\brm(?=\s)[^|;&]*(?:\s-[a-z]*f[a-z]*|--force)\b[^|;&]*(?:\s-[a-z]*r[a-z]*|--recursive)\b"#,
        #"\bgit\b[^|;&]*\bpush\b[^|;&]*\s(?:--force|--force-with-lease|-f)\b"#,
        #"\bgit\b[^|;&]*\breset\b[^|;&]*\s--hard\b"#,
        #"\bgit\b[^|;&]*\bclean\b[^|;&]*\s-[a-z]*f"#,
        #"\bterraform\b[^|;&]*\b(?:apply|destroy)\b"#,
        #"\bkubectl\b[^|;&]*\bdelete\b"#,
        #"\bdrop\s+(?:table|database)\b"#,
        #"\bmkfs\b"#,
        #"\bdd\b[^|;&]*\bof=/dev/"#,
        #"\bchmod\s[^|;&]*-[a-z]*r[^|;&]*\s0?777\b"#,
        #"\b(?:curl|wget)\b[^|;]*\|\s*(?:sudo\s+)?(?:ba|z)?sh\b"#,
    ]
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

        if settings.dangerousBash.enabled, toolName == "Bash", let command = input["command"]?.stringValue,
           let pattern = firstMatch(command, patterns: settings.dangerousBash.patterns) {
            findings.append(PolicyFinding(rule: .dangerousBash, verdict: .ask,
                                          reason: "The command matches a dangerous-command pattern: \(pattern)"))
        }

        state.toolCalls += 1
        if let max = settings.maxToolCalls, max > 0, state.toolCalls > (state.toolCallAllowance ?? max) {
            findings.append(PolicyFinding(rule: .maxToolCalls, verdict: .ask, reason:
                "This session has made \(state.toolCalls - 1) tool calls, its limit of \(max)."))
        }
        return PolicyCheck(findings: findings)
    }

    /// The user allowed a call the rules asked about: the budget stops asking, and the call limit lets this
    /// call and `maxToolCalls` more through. A dangerous command has no memory; the next one asks again.
    public static func approve(_ rules: [PolicyRule], settings: PolicySettings, state: inout PolicyState) {
        if rules.contains(.cost) { state.budgetApproved = true }
        if rules.contains(.maxToolCalls), let max = settings.maxToolCalls {
            state.toolCallAllowance = state.toolCalls + max
        }
    }

    /// The first pattern that matches `command`, case-insensitively; patterns that do not compile are skipped.
    public static func firstMatch(_ command: String, patterns: [String]) -> String? {
        let range = NSRange(command.startIndex..., in: command)
        return patterns.first { pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return false }
            return regex.firstMatch(in: command, range: range) != nil
        }
    }

    static func dollars(_ value: Double) -> String { String(format: "$%.2f", value) }
}
