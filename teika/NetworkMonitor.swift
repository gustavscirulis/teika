import Network
import Observation

/// Watches only for a metered connection, so the model-download prompt can say
/// what the download will cost before the user commits to it.
@MainActor
@Observable
final class NetworkMonitor {
    /// True on cellular and on a personal hotspot — the cases where a 0.5 GB
    /// download is billable. Starts `false`, so the warning appears once the
    /// first path update lands rather than flashing on launch.
    private(set) var isExpensive = false

    private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let expensive = path.isExpensive
            Task { @MainActor in self.isExpensive = expensive }
        }
        monitor.start(queue: DispatchQueue(label: "com.gustavscirulis.teika.network"))
    }

    deinit {
        monitor.cancel()
    }
}
