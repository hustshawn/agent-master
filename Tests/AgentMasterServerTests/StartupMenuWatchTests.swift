import XCTest
@testable import AgentMasterServerKit

final class StartupMenuWatchTests: XCTestCase {
    func testMenusAreRecognisedThroughEscapeSequencesAndSplitOutput() {
        // The key hints under Kiro's, Claude Code's and Codex's startup menus, styled and spaced as they draw them.
        for hint in ["\u{1b}[2mesc to cancel · \u{1b}[1m↑↓\u{1b}[22m to navigate · ↵ to select\u{1b}[0m",
                     "Enter to confirm\u{1b}[1C·\u{1b}[1CEsc to cancel",
                     "\u{1b}[1menter\u{1b}[22m continue · \u{1b}[1mesc\u{1b}[22m skip"] {
            var watch = StartupMenuWatch()
            watch.output(Data("Welcome\r\n".utf8))
            XCTAssertFalse(watch.isShowing)
            let bytes = Data(hint.utf8)
            watch.output(bytes.prefix(bytes.count / 2))
            watch.output(bytes.dropFirst(bytes.count / 2))
            XCTAssertTrue(watch.isShowing, hint)
        }
    }

    func testOnlyAnAnswerClearsAMenu() {
        var watch = StartupMenuWatch()
        watch.output(Data("↑↓ to navigate · ↵ to select".utf8))
        // An arrow key moves through it; what xterm.js answers by itself (device attributes, focus) is no answer.
        for input in ["\u{1b}[B", "\u{1b}[?1;2c", "\u{1b}[I", "ab"] {
            watch.input(Data(input.utf8))
            XCTAssertTrue(watch.isShowing, input.debugDescription)
        }
        for answer in ["\r", "\u{1b}", "2"] {
            var answered = watch
            answered.input(Data(answer.utf8))
            XCTAssertFalse(answered.isShowing, answer.debugDescription)
        }
        // Once answered, only a menu drawn again shows again.
        watch.input(Data("\r".utf8))
        watch.output(Data("› ask a question".utf8))
        XCTAssertFalse(watch.isShowing)
        watch.output(Data("Enter to confirm · Esc to cancel".utf8))
        XCTAssertTrue(watch.isShowing)
    }

    func testAnEmptyPromptOnScreenMeansReadyUnlessAMenuIsUp() {
        var watch = StartupMenuWatch(promptHints: ["ask a question or describe a task"])
        watch.output(Data("⠋ Launching...\r\n".utf8))
        XCTAssertFalse(watch.isPromptReady)
        // Kiro V2's trust-all-tools warning is drawn over its prompt: the menu comes first.
        watch.output(Data("› ask a question or describe a task ↵\r\nesc to cancel · ↑↓ to navigate · ↵ to select".utf8))
        XCTAssertTrue(watch.isShowing)
        XCTAssertFalse(watch.isPromptReady)
        watch.input(Data("\r".utf8))
        watch.output(Data("\u{1b}[2m›\u{1b}[0m ask a question\u{1b}[1C or describe a task ↵".utf8))
        XCTAssertTrue(watch.isPromptReady)
        XCTAssertFalse(StartupMenuWatch().isPromptReady, "an agent without prompt hints is never ready this way")
    }
}
