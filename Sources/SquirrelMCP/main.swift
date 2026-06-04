import Foundation
import SquirrelCore

/// MCP server for Squirrel.
///
/// Speaks Model Context Protocol over stdio (line-delimited JSON-RPC 2.0).
/// Exposes tools that let Claude Code stash ideas into and retrieve ideas from
/// the user's global forest.md.

@main
struct SquirrelMCP {
    static func main() async {
        // Defensive startup: reap orphaned squirrel-mcp instances from prior
        // Claude Code sessions that didn't exit cleanly, and install signal
        // handlers so this instance exits cleanly when its parent goes away.
        // Without this, a stale process holding /usr/local/bin/squirrel-mcp
        // causes new spawns to be SIGKILL'd by macOS at the same path, which
        // surfaces as `Failed to reconnect: -32000` in Claude Code with no
        // useful diagnostic.
        reapOrphanedInstances()
        installSignalHandlers()

        let server = MCPServer()
        await server.run()
    }

    /// Find other squirrel-mcp processes whose parent has died (orphaned by a
    /// Claude Code session that exited without cleaning them up) and terminate
    /// them. Live siblings (whose parent is still alive — e.g., a concurrent
    /// Claude Code session) are left alone.
    static func reapOrphanedInstances() {
        let myPid = ProcessInfo.processInfo.processIdentifier

        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-A", "-o", "pid=,ppid=,comm="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = Pipe()

        do {
            try ps.run()
            ps.waitUntilExit()
        } catch {
            // ps failed; bail silently — we'll let macOS sort it out the hard way.
            return
        }

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        for line in output.split(separator: "\n") {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard cols.count >= 3,
                  let pid = pid_t(cols[0]),
                  let ppid = pid_t(cols[1]) else { continue }
            let comm = cols[2...].joined(separator: " ")
            // Only consider squirrel-mcp processes that aren't us.
            guard comm.contains("squirrel-mcp"), pid != myPid else { continue }
            // Parent dead (or reparented to launchd) → orphan.
            // kill(ppid, 0) returns 0 iff the parent is still alive.
            let parentAlive = (kill(ppid, 0) == 0) && ppid != 1
            guard !parentAlive else { continue }

            FileHandle.standardError.write(Data("[squirrel-mcp] reaping orphaned PID \(pid) (parent \(ppid) is gone)\n".utf8))
            _ = kill(pid, SIGTERM)
            usleep(200_000) // 200ms grace
            if kill(pid, 0) == 0 {
                _ = kill(pid, SIGKILL)
            }
        }
    }

    /// Install graceful-shutdown handlers for SIGTERM/SIGINT. Without these,
    /// the process may linger in odd states when Claude Code tears down the
    /// stdio pipe — which causes the orphan accumulation we just cleaned up.
    static func installSignalHandlers() {
        // DispatchSource on a background queue so the handler still fires while
        // the main thread is blocked in readLine().
        let queue = DispatchQueue.global()
        for sig in [SIGTERM, SIGINT] {
            // Replace the default disposition first so the source actually delivers.
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            src.setEventHandler {
                FileHandle.standardError.write(Data("[squirrel-mcp] received signal \(sig), exiting cleanly\n".utf8))
                Foundation.exit(0)
            }
            src.resume()
            // Retain by storing in a static collection so it isn't deallocated.
            Self.signalSources.append(src)
        }
    }

    // Written exactly once during startup (in installSignalHandlers, called from
    // main before any concurrency); `nonisolated(unsafe)` is the standard escape
    // hatch for "mutable global by spec, but only mutated at startup."
    nonisolated(unsafe) private static var signalSources: [DispatchSourceSignal] = []
}

// MARK: - Server

actor MCPServer {
    private let protocolVersion = "2024-11-05"
    private let stderr = FileHandle.standardError

    func run() async {
        log("squirrel-mcp starting")
        // Claude Code spawns one squirrel-mcp per session with cwd = workspace root.
        // Use that as a one-shot place to (a) register the cwd as a known project,
        // (b) initialize the project's `.claude/nest/` if it doesn't have one yet,
        // and (c) make sure CLAUDE.md @-imports the nest index. All idempotent.
        let cwd = FileManager.default.currentDirectoryPath
        let normalized = (cwd as NSString).standardizingPath
        let autoInitBlocklist: Set<String> = [NSHomeDirectory(), "/", "/tmp", "/private/tmp"]
        if !autoInitBlocklist.contains(normalized) {
            let registered = try? ProjectRegistry.register(path: cwd)
            if let project = registered {
                log("registered project: \(project.name) at \(project.path)")
            }
            let nest = NestStore(projectRoot: cwd)
            if !nest.isInitialized() {
                do {
                    try nest.ensureInitialized()
                    log("initialized nest at \(nest.nestFolder.path)")
                } catch {
                    log("could not initialize nest: \(error.localizedDescription)")
                }
            }
            do {
                try nest.ensureClaudeMdSnippet()
            } catch {
                log("could not update CLAUDE.md: \(error.localizedDescription)")
            }
            // Reconcile forest → nest: materialize a nest file for every forest
            // entry tagged with this project that doesn't have one yet. This is
            // what makes tag-at-capture (and the app's assign dropdown, which
            // writes the forest tag but not the nest file) actually land in the
            // project. Create-only — NestStore.nest() skips files that already
            // exist, so it never clobbers a nest file you've edited.
            if let project = registered {
                let slug = ForestStore.projectTagSlug(project.name)
                let store = ForestStore(forestPath: Configuration.load().forestPath)
                if let entries = try? store.entries() {
                    var created = 0
                    for entry in entries where entry.projectSlugs.contains(slug) {
                        let title = nest.slug(forTitle: entry.title)
                        let existed = FileManager.default.fileExists(
                            atPath: nest.nestFolder.appendingPathComponent("\(title).md").path
                        )
                        if (try? nest.nest(entry: entry)) != nil, !existed { created += 1 }
                    }
                    if created > 0 {
                        log("reconciled \(created) tagged entr\(created == 1 ? "y" : "ies") into nest")
                    }
                }
            }
            // Rebuild INDEX.md on every session start so reconciled entries and any
            // frontmatter edits made between sessions (priority, status) get picked up.
            do {
                try nest.regenerateIndex()
            } catch {
                log("could not regenerate nest INDEX: \(error.localizedDescription)")
            }
            // Stamp this MCP server's start time. session-check uses this as the
            // cutoff for "captured during this session" — anything older is
            // pull-based (find_in_forest). The file persists across restarts but
            // is overwritten on each new MCP startup, so the cursor naturally
            // resets per Claude Code session.
            do {
                try nest.setSessionStartTs(Date())
            } catch {
                log("could not write session-start timestamp: \(error.localizedDescription)")
            }
        }
        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            await handle(rawMessage: trimmed)
        }
        log("stdin closed, exiting")
    }

    private func handle(rawMessage: String) async {
        guard let data = rawMessage.data(using: .utf8),
              let any = try? JSONSerialization.jsonObject(with: data),
              let message = any as? [String: Any] else {
            log("could not parse: \(rawMessage)")
            return
        }

        let id = message["id"]
        let method = message["method"] as? String ?? ""
        let params = message["params"] as? [String: Any] ?? [:]

        // Notifications have no id and expect no response.
        if id == nil {
            switch method {
            case "notifications/initialized":
                log("client signaled initialized")
            default:
                log("ignoring notification \(method)")
            }
            return
        }

        switch method {
        case "initialize":
            sendResult(id: id, result: [
                "protocolVersion": protocolVersion,
                "capabilities": [
                    "tools": [:]
                ],
                "serverInfo": [
                    "name": "squirrel",
                    "version": "0.1.0"
                ]
            ])
        case "tools/list":
            sendResult(id: id, result: ["tools": toolDefinitions()])
        case "tools/call":
            await handleToolCall(id: id, params: params)
        case "ping":
            sendResult(id: id, result: [:])
        default:
            sendError(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    private func handleToolCall(id: Any?, params: [String: Any]) async {
        let name = params["name"] as? String ?? ""
        let arguments = params["arguments"] as? [String: Any] ?? [:]

        switch name {
        case "stash_idea":
            await toolStashIdea(id: id, arguments: arguments)
        case "session_captures":
            toolSessionCaptures(id: id, arguments: arguments)
        case "find_in_forest":
            toolFindInForest(id: id, arguments: arguments)
        case "nest_idea":
            toolNestIdea(id: id, arguments: arguments)
        case "archive_nest":
            toolArchiveNest(id: id, arguments: arguments)
        case "refresh_nest_index":
            toolRefreshNestIndex(id: id, arguments: arguments)
        case "recent_ideas":
            toolRecentIdeas(id: id, arguments: arguments)
        case "ideas_for_project":
            toolIdeasForProject(id: id, arguments: arguments)
        case "untagged_ideas":
            toolUntaggedIdeas(id: id, arguments: arguments)
        case "read_forest":
            toolReadForest(id: id)
        case "list_projects":
            toolListProjects(id: id)
        default:
            sendError(id: id, code: -32602, message: "Unknown tool: \(name)")
        }
    }

    // MARK: - Tool implementations

    private struct ResolvedProject {
        let name: String
        let slug: String
        let source: String
    }

    /// Resolve which project a tool call applies to.
    /// Order: (1) explicit `project` arg, (2) registered project matching cwd,
    /// (3) auto-register cwd as a new project. Returns nil if cwd is too generic
    /// (home dir, root, /tmp) and there's no explicit project.
    private func resolveProject(explicit: String?) -> ResolvedProject? {
        if let explicit, !explicit.isEmpty {
            return ResolvedProject(name: explicit, slug: ForestStore.projectTagSlug(explicit), source: "explicit")
        }
        let cwd = FileManager.default.currentDirectoryPath
        if let existing = ProjectRegistry.find(byPath: cwd) {
            return ResolvedProject(name: existing.name, slug: ForestStore.projectTagSlug(existing.name), source: "registered cwd")
        }
        let normalized = (cwd as NSString).standardizingPath
        let blocklist: Set<String> = [NSHomeDirectory(), "/", "/tmp", "/private/tmp"]
        if blocklist.contains(normalized) { return nil }
        if let newProject = try? ProjectRegistry.register(path: cwd) {
            return ResolvedProject(name: newProject.name, slug: ForestStore.projectTagSlug(newProject.name), source: "auto-registered cwd")
        }
        return nil
    }

    /// NestStore for the project resolved from arguments (or cwd).
    private func nestStore(for project: ResolvedProject) -> NestStore {
        if let registered = ProjectRegistry.find(byName: project.name) {
            return NestStore(projectRoot: registered.path)
        }
        return NestStore(projectRoot: FileManager.default.currentDirectoryPath)
    }

    private func toolStashIdea(id: Any?, arguments: [String: Any]) async {
        guard let text = arguments["text"] as? String else {
            sendError(id: id, code: -32602, message: "stash_idea requires a 'text' string argument")
            return
        }
        let resolved = resolveProject(explicit: arguments["project"] as? String)
        // nest defaults to true whenever we have a project context — the common case
        // is "stash this into the project I'm working in," and that should also
        // materialize a nest file so Claude Code sees it in this and future sessions.
        let shouldNest: Bool = {
            if let explicit = arguments["nest"] as? Bool { return explicit }
            return resolved != nil
        }()

        let config = Configuration.load()
        let service = CaptureService(
            forestPath: config.forestPath,
            summarizeWithClaude: config.summarizeWithClaude,
            anthropicKey: config.anthropicKey,
            claudeModel: config.claudeModel
        )
        do {
            let outcome = try await service.capture(transcript: text, project: resolved?.name)
            switch outcome {
            case .empty:
                sendToolResult(id: id, text: "Empty input — nothing stashed.")
            case .captured(let idea, let summarized):
                var lines: [String] = []
                lines.append("Stashed in \(config.forestPath).")
                lines.append("Title: \(idea.title)")
                if !idea.bullets.isEmpty {
                    lines.append("Bullets:")
                    for bullet in idea.bullets { lines.append("- \(bullet)") }
                }
                if let resolved {
                    lines.append("Tagged: #\(resolved.slug) (\(resolved.source))")
                    if shouldNest {
                        // Read the freshly-appended entry back out so the nest file
                        // contains the same timestamp/title/bullets/raw as global.
                        let store = ForestStore(forestPath: config.forestPath)
                        if let entry = (try? store.entries())?.first(where: { $0.timestampString == ISO8601EncodedString(idea.createdAt) }) {
                            let nest = nestStore(for: resolved)
                            if let url = try? nest.nest(entry: entry) {
                                lines.append("Nested at: \(url.path)")
                            } else {
                                lines.append("Note: stash succeeded but nest write failed.")
                            }
                        }
                    }
                } else {
                    lines.append("No project tag — cwd is too generic (home, /, or /tmp). Re-run with explicit `project`.")
                }
                lines.append(summarized ? "(summarized by Claude)" : "(raw)")
                sendToolResult(id: id, text: lines.joined(separator: "\n"))
            }
        } catch {
            sendToolResult(id: id, text: "Error: \(error.localizedDescription)", isError: true)
        }
    }

    private func toolSessionCaptures(id: Any?, arguments: [String: Any]) {
        guard let resolved = resolveProject(explicit: arguments["project"] as? String) else {
            sendError(id: id, code: -32602, message: "session_captures: no project — current cwd is too generic, pass `project` explicitly.")
            return
        }
        let limit = min((arguments["limit"] as? Int) ?? 20, 20)
        let config = Configuration.load()
        let store = ForestStore(forestPath: config.forestPath)
        let nest = nestStore(for: resolved)

        // Session-scoped: only entries newer than this session's MCP start time.
        // If no session-start exists yet, treat the cutoff as "nothing qualifies"
        // — better to return empty than to spam the whole forest.
        guard let sessionStart = nest.sessionStartTs() else {
            sendToolResult(id: id, text: "No active session timestamp recorded yet — try sending another prompt first, or call `find_in_forest` to search older captures.")
            return
        }

        do {
            let entries = try store.entries().filter { entry in
                guard entry.projectSlugs.isEmpty else { return false }
                guard let ts = entry.timestamp, ts > sessionStart else { return false }
                return true
            }.prefix(limit)

            if entries.isEmpty {
                sendToolResult(id: id, text: "No new captures since this session started (\(ISO8601DateFormatter().string(from: sessionStart))). For older captures, use `find_in_forest`.")
                return
            }
            var blocks: [String] = []
            blocks.append("\(entries.count) capture(s) during this session:\n")
            for (index, entry) in entries.enumerated() {
                let ts = entry.timestampString ?? "?"
                blocks.append("\(index + 1). \(entry.title)  (`\(ts)`)")
                for bullet in entry.bullets.prefix(3) {
                    blocks.append("   • \(bullet)")
                }
                if let raw = entry.raw, !raw.isEmpty {
                    blocks.append("   raw: \(raw)")
                }
                blocks.append("")
            }
            blocks.append("Each item shows the title, summary bullets, and the full raw transcript. The title is a short summary and may be truncated — treat the raw transcript as the source of truth for what the user actually said. Present the numbered list to the user using natural language — never name MCP tools out loud. Ask which should go in this project's nest. They will reply by number (e.g. \"1 and 3\" or \"just 2, skip the others\"). Map numbers to the timestamps shown in backticks; for items they want, call `nest_idea(timestamp, project)`. Items they don't want stay in the forest untouched — they can be found later via `find_in_forest`. Don't renumber or reorder.")
            sendToolResult(id: id, text: blocks.joined(separator: "\n"))
        } catch {
            sendToolResult(id: id, text: "Error: \(error.localizedDescription)", isError: true)
        }
    }

    private func toolFindInForest(id: Any?, arguments: [String: Any]) {
        guard let rawQuery = arguments["query"] as? String, !rawQuery.trimmingCharacters(in: .whitespaces).isEmpty else {
            sendError(id: id, code: -32602, message: "find_in_forest requires a non-empty `query` string.")
            return
        }
        let query = rawQuery.lowercased()
        let limit = min((arguments["limit"] as? Int) ?? 30, 50)

        // Optional since / project filters.
        let since: Date? = {
            if let s = arguments["since"] as? String, let d = ISO8601DateFormatter().date(from: s) { return d }
            return nil
        }()
        let projectFilter: String? = {
            if let p = arguments["project"] as? String, !p.isEmpty {
                return ForestStore.projectTagSlug(p)
            }
            return nil
        }()

        let config = Configuration.load()
        let store = ForestStore(forestPath: config.forestPath)
        do {
            let matches = try store.entries().filter { entry in
                if let since, let ts = entry.timestamp, ts < since { return false }
                if let projectFilter, !entry.projectSlugs.contains(projectFilter) { return false }
                return entry.title.lowercased().contains(query) || entry.body.lowercased().contains(query)
            }.prefix(limit)

            if matches.isEmpty {
                sendToolResult(id: id, text: "No forest entries matching \"\(rawQuery)\"\(projectFilter.map { " in project " + $0 } ?? "")\(since.map { " since " + ISO8601DateFormatter().string(from: $0) } ?? "").")
                return
            }
            var blocks: [String] = []
            blocks.append("\(matches.count) match(es) for \"\(rawQuery)\":\n")
            for entry in matches {
                let ts = entry.timestampString ?? "?"
                let tagSuffix = entry.projectSlugs.isEmpty ? "" : "  [tagged: " + entry.projectSlugs.map { "#\($0)" }.joined(separator: ", ") + "]"
                blocks.append("- \(entry.title)  (`\(ts)`)\(tagSuffix)")
                for bullet in entry.bullets.prefix(3) {
                    blocks.append("  • \(bullet)")
                }
                if let raw = entry.raw, !raw.isEmpty {
                    blocks.append("  raw: \(raw)")
                }
            }
            blocks.append("\nTitles are short summaries and may be truncated — when reasoning about what the user actually said, trust the raw transcript on each entry over the title.")
            sendToolResult(id: id, text: blocks.joined(separator: "\n"))
        } catch {
            sendToolResult(id: id, text: "Error: \(error.localizedDescription)", isError: true)
        }
    }

    private func toolNestIdea(id: Any?, arguments: [String: Any]) {
        guard let timestamp = arguments["timestamp"] as? String, !timestamp.isEmpty else {
            sendError(id: id, code: -32602, message: "nest_idea requires a 'timestamp' string (ISO 8601 from session_captures, find_in_forest, or recent_ideas).")
            return
        }
        guard let resolved = resolveProject(explicit: arguments["project"] as? String) else {
            sendError(id: id, code: -32602, message: "nest_idea: cwd too generic, pass `project` explicitly.")
            return
        }
        let config = Configuration.load()
        let store = ForestStore(forestPath: config.forestPath)
        do {
            guard let entry = try store.entries().first(where: { $0.timestampString == timestamp }) else {
                sendToolResult(id: id, text: "No entry found with timestamp \(timestamp).", isError: true)
                return
            }
            _ = try store.addProjectTag(timestamp: timestamp, project: resolved.name)
            let nest = nestStore(for: resolved)
            let url = try nest.nest(entry: entry)
            sendToolResult(id: id, text: "Nested #\(resolved.slug) → \(url.path)")
        } catch {
            sendToolResult(id: id, text: "Error: \(error.localizedDescription)", isError: true)
        }
    }

    private func toolRefreshNestIndex(id: Any?, arguments: [String: Any]) {
        guard let resolved = resolveProject(explicit: arguments["project"] as? String) else {
            sendError(id: id, code: -32602, message: "refresh_nest_index: cwd too generic, pass `project` explicitly.")
            return
        }
        let nest = nestStore(for: resolved)
        do {
            try nest.regenerateIndex()
            sendToolResult(id: id, text: "Regenerated \(nest.indexFile.path) — grouped by priority, ordered open → deferred → resolved.")
        } catch {
            sendToolResult(id: id, text: "Error: \(error.localizedDescription)", isError: true)
        }
    }

    private func toolArchiveNest(id: Any?, arguments: [String: Any]) {
        guard let slug = arguments["slug"] as? String, !slug.isEmpty else {
            sendError(id: id, code: -32602, message: "archive_nest requires a 'slug' string (the filename without .md).")
            return
        }
        guard let resolved = resolveProject(explicit: arguments["project"] as? String) else {
            sendError(id: id, code: -32602, message: "archive_nest: cwd too generic, pass `project` explicitly.")
            return
        }
        let nest = nestStore(for: resolved)
        do {
            let moved = try nest.archive(slug: slug)
            if moved {
                sendToolResult(id: id, text: "Archived \(slug).md → \(nest.archiveFolder.path)/\(slug).md")
            } else {
                sendToolResult(id: id, text: "No active nest file named \(slug).md.", isError: true)
            }
        } catch {
            sendToolResult(id: id, text: "Error: \(error.localizedDescription)", isError: true)
        }
    }

    private func toolRecentIdeas(id: Any?, arguments: [String: Any]) {
        let limit = (arguments["limit"] as? Int) ?? 20
        let config = Configuration.load()
        let store = ForestStore(forestPath: config.forestPath)
        do {
            let entries = try store.entries().prefix(limit)
            if entries.isEmpty {
                sendToolResult(id: id, text: "Forest is empty.")
                return
            }
            let rendered = entries.map { $0.markdown }.joined(separator: "\n\n")
            sendToolResult(id: id, text: rendered)
        } catch {
            sendToolResult(id: id, text: "Error: \(error.localizedDescription)", isError: true)
        }
    }

    private func toolIdeasForProject(id: Any?, arguments: [String: Any]) {
        guard let projectName = arguments["project"] as? String, !projectName.isEmpty else {
            sendError(id: id, code: -32602, message: "ideas_for_project requires a 'project' string argument")
            return
        }
        let limit = (arguments["limit"] as? Int) ?? 20
        let slug = ForestStore.projectTagSlug(projectName)
        let config = Configuration.load()
        let store = ForestStore(forestPath: config.forestPath)
        do {
            let matches = try store.entries().filter { $0.projectSlugs.contains(slug) }.prefix(limit)
            if matches.isEmpty {
                sendToolResult(id: id, text: "No ideas tagged for project \"\(projectName)\".")
                return
            }
            let rendered = matches.map { $0.markdown }.joined(separator: "\n\n")
            sendToolResult(id: id, text: rendered)
        } catch {
            sendToolResult(id: id, text: "Error: \(error.localizedDescription)", isError: true)
        }
    }

    private func toolUntaggedIdeas(id: Any?, arguments: [String: Any]) {
        let limit = (arguments["limit"] as? Int) ?? 30
        let config = Configuration.load()
        let store = ForestStore(forestPath: config.forestPath)
        do {
            let untagged = try store.entries().filter { $0.projectSlugs.isEmpty }.prefix(limit)
            if untagged.isEmpty {
                sendToolResult(id: id, text: "No untagged ideas — every entry already carries a project tag.")
                return
            }
            var blocks: [String] = []
            for entry in untagged {
                let header = entry.timestampString.map { "[id: \($0)]" } ?? "[id: ?]"
                blocks.append("\(header)\n## \(entry.title)\n\(entry.body)")
            }
            sendToolResult(id: id, text: blocks.joined(separator: "\n\n"))
        } catch {
            sendToolResult(id: id, text: "Error: \(error.localizedDescription)", isError: true)
        }
    }

    private func toolListProjects(id: Any?) {
        let projects = ProjectRegistry.all()
        if projects.isEmpty {
            sendToolResult(id: id, text: "No projects registered. Open Claude Code in a project directory; squirrel-mcp will auto-register the cwd on startup.")
            return
        }
        let isoFormatter = ISO8601DateFormatter()
        let lines = projects.map { project in
            "- \(project.name) — \(project.path) (last seen \(isoFormatter.string(from: project.lastSeenAt)))"
        }
        sendToolResult(id: id, text: lines.joined(separator: "\n"))
    }

    private func toolReadForest(id: Any?) {
        let config = Configuration.load()
        let store = ForestStore(forestPath: config.forestPath)
        do {
            let contents = try store.read()
            if contents.isEmpty {
                sendToolResult(id: id, text: "Forest is empty.")
            } else {
                sendToolResult(id: id, text: contents)
            }
        } catch {
            sendToolResult(id: id, text: "Error: \(error.localizedDescription)", isError: true)
        }
    }

    private nonisolated func ISO8601EncodedString(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    // MARK: - Tool definitions

    private func toolDefinitions() -> [[String: Any]] {
        [
            [
                "name": "stash_idea",
                "description": """
                Capture a new idea into the user's global forest (~/forest.md). The text is \
                summarized by Claude if configured. When `project` is set (or auto-resolved from \
                the cwd), the entry is also nested into that project's .claude/nest/ so it becomes \
                part of the project's loaded context. Use this to (a) record an idea mid-conversation, \
                or (b) migrate items from an existing parking-lot/TODO file into squirrel by looping \
                over them.
                """,
                "inputSchema": [
                    "type": "object",
                    "required": ["text"],
                    "properties": [
                        "text": ["type": "string", "description": "The idea text to stash."],
                        "project": [
                            "type": "string",
                            "description": "Optional project name to tag and nest under. Defaults to the registered project matching the current cwd."
                        ],
                        "nest": [
                            "type": "boolean",
                            "description": "Whether to also write a nest file in the project's .claude/nest/. Defaults to true when a project is resolved."
                        ]
                    ]
                ]
            ],
            [
                "name": "session_captures",
                "description": """
                Return ideas captured during the current Claude Code session (since this MCP \
                server started) as a NUMBERED LIST. Each item: title, ISO timestamp (in \
                backticks), up to 3 summary bullets. Capped at 20. \
                CALL THIS when the user asks about new/recent captures, or right after a hook \
                nudge mentions in-session captures. PRESENT THE NUMBERED LIST TO THE USER \
                USING NATURAL LANGUAGE — never name MCP tools out loud (no \"session_captures\", \
                \"nest_idea\"); say things like \"Want me to add any of these to your nest?\". \
                User replies by number (\"1 and 3\" / \"just 2\"); map to timestamps shown in \
                backticks, then call `nest_idea` per item they choose. Items not chosen stay \
                in the forest untouched (no rejection bookkeeping). DON'T use this for older \
                captures — use `find_in_forest` instead.
                """,
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "project": [
                            "type": "string",
                            "description": "Project name. Defaults to the registered project at the current cwd."
                        ],
                        "since": [
                            "type": "string",
                            "description": "Override the lookback start with an explicit ISO 8601 timestamp."
                        ],
                        "limit": [
                            "type": "integer",
                            "description": "Maximum entries (default 20, hard cap 20)."
                        ]
                    ]
                ]
            ],
            [
                "name": "find_in_forest",
                "description": """
                Substring search over the global forest (~/forest.md). Returns matching entries \
                with timestamps and any project tags so you can route them. CALL THIS when: \
                (a) the user asks \"did I stash anything about X?\" / \"any squirrels for this?\"; \
                (b) you're starting work on a topic that may have been captured before (e.g. \
                starting Plex work → call with query=\"plex\"; refactoring auth → query=\"auth\"); \
                (c) a topic from the conversation matches words that might appear in past \
                captures. Lexical/substring match only — not semantic. If the user names a \
                specific term, that's your strongest signal. Use THIS for anything older than \
                the current session; use `session_captures` for fresh in-session ideas.
                """,
                "inputSchema": [
                    "type": "object",
                    "required": ["query"],
                    "properties": [
                        "query": ["type": "string", "description": "Substring to match (case-insensitive)."],
                        "since": ["type": "string", "description": "Optional ISO 8601 timestamp; only return entries captured after this."],
                        "project": ["type": "string", "description": "Optional project name; only return entries already tagged for that project."],
                        "limit": ["type": "integer", "description": "Max results (default 30, hard cap 50)."]
                    ]
                ]
            ],
            [
                "name": "nest_idea",
                "description": """
                Pull a forest entry into the current project: tag it with #project in global \
                forest.md AND write a {slug}.md file into the project's .claude/nest/. Use when \
                the user says an item is relevant to the project they're in. Identify the entry \
                by its ISO timestamp (returned by session_captures / find_in_forest / recent_ideas).
                """,
                "inputSchema": [
                    "type": "object",
                    "required": ["timestamp"],
                    "properties": [
                        "timestamp": ["type": "string", "description": "ISO 8601 timestamp identifying the entry."],
                        "project": ["type": "string", "description": "Project name. Defaults to cwd's registered project."]
                    ]
                ]
            ],
            [
                "name": "archive_nest",
                "description": """
                Move a nest file from .claude/nest/{slug}.md to .claude/nest/archive/{slug}.md and \
                remove it from INDEX. Use this only when an idea should be REMOVED from the \
                project's always-loaded context (stale, irrelevant, no longer worth thinking about). \
                For DONE items that you want to keep visible as historical record, set \
                `status: resolved` in the file's frontmatter instead and call `refresh_nest_index` — \
                resolved items stay in INDEX but sort below open/deferred. Global forest entry is \
                untouched either way.
                """,
                "inputSchema": [
                    "type": "object",
                    "required": ["slug"],
                    "properties": [
                        "slug": ["type": "string", "description": "The nest file's slug (filename without .md)."],
                        "project": ["type": "string", "description": "Project name. Defaults to cwd's registered project."]
                    ]
                ]
            ],
            [
                "name": "refresh_nest_index",
                "description": """
                Regenerate the project's INDEX.md from the current contents of .claude/nest/. \
                The INDEX lists each parked idea as a title + one-line summary (the summary \
                defaults to the idea's first bullet, or its `summary:` frontmatter override). \
                CALL THIS after editing the `priority:`, `status:`, or `summary:` frontmatter \
                of any nest file, or after rewriting a title/first bullet, so the INDEX \
                reflects the change. Auto-called on MCP startup, so between sessions you don't \
                need it. Within a session, after you edit a nest file directly, call this once.
                """,
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "project": ["type": "string", "description": "Project name. Defaults to cwd's registered project."]
                    ]
                ]
            ],
            [
                "name": "list_projects",
                "description": "List registered projects (name, path, last-seen). Useful for cross-project queries.",
                "inputSchema": ["type": "object", "properties": [:]]
            ],
            [
                "name": "ideas_for_project",
                "description": """
                Return ALL forest entries tagged with #project. Useful for the historical/global \
                view (e.g. counting nested + archived entries for a project, or finding entries \
                tagged for a different project than the current cwd's).
                """,
                "inputSchema": [
                    "type": "object",
                    "required": ["project"],
                    "properties": [
                        "project": ["type": "string", "description": "Project name (case-insensitive)."],
                        "limit": ["type": "integer", "description": "Max entries (default 20)."]
                    ]
                ]
            ],
            [
                "name": "untagged_ideas",
                "description": """
                Return ALL untagged forest entries (across all of time). Rarely the right tool — \
                for in-session captures use `session_captures`; for older captures matching a \
                topic use `find_in_forest`. This one is the rare \"give me everything that's \
                still un-routed\" view, e.g. for a manual audit.
                """,
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "limit": ["type": "integer", "description": "Max entries (default 30)."]
                    ]
                ]
            ],
            [
                "name": "recent_ideas",
                "description": "Return the most-recently-stashed forest entries (most-recent-first). For session-scoped lookups use `session_captures`; for topical search use `find_in_forest`.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "limit": ["type": "integer", "description": "Max entries (default 20)."]
                    ]
                ]
            ],
            [
                "name": "read_forest",
                "description": "Return the entire global forest.md as raw markdown. Use sparingly — prefer the targeted tools above.",
                "inputSchema": ["type": "object", "properties": [:]]
            ]
        ]
    }

    // MARK: - I/O

    private nonisolated func log(_ message: String) {
        let line = "[squirrel-mcp] \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    private func sendResult(id: Any?, result: [String: Any]) {
        var response: [String: Any] = [
            "jsonrpc": "2.0",
            "result": result
        ]
        if let id = id { response["id"] = id }
        write(response)
    }

    private func sendError(id: Any?, code: Int, message: String) {
        var response: [String: Any] = [
            "jsonrpc": "2.0",
            "error": ["code": code, "message": message]
        ]
        if let id = id { response["id"] = id }
        write(response)
    }

    private func sendToolResult(id: Any?, text: String, isError: Bool = false) {
        let result: [String: Any] = [
            "content": [[
                "type": "text",
                "text": text
            ]],
            "isError": isError
        ]
        sendResult(id: id, result: result)
    }

    private func write(_ json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: []),
              var line = String(data: data, encoding: .utf8) else { return }
        line.append("\n")
        FileHandle.standardOutput.write(Data(line.utf8))
    }
}
