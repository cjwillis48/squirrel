import Foundation

/// Per-project working storage for forest ideas that have been pulled into a project
/// (a "nest"). Lives under `<projectRoot>/.claude/nest/`. Once an idea is nested, its
/// file is owned by the project — squirrel writes it on first nest, the user/Claude
/// edit it freely afterward, and it is never synced back from global forest.md.
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

    public var archiveFolder: URL {
        nestFolder.appendingPathComponent("archive", isDirectory: true)
    }

    public var indexFile: URL {
        nestFolder.appendingPathComponent("INDEX.md")
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

    /// Create the nest folder + empty INDEX.md if absent. Idempotent.
    public func ensureInitialized() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: nestFolder, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: indexFile.path) {
            try Self.emptyIndexBody.write(to: indexFile, atomically: true, encoding: .utf8)
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

    // MARK: - Nest / archive

    /// Write a nest file for `entry` if one does not already exist, and ensure the
    /// INDEX reflects the current nest contents (grouped by priority). Returns the
    /// file URL written or referenced.
    @discardableResult
    public func nest(entry: ForestEntry) throws -> URL {
        try ensureInitialized()
        let slug = slug(forTitle: entry.title)
        let file = nestFolder.appendingPathComponent("\(slug).md")

        if !FileManager.default.fileExists(atPath: file.path) {
            let body = renderNestFile(entry: entry, slug: slug)
            try body.write(to: file, atomically: true, encoding: .utf8)
        }
        try regenerateIndex()
        return file
    }

    /// Move the named nest file into the archive subfolder and regenerate INDEX.
    /// Returns true if a file was moved.
    @discardableResult
    public func archive(slug: String) throws -> Bool {
        let fm = FileManager.default
        let source = nestFolder.appendingPathComponent("\(slug).md")
        guard fm.fileExists(atPath: source.path) else { return false }

        try fm.createDirectory(at: archiveFolder, withIntermediateDirectories: true)
        let target = archiveFolder.appendingPathComponent("\(slug).md")
        if fm.fileExists(atPath: target.path) {
            try fm.removeItem(at: target)
        }
        try fm.moveItem(at: source, to: target)
        try regenerateIndex()
        return true
    }

    /// Rebuild INDEX.md from the current contents of the nest folder, grouped by
    /// `priority:` frontmatter and ordered open → deferred → resolved within each
    /// group. Call this after any direct edit to a nest file's frontmatter (or via
    /// the `refresh_nest_index` MCP tool).
    public func regenerateIndex() throws {
        try ensureInitialized()
        let fm = FileManager.default
        let contents = try fm.contentsOfDirectory(at: nestFolder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])

        struct Item {
            var slug: String
            var title: String
            var summary: String?
            var priority: String?
            var status: String
        }

        var items: [Item] = []
        for url in contents {
            guard url.pathExtension == "md", url.lastPathComponent != "INDEX.md" else { continue }
            let slug = url.deletingPathExtension().lastPathComponent
            let fm = readFrontmatter(from: url)
            let (title, firstBullet) = titleAndFirstBullet(from: url, slug: slug)
            // Frontmatter `summary:` is an explicit override; otherwise lead with the
            // first bullet so the index reads as a one-line gloss of the idea.
            let summary = fm.summary ?? firstBullet
            items.append(Item(slug: slug, title: title, summary: summary, priority: fm.priority, status: fm.status ?? "open"))
        }

        // Group by priority. Sort priorities so P-numbers go in numeric order,
        // anything else sorts alphabetically, no-priority lands last.
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

        var lines: [String] = []
        lines.append(contentsOf: Self.indexHeaderLines)

        for key in orderedKeys {
            let heading = key.isEmpty ? "## (no priority)" : "## \(key)"
            lines.append(heading)
            // Within a priority bucket: open first, deferred next, resolved last.
            let bucket = (grouped[key] ?? []).sorted { lhs, rhs in
                statusRank(lhs.status) < statusRank(rhs.status) ||
                (statusRank(lhs.status) == statusRank(rhs.status) && lhs.slug < rhs.slug)
            }
            for item in bucket {
                lines.append(indexLine(for: item.slug, title: item.title, summary: item.summary, status: item.status))
            }
            lines.append("")
        }

        try lines.joined(separator: "\n").write(to: indexFile, atomically: true, encoding: .utf8)
    }

    /// Render one INDEX bullet: `- **Title** — summary (slug) <!-- status -->`.
    /// The bare slug is kept so a reader (or the user) can jump straight to
    /// `.claude/nest/<slug>.md` for the full entry without guessing the filename.
    private func indexLine(for slug: String, title: String, summary: String?, status: String) -> String {
        var line = "- **\(title)**"
        if let summary, !summary.isEmpty {
            line += " — \(clampSummary(summary))"
        }
        line += " `(\(slug))`"
        switch status.lowercased() {
        case "open": break
        case "deferred": line += "  <!-- deferred -->"
        case "resolved": line += "  <!-- resolved -->"
        default: line += "  <!-- \(status) -->"
        }
        return line
    }

    /// Trim a summary to a single tidy line for the index (the full text lives in the
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

    private func statusRank(_ status: String) -> Int {
        switch status.lowercased() {
        case "open": return 0
        case "deferred": return 1
        case "resolved": return 2
        default: return 3
        }
    }

    // MARK: - Session-start timestamp
    //
    // Written by `squirrel-mcp` on startup to mark when the current Claude Code
    // session began. `session-check` and `session_captures` both read this as
    // the cutoff for "captured during this session."

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
    // the hook surfaces it once, the model acks it, and subsequent prompts no
    // longer carry the same reminder. Persistence lives in `squirrel-state.json`
    // alongside `session_start_ts`; the set is cleared on every MCP startup.

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
    /// Collision handling (appending a timestamp suffix) is applied if a file already
    /// exists for the base slug AND that file's `captured:` frontmatter differs from
    /// the caller's intent — i.e., we only suffix when this is genuinely a different
    /// idea sharing a similar title.
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

    /// Header lines shared by the empty index and every regeneration. Kept as a
    /// single source so the prose can't drift between the two write paths.
    static let indexHeaderLines: [String] = [
        "# Squirrel nest",
        "",
        "Auto-managed by squirrel-mcp. Parked ideas for this project — title, a one-line",
        "summary, and the `(slug)` of the file under `.claude/nest/` that holds the full",
        "detail. This index is loaded via CLAUDE.md; open a slug's file only when you act on it.",
        ""
    ]

    private static let emptyIndexBody = indexHeaderLines.joined(separator: "\n") + "\n"

    private func renderNestFile(entry: ForestEntry, slug: String) -> String {
        let ts = entry.timestampString ?? ISO8601DateFormatter().string(from: Date())
        var lines: [String] = []
        lines.append("---")
        lines.append("captured: \(ts)")
        lines.append("slug: \(slug)")
        lines.append("status: open   # one of: open | deferred | resolved | archived")
        lines.append("# priority: P0   # optional, freeform — e.g. P0/P1/P2, high/medium/low, now/next/later")
        lines.append("# summary:    # optional one-liner for INDEX.md; defaults to the first bullet below")
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
