import Foundation

/// A server we monitor. `name` is the ssh alias/host as it appears in ~/.ssh/config or DNS.
struct HostConfig: Identifiable, Hashable {
    var name: String
    var display: String
    var id: String { name }

    init(_ name: String, display: String? = nil) {
        self.name = name
        self.display = display ?? name
    }
}

/// Per-GPU sample.
struct GPUStat: Identifiable, Hashable {
    var index: Int
    var uuid: String          // nvidia-smi GPU UUID, used to attribute running processes
    var name: String          // full marketing name from nvidia-smi
    var utilization: Double    // 0...100, compute %
    var memUsedMiB: Double
    var memTotalMiB: Double
    var tempC: Double
    var powerW: Double
    var powerLimitW: Double?   // nil when nvidia-smi reports N/A (e.g. integrated GB10)
    var memIsSystemRAM: Bool   // true when memory figures are a unified-memory / system-RAM fallback
    var job: String?           // what's running on this GPU (e.g. "ComfyUI", "vLLM", a project dir)

    var id: Int { index }

    var memFraction: Double {
        memTotalMiB > 0 ? min(1, max(0, memUsedMiB / memTotalMiB)) : 0
    }
    var utilFraction: Double { min(1, max(0, utilization / 100)) }

    /// "RTX PRO 6000 Blackwell" -> a tight label. Drops the "NVIDIA" prefix and trailing edition words.
    var shortName: String {
        var n = name
        for prefix in ["NVIDIA ", "GeForce "] where n.hasPrefix(prefix) {
            n.removeFirst(prefix.count)
        }
        return n
    }
}

enum HostStatus: Equatable {
    case connecting
    case ok
    case warning(String)   // connected, but something's off (e.g. nvidia-smi failed)
    case offline(String)   // not reachable / ssh exited

    var isLive: Bool { if case .ok = self { return true }; if case .warning = self { return true }; return false }
}

/// Live, observable state for one host. Collectors mutate this on the main actor.
@MainActor
final class HostSnapshot: ObservableObject, Identifiable {
    let config: HostConfig
    nonisolated var id: String { config.name }

    @Published var status: HostStatus = .connecting
    @Published var gpus: [GPUStat] = []
    @Published var loadAvg1: Double = 0
    @Published var cpuCount: Int = 0
    @Published var lastUpdate: Date?

    init(_ config: HostConfig) { self.config = config }

    var cpuLoadFraction: Double {
        cpuCount > 0 ? min(1, loadAvg1 / Double(cpuCount)) : 0
    }

    var totalWatts: Double { gpus.reduce(0) { $0 + $1.powerW } }
    var totalMemMiB: Double { gpus.reduce(0) { $0 + $1.memTotalMiB } }

    /// Trimmed GPU model name, e.g. "RTX PRO 6000 Blackwell" — shown once in the host header.
    var gpuModelName: String? {
        guard let first = gpus.first else { return nil }
        var n = first.shortName
        for junk in [" Workstation Edition", " Generation", " Edition"] {
            n = n.replacingOccurrences(of: junk, with: "")
        }
        return n
    }
}

@MainActor
final class MonitorStore: ObservableObject {
    @Published var hosts: [HostSnapshot]
    private var collectors: [Collector] = []

    init(_ configs: [HostConfig]) {
        self.hosts = configs.map(HostSnapshot.init)
    }

    func start() {
        collectors = hosts.map { snap in
            let c = Collector(snapshot: snap)
            c.onUpdate = { [weak self] in self?.resort() }
            return c
        }
        collectors.forEach { $0.start() }
    }

    /// Re-order biggest-VRAM-first; only re-publish when the order actually changes.
    private func resort() {
        let sorted = hosts.sorted { $0.totalMemMiB > $1.totalMemMiB }
        if sorted.map(\.id) != hosts.map(\.id) { hosts = sorted }
    }

    func stop() {
        collectors.forEach { $0.stop() }
    }
}
