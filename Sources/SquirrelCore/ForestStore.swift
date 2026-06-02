import Foundation

/// Append-only sink for ideas. Single global forest.md, no per-project routing.
public struct ForestStore: Sendable {
    public var forestPath: String

    public init(forestPath: String) {
        self.forestPath = forestPath
    }

    public var forestURL: URL {
        URL(fileURLWithPath: forestPath)
    }

    @discardableResult
    public func append(idea: Idea) throws -> URL {
        let url = forestURL
        let entry = formatEntry(idea: idea)

        let fm = FileManager.default
        let parent = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: parent.path) {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        }

        if fm.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            if let data = ("\n" + entry).data(using: .utf8) {
                try handle.write(contentsOf: data)
            }
        } else {
            let header = "# Forest\n\nA running parking lot of ideas captured by Squirrel.\n\n"
            try (header + entry).write(to: url, atomically: true, encoding: .utf8)
        }

        return url
    }

    /// Returns the full forest contents, or an empty string if the file doesn't exist.
    public func read() throws -> String {
        let url = forestURL
        guard FileManager.default.fileExists(atPath: url.path) else { return "" }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Parses the forest into individual entries by `## ` headings. Returns most-recent-first.
    public func entries() throws -> [ForestEntry] {
        let text = try read()
        guard !text.isEmpty else { return [] }

        var entries: [ForestEntry] = []
        var currentBody: [String] = []
        var currentTitle: String?

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for line in lines {
            if line.hasPrefix("## ") {
                if let title = currentTitle {
                    entries.append(ForestEntry(title: title, body: currentBody.joined(separator: "\n")))
                }
                currentTitle = String(line.dropFirst(3))
                currentBody = []
            } else if currentTitle != nil {
                currentBody.append(line)
            }
        }
        if let title = currentTitle {
            entries.append(ForestEntry(title: title, body: currentBody.joined(separator: "\n")))
        }
        // File is oldest → newest; reverse for most-recent-first.
        return entries.reversed()
    }

    /// Remove the entry whose metadata line carries the given timestamp.
    /// Returns true if an entry was found and removed.
    @discardableResult
    public func deleteEntry(timestamp: String) throws -> Bool {
        let original = try read()
        guard !original.isEmpty else { return false }

        let lines = original.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var output: [String] = []
        var skipping = false
        var found = false
        var pendingHeading: String?
        // We walk the file. When we see "## ", we hold it until we know whether the
        // following metadata line carries the target timestamp.
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if line.hasPrefix("## ") {
                // Flush any previously-held heading (means it wasn't the target).
                if let prev = pendingHeading {
                    output.append(prev)
                    pendingHeading = nil
                }
                // A new entry starts here, so stop discarding the previous one.
                // Critical: when the entry we just deleted was the target, its
                // heading was nil'd on match (so the flush above is a no-op) — if we
                // didn't reset skipping here we'd keep discarding into THIS following
                // entry, eating its metadata + body and leaving its heading orphaned
                // (an entry with no timestamp, which then can't be deleted at all).
                skipping = false
                pendingHeading = line
                i += 1
                // Look ahead for the metadata line within the next few lines (skip blanks).
                var j = i
                while j < lines.count, lines[j].trimmingCharacters(in: .whitespaces).isEmpty {
                    j += 1
                }
                if j < lines.count, lines[j].contains("`\(timestamp)`") {
                    // Skip this entry entirely up to the next "## " or EOF.
                    found = true
                    pendingHeading = nil
                    skipping = true
                }
                continue
            }
            if pendingHeading != nil {
                // Buffer everything (including the metadata line) until we know.
                if skipping {
                    // Still inside the target entry — discard.
                    i += 1
                    continue
                }
                // Not the target — flush the heading first, then this line.
                output.append(pendingHeading!)
                pendingHeading = nil
                output.append(line)
                i += 1
                continue
            }
            if skipping {
                // We're inside an entry we're discarding; skip its body lines.
                i += 1
                continue
            }
            output.append(line)
            i += 1
        }
        if let prev = pendingHeading {
            output.append(prev)
        }

        guard found else { return false }

        // Collapse runs of >2 blank lines into 2 to keep formatting tidy after removal.
        var collapsed: [String] = []
        var blankRun = 0
        for line in output {
            if line.isEmpty {
                blankRun += 1
                if blankRun <= 2 { collapsed.append(line) }
            } else {
                blankRun = 0
                collapsed.append(line)
            }
        }

        let result = collapsed.joined(separator: "\n")
        try result.write(to: forestURL, atomically: true, encoding: .utf8)
        return true
    }

    /// Assign or clear THE project tag for the entry matching `timestamp` (replace semantics).
    /// `project` may be nil to remove the tag. Used by the menu bar UI's single-project picker.
    /// For multi-tag append semantics, use `addProjectTag`.
    public func assignProject(timestamp: String, project: String?) throws -> Bool {
        try mutateMetadataLine(timestamp: timestamp) { oldLine in
            Self.replaceProjectTag(in: oldLine, with: project)
        }
    }

    /// Append a `#project` tag to the entry's metadata line if not already present.
    /// Multiple project tags are allowed — used when an idea is "nested" into a project
    /// without disturbing existing nest relationships with other projects.
    @discardableResult
    public func addProjectTag(timestamp: String, project: String) throws -> Bool {
        let slug = Self.projectTagSlug(project)
        guard !slug.isEmpty else { return false }
        return try mutateMetadataLine(timestamp: timestamp) { oldLine in
            // Idempotent: only append if this tag isn't already on the line.
            let pattern = "·\\s*#\(NSRegularExpression.escapedPattern(for: slug))\\b"
            if let regex = try? NSRegularExpression(pattern: pattern, options: []),
               regex.firstMatch(in: oldLine, range: NSRange(location: 0, length: (oldLine as NSString).length)) != nil {
                return oldLine
            }
            return oldLine + " · #" + slug
        }
    }

    /// Locate the metadata line for `timestamp` and rewrite it via `transform`.
    /// Returns true iff the rewritten line differs from the original.
    private func mutateMetadataLine(timestamp: String, transform: (String) -> String) throws -> Bool {
        let original = try read()
        guard !original.isEmpty else { return false }

        let escaped = NSRegularExpression.escapedPattern(for: timestamp)
        let pattern = "(`\(escaped)`[^\\n]*)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return false }

        let nsString = original as NSString
        let range = NSRange(location: 0, length: nsString.length)
        guard let match = regex.firstMatch(in: original, options: [], range: range) else { return false }

        let oldLine = nsString.substring(with: match.range(at: 1))
        let newLine = transform(oldLine)
        guard oldLine != newLine else { return false }

        let updated = nsString.replacingCharacters(in: match.range(at: 1), with: newLine)
        try updated.write(to: forestURL, atomically: true, encoding: .utf8)
        return true
    }

    static func replaceProjectTag(in metadataLine: String, with project: String?) -> String {
        // Strip any existing trailing " · #tag"; preserve everything else (incl. ¬rejections).
        let pattern = "\\s*·\\s*#[^\\s·]+\\s*$"
        let stripped: String
        if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
            let ns = metadataLine as NSString
            let range = NSRange(location: 0, length: ns.length)
            stripped = regex.stringByReplacingMatches(in: metadataLine, options: [], range: range, withTemplate: "")
        } else {
            stripped = metadataLine
        }
        if let project, !project.isEmpty {
            return stripped + " · #" + projectTagSlug(project)
        }
        return stripped
    }

    /// Convert a project display name into a hashtag-safe slug.
    public static func projectTagSlug(_ name: String) -> String {
        let lowered = name.lowercased()
        var out = ""
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
            } else if scalar == " " || scalar == "_" || scalar == "-" || scalar == "." {
                out.append("-")
            }
        }
        while out.contains("--") { out = out.replacingOccurrences(of: "--", with: "-") }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private func formatEntry(idea: Idea) -> String {
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime]
        let timestamp = dateFormatter.string(from: idea.createdAt)

        var metadata = "`\(timestamp)`"
        if idea.durationSeconds > 0 {
            metadata += " · " + String(format: "%.1f", idea.durationSeconds) + "s"
        }
        if let project = idea.project, !project.isEmpty {
            metadata += " · #" + Self.projectTagSlug(project)
        }

        var lines: [String] = []
        lines.append("## \(idea.title)")
        lines.append("")
        lines.append(metadata)
        lines.append("")
        for bullet in idea.bullets {
            lines.append("- \(bullet)")
        }
        if !idea.bullets.isEmpty {
            lines.append("")
        }
        lines.append("<details><summary>raw</summary>")
        lines.append("")
        lines.append(idea.transcript)
        lines.append("")
        lines.append("</details>")
        lines.append("")
        return lines.joined(separator: "\n")
    }
}

public struct ForestEntry: Sendable, Codable, Equatable, Identifiable {
    public var title: String
    public var body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }

    public var markdown: String {
        "## \(title)\n\(body)"
    }

    /// Stable identity: ISO timestamp string from the metadata line, falling back to title.
    public var id: String {
        timestampString ?? title
    }

    /// Raw timestamp string (between backticks) on the metadata line, if any.
    public var timestampString: String? {
        guard let line = metadataLine else { return nil }
        // Match the first `…` token.
        let pattern = "`([^`]+)`"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = line as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = regex.firstMatch(in: line, range: range), match.numberOfRanges > 1 else { return nil }
        return ns.substring(with: match.range(at: 1))
    }

    /// Parsed Date from `timestampString`, when ISO-8601.
    public var timestamp: Date? {
        guard let s = timestampString else { return nil }
        return ISO8601DateFormatter().date(from: s)
    }

    /// All project slugs parsed from `#tag` markers in the metadata line.
    /// An entry can be nested in multiple projects simultaneously.
    public var projectSlugs: [String] {
        Self.parseSlugs(in: metadataLine, prefix: "#")
    }

    private static func parseSlugs(in line: String?, prefix: String) -> [String] {
        guard let line else { return [] }
        let pattern = "·\\s*\(NSRegularExpression.escapedPattern(for: prefix))([\\w-]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = line as NSString
        let range = NSRange(location: 0, length: ns.length)
        let matches = regex.matches(in: line, range: range)
        return matches.compactMap { match in
            guard match.numberOfRanges > 1 else { return nil }
            return ns.substring(with: match.range(at: 1))
        }
    }

    /// Optional duration in seconds (e.g. "5.2s") from the metadata line.
    public var durationSeconds: Double? {
        guard let line = metadataLine else { return nil }
        let pattern = "·\\s*([0-9]+\\.[0-9]+)s"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = line as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = regex.firstMatch(in: line, range: range), match.numberOfRanges > 1 else { return nil }
        return Double(ns.substring(with: match.range(at: 1)))
    }

    /// Bullet items (lines starting with `- `).
    public var bullets: [String] {
        body.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0) }
            .compactMap { line -> String? in
                guard line.hasPrefix("- ") else { return nil }
                return String(line.dropFirst(2))
            }
    }

    /// Raw transcript text inside the `<details>…</details>` block, if present.
    public var raw: String? {
        guard let detailsStart = body.range(of: "<details><summary>raw</summary>"),
              let detailsEnd = body.range(of: "</details>", range: detailsStart.upperBound..<body.endIndex) else {
            return nil
        }
        let inner = body[detailsStart.upperBound..<detailsEnd.lowerBound]
        return inner.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The first non-empty line of the body that begins with a backtick (the metadata line).
    public var metadataLine: String? {
        for raw in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("`") { return trimmed }
        }
        return nil
    }
}
