import SwiftUI

// MARK: - Color scales

private func tempColor(_ c: Double) -> Color {
    switch c {
    case ..<60: return Color(red: 0.40, green: 0.78, blue: 0.45)   // green
    case ..<75: return Color(red: 0.85, green: 0.78, blue: 0.30)   // yellow
    case ..<85: return Color(red: 0.92, green: 0.58, blue: 0.25)   // orange
    default:    return Color(red: 0.92, green: 0.33, blue: 0.33)   // red
    }
}

private func utilColor(_ frac: Double) -> Color {
    Color(red: 0.30, green: 0.62, blue: 0.92).opacity(0.55 + 0.45 * frac)
}

private let memColor = Color(red: 0.55, green: 0.45, blue: 0.85)

func fmtWatts(_ w: Double) -> String {
    w >= 1000 ? String(format: "%.1fkW", w / 1000) : "\(Int(w.rounded()))W"
}

/// Whole-GB used/total, e.g. "88/96". Big GPUs and unified memory both read cleanly.
func fmtMem(used: Double, total: Double) -> String {
    "\(Int((used / 1024).rounded()))/\(Int((total / 1024).rounded()))G"
}

// MARK: - Bar

struct MeterBar: View {
    var fraction: Double
    var color: Color
    var width: CGFloat = 46
    var height: CGFloat = 7

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: height / 2)
                .fill(Color.primary.opacity(0.12))
            RoundedRectangle(cornerRadius: height / 2)
                .fill(color)
                .frame(width: max(0, width * CGFloat(min(1, fraction))))
        }
        .frame(width: width, height: height)
    }
}

// MARK: - One GPU row

struct GPURow: View {
    let gpu: GPUStat

    var body: some View {
        HStack(spacing: 4) {
            Text("\(gpu.index)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 12, alignment: .leading)

            MeterBar(fraction: gpu.utilFraction, color: utilColor(gpu.utilFraction), width: 36)
            Text("\(Int(gpu.utilization))%")
                .font(.system(size: 10, design: .monospaced))
                .frame(width: 30, alignment: .trailing)

            MeterBar(fraction: gpu.memFraction, color: memColor, width: 36)
            // Width sized to the widest value ("100/128G") and left-aligned so the text
            // sits right next to its bar instead of floating off with a gap.
            Text(fmtMem(used: gpu.memUsedMiB, total: gpu.memTotalMiB))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)

            Text("\(Int(gpu.tempC))°")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(tempColor(gpu.tempC))
                .frame(width: 26, alignment: .trailing)

            Text(fmtWatts(gpu.powerW))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)

            // What's running on this GPU — right-aligned so every row shares a clean right edge.
            Text(gpu.job ?? "—")
                .font(.system(size: 10))
                .foregroundStyle(gpu.job == nil ? .tertiary : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 12)
        }
        .help("\(gpu.shortName) — \(fmtMem(used: gpu.memUsedMiB, total: gpu.memTotalMiB))B"
              + (gpu.memIsSystemRAM ? " unified" : "")
              + (gpu.powerLimitW.map { ", \(Int(gpu.powerW))/\(Int($0))W" } ?? ""))
    }
}

// MARK: - One host section

struct HostSection: View {
    @ObservedObject var host: HostSnapshot

    private var dotColor: Color {
        switch host.status {
        case .ok: return Color(red: 0.40, green: 0.78, blue: 0.45)
        case .warning: return Color(red: 0.92, green: 0.58, blue: 0.25)
        case .offline: return Color(red: 0.92, green: 0.33, blue: 0.33)
        case .connecting: return Color.gray
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // machine name ⟶ (big space) ⟶ GPU model
            HStack(spacing: 6) {
                Circle().fill(dotColor).frame(width: 7, height: 7)
                Text(host.config.display)
                    .font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 12)
                if let model = host.gpuModelName {
                    HStack(spacing: 4) {
                        Text(model)
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        // Count badge — a subtle message-style pill.
                        Text("×\(host.gpus.count)")
                            .font(.system(size: 8.5, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.92))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(Color(red: 0.34, green: 0.42, blue: 0.56)))
                    }
                }
            }

            switch host.status {
            case .warning(let msg), .offline(let msg):
                Text(msg)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 13)
            case .connecting:
                Text("connecting…")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 13)
            case .ok:
                ForEach(host.gpus) { GPURow(gpu: $0) }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Root

struct ContentView: View {
    @EnvironmentObject var store: MonitorStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "cpu")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("vibemon")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Quit")
            }

            Divider().opacity(0.4)

            // Biggest rigs first — the store keeps `hosts` ordered by total VRAM, descending.
            ForEach(store.hosts) { HostSection(host: $0) }
        }
        .padding(10)
        .frame(width: 400, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            // Material for the blur, plus a dark scrim so text stays legible over any wallpaper.
            RoundedRectangle(cornerRadius: 10)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.34)))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.10)))
        }
    }
}
