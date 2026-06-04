import AppKit
import SwiftUI
import SquirrelCore

@MainActor
final class ParkingLotWindowController: NSObject {
    static let shared = ParkingLotWindowController()
    private var window: NSWindow?

    func showOrFocus() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        controller.title = "Forest"
        controller.titlebarAppearsTransparent = true
        controller.isReleasedWhenClosed = false
        controller.center()
        controller.minSize = NSSize(width: 760, height: 480)
        controller.delegate = self

        let hosting = NSHostingController(
            rootView: ParkingLotView()
                .environmentObject(AppState.shared)
        )
        controller.contentViewController = hosting

        NSApp.activate(ignoringOtherApps: true)
        controller.makeKeyAndOrderFront(nil)
        self.window = controller
    }
}

extension ParkingLotWindowController: NSWindowDelegate {
    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in self.window = nil }
    }
}

struct ParkingLotView: View {
    @EnvironmentObject private var state: AppState
    @State private var entries: [ForestEntry] = []
    @State private var selectedID: ForestEntry.ID?
    @State private var projects: [Project] = []
    @State private var filterProject: String? = nil
    @State private var searchText: String = ""
    @State private var lastError: String?
    @State private var showingManageProjects = false

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 420)
            detail
                .frame(minWidth: 440)
        }
        .frame(minWidth: 760, minHeight: 480)
        .toolbar { toolbar }
        .onAppear(perform: reload)
        .sheet(isPresented: $showingManageProjects) {
            ManageProjectsView(projects: projects) { reload() }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            HStack {
                Picker("", selection: $filterProject) {
                    Text("All projects").tag(String?.none)
                    Divider()
                    ForEach(projects) { project in
                        Text(project.name).tag(String?.some(project.name))
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 200)
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                reload()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Reload from forest.md")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                NSWorkspace.shared.open(URL(fileURLWithPath: state.preferences.forestPath))
            } label: {
                Image(systemName: "doc.text")
            }
            .help("Open forest.md")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                showingManageProjects = true
            } label: {
                Image(systemName: "folder.badge.gearshape")
            }
            .help("Manage the project list")
        }
    }

    private var filteredEntries: [ForestEntry] {
        var list = entries
        if let filterProject {
            let slug = ForestStore.projectTagSlug(filterProject)
            list = list.filter { $0.projectSlugs.contains(slug) }
        }
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !q.isEmpty {
            list = list.filter {
                $0.title.lowercased().contains(q) || $0.body.lowercased().contains(q)
            }
        }
        return list
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(8)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            if filteredEntries.isEmpty {
                emptyState
            } else {
                List(filteredEntries, selection: $selectedID) { entry in
                    ParkingLotRow(entry: entry, projects: projects)
                        .tag(entry.id)
                }
                .listStyle(.sidebar)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let entry = filteredEntries.first(where: { $0.id == selectedID })
            ?? filteredEntries.first {
            EntryDetailView(
                entry: entry,
                projects: projects,
                onAssign: { project in assign(entry: entry, project: project) },
                onDelete: { confirmDelete(entry: entry) }
            )
            .id(entry.id)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "tree")
                    .imageScale(.large)
                    .foregroundStyle(.tint)
                Text("Your forest is empty")
                    .font(.headline)
                Text("Capture an idea with the menu bar hotkeys or the squirrel CLI.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            Spacer()
            Image(systemName: "leaf")
                .imageScale(.large)
                .foregroundStyle(.secondary)
            Text("Nothing matches")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func reload() {
        let store = ForestStore(forestPath: state.preferences.forestPath)
        do {
            entries = try store.entries()
            if let id = selectedID, !entries.contains(where: { $0.id == id }) {
                selectedID = nil
            }
        } catch {
            lastError = error.localizedDescription
            entries = []
        }
        projects = ProjectRegistry.all()
    }

    private func assign(entry: ForestEntry, project: String?) {
        guard let timestamp = entry.timestampString else { return }
        let store = ForestStore(forestPath: state.preferences.forestPath)
        do {
            _ = try store.assignProject(timestamp: timestamp, project: project)
            reload()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func confirmDelete(entry: ForestEntry) {
        let alert = NSAlert()
        alert.messageText = "Remove this idea from the forest?"
        alert.informativeText = entry.title
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let timestamp = entry.timestampString else { return }
        let store = ForestStore(forestPath: state.preferences.forestPath)
        do {
            _ = try store.deleteEntry(timestamp: timestamp)
            selectedID = nil
            reload()
        } catch {
            lastError = error.localizedDescription
        }
    }
}

private struct ParkingLotRow: View {
    let entry: ForestEntry
    let projects: [Project]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(entry.title)
                .font(.callout.weight(.medium))
                .lineLimit(1)
            HStack(spacing: 6) {
                if let ts = entry.timestamp {
                    Text(ts, style: .relative)
                        .foregroundStyle(.secondary)
                }
                if let slug = entry.projectSlugs.first {
                    Text("#\(projectName(for: slug))")
                        .foregroundStyle(.tint)
                        .lineLimit(1)
                }
            }
            .font(.caption2)
        }
        .padding(.vertical, 4)
    }

    private func projectName(for slug: String) -> String {
        projects.first { ForestStore.projectTagSlug($0.name) == slug }?.name ?? slug
    }
}

private struct EntryDetailView: View {
    let entry: ForestEntry
    let projects: [Project]
    let onAssign: (String?) -> Void
    let onDelete: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text(entry.title)
                        .font(.title2.weight(.semibold))
                    Spacer()
                    Button(role: .destructive) {
                        onDelete()
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                    .controlSize(.small)
                }

                metadataRow

                projectPicker

                if !entry.bullets.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(entry.bullets, id: \.self) { bullet in
                            HStack(alignment: .top, spacing: 8) {
                                Text("•").foregroundStyle(.secondary)
                                Text(bullet)
                            }
                        }
                    }
                }

                if let raw = entry.raw, !raw.isEmpty {
                    DisclosureGroup("Transcript") {
                        Text(raw)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var metadataRow: some View {
        HStack(spacing: 12) {
            if let ts = entry.timestamp {
                Label(formattedDate(ts), systemImage: "clock")
            }
            if let duration = entry.durationSeconds, duration > 0 {
                Label(String(format: "%.1fs", duration), systemImage: "waveform")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var projectPicker: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            Menu {
                Button("None") { onAssign(nil) }
                if !projects.isEmpty { Divider() }
                ForEach(projects) { project in
                    Button(project.name) { onAssign(project.name) }
                }
                Divider()
                Button("Custom folder…") { pickAndAssignCustomFolder() }
            } label: {
                Text(currentProjectLabel)
                    .lineLimit(1)
            }
            .menuStyle(.borderedButton)
            .frame(maxWidth: 260, alignment: .leading)
        }
    }

    private func pickAndAssignCustomFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Assign"
        panel.message = "Pick a folder to tag this idea with"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let project = try ProjectRegistry.register(path: url.path)
            onAssign(project.name)
        } catch {
            NSSound.beep()
        }
    }

    private var currentProjectLabel: String {
        guard let slug = entry.projectSlugs.first else { return "Assign project…" }
        if let project = projects.first(where: { ForestStore.projectTagSlug($0.name) == slug }) {
            return project.name
        }
        return "#\(slug)"
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

/// Prune the project list. Projects are auto-registered every time Claude Code
/// opens in a directory, so the list accumulates throwaway dirs; this lets the
/// user forget them. Removing a project only drops it from the picker — entries
/// already tagged with it keep their tag.
private struct ManageProjectsView: View {
    let projects: [Project]
    let onChange: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [Project]

    init(projects: [Project], onChange: @escaping () -> Void) {
        self.projects = projects
        self.onChange = onChange
        _rows = State(initialValue: projects)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Manage projects")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)

            Divider()

            if rows.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "folder")
                        .imageScale(.large)
                        .foregroundStyle(.secondary)
                    Text("No projects registered")
                        .foregroundStyle(.secondary)
                    Text("They appear automatically when you open Claude Code in a repo.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: 160)
                .padding()
            } else {
                List {
                    ForEach(rows) { project in
                        HStack(spacing: 8) {
                            Image(systemName: "folder.fill").foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(project.name)
                                Text(project.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                remove(project)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Forget this project")
                        }
                        .padding(.vertical, 2)
                    }
                }
                .listStyle(.inset)
                .frame(minHeight: 240)
            }
        }
        .frame(width: 460, height: 360)
    }

    private func remove(_ project: Project) {
        do {
            try ProjectRegistry.remove(path: project.path)
            rows.removeAll { $0.id == project.id }
            onChange()
        } catch {
            NSSound.beep()
        }
    }
}
