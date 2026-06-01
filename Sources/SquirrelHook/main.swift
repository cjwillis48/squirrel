import Foundation
import SquirrelCore

/// The `squirrel-hook` binary exists for exactly one reason: Claude Code's
/// `UserPromptSubmit` hook is subprocess-based, not tool-based, so MCP can't
/// service it. This binary is invoked on every user prompt; it reads cwd's
/// session-start cursor (written by `squirrel-mcp` on its startup) and emits
/// stdout — which Claude Code injects as `additionalContext` for the next
/// turn. Read-only; never writes the cursor.
///
/// Everything else (capture, browse, project management, hook installation) is
/// owned elsewhere: the menu bar app for capture and browse; install.sh for
/// setup; squirrel-mcp for all in-Claude-Code operations.
@main
struct SquirrelHook {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        switch args.first {
        case "session-check":
            handleSessionCheck()
        default:
            FileHandle.standardError.write(Data("usage: squirrel-hook session-check\n".utf8))
            exit(64) // EX_USAGE
        }
    }

    /// Read cwd's session-start timestamp (written by `squirrel-mcp` at startup)
    /// and surface only forest entries captured during *this* Claude Code session.
    /// Anything older is pull-based — model calls `find_in_forest` when relevant.
    static func handleSessionCheck() {
        let cwd = FileManager.default.currentDirectoryPath
        let nest = NestStore(projectRoot: cwd)
        guard nest.isInitialized() else { return }
        guard ProjectRegistry.find(byPath: cwd) != nil else { return }

        // No session-start timestamp = no active session-scoped notion of "new",
        // so emit nothing.
        guard let sessionStart = nest.sessionStartTs() else { return }

        let config = Configuration.load()
        let store = ForestStore(forestPath: config.forestPath)
        let allEntries = (try? store.entries()) ?? []

        // Untagged-for-any-project, captured since this session started, and not
        // yet nudged about. Once a capture has been surfaced to the model once,
        // it stays out of the hook payload for the remainder of this session —
        // the ack line in conversation history is the index entry; everything
        // beyond that is bloat.
        let nudged = nest.nudgedCaptureIDs()
        let inSession = allEntries.filter { entry in
            guard entry.projectSlugs.isEmpty else { return false }
            guard let ts = entry.timestamp, ts > sessionStart else { return false }
            if let tsString = entry.timestampString, nudged.contains(tsString) { return false }
            return true
        }

        if inSession.isEmpty { return }

        var lines: [String] = []
        lines.append("[Squirrel] The user just stashed the items below. Start your reply with one `[Stashed: <title>]` line per item — nothing more on those lines, no commentary — then continue with the user's actual request. Don't expand or discuss the captures unless the user does.")
        lines.append("")
        lines.append("New captures:")
        for entry in inSession.prefix(10) {
            let id = entry.timestampString.map { "`\($0)`" } ?? "?"
            lines.append("  • \(entry.title)  (\(id))")
        }
        if inSession.count > 10 { lines.append("  • (+\(inSession.count - 10) more)") }
        print(lines.joined(separator: "\n"))

        // Optimistically mark these as nudged. Worst case: the model never
        // emits an ack and the user loses one visible bracket line — the
        // capture is still in the forest, retrievable via find_in_forest.
        let toMark = inSession.compactMap { $0.timestampString }
        try? nest.markNudged(toMark)
    }
}
