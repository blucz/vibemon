import SwiftUI

// MARK: - Design tokens
//
// Recreates the "2b · Stacked + host status line" handoff. Solid, opaque surfaces
// (no vibrancy) so the widget holds contrast over any wallpaper. All numbers are
// SF Mono with tabular figures; the only bars on screen are per-GPU util/VRAM.
//
// Every geometric literal is multiplied by `s` (the user's zoom factor, read from
// the environment) so the whole widget scales uniformly and re-lays-out crisply —
// the hosting controller resizes the panel to fit automatically.

private extension Color {
    init(hex: UInt) {
        self.init(.sRGB,
                  red:   Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue:  Double(hex & 0xff) / 255,
                  opacity: 1)
    }
}

private enum VM {
    static let bg          = Color(hex: 0x15161A)   // widget body (opaque)
    static let bgRaise     = Color(hex: 0x1D1F24)   // title bar
    static let line        = Color(hex: 0x2A2D34)   // widget border
    static let lineSoft    = Color(hex: 0x232529)   // host dividers, title underline
    static let fg          = Color(hex: 0xF2F3F5)   // primary text
    static let fgMid       = Color(hex: 0x9AA0AB)   // secondary text
    static let fgDim       = Color(hex: 0x5B606B)   // idle/zero, index, separators, units
    static let blue        = Color(hex: 0x3A9BF4)   // GPU utilization bar
    static let blueText    = Color(hex: 0x74BDFF)   // active util value
    static let purple      = Color(hex: 0xA586F5)   // VRAM bar
    static let track       = Color(hex: 0x2C2F36)   // empty bar track
    static let cool        = Color(hex: 0x4EC98A)   // temp green
    static let warm        = Color(hex: 0xF2BE3C)   // temp amber
    static let hot         = Color(hex: 0xF56A5B)   // temp red
    static let dotOn       = Color(hex: 0x43C46A)
    static let dotOff      = Color(hex: 0x5B606B)
    static let badgeBg     = Color(hex: 0x2A3340)
    static let badgeFg     = Color(hex: 0xB9C6D6)
    static let powerStrong = Color(hex: 0xD7DBE2)   // host total power
    static let vramValue   = Color(hex: 0xC3C8D1)   // VRAM value (non-zero)
    static let rowActive   = Color(hex: 0x3A9BF4).opacity(0.07)
    static let rowIdle     = Color.white.opacity(0.018)
    static let control     = Color(hex: 0x2C2F36)   // title-bar round button bg
}

private func tempColor(_ c: Double) -> Color {
    if c >= 83 { return VM.hot }
    if c >= 65 { return VM.warm }
    return VM.cool
}

// MARK: - Zoom (uniform scale factor) plumbed through the environment

private struct UIScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1.0
}
private extension EnvironmentValues {
    var uiScale: CGFloat {
        get { self[UIScaleKey.self] }
        set { self[UIScaleKey.self] = newValue }
    }
}

let zoomMin = 0.6
let zoomMax = 1.5
let zoomDefault = 0.8

/// Snap to a 0.05 grid and clamp — keeps steps exact and avoids float drift.
func clampZoom(_ v: Double) -> Double {
    min(zoomMax, max(zoomMin, (v * 20).rounded() / 20))
}

// MARK: - Primitives

/// A capsule meter: track + leading fill sized to `fraction`. Fills the width it's given.
private struct VMBar: View {
    @Environment(\.uiScale) private var s
    var fraction: Double
    var color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(VM.track)
                Capsule().fill(color)
                    .frame(width: max(0, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 6 * s)
    }
}

/// Online status dot with a soft glow ring; layout stays dot-sized so the glow doesn't shift things.
private struct StatusDot: View {
    @Environment(\.uiScale) private var s
    var status: HostStatus

    private var color: Color {
        switch status {
        case .ok:         return VM.dotOn
        case .warning:    return VM.warm
        case .offline:    return VM.dotOff
        case .connecting: return VM.dotOff
        }
    }

    var body: some View {
        let online = { if case .ok = status { return true }; return false }()
        ZStack {
            if online {
                Circle().fill(VM.dotOn.opacity(0.14)).frame(width: 14 * s, height: 14 * s)
            }
            Circle().fill(color).frame(width: 8 * s, height: 8 * s)
        }
        .frame(width: 8 * s, height: 8 * s)
    }
}

private struct CountBadge: View {
    @Environment(\.uiScale) private var s
    var count: Int
    var body: some View {
        Text("×\(count)")
            .font(.system(size: 10.5 * s, weight: .semibold, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(VM.badgeFg)
            .padding(.horizontal, 6 * s)
            .padding(.vertical, 1.5 * s)
            .background(RoundedRectangle(cornerRadius: 6 * s).fill(VM.badgeBg))
    }
}

/// Small round title-bar button (matches the close button), used for zoom −/+ and close.
private struct RoundIconButton: View {
    @Environment(\.uiScale) private var s
    var systemName: String
    var glyphSize: CGFloat = 8.5
    var highlighted: Bool = false
    var help: String = ""
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(highlighted ? VM.blue : VM.control).frame(width: 18 * s, height: 18 * s)
                Image(systemName: systemName)
                    .font(.system(size: glyphSize * s, weight: .semibold))
                    .foregroundStyle(highlighted ? Color.white : VM.fgMid)
            }
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - GPU card (two lines)

private struct GPUCard: View {
    @Environment(\.uiScale) private var s
    let gpu: GPUStat

    var body: some View {
        VStack(alignment: .leading, spacing: 6 * s) {
            // Line 1 — identity
            HStack(alignment: .firstTextBaseline, spacing: 8 * s) {
                Text("\(gpu.index)")
                    .font(.system(size: 11 * s, design: .monospaced))
                    .foregroundStyle(VM.fgDim)

                Text(gpu.job ?? "idle")
                    .font(.system(size: 12 * s))
                    .foregroundStyle(gpu.job != nil ? VM.fg : VM.fgDim)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text("\(Int(gpu.tempC.rounded()))°")
                    .font(.system(size: 12.5 * s, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(tempColor(gpu.tempC))

                (Text("\(Int(gpu.powerW.rounded()))").foregroundStyle(VM.fgMid)
                 + Text("W").foregroundStyle(VM.fgDim))
                    .font(.system(size: 11 * s, design: .monospaced))
                    .monospacedDigit()
                    .frame(minWidth: 42 * s, alignment: .trailing)
            }

            // Line 2 — meters (two equal cells: bar fills, value fixed-width so bars align)
            HStack(spacing: 12 * s) {
                meterCell {
                    VMBar(fraction: gpu.utilFraction, color: VM.blue)
                } value: {
                    Text("\(Int(gpu.utilization.rounded()))%")
                        .foregroundStyle(gpu.utilization > 0 ? VM.blueText : VM.fgDim)
                        .fontWeight(gpu.utilization > 0 ? .semibold : .regular)
                        .frame(width: 32 * s, alignment: .trailing)
                }
                meterCell {
                    VMBar(fraction: gpu.memFraction, color: VM.purple)
                } value: {
                    (Text("\(gpu.memUsedGB)").foregroundStyle(gpu.memUsedGB > 0 ? VM.vramValue : VM.fgDim)
                     + Text("/\(gpu.memTotalGB)G").foregroundStyle(VM.fgDim))
                        .frame(width: 58 * s, alignment: .trailing)
                }
            }
        }
        .padding(EdgeInsets(top: 6 * s, leading: 9 * s, bottom: 7 * s, trailing: 9 * s))
        .background(RoundedRectangle(cornerRadius: 9 * s).fill(gpu.isActive ? VM.rowActive : VM.rowIdle))
    }

    private func meterCell<Bar: View, Value: View>(
        @ViewBuilder bar: () -> Bar,
        @ViewBuilder value: () -> Value
    ) -> some View {
        HStack(spacing: 8 * s) {
            bar()
            value()
                .font(.system(size: 10.5 * s, design: .monospaced))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Host section

private struct HostSection: View {
    @Environment(\.uiScale) private var s
    @ObservedObject var host: HostSnapshot
    var editing: Bool = false
    var onRemove: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            switch host.status {
            case .ok:
                statusLine
                VStack(spacing: 3 * s) {
                    ForEach(host.gpus) { GPUCard(gpu: $0) }
                }
            case .warning(let msg), .offline(let msg):
                message(msg)
            case .connecting:
                message("connecting…")
            }
        }
        .padding(.horizontal, 13 * s)
        .padding(.vertical, 9 * s)
    }

    private var header: some View {
        HStack(spacing: 8 * s) {
            if editing {
                Button(action: onRemove) {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 14 * s))
                        .foregroundStyle(VM.hot)
                }
                .buttonStyle(.plain)
                .help("Remove \(host.config.display)")
            } else {
                StatusDot(status: host.status)
            }
            Text(host.config.display)
                .font(.system(size: 14 * s, weight: .semibold))
                .foregroundStyle(VM.fg)
                .fixedSize()
            if let model = host.gpuModelName {
                Text(model)
                    .font(.system(size: 10.5 * s))
                    .foregroundStyle(VM.fgMid)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                Spacer(minLength: 0)
            }
            CountBadge(count: host.gpus.count)
        }
    }

    private var statusLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8 * s) {
            Text("\(Int(host.totalWatts.rounded()))W")
                .font(.system(size: 11 * s, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(VM.powerStrong)
            separator
            statItem("CPU", "\(host.cpuPercent)%")
            separator
            statItem("RAM", "\(host.ramUsedGB)/\(host.ramTotalGB)G")
        }
        .padding(.leading, 16 * s)
        .padding(.top, 5 * s)
        .padding(.bottom, 8 * s)
    }

    private var separator: some View {
        Text("·").font(.system(size: 11 * s)).foregroundStyle(VM.fgDim)
    }

    private func statItem(_ key: String, _ value: String) -> some View {
        HStack(spacing: 5 * s) {
            Text(key)
                .font(.system(size: 9 * s, weight: .bold))
                .tracking(0.6 * s)
                .foregroundStyle(VM.fgDim)
            Text(value)
                .font(.system(size: 11 * s, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(VM.fgMid)
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11 * s))
            .foregroundStyle(VM.fgMid)
            .padding(.leading, 16 * s)
            .padding(.top, 5 * s)
            .padding(.bottom, 2 * s)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Title bar

private struct TitleBarView: View {
    @Environment(\.uiScale) private var s
    @Binding var editing: Bool
    var onClose: () -> Void

    var body: some View {
        HStack(spacing: 9 * s) {
            Image(systemName: "cpu")
                .font(.system(size: 15 * s))
                .foregroundStyle(VM.fgMid)
                .frame(width: 17 * s, height: 17 * s)
            Text(editing ? "edit hosts" : "vibemon")
                .font(.system(size: 13 * s, weight: .semibold))
                .tracking(0.2 * s)
                .foregroundStyle(VM.fg)
                .help("⌘+ / ⌘− to zoom, ⌘0 to reset")

            Spacer()

            RoundIconButton(systemName: editing ? "checkmark" : "pencil",
                            highlighted: editing,
                            help: editing ? "Done editing" : "Add or remove hosts") {
                editing.toggle()
            }
            RoundIconButton(systemName: "xmark",
                            help: "Hide (re-open from the menu bar; Quit lives there too)") {
                onClose()
            }
        }
        .padding(.horizontal, 13 * s)
        .padding(.vertical, 11 * s)
        .background(VM.bgRaise)
        .overlay(alignment: .bottom) {
            Rectangle().fill(VM.lineSoft).frame(height: 1)
        }
    }
}

/// Invisible, zero-footprint buttons that register the ⌘+/⌘−/⌘0 zoom shortcuts.
/// Hidden by design — the widget has no on-screen zoom chrome (see the title tooltip).
private struct ZoomHotkeys: View {
    @Binding var zoom: Double

    var body: some View {
        ZStack {
            Button("") { zoom = clampZoom(zoom + 0.1) }.keyboardShortcut("+", modifiers: .command)
            Button("") { zoom = clampZoom(zoom + 0.1) }.keyboardShortcut("=", modifiers: .command)
            Button("") { zoom = clampZoom(zoom - 0.1) }.keyboardShortcut("-", modifiers: .command)
            Button("") { zoom = zoomDefault }.keyboardShortcut("0", modifiers: .command)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }
}

// MARK: - Add-host row (edit mode)

private struct AddHostRow: View {
    @Environment(\.uiScale) private var s
    var onAdd: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8 * s) {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 14 * s))
                .foregroundStyle(VM.dotOn)

            TextField("ssh alias or hostname", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13 * s))
                .foregroundStyle(VM.fg)
                .focused($focused)
                .onSubmit(submit)

            Button("Add", action: submit)
                .buttonStyle(.plain)
                .font(.system(size: 11 * s, weight: .semibold))
                .foregroundStyle(text.trimmingCharacters(in: .whitespaces).isEmpty ? VM.fgDim : VM.blueText)
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 13 * s)
        .padding(.vertical, 10 * s)
        .onAppear { focused = true }
    }

    private func submit() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        onAdd(t)
        text = ""
        focused = true
    }
}

// MARK: - Root

struct ContentView: View {
    @EnvironmentObject var store: MonitorStore
    @AppStorage("zoomLevel") private var zoom: Double = zoomDefault
    @State private var editing = false
    var onClose: () -> Void = {}

    var body: some View {
        let s = CGFloat(zoom)
        return VStack(spacing: 0) {
            TitleBarView(editing: $editing, onClose: onClose)

            VStack(spacing: 0) {
                // Biggest rigs first — the store keeps `hosts` ordered by total VRAM, descending.
                ForEach(Array(store.hosts.enumerated()), id: \.element.id) { index, host in
                    if index > 0 {
                        Rectangle().fill(VM.lineSoft).frame(height: 1)
                    }
                    HostSection(host: host,
                                editing: editing,
                                onRemove: { store.removeHost(host.id) })
                }

                if editing {
                    if !store.hosts.isEmpty {
                        Rectangle().fill(VM.lineSoft).frame(height: 1)
                    }
                    AddHostRow { store.addHost($0) }
                }
            }
            .padding(.top, 4 * s)
            .padding(.bottom, 6 * s)
        }
        .frame(width: 376 * s)
        .fixedSize(horizontal: false, vertical: true)
        .background(VM.bg)
        .clipShape(RoundedRectangle(cornerRadius: 14 * s))
        .overlay(RoundedRectangle(cornerRadius: 14 * s).strokeBorder(VM.line, lineWidth: 1))
        .background(ZoomHotkeys(zoom: $zoom))
        .environment(\.uiScale, s)
    }
}
