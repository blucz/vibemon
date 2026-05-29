import Foundation

/// Remote shell program, fed to `ssh host bash -s` over stdin so we never fight nested quoting.
/// Emits one block per interval:
///   LOAD:<load1>:<ncpu>
///   MEM:<memTotalKB>:<memAvailableKB>
///   GPU:<index>, <uuid>, <name>, <util>, <memUsed>, <memTotal>, <temp>, <power>, <powerLimit>  (repeated)
///   GPUERR:<first line of nvidia-smi error>                                                     (instead, on failure)
///   PROC\t<uuid>\t<pid>\t<usedMiB>\t<process_name>\t<cmdline>\t<cwd>                            (repeated, tab-separated)
///   END
/// When the local ssh process dies, the next printf hits a broken pipe (SIGPIPE) and the
/// remote loop exits on its own — no orphaned loops left on the servers.
private let remoteScript = """
trap 'exit 0' PIPE
while true; do
  read -r l1 _ < /proc/loadavg
  printf 'LOAD:%s:%s\\n' "$l1" "$(nproc)"
  mt=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
  ma=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
  printf 'MEM:%s:%s\\n' "$mt" "$ma"
  if g=$(nvidia-smi --query-gpu=index,uuid,name,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw,power.limit --format=csv,noheader,nounits 2>&1); then
    printf '%s\\n' "$g" | while IFS= read -r line; do printf 'GPU:%s\\n' "$line"; done
    apps=$(nvidia-smi --query-compute-apps=gpu_uuid,pid,used_memory,process_name --format=csv,noheader,nounits 2>/dev/null)
    if [ -n "$apps" ]; then
      printf '%s\\n' "$apps" | while IFS=',' read -r uuid pid mem pname; do
        uuid=$(printf '%s' "$uuid" | tr -d ' ')
        pid=$(printf '%s' "$pid" | tr -d ' ')
        [ -z "$pid" ] && continue
        pname=$(printf '%s' "$pname" | sed 's/^ *//; s/ *$//')
        cmd=$(tr '\\0' ' ' < /proc/$pid/cmdline 2>/dev/null)
        cwd=$(readlink /proc/$pid/cwd 2>/dev/null)
        printf 'PROC\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n' "$uuid" "$pid" "$mem" "$pname" "$cmd" "$cwd"
      done
    fi
  else
    printf 'GPUERR:%s\\n' "$(printf '%s' "$g" | head -1)"
  fi
  printf 'END\\n'
  sleep 2
done
"""

private let sshArgs = [
    "-o", "BatchMode=yes",
    "-o", "ConnectTimeout=10",
    "-o", "ServerAliveInterval=15",
    "-o", "ServerAliveCountMax=3",
    "-o", "StrictHostKeyChecking=accept-new",
]

/// A tiny shell watcher we wrap each ssh in. Two safety nets:
///   - on SIGTERM (our `Process.terminate()`) it kills the ssh child before exiting
///   - if our process dies ungracefully (crash / SIGKILL) and this sh gets re-parented to
///     launchd (ppid==1), the polling loop notices and kills ssh so no remote loop is left orphaned
private let sshWatcher = #"""
ssh "$@" <&0 &
SSH=$!
trap 'kill "$SSH" 2>/dev/null; wait "$SSH" 2>/dev/null; exit 0' TERM INT HUP
while [ "$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')" != "1" ] && kill -0 "$SSH" 2>/dev/null; do
  sleep 1
done
kill "$SSH" 2>/dev/null
wait "$SSH" 2>/dev/null
"""#

/// Owns one long-lived ssh connection to a host and keeps its HostSnapshot up to date.
@MainActor
final class Collector {
    private let snapshot: HostSnapshot
    var onUpdate: (() -> Void)?
    private var process: Process?
    private var stopped = false
    private var lineBuffer = Data()

    // Accumulated across a single block, flushed on END.
    private struct ProcInfo { var uuid: String; var memMiB: Double; var label: String }
    private var pendingGPUs: [GPUStat] = []
    private var pendingProcs: [ProcInfo] = []
    private var pendingLoad: Double = 0
    private var pendingCPUs: Int = 0
    private var sysMemTotalMiB: Double = 0
    private var sysMemUsedMiB: Double = 0
    private var pendingError: String?

    init(snapshot: HostSnapshot) { self.snapshot = snapshot }

    func start() {
        stopped = false
        spawn()
    }

    func stop() {
        stopped = true
        process?.terminate()
        process = nil
    }

    private func spawn() {
        guard !stopped else { return }
        snapshot.status = .connecting

        // Launch ssh via the watcher script so the remote loop can't outlive us.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", sshWatcher, "vibemon-ssh"]
                       + sshArgs + [snapshot.config.name, "bash", "-s"]

        let stdout = Pipe()
        let stdin = Pipe()
        proc.standardOutput = stdout
        proc.standardError = Pipe()   // swallow "no mutual signature"-type warnings
        proc.standardInput = stdin

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.ingest(data) }
        }

        proc.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.handleExit() }
        }

        do {
            try proc.run()
            process = proc
            // Feed the script, then keep stdin open so ssh stays alive.
            stdin.fileHandleForWriting.write(Data((remoteScript + "\n").utf8))
        } catch {
            snapshot.status = .offline("ssh failed to launch: \(error.localizedDescription)")
            scheduleRestart()
        }
    }

    private func handleExit() {
        process = nil
        guard !stopped else { return }
        if snapshot.status.isLive {
            snapshot.status = .offline("connection dropped")
        } else if case .connecting = snapshot.status {
            snapshot.status = .offline("could not connect")
        }
        scheduleRestart()
    }

    private func scheduleRestart() {
        guard !stopped else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.spawn()
        }
    }

    // MARK: parsing

    private func ingest(_ data: Data) {
        lineBuffer.append(data)
        while let nl = lineBuffer.firstIndex(of: 0x0a) {
            let lineData = lineBuffer[lineBuffer.startIndex..<nl]
            lineBuffer.removeSubrange(lineBuffer.startIndex...nl)
            guard let line = String(data: lineData, encoding: .utf8) else { continue }
            handleLine(line.trimmingCharacters(in: CharacterSet(charactersIn: "\r")))
        }
    }

    private func handleLine(_ line: String) {
        if line.hasPrefix("LOAD:") {
            let parts = line.dropFirst(5).split(separator: ":")
            if parts.count == 2 {
                pendingLoad = Double(parts[0]) ?? 0
                pendingCPUs = Int(parts[1]) ?? 0
            }
        } else if line.hasPrefix("MEM:") {
            let parts = line.dropFirst(4).split(separator: ":")
            if parts.count == 2, let total = Double(parts[0]), let avail = Double(parts[1]) {
                sysMemTotalMiB = total / 1024
                sysMemUsedMiB = (total - avail) / 1024
            }
        } else if line.hasPrefix("GPU:") {
            if let g = parseGPU(String(line.dropFirst(4))) {
                pendingGPUs.append(g)
            }
        } else if line.hasPrefix("GPUERR:") {
            pendingError = String(line.dropFirst(7))
        } else if line.hasPrefix("PROC\t") {
            parseProc(line)
        } else if line == "END" {
            flush()
        }
    }

    /// PROC\t<uuid>\t<pid>\t<usedMiB>\t<process_name>\t<cmdline>\t<cwd>
    private func parseProc(_ line: String) {
        let f = line.components(separatedBy: "\t")
        guard f.count >= 7 else { return }
        let uuid = f[1]
        let mem = num(f[3]) ?? 0
        let label = JobLabeler.label(processName: f[4], cmdline: f[5], cwd: f[6])
        if !label.isEmpty { pendingProcs.append(ProcInfo(uuid: uuid, memMiB: mem, label: label)) }
    }

    private func parseGPU(_ csv: String) -> GPUStat? {
        // index, uuid, name, util, memUsed, memTotal, temp, power, powerLimit
        let f = csv.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard f.count >= 9, let index = Int(f[0]) else { return nil }

        // Integrated GPUs (e.g. GB10) report memory & power-limit as "[N/A]". Fall back to system RAM.
        let naMem = num(f[5]) == nil
        let memTotal = naMem ? sysMemTotalMiB : (num(f[5]) ?? 0)
        let memUsed = naMem ? sysMemUsedMiB : (num(f[4]) ?? 0)

        return GPUStat(
            index: index,
            uuid: f[1],
            name: f[2],
            utilization: num(f[3]) ?? 0,
            memUsedMiB: memUsed,
            memTotalMiB: memTotal,
            tempC: num(f[6]) ?? 0,
            powerW: num(f[7]) ?? 0,
            powerLimitW: num(f[8]),
            memIsSystemRAM: naMem,
            job: nil
        )
    }

    private func num(_ s: String) -> Double? {
        if s.contains("N/A") || s.isEmpty { return nil }
        return Double(s)
    }

    private func flush() {
        snapshot.loadAvg1 = pendingLoad
        snapshot.cpuCount = pendingCPUs
        snapshot.ramTotalMiB = sysMemTotalMiB
        snapshot.ramUsedMiB = sysMemUsedMiB
        snapshot.lastUpdate = Date()
        if let err = pendingError {
            snapshot.gpus = []
            snapshot.status = .warning(friendlyGPUError(err))
        } else {
            var gpus = pendingGPUs.sorted { $0.index < $1.index }
            for i in gpus.indices { gpus[i].job = jobLabel(forUUID: gpus[i].uuid) }
            snapshot.gpus = gpus
            snapshot.status = .ok
        }
        pendingGPUs = []
        pendingProcs = []
        pendingError = nil
        onUpdate?()
    }

    /// Combine the processes on one GPU into a single label: the biggest memory user wins,
    /// with "+N" appended when other distinct jobs share the card.
    private func jobLabel(forUUID uuid: String) -> String? {
        let procs = pendingProcs.filter { $0.uuid == uuid }
        guard let primary = procs.max(by: { $0.memMiB < $1.memMiB }) else { return nil }
        let others = Set(procs.map(\.label)).subtracting([primary.label])
        return others.isEmpty ? primary.label : "\(primary.label) +\(others.count)"
    }

    private func friendlyGPUError(_ raw: String) -> String {
        if raw.contains("Driver/library version mismatch") {
            return "GPU driver mismatch (reboot needed)"
        }
        if raw.contains("command not found") || raw.contains("No such file") {
            return "nvidia-smi not found"
        }
        if raw.contains("NVML") { return "NVML error" }
        return raw.isEmpty ? "nvidia-smi error" : raw
    }
}
