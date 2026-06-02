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

        // Two tiers, both drawn from forest entries untagged for any project:
        //
        //  FRESH  — captured since this session started and not yet acked. The
        //           model MUST confirm these once (a stash you can't see landing
        //           breaks trust). Marked nudged after, so they never re-ack.
        //  PARKED — everything else still untagged (older than this session, or
        //           already acked this session). NOT shown by default. Provided to
        //           the model as candidates; surfaced only when one is genuinely
        //           relevant to the current turn, flagged `[likely relevant]`.
        //           Never marked nudged — relevance-gated re-surfacing isn't
        //           pestering, and tagging/nesting an item drops it from the pool.
        let nudged = nest.nudgedCaptureIDs()
        let untagged = allEntries.filter { $0.projectSlugs.isEmpty }
        let fresh = untagged.filter { entry in
            guard let ts = entry.timestamp, ts > sessionStart else { return false }
            if let tsString = entry.timestampString, nudged.contains(tsString) { return false }
            return true
        }
        let freshIDs = Set(fresh.compactMap { $0.timestampString })
        // `allEntries` is most-recent-first, so prefix() keeps the freshest parked.
        let parked = untagged
            .filter { entry in
                guard let id = entry.timestampString else { return false }
                return !freshIDs.contains(id)
            }
            .prefix(6)

        if fresh.isEmpty && parked.isEmpty { return }

        var lines: [String] = []
        lines.append(Self.instruction)
        if !fresh.isEmpty {
            lines.append("")
            lines.append("NEW captures (always confirm these):")
            for entry in fresh.prefix(10) {
                let id = entry.timestampString.map { "`\($0)`" } ?? "?"
                lines.append("  • \(entry.title)  (\(id))")
            }
            if fresh.count > 10 { lines.append("  • (+\(fresh.count - 10) more)") }
        }
        if !parked.isEmpty {
            lines.append("")
            lines.append("PARKED ideas (untriaged — surface ONLY if clearly relevant to this turn):")
            for entry in parked {
                let id = entry.timestampString.map { "`\($0)`" } ?? "?"
                lines.append("  • \(entry.title)  (\(id))")
            }
        }
        print(lines.joined(separator: "\n"))

        // One-shot only for FRESH. Parked items are deliberately left unmarked so
        // they can resurface on a later, genuinely-relevant turn.
        let toMark = fresh.compactMap { $0.timestampString }
        try? nest.markNudged(toMark)
    }

    /// The behavioral spec handed to the model. Not shown to the user — it tells
    /// the model how to render the Squirrel block. Backticks are intentional: the
    /// user's terminal theme tints inline code, so the markers render in colour.
    static let instruction = """
    [Squirrel] Below are the user's parked ideas. Answer the user's actual request FIRST, then \
    render a Squirrel block as the VERY LAST thing in your reply — nothing after it. The block is a \
    markdown blockquote so it renders set-apart from your own answer. A long answer with tool use \
    buries anything at the top, so this goes at the bottom on purpose.

    Render it EXACTLY like this, keeping the backticks (they colour the markers in the user's theme):

    > `[🐿️ Squirrel]` — captured while we talked:
    > 1. <new capture title>
    > 2. <new capture title>
    >
    > Want any recorded for this project? Just say which (e.g. "1 and 3").

    Rules:
    - Pick the intro line to match what's shown: "captured while we talked:" when there are new \
    captures; "possibly relevant to this:" when the block is ONLY a relevant parked idea.
    - Number every shown item in one list so "nest 1 and 3" maps cleanly.
    - NEW captures are listed unconditionally — one numbered line each, title only, no commentary.
    - PARKED ideas are hidden BY DEFAULT. Include a parked idea ONLY if it is clearly relevant to \
    what the user is asking or doing THIS turn. When you do, mark it: `[likely relevant]` <title> — \
    <≤8 words on why it fits>. If unsure, leave it out — a false "relevant" erodes trust faster than \
    a miss. If none are relevant, show nothing about parked ideas (and if there are also no new \
    captures, output NO block at all).
    - Stay inside the blockquote. Don't expand or discuss the ideas unless the user does.
    """
}
