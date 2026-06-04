import Foundation

/// Watches `forest.md` for changes and fires a debounced callback. Other
/// processes mutate the forest too (`squirrel-mcp` on /stash, /scan-forest), so
/// the app can't compute the untagged count once — it has to react to the file.
///
/// `ForestStore` writes atomically (`data.write(.atomic)`), which replaces the
/// inode via rename. A plain fd watch dies after the first such write, so on a
/// `.delete`/`.rename` event we cancel and re-arm against the new file.
// All mutable state is confined to the private serial `queue`, so the cross-
// closure captures the compiler flags are safe in practice.
final class ForestWatcher: @unchecked Sendable {
    private let path: String
    private let onChange: () -> Void
    private let queue = DispatchQueue(label: "com.charliewillis.squirrel.forestwatcher")
    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: CInt = -1
    private var debounceWorkItem: DispatchWorkItem?

    init(path: String, onChange: @escaping () -> Void) {
        self.path = path
        self.onChange = onChange
        arm()
    }

    deinit { stop() }

    func stop() {
        queue.sync {
            debounceWorkItem?.cancel()
            debounceWorkItem = nil
            source?.cancel()
            source = nil
            // The cancel handler closes the fd; guard against double-close if no
            // source was ever armed.
            if source == nil && fileDescriptor >= 0 {
                close(fileDescriptor)
                fileDescriptor = -1
            }
        }
    }

    private func arm() {
        queue.async { [weak self] in self?.armOnQueue() }
    }

    private func armOnQueue() {
        // Tear down any existing watch first (re-arm path).
        source?.cancel()
        source = nil

        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            // File may not exist yet; retry shortly so the badge still comes alive
            // once the first capture creates forest.md.
            queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.armOnQueue() }
            return
        }
        fileDescriptor = fd

        let newSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: queue
        )

        newSource.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = self.source?.data ?? []
            if flags.contains(.delete) || flags.contains(.rename) {
                // Atomic replace or move — re-arm against the new file, then notify.
                self.armOnQueue()
            }
            self.scheduleNotify()
        }

        newSource.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.fileDescriptor >= 0 {
                close(self.fileDescriptor)
                self.fileDescriptor = -1
            }
        }

        source = newSource
        newSource.resume()
    }

    /// Coalesce bursts (an atomic write fires write+rename) into one callback.
    private func scheduleNotify() {
        debounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        debounceWorkItem = work
        queue.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
}
