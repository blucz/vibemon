import Foundation

/// Standard installed-memory capacities, ascending. `/proc/meminfo` (and nvidia-smi for
/// unified memory) report kernel-visible RAM, which sits a few percent under the marketed
/// size — e.g. a 512 GB box reads ~504, a 128 GB box ~120. Snap the *total* back to the
/// capacity a human recognizes; leave *used* alone so it stays accurate.
private let ramSteps: [Int] = [
    1, 2, 4, 6, 8, 12, 16, 24, 32, 48, 64, 96, 128, 160, 192, 256, 320, 384,
    512, 640, 768, 1024, 1280, 1536, 2048, 3072, 4096, 6144, 8192,
]

/// Round a kernel-reported MiB figure to the nearest standard capacity when it's within
/// ~10% below one (the usual reserved-memory gap); otherwise show the literal rounded value.
func niceCapacityGB(_ miB: Double) -> Int {
    let gib = miB / 1024
    for c in ramSteps where Double(c) >= gib {
        return (Double(c) - gib) / Double(c) <= 0.10 ? c : Int(gib.rounded())
    }
    return Int(gib.rounded())
}

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

    /// A card is "active" if it's computing or holding a workload — a resident model at 0% counts.
    var isActive: Bool { utilization > 0 || job != nil }

    var memUsedGB: Int { Int((memUsedMiB / 1024).rounded()) }
    /// Discrete VRAM already reads cleanly; unified/system-RAM totals get the marketing snap.
    var memTotalGB: Int {
        memIsSystemRAM ? niceCapacityGB(memTotalMiB) : Int((memTotalMiB / 1024).rounded())
    }

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
    @Published var ramUsedMiB: Double = 0   // system RAM, machine-level
    @Published var ramTotalMiB: Double = 0
    @Published var lastUpdate: Date?

    init(_ config: HostConfig) { self.config = config }

    var cpuLoadFraction: Double {
        cpuCount > 0 ? min(1, loadAvg1 / Double(cpuCount)) : 0
    }

    /// Machine CPU usage as a 0–100 percent, derived from 1-min load average over core count.
    var cpuPercent: Int { Int((cpuLoadFraction * 100).rounded()) }

    /// Whole-GB system RAM, e.g. used 88 / total 256.
    var ramUsedGB: Int { Int((ramUsedMiB / 1024).rounded()) }
    var ramTotalGB: Int { niceCapacityGB(ramTotalMiB) }

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

private let hostsDefaultsKey = "hostNames"

@MainActor
final class MonitorStore: ObservableObject {
    @Published var hosts: [HostSnapshot]
    private var collectors: [String: Collector] = [:]
    private var started = false

    /// Seed list, used the first time the app runs (before the user has edited the
    /// host list, which is then persisted to UserDefaults).
    private let defaults: [String]

    init(defaults: [String]) {
        self.defaults = defaults
        let names = MonitorStore.loadHostNames(defaults: defaults)
        self.hosts = names.map { HostSnapshot(HostConfig($0)) }
    }

    private static func loadHostNames(defaults: [String]) -> [String] {
        if let saved = UserDefaults.standard.array(forKey: hostsDefaultsKey) as? [String] {
            return saved
        }
        return defaults
    }

    private func persist() {
        UserDefaults.standard.set(hosts.map(\.config.name), forKey: hostsDefaultsKey)
    }

    func start() {
        started = true
        hosts.forEach(startCollector)
    }

    func stop() {
        started = false
        collectors.values.forEach { $0.stop() }
        collectors = [:]
    }

    private func startCollector(for snap: HostSnapshot) {
        guard collectors[snap.id] == nil else { return }
        let c = Collector(snapshot: snap)
        c.onUpdate = { [weak self] in self?.resort() }
        collectors[snap.id] = c
        c.start()
    }

    /// Add a host by ssh alias / hostname. No-ops on blank or duplicate names.
    func addHost(_ rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !hosts.contains(where: { $0.config.name == name }) else { return }
        let snap = HostSnapshot(HostConfig(name))
        hosts.append(snap)
        if started { startCollector(for: snap) }
        persist()
    }

    func removeHost(_ id: String) {
        collectors[id]?.stop()
        collectors[id] = nil
        hosts.removeAll { $0.id == id }
        persist()
    }

    /// Re-order biggest-VRAM-first; only re-publish when the order actually changes.
    private func resort() {
        let sorted = hosts.sorted { $0.totalMemMiB > $1.totalMemMiB }
        if sorted.map(\.id) != hosts.map(\.id) { hosts = sorted }
    }
}
