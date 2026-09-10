import Foundation

/// Watches a file for changes, surviving the delete/rename cycle most editors
/// perform on atomic saves. Events are debounced; the callback runs on main.
final class FileWatcher {
    private let url: URL
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private var stopped = false

    init?(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
        guard arm() else { return nil }
    }

    deinit {
        stop()
    }

    /// Cancels the source, any debounced callback, and any scheduled re-arm. Idempotent;
    /// safe from `deinit`. The descriptor closes in the source's cancel handler.
    func stop() {
        stopped = true
        pending?.cancel()
        pending = nil
        source?.cancel()
        source = nil
    }

    private func arm() -> Bool {
        guard !stopped else { return false }
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return false }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename, .attrib],
            queue: .main
        )
        source.setCancelHandler { close(descriptor) }
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            if source.data.contains(.delete) || source.data.contains(.rename) {
                source.cancel()
                self.source = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    guard let self else { return }
                    if self.arm() { self.fire() }
                }
            } else {
                self.fire()
            }
        }
        source.resume()
        self.source = source
        return true
    }

    private func fire() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
}
