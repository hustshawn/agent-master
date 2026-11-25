import Foundation

/// The built-in dangerous-command checks (ADR 0017), on a shell command split into simple commands and words
/// instead of regular expressions: one linear pass, so a long command (a heredoc writing a large file) cannot
/// hold up the hook thread, and quoting or combined flags (`"rm" '-rf'`, `push -uf`) do not get past it.
/// Still text, not a shell: `eval`, variables or a script file get past it; it is a guard rail.
public enum DangerousCommand {
    /// The first thing the rules found, for the reason shown on the card.
    public static func finding(in command: String) -> String? {
        findings(in: command).first
    }

    /// Everything the rules found in the command, in order and without repeats, so allowing one kind for the
    /// session (`rm with -r and -f`) cannot hide another later in the same call (`&& git push --force`).
    public static func findings(in command: String) -> [String] {
        var found: [String] = []
        collect(command, depth: 0) { if !found.contains($0) { found.append($0) } }
        return found
    }

    private static func collect(_ command: String, depth: Int, _ add: (String) -> Void) {
        let pipeline = split(command)
        for (index, segment) in pipeline.enumerated() {
            let command = commandWords(words(segment.text))
            guard let name = command.first.map(baseName) else { continue }
            let args = Array(command.dropFirst())
            // `grep -r "drop table" .` only searches for the words; `echo "drop table t" | psql` runs them.
            let next = segment.pipesToNext && index + 1 < pipeline.count
                ? commandWords(words(pipeline[index + 1].text)).first.map(baseName) : nil
            let sqlIsData = textCommands.contains(name) && (next.map(textCommands.contains) ?? true)
            check(name: name, args: args, raw: segment.text, sqlIsData: sqlIsData).forEach(add)
            // curl … | sh: the next command in the pipe is a shell.
            if ["curl", "wget"].contains(name), let next, shells.contains(next) {
                add("downloads a script and pipes it to \(next)")
            }
            // bash -c '…' runs its argument as a command.
            if shells.contains(name), depth < 3, let flag = args.firstIndex(of: "-c"), flag + 1 < args.count {
                collect(args[flag + 1], depth: depth + 1, add)
            }
        }
    }

    static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "fish"]

    /// Commands that search or print text, so SQL in their arguments is data, unless piped into something else.
    /// (git is checked by its subcommand, so `git log --grep "drop table"` never reaches the SQL check.)
    static let textCommands: Set<String> = ["grep", "egrep", "fgrep", "rg", "ag", "ack", "echo", "printf", "cat",
                                            "head", "tail", "less", "more", "wc", "sort", "uniq"]

    /// What one simple command trips: its own check, a downloaded script run by a shell, and SQL that drops.
    private static func check(name: String, args: [String], raw: String, sqlIsData: Bool) -> [String] {
        var found = command(name: name, args: args).map { [$0] } ?? []
        if name == "git" { return found }   // judged by its subcommand only: `git log --grep "drop table"`
        // bash <(curl …), sh -c "$(curl …)", source <(wget …)
        if shells.contains(name) || name == "source" || name == "." {
            let flat = raw.lowercased().filter { !$0.isWhitespace }
            if ["<(curl", "<(wget", "$(curl", "$(wget", "`curl", "`wget"].contains(where: flat.contains) {
                found.append("runs a downloaded script with \(name)")
            }
        }
        if !sqlIsData, containsDrop(raw) { found.append("DROP TABLE or DATABASE") }
        return found
    }

    private static func command(name: String, args: [String]) -> String? {
        let flags = Flags(args)
        switch name {
        case "rm":
            if flags.has("r", "R", long: "recursive") && flags.has("f", long: "force") { return "rm with -r and -f" }
        case "git":
            return git(args)
        case "terraform":
            if let sub = args.first(where: { !$0.hasPrefix("-") }), ["apply", "destroy"].contains(sub) { return "terraform \(sub)" }
        case "kubectl":
            if args.contains("delete") { return "kubectl delete" }
        case "dd":
            if args.contains(where: { $0.hasPrefix("of=/dev/") }) { return "dd onto a device" }
        case "chmod":
            if flags.has("R", long: "recursive"), args.contains(where: { ["777", "0777", "a+rwx", "ugo+rwx"].contains($0) }) {
                return "chmod -R 777"
            }
        default:
            if name == "mkfs" || name.hasPrefix("mkfs.") { return "mkfs" }
        }
        return nil
    }

    private static func git(_ args: [String]) -> String? {
        // Global options before the subcommand; -C and -c take a value.
        var index = 0
        while index < args.count, args[index].hasPrefix("-") {
            index += ["-C", "-c"].contains(args[index]) ? 2 : 1
        }
        guard index < args.count else { return nil }
        let sub = args[index]
        let rest = Array(args[(index + 1)...])
        let flags = Flags(rest)
        switch sub {
        case "push":
            if flags.has("f", long: "force") || rest.contains(where: { $0.hasPrefix("--force-with-lease") }) {
                return "git push --force"
            }
            if flags.has("d", long: "delete") || rest.contains("--mirror") { return "git push that deletes remote refs" }
            let refspecs = flags.operands.dropFirst()   // the first operand is the remote
            if refspecs.contains(where: { $0.hasPrefix("+") }) { return "git push with a forced (+) refspec" }
            if refspecs.contains(where: { $0.hasPrefix(":") }) { return "git push that deletes a remote branch" }
        case "reset":
            if rest.contains("--hard") { return "git reset --hard" }
        case "clean":
            if flags.has("f", long: "force"), !flags.has("n", long: "dry-run") { return "git clean -f" }
        default:
            break
        }
        return nil
    }

    /// `drop table` / `drop database` anywhere in the text, as words, without regard to case.
    private static func containsDrop(_ raw: String) -> Bool {
        let words: [Substring] = raw.lowercased().split { (char: Character) -> Bool in !(char.isLetter || char == "_") }
        for index in words.indices.dropLast() where words[index] == "drop" {
            let next = words[index + 1]
            if next == "table" || next == "database" { return true }
        }
        return false
    }

    /// Short flags (combined ones split: `-uf` is u and f), long flags and the other arguments; `--` ends flags.
    struct Flags {
        var short: Set<Character> = []
        var long: Set<String> = []
        var operands: [String] = []

        init(_ args: [String]) {
            var ended = false
            for arg in args {
                if ended || arg == "-" || !arg.hasPrefix("-") {
                    operands.append(arg)
                } else if arg == "--" {
                    ended = true
                } else if arg.hasPrefix("--") {
                    long.insert(String(arg.dropFirst(2).prefix { $0 != "=" }))
                } else {
                    short.formUnion(arg.dropFirst())
                }
            }
        }

        func has(_ letters: Character..., long name: String) -> Bool {
            letters.contains(where: short.contains) || long.contains(name)
        }
    }

    // MARK: splitting

    struct Segment {
        var text: String
        /// Followed by a single `|`, so its output is the next command's input.
        var pipesToNext = false
    }

    /// The simple commands: split at unquoted newlines, `;`, `|`, `||`, `&` and `&&`. Text inside `$( )`,
    /// `<( )` and backquotes stays with its command, for the checks above.
    static func split(_ command: String) -> [Segment] {
        var segments: [Segment] = []
        var current = ""
        var single = false, double = false, escaped = false
        var depth = 0
        var chars = Array(command)[...]
        func end(pipe: Bool) {
            segments.append(Segment(text: current, pipesToNext: pipe))
            current = ""
        }
        while let char = chars.popFirst() {
            if escaped { escaped = false; current.append(char); continue }
            if char == "\\" && !single { escaped = true; current.append(char); continue }
            if char == "'" && !double { single.toggle() }
            else if char == "\"" && !single { double.toggle() }
            else if !single && char == "(" && (current.last == "$" || current.last == "<") { depth += 1 }
            else if !single && char == ")" && depth > 0 { depth -= 1 }
            else if !single && !double && depth == 0 {
                switch char {
                case "\n", ";":
                    end(pipe: false); continue
                case "|":
                    if chars.first == "|" { chars.removeFirst(); end(pipe: false) } else { end(pipe: true) }
                    continue
                case "&":
                    if chars.first == "&" { chars.removeFirst() }
                    end(pipe: false); continue
                default: break
                }
            }
            current.append(char)
        }
        end(pipe: false)
        return segments.filter { !$0.text.allSatisfy(\.isWhitespace) }
    }

    /// Words with quotes and backslashes removed, as the shell would pass them.
    static func words(_ text: String) -> [String] {
        var words: [String] = []
        var current = "", inWord = false
        var single = false, double = false, escaped = false
        for char in text {
            if escaped { current.append(char); escaped = false; inWord = true; continue }
            if char == "\\" && !single { escaped = true; inWord = true; continue }
            if char == "'" && !double { single.toggle(); inWord = true; continue }
            if char == "\"" && !single { double.toggle(); inWord = true; continue }
            if char.isWhitespace && !single && !double {
                if inWord { words.append(current); current = ""; inWord = false }
                continue
            }
            current.append(char)
            inWord = true
        }
        if inWord { words.append(current) }
        return words
    }

    /// The command itself, past `VAR=value` prefixes and wrappers such as sudo, env, nohup and xargs.
    static func commandWords(_ words: [String]) -> [String] {
        var rest = words[...]
        while let first = rest.first {
            let name = baseName(first)
            if first.contains("="), !first.hasPrefix("-"), !first.hasPrefix("=") {
                rest.removeFirst()   // VAR=value
            } else if ["sudo", "doas", "env", "command", "exec", "nohup", "time", "nice", "xargs", "builtin"].contains(name) {
                rest.removeFirst()
                // Their options; sudo -u/-g, nice -n and xargs -I/-n take a value.
                while let option = rest.first, option.hasPrefix("-") {
                    rest.removeFirst()
                    if ["-u", "-g", "-n", "-I", "-P", "-L", "-C"].contains(option) { _ = rest.popFirst() }
                }
            } else {
                break
            }
        }
        return Array(rest)
    }

    static func baseName(_ word: String) -> String {
        word.split(separator: "/").last.map(String.init) ?? word
    }
}
