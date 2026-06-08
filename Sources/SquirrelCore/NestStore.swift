import Foundation

/// The lifecycle state of a nested idea. Each state is a subfolder under
/// `.claude/nest/`, and a file physically lives in the folder matching its
/// `status:` frontmatter. Only `open` is loaded into context (via the top-level
/// INDEX.md that CLAUDE.md imports); the rest are pull-only records.
///
/// - open: on the plate now — the live working queue.
/// - deferred: alive, but parked for later; expected to return to `open`.
/// - done: completed.
/// - dropped: decided against — a tombstone, not a completion.
public enum NestState: String, CaseIterable, Sendable {
    case open, deferred, done, dropped

    /// Map a frontmatter `status:` value (including legacy vocabulary) to a state.
    /// Legacy `resolved` → done, `archived` → dropped. Unknown / missing → open.
    public init(status: String?) {
        switch status?.lowercased() {
        case "deferred": self = .deferred
        case "done", "resolved", "completed": self = .done
        case "dropped", "archived": self = .dropped
        default: self = .open
        }
    }
}

/// Per-project working storage for forest ideas that have been pulled into a project
/// (a "nest"). Lives under `<projectRoot>/.claude/nest/`. Once an idea is nested, its
/// file is owned by the project — squirrel writes it on first nest, the user/Claude
/// edit it freely afterward, and it is never synced back from global forest.md.
///
/// Layout (all under `.claude/nest/`):
///   INDEX.md            digest of `open/` — the one file CLAUDE.md loads
///   .gitignore          ignores everything but itself (the nest is personal)
///   open/<slug>.md      live working queue
///   deferred/<slug>.md  + deferred/INDEX.md
///   done/<slug>.md      + done/INDEX.md
///   dropped/<slug>.md   + dropped/INDEX.md
///
/// Changing a file's `status:` and refreshing moves it into the matching folder —
/// the sweep in `regenerateIndex()` is self-healing in every direction.
public struct NestStore: Sendable {
    public let projectRoot: String

    public init(projectRoot: String) {
        self.projectRoot = projectRoot
    }

    // MARK: - Paths

    public var claudeFolder: URL {
        URL(fileURLWithPath: projectRoot).appendingPathComponent(".claude", isDirectory: true)
    }

    public var nestFolder: URL {
        claudeFolder.appendingPathComponent("nest", isDirectory: true)
    }

    /// The subfolder that holds files in `state`.
    public func folder(for state: NestState) -> URL {
        nestFolder.appendingPathComponent(state.rawValue, isDirectory: true)
    }

    /// The digest for `state`. The `open` digest is hoisted to the top-level
    /// `INDEX.md` (the stable path CLAUDE.md imports); the others live inside
    /// their own folder.
    public func digestFile(for state: NestState) -> URL {
        state == .open ? indexFile : folder(for: state).appendingPathComponent("INDEX.md")
    }

    /// Top-level INDEX.md — the `open` digest, loaded into context via CLAUDE.md.
    public var indexFile: URL {
        nestFolder.appendingPathComponent("INDEX.md")
    }

    public var gitignoreFile: URL {
        nestFolder.appendingPathComponent(".gitignore")
    }

    public var stateFile: URL {
        claudeFolder.appendingPathComponent("squirrel-state.json")
    }

    public var claudeMdFile: URL {
        URL(fileURLWithPath: projectRoot).appendingPathComponent("CLAUDE.md")
    }

    // MARK: - Initialization

    public func isInitialized() -> Bool {
        FileManager.default.fileExists(atPath: nestFolder.path) &&
        FileManager.default.fileExists(atPath: indexFile.path)
    }

    /// Create the nest folder, the `open/` subfolder, an empty top-level INDEX.md,
    /// and (on first creation) a `.gitignore`. Idempotent.
    public func ensureInitialized() throws {
        let fm = FileManager.default
        let folderExisted = fm.fileExists(atPath: nestFolder.path)
        try fm.createDirectory(at: nestFolder, withIntermediateDirectories: true)
        try fm.createDirectory(at: folder(for: .open), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: indexFile.path) {
            try renderDigest(state: .open, items: []).write(to: indexFile, atomically: true, encoding: .utf8)
        }
        // Seed a .gitignore the first time we create the nest folder so the nest
        // defaults to a personal, locally-regenerated parking lot rather than a
        // checked-in backlog. INDEX.md and the slug files are regenerated on every
        // session, so committing them just manufactures drift between git and the
        // working tree. The `!.gitignore` line keeps the ignore file itself
        // trackable so the intent is visible in the repo. Tying this to *first
        // creation* (folder absent) means a user who deletes it to deliberately
        // commit their nest isn't re-fought on every session.
        if !folderExisted && !fm.fileExists(atPath: gitignoreFile.path) {
            try Self.nestGitignoreBody.write(to: gitignoreFile, atomically: true, encoding: .utf8)
        }
    }

    /// Append the standard Squirrel snippet to the project's CLAUDE.md (creating if absent).
    /// Idempotent — looks for the existing import line before writing.
    public func ensureClaudeMdSnippet() throws {
        let importLine = "@.claude/nest/INDEX.md"
        let existing = (try? String(contentsOf: claudeMdFile, encoding: .utf8)) ?? ""
        if existing.contains(importLine) { return }

        let separator = existing.isEmpty ? "" : (existing.hasSuffix("\n") ? "\n" : "\n\n")
        let snippet = """
        ## Squirrel parking lot

        Project-local forest ideas. Treat as known parking-lot items (context, not active tasks unless explicitly worked on):

        \(importLine)
        """
        try (existing + separator + snippet + "\n").write(to: claudeMdFile, atomically: true, encoding: .utf8)
    }

    // MARK: - Nest / state transitions

    /// Find the file for `slug` in whichever state folder (or legacy flat location)
    /// it currently lives. Returns nil if no nest file exists for the slug.
    public func locate(slug: String) -> URL? {
        let fm = FileManager.default
        let name = "\(slug).md"
        for state in NestState.allCases {
            let url = folder(for: state).appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) { return url }
        }
        let legacy = nestFolder.appendingPathComponent(name)
        return fm.fileExists(atPath: legacy.path) ? legacy : nil
    }

    /// Write a nest file for `entry` if one does not already exist (in any state),
    /// then regenerate. New captures land in `open/`. Returns the file URL.
    @discardableResult
    public func nest(entry: ForestEntry) throws -> URL {
        try ensureInitialized()
        let (url, _) = try ensureNestFile(for: entry)
        try regenerateIndex()
        return url
    }

    /// Create-only write: if a file for this slug already exists anywhere, return it
    /// untouched; otherwise write a fresh `open/` file. Does NOT regenerate (callers
    /// batch that). Returns the URL and whether it was newly created.
    @discardableResult
    private func ensureNestFile(for entry: ForestEntry) throws -> (url: URL, created: Bool) {
        let slug = slug(forTitle: entry.title)
        if let existing = locate(slug: slug) { return (existing, false) }
        try FileManager.default.createDirectory(at: folder(for: .open), withIntermediateDirectories: true)
        let file = folder(for: .open).appendingPathComponent("\(slug).md")
        try renderNestFile(entry: entry, slug: slug).write(to: file, atomically: true, encoding: .utf8)
        return (file, true)
    }

    /// Pull every forest entry tagged with `projectSlug` into the nest as an `open/`
    /// file, skipping ones that already have a nest file in any state (create-only —
    /// never clobbers an edited file, never resurrects a done/dropped item). Returns
    /// the count of newly-written files. This is the forest→nest reconcile. It runs
    /// on MCP startup, but the MCP server — and so that startup pass — persists across
    /// `/clear`, so in a long-lived session it can be hours stale. It's therefore
    /// also run on every deliberate pull (e.g. scan-forest) so captures tagged after
    /// boot still land.
    @discardableResult
    public func reconcile(taggedWith projectSlug: String, from store: ForestStore) -> Int {
        guard (try? ensureInitialized()) != nil, let entries = try? store.entries() else { return 0 }
        var created = 0
        for entry in entries where entry.projectSlugs.contains(projectSlug) {
            if let result = try? ensureNestFile(for: entry), result.created { created += 1 }
        }
        // Always regenerate: besides surfacing new files, this self-heals any
        // status edits made since the last refresh (moving files to the right folder).
        try? regenerateIndex()
        return created
    }

    /// Set the lifecycle state of the nest file named `slug` by rewriting its
    /// `status:` frontmatter, then regenerate — which sweeps the file into the
    /// matching folder. Returns true if a file was found and updated.
    @discardableResult
    public func setStatus(slug: String, to state: NestState) throws -> Bool {
        guard let url = locate(slug: slug) else { return false }
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try rewriteStatusLine(in: text, to: state).write(to: url, atomically: true, encoding: .utf8)
        try regenerateIndex()
        return true
    }

    /// Rewrite the first `status:` line inside the frontmatter to `state`,
    /// preserving the rest of the file. Inserts a frontmatter block / status line
    /// if one is missing.
    private func rewriteStatusLine(in text: String, to state: NestState) -> String {
        let statusLine = "status: \(state.rawValue)   # one of: open | deferred | done | dropped"
        var lines = text.components(separatedBy: "\n")
        guard let open = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            return "---\n\(statusLine)\n---\n\n" + text
        }
        var close: Int?
        var i = open + 1
        while i < lines.count {
            if lines[i].trimmingCharacters(in: .whitespaces) == "---" { close = i; break }
            i += 1
        }
        guard let closeIdx = close else {
            return "---\n\(statusLine)\n---\n\n" + text
        }
        if let sIdx = (open + 1..<closeIdx).first(where: {
            lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix("status:")
        }) {
            lines[sIdx] = statusLine
        } else {
            lines.insert(statusLine, at: open + 1)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Index regeneration (sweep + digests)

    private struct DigestItem {
        var slug: String
        var title: String
        var summary: String?
        var priority: String?
    }

    /// Sweep every nest file into the folder matching its `status:`, then rebuild a
    /// digest for each state. This is the self-healing core: edit a file's status
    /// (or drop a legacy flat file in), refresh, and everything lands where it
    /// belongs with up-to-date indexes. Called after any change and on the
    /// `refresh_nest_index` MCP tool / MCP startup.
    public func regenerateIndex() throws {
        try ensureInitialized()
        let fm = FileManager.default

        // 1. Gather candidate files: legacy flat files at nest/ top level (pre-folder
        //    layout — this migrates them) plus everything already in a state folder.
        var candidates: [URL] = []
        if let top = try? fm.contentsOfDirectory(at: nestFolder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            candidates += top.filter { $0.pathExtension == "md" && $0.lastPathComponent != "INDEX.md" }
        }
        for state in NestState.allCases {
            if let urls = try? fm.contentsOfDirectory(at: folder(for: state), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                candidates += urls.filter { $0.pathExtension == "md" && $0.lastPathComponent != "INDEX.md" }
            }
        }

        // 1b. Legacy migration: the previous design moved "archived" files into
        //     nest/archive/. Those are abandoned items → dropped. Force their status
        //     to dropped (they may still read open/resolved from before) so the sweep
        //     routes them to dropped/ instead of resurrecting them into open/.
        let legacyArchive = nestFolder.appendingPathComponent("archive", isDirectory: true)
        if let urls = try? fm.contentsOfDirectory(at: legacyArchive, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for url in urls where url.pathExtension == "md" && url.lastPathComponent != "INDEX.md" {
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                try? rewriteStatusLine(in: text, to: .dropped).write(to: url, atomically: true, encoding: .utf8)
                candidates.append(url)
            }
        }

        // 2. Move any file that isn't in the folder its status dictates.
        for url in candidates {
            let desired = NestState(status: readFrontmatter(from: url).status)
            let target = folder(for: desired).appendingPathComponent(url.lastPathComponent)
            if url.standardizedFileURL == target.standardizedFileURL { continue }
            try fm.createDirectory(at: folder(for: desired), withIntermediateDirectories: true)
            if fm.fileExists(atPath: target.path) { try? fm.removeItem(at: target) }
            try fm.moveItem(at: url, to: target)
        }

        // 2b. Remove the now-empty legacy archive/ folder (only if truly empty).
        if let remaining = try? fm.contentsOfDirectory(at: legacyArchive, includingPropertiesForKeys: nil), remaining.isEmpty {
            try? fm.removeItem(at: legacyArchive)
        }

        // 3. Rebuild each state's digest from its (now-correct) contents.
        for state in NestState.allCases {
            try writeDigest(for: state)
        }
    }

    /// Build the digest for one state from the files now in its folder. The `open`
    /// digest (top-level INDEX.md) is always written so the CLAUDE.md @-import never
    /// dangles; the others are written only when their folder is non-empty and
    /// removed when it empties out, so stale digests don't linger.
    private func writeDigest(for state: NestState) throws {
        let fm = FileManager.default
        let dir = folder(for: state)
        let urls = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        var items: [DigestItem] = []
        for url in urls where url.pathExtension == "md" && url.lastPathComponent != "INDEX.md" {
            let slug = url.deletingPathExtension().lastPathComponent
            let f = readFrontmatter(from: url)
            let (title, firstBullet) = titleAndFirstBullet(from: url, slug: slug)
            // Frontmatter `summary:` is an explicit override; otherwise lead with the
            // first bullet so the digest reads as a one-line gloss of the idea.
            items.append(DigestItem(slug: slug, title: title, summary: f.summary ?? firstBullet, priority: f.priority))
        }

        let digest = digestFile(for: state)
        if state != .open && items.isEmpty {
            // Folder emptied out: drop its digest, and the folder too if nothing
            // else remains, so the nest doesn't accumulate stale dirs. (The sweep
            // re-creates the folder before moving a file in, so this is safe.) Only
            // remove the dir when truly empty — never recursively.
            if fm.fileExists(atPath: digest.path) { try? fm.removeItem(at: digest) }
            let remaining = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            if remaining.isEmpty { try? fm.removeItem(at: dir) }
            return
        }
        try renderDigest(state: state, items: items).write(to: digest, atomically: true, encoding: .utf8)
    }

    /// Render a digest: header + items grouped by priority. Each bullet carries the
    /// `(state/slug)` path so a reader can jump straight to the file.
    private func renderDigest(state: NestState, items: [DigestItem]) -> String {
        var lines = headerLines(for: state)

        let grouped = Dictionary(grouping: items, by: { $0.priority ?? "" })
        let orderedKeys: [String] = grouped.keys.sorted { a, b in
            switch (a.isEmpty, b.isEmpty) {
            case (true, false): return false
            case (false, true): return true
            default: break
            }
            if let na = parsePriorityNumber(a), let nb = parsePriorityNumber(b) {
                return na < nb
            }
            return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }

        for key in orderedKeys {
            lines.append(key.isEmpty ? "## (no priority)" : "## \(key)")
            for item in (grouped[key] ?? []).sorted(by: { $0.slug < $1.slug }) {
                lines.append(indexLine(ref: "\(state.rawValue)/\(item.slug)", title: item.title, summary: item.summary))
            }
            lines.append("")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Render one digest bullet: `- **Title** — summary `(state/slug)``.
    private func indexLine(ref: String, title: String, summary: String?) -> String {
        var line = "- **\(title)**"
        if let summary, !summary.isEmpty {
            line += " — \(clampSummary(summary))"
        }
        line += " `(\(ref))`"
        return line
    }

    /// Per-state digest header. Only `open` is loaded into context.
    private func headerLines(for state: NestState) -> [String] {
        switch state {
        case .open:
            return [
                "# Squirrel nest — open",
                "",
                "Auto-managed by squirrel-mcp. Open items for this project — title, a one-line",
                "summary, and the `(open/slug)` path of the file under `.claude/nest/open/`. This",
                "is the only digest loaded via CLAUDE.md. Lifecycle: set a file's `status:` to",
                "done / deferred / dropped and it moves to that folder on the next refresh.",
                ""
            ]
        case .deferred:
            return [
                "# Squirrel nest — deferred",
                "",
                "Parked for later (not loaded into context). Set `status: open` in a file to",
                "bring it back into the open list.",
                ""
            ]
        case .done:
            return [
                "# Squirrel nest — done",
                "",
                "Completed items for this project (a record, not loaded into context). Set",
                "`status: open` in a file to reopen it.",
                ""
            ]
        case .dropped:
            return [
                "# Squirrel nest — dropped",
                "",
                "Decided against — kept as a record (not loaded into context). Not the same as",
                "done: these were abandoned, not finished.",
                ""
            ]
        }
    }

    /// Trim a summary to a single tidy line for the digest (the full text lives in the
    /// idea file). Collapses internal newlines and clamps to a word boundary.
    private func clampSummary(_ raw: String, maxWords: Int = 18) -> String {
        let oneLine = raw.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        let words = oneLine.split(separator: " ").map(String.init)
        guard words.count > maxWords else { return oneLine }
        return words.prefix(maxWords).joined(separator: " ") + "…"
    }

    /// Read the `# Heading` title and first `- bullet` from a nest file body.
    /// Falls back to a de-slugged title when no heading is present.
    private func titleAndFirstBullet(from url: URL, slug: String) -> (title: String, firstBullet: String?) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return (deslug(slug), nil)
        }
        var title: String?
        var firstBullet: String?
        var inFrontmatter = false
        var sawFrontmatterOpen = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" {
                if !sawFrontmatterOpen { sawFrontmatterOpen = true; inFrontmatter = true }
                else if inFrontmatter { inFrontmatter = false }
                continue
            }
            if inFrontmatter { continue }
            if title == nil, trimmed.hasPrefix("# ") {
                title = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            } else if firstBullet == nil, trimmed.hasPrefix("- ") {
                firstBullet = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
            if title != nil && firstBullet != nil { break }
        }
        return (title ?? deslug(slug), firstBullet)
    }

    /// Turn a kebab slug back into a readable title as a last-resort fallback.
    private func deslug(_ slug: String) -> String {
        let words = slug.split(separator: "-").map(String.init)
        guard let first = words.first else { return slug }
        return ([first.capitalized] + words.dropFirst()).joined(separator: " ")
    }

    /// Parse the YAML-ish frontmatter at the top of a nest file. Only `status`,
    /// `priority`, and `summary` are read; everything else is ignored. Returns empty
    /// values if the file has no frontmatter block.
    public func readFrontmatter(from url: URL) -> (status: String?, priority: String?, summary: String?) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return (nil, nil, nil) }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let firstIdx = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            return (nil, nil, nil)
        }
        // Find the closing --- after the opener.
        var endIdx: Int?
        for i in (firstIdx + 1)..<lines.count {
            if lines[i].trimmingCharacters(in: .whitespaces) == "---" {
                endIdx = i
                break
            }
        }
        guard let endIdx else { return (nil, nil, nil) }

        var status: String?
        var priority: String?
        var summary: String?
        for i in (firstIdx + 1)..<endIdx {
            let raw = lines[i]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = trimmed[..<colon].trimmingCharacters(in: .whitespaces)
            let value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch key {
            // `summary` is free prose — take it verbatim (a `#` is content, not a comment).
            case "summary": summary = value.isEmpty ? nil : value
            // `status`/`priority` use the `value  # comment` convention; strip the comment.
            case "status": status = stripTrailingComment(value).isEmpty ? nil : stripTrailingComment(value)
            case "priority": priority = stripTrailingComment(value).isEmpty ? nil : stripTrailingComment(value)
            default: continue
            }
        }
        return (status, priority, summary)
    }

    /// Strip a trailing `  # comment` (hash preceded by whitespace) from a frontmatter
    /// value, leaving inline `#`s that are part of the value alone.
    private func stripTrailingComment(_ value: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "\\s+#.*$") else { return value }
        let ns = value as NSString
        let range = NSRange(location: 0, length: ns.length)
        return regex.stringByReplacingMatches(in: value, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespaces)
    }

    private func parsePriorityNumber(_ s: String) -> Int? {
        // Matches `P0`, `P1`, … `P99` (case-insensitive).
        let lowered = s.lowercased()
        guard lowered.hasPrefix("p"), lowered.count >= 2 else { return nil }
        return Int(lowered.dropFirst())
    }

    // MARK: - Session-start timestamp
    //
    // Written by `squirrel-mcp` on startup to mark when the current Claude Code
    // session began. `session_captures` reads this as the cutoff for "captured
    // during this session."

    public func sessionStartTs() -> Date? {
        guard let data = try? Data(contentsOf: stateFile),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let str = obj["session_start_ts"] as? String else { return nil }
        return ISO8601DateFormatter().date(from: str)
    }

    public func setSessionStartTs(_ date: Date) throws {
        try ensureInitialized()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        // New session = clean slate. Resetting `nudged_capture_ids` here means
        // any capture written in a prior session that was acked then will be
        // re-introduced if it's still untagged when *this* session starts.
        let dict: [String: Any] = [
            "session_start_ts": formatter.string(from: date),
            "nudged_capture_ids": []
        ]
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: stateFile, options: [.atomic])
    }

    // MARK: - One-shot nudges
    //
    // Each in-session capture gets at most one prompt-time nudge per session:
    // the model surfaces it once, acks it, and subsequent prompts no longer carry
    // the same reminder. Persistence lives in `squirrel-state.json` alongside
    // `session_start_ts`; the set is cleared on every MCP startup.

    public func nudgedCaptureIDs() -> Set<String> {
        guard let data = try? Data(contentsOf: stateFile),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["nudged_capture_ids"] as? [String] else { return [] }
        return Set(arr)
    }

    public func markNudged(_ ids: [String]) throws {
        guard !ids.isEmpty else { return }
        try ensureInitialized()
        var dict: [String: Any] = [:]
        if let data = try? Data(contentsOf: stateFile),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            dict = obj
        }
        var union = (dict["nudged_capture_ids"] as? [String]) ?? []
        for id in ids where !union.contains(id) { union.append(id) }
        dict["nudged_capture_ids"] = union
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: stateFile, options: [.atomic])
    }

    // MARK: - Slug

    /// Generate a kebab-case slug from a title, capped at `maxWords` and ASCII-safe.
    public func slug(forTitle title: String, maxWords: Int = 4) -> String {
        let normalized = title.lowercased()
        var words: [String] = []
        var current = ""
        for scalar in normalized.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else {
                if !current.isEmpty {
                    words.append(current)
                    current = ""
                    if words.count >= maxWords { break }
                }
            }
        }
        if !current.isEmpty && words.count < maxWords { words.append(current) }
        let base = words.joined(separator: "-")
        return base.isEmpty ? "untitled" : base
    }

    // MARK: - Internals

    /// Seeded into `.claude/nest/.gitignore` on first nest creation. Ignores the
    /// regenerated digests and all slug files while keeping the ignore file itself
    /// trackable, so a fresh clone can see the nest is personal by design.
    static let nestGitignoreBody = """
    # Squirrel nest: a personal "don't forget this while I'm in here" parking lot,
    # regenerated locally every session — not a shared backlog. Ignored on purpose.
    # Delete this file if you'd rather commit the nest as a shared project backlog.
    *
    !.gitignore
    """ + "\n"

    private func renderNestFile(entry: ForestEntry, slug: String) -> String {
        let ts = entry.timestampString ?? ISO8601DateFormatter().string(from: Date())
        var lines: [String] = []
        lines.append("---")
        lines.append("captured: \(ts)")
        lines.append("slug: \(slug)")
        lines.append("status: open   # one of: open | deferred | done | dropped")
        lines.append("# priority: P0   # optional, freeform — e.g. P0/P1/P2, high/medium/low, now/next/later")
        lines.append("# summary:    # optional one-liner for the digest; defaults to the first bullet below")
        lines.append("---")
        lines.append("")
        lines.append("# \(entry.title)")
        lines.append("")
        for b in entry.bullets {
            lines.append("- \(b)")
        }
        if !entry.bullets.isEmpty { lines.append("") }

        if let raw = entry.raw, !raw.isEmpty {
            lines.append("## Raw capture")
            lines.append("")
            for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: false) {
                lines.append("> \(rawLine)")
            }
            if let dur = entry.durationSeconds, dur > 0 {
                lines.append("> ")
                lines.append("> _Captured \(ts), \(String(format: "%.1f", dur))s_")
            } else {
                lines.append("> ")
                lines.append("> _Captured \(ts)_")
            }
            lines.append("")
        }

        lines.append("## Notes")
        lines.append("")
        lines.append("<!-- project-local notes accumulate here as you investigate -->")
        lines.append("")
        return lines.joined(separator: "\n")
    }

}
