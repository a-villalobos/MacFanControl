import AppKit
import SwiftUI

struct FanReading: Identifiable, Codable {
    let id: Int
    let name: String
    let actual: Int
    let target: Int
    let min: Int
    let max: Int
    let mode: String
}

struct ThermalSummary: Codable {
    let average: Double
    let hottest: Double
    let sensor: String
    let count: Int

    var label: String {
        if hottest >= 100 { return "Hot" }
        if hottest >= 80 { return "Warm" }
        return "Normal"
    }

    var color: Color {
        if hottest >= 100 { return .red }
        if hottest >= 80 { return .orange }
        return .green
    }
}

struct FanGlyph: View {
    let isRunning: Bool
    let rpm: Int
    let size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                icon(phase: 0)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                    let seconds = timeline.date.timeIntervalSinceReferenceDate
                    let duration = max(0.45, 1.8 - (Double(rpm) / 6800.0) * 1.35)
                    let phase = isRunning ? (seconds.truncatingRemainder(dividingBy: duration) / duration) * 360.0 : 0
                    icon(phase: phase)
                }
            }
        }
        .frame(width: size + 6, height: size + 6)
        .accessibilityLabel(isRunning ? "Fan running" : "Fan stopped")
    }

    private func icon(phase: Double) -> some View {
        Image(systemName: "fanblades")
            .font(.system(size: size, weight: .medium))
            .rotationEffect(.degrees(phase), anchor: .center)
            .foregroundStyle(.tint)
    }
}

private struct Telemetry: Codable {
    let fans: [FanReading]
    let thermal: ThermalSummary?
}

final class FanModel: ObservableObject {
    @Published var fans: [FanReading] = []
    @Published var thermal: ThermalSummary?
    @Published var isWorking = false
    @Published var drafts: [Int: Double] = [:]
    @Published var percentDrafts: [Int: Double] = [:]
    @Published var authorized = false
    @Published var authorizationMessage: String?
    @Published var errorMessage: String?
    @Published var selectedFanID: Int?
    private let binary = "/Users/alexis/bin/macfan"
    private var timer: Timer?

    func start() {
        checkAuthorization()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func checkAuthorization() {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.run("/usr/bin/sudo", ["-n", "/Library/PrivilegedHelperTools/com.alexis.macfan.helper", "auto"]) ?? ""
            DispatchQueue.main.async {
                self.authorized = !result.contains("password is required") && !result.contains("not found")
            }
        }
    }

    func authorize() {
        isWorking = true
        let command = "/usr/bin/install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools && /usr/bin/install -o root -g wheel -m 755 /Users/alexis/bin/macfan /Library/PrivilegedHelperTools/macfan && /usr/bin/install -o root -g wheel -m 755 /Users/alexis/src/macfan/macfan-privileged-helper.zsh /Library/PrivilegedHelperTools/com.alexis.macfan.helper && /bin/grep -q \"com.alexis.macfan.helper\" /etc/sudoers || /bin/printf \"\\\\nalexis ALL=(root) NOPASSWD: /Library/PrivilegedHelperTools/com.alexis.macfan.helper\\\\n\" >> /etc/sudoers && /usr/sbin/visudo -cf /etc/sudoers"
        DispatchQueue.global(qos: .userInitiated).async {
            let script = "do shell script \"\(command)\" with administrator privileges"
            let result = Self.run("/usr/bin/osascript", ["-e", script]) ?? ""
            DispatchQueue.main.async {
                self.isWorking = false
                if result.contains("error") || result.contains("syntax") {
                    self.authorizationMessage = "Authorization could not be completed."
                } else {
                    self.authorizationMessage = nil
                    self.checkAuthorization()
                }
            }
        }
    }

    func refresh() {
        DispatchQueue.global(qos: .userInitiated).async { [binary] in
            let output = Self.run(binary, ["--json"]) ?? ""
            let telemetry = try? JSONDecoder().decode(Telemetry.self, from: Data(output.utf8))
            DispatchQueue.main.async {
                self.fans = telemetry?.fans ?? []
                self.thermal = telemetry?.thermal
                self.errorMessage = telemetry == nil ? "Unable to read fan telemetry." : nil
            }
        }
    }

    func set(_ fan: FanReading, rpm: Int) {
        drafts[fan.id] = Double(rpm)
        isWorking = true
        DispatchQueue.global(qos: .userInitiated).async {
            let helper = Self.runStatus("/usr/bin/sudo", ["-n", "/Library/PrivilegedHelperTools/com.alexis.macfan.helper", "set", "\(fan.id)", "\(rpm)"])
            if helper.status != 0 {
                let script = "do shell script \"\(self.binary) --set \(fan.id) \(rpm)\" with administrator privileges"
                let fallback = Self.runStatus("/usr/bin/osascript", ["-e", script])
                if fallback.status != 0 {
                    DispatchQueue.main.async { self.errorMessage = "Fan change was not authorized." }
                }
            }
            DispatchQueue.main.async {
                self.isWorking = false
                self.authorizationMessage = "Using macOS authorization for this change."
                self.refresh()
            }
        }
    }

    func draft(for fan: FanReading) -> Double {
        drafts[fan.id] ?? Double(max(fan.target, fan.actual, fan.min))
    }

    func updateDraft(_ fan: FanReading, value: Double) {
        drafts[fan.id] = value
    }

    func percent(for fan: FanReading) -> Double {
        guard fan.mode == "MANUAL", fan.max > fan.min else { return 0 }
        return min(100, max(0, (Double(fan.target - fan.min) / Double(fan.max - fan.min)) * 100))
    }

    func percentDraft(for fan: FanReading) -> Double {
        percentDrafts[fan.id] ?? percent(for: fan)
    }

    func updatePercentDraft(_ fan: FanReading, value: Double) {
        percentDrafts[fan.id] = value
    }

    func applyPercent(_ percent: Double, to fan: FanReading) {
        percentDrafts[fan.id] = percent
        if percent < 0.5 {
            automatic()
            return
        }
        let rpm = Int((Double(fan.min) + (percent / 100) * Double(fan.max - fan.min)).rounded())
        set(fan, rpm: rpm)
    }

    func automatic() {
        isWorking = true
        DispatchQueue.global(qos: .userInitiated).async {
            let helper = Self.runStatus("/usr/bin/sudo", ["-n", "/Library/PrivilegedHelperTools/com.alexis.macfan.helper", "auto"])
            if helper.status != 0 {
                let script = "do shell script \"\(self.binary) --auto\" with administrator privileges"
                let fallback = Self.runStatus("/usr/bin/osascript", ["-e", script])
                if fallback.status != 0 {
                    DispatchQueue.main.async { self.errorMessage = "Automatic restore was not authorized." }
                }
            }
            DispatchQueue.main.async {
                self.isWorking = false
                self.authorizationMessage = "Using macOS authorization for this change."
                self.refresh()
            }
        }
    }

    private static func run(_ path: String, _ arguments: [String]) -> String? {
        runStatus(path, arguments).output
    }

    private static func runStatus(_ path: String, _ arguments: [String]) -> (status: Int32, output: String?) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
            return (process.terminationStatus, output)
        } catch { return (-1, nil) }
    }

}

struct FanCard: View {
    let fan: FanReading
    let selected: Bool
    let select: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.12), lineWidth: 8)
                Circle()
                    .trim(from: 0, to: min(1, max(0, Double(fan.actual) / Double(max(fan.max, 1)))))
                    .stroke(fan.mode == "MANUAL" ? .orange : .blue, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                FanGlyph(isRunning: fan.actual > 0, rpm: fan.actual, size: 25)
            }
            .frame(width: 94, height: 94)
            Text(fan.name.replacingOccurrences(of: " Fan", with: ""))
                .font(.headline)
            Text("\(fan.actual) RPM")
                .font(.system(.callout, design: .rounded).weight(.semibold))
                .monospacedDigit()
            Text(fan.mode == "MANUAL" ? "Manual" : "Automatic")
                .font(.caption2.weight(.medium))
                .foregroundStyle(fan.mode == "MANUAL" ? .orange : .secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(selected ? .blue.opacity(0.9) : .white.opacity(0.12), lineWidth: selected ? 1.5 : 0.5)
        }
        .onTapGesture(perform: select)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(fan.name), \(fan.actual) RPM")
        .accessibilityHint("Select this fan for control")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct ContentView: View {
    @ObservedObject var model: FanModel
    let close: () -> Void

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "circle.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(model.thermal?.color ?? .secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Fan")
                        .font(.title2.weight(.semibold))
                        Text("AppleSMC thermal control")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: model.isWorking ? "arrow.triangle.2.circlepath" : "thermometer.medium")
                    .foregroundStyle(model.isWorking ? .orange : (model.thermal?.color ?? .secondary))
                    .symbolEffect(.pulse, isActive: model.isWorking)
                Text(model.thermal?.label ?? "Reading")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(model.thermal?.color ?? .secondary)
                Menu {
                    Button("Quit Fan", role: .destructive) { close() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                }
                .menuStyle(.borderlessButton)
                .help("More options")
            }
            Divider()
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Average")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(model.thermal.map { String(format: "%.1f°C", $0.average) } ?? "—")
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hottest")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(model.thermal.map { String(format: "%.1f°C", $0.hottest) } ?? "—")
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                        .foregroundStyle(model.thermal?.color ?? .primary)
                }
                Spacer()
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Refresh fan telemetry")
                    .help("Refresh")
            }
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
            }
            if let thermal = model.thermal {
                Text("\(thermal.sensor) · \(thermal.count) sensors")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if !model.authorized {
                HStack(spacing: 8) {
                    Image(systemName: "lock.circle")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Controls need authorization")
                            .font(.caption.weight(.medium))
                        Text("Enable once to avoid prompts for each change.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Enable") { model.authorize() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(.orange.opacity(0.25), lineWidth: 0.5)
                }
            }
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if !model.fans.isEmpty {
                Text("FANS")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .tracking(1.2)
                HStack(spacing: 10) {
                    ForEach(model.fans) { fan in
                        FanCard(fan: fan, selected: selectedFan?.id == fan.id) {
                            model.selectedFanID = fan.id
                        }
                    }
                }

                if let fan = selectedFan {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Adjusting \(fan.name)")
                                .font(.headline)
                            Spacer()
                            Text("\(Int(model.percentDraft(for: fan).rounded()))%")
                                .font(.system(.body, design: .rounded).weight(.semibold))
                                .monospacedDigit()
                        }
                        Slider(
                            value: Binding(
                                get: { model.percentDraft(for: fan) },
                                set: { model.updatePercentDraft(fan, value: $0) }
                            ),
                            in: 0...100,
                            step: 1,
                            onEditingChanged: { active in
                                if !active {
                                    model.applyPercent(model.percentDraft(for: fan), to: fan)
                                }
                            }
                        )
                        .tint(model.percentDraft(for: fan) == 0 ? .blue : .orange)
                        .accessibilityLabel("\(fan.name) fan control")
                        .accessibilityValue(model.percentDraft(for: fan) == 0 ? "Automatic" : "\(Int(model.percentDraft(for: fan).rounded())) percent manual")
                        HStack {
                            Text("Automatic")
                            Spacer()
                            Text("Manual")
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
                    }
                }
            }
            Divider()
            if let message = model.authorizationMessage {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            }
            .padding(16)
        }
        .frame(width: 370, height: 430)
    }

    private var selectedFan: FanReading? {
        model.fans.first(where: { $0.id == model.selectedFanID }) ?? model.fans.first
    }
}

private struct ToolbarFanGlyph: View {
    @ObservedObject var model: FanModel

    var body: some View {
        FanGlyph(
            isRunning: model.fans.map(\.actual).max() ?? 0 > 0,
            rpm: model.fans.map(\.actual).max() ?? 0,
            size: 16
        )
        .tint(.primary)
    }
}

final class FanStatusView: NSView {
    private let hostingView: NSHostingView<ToolbarFanGlyph>
    var onClick: (() -> Void)?

    init(model: FanModel, frame frameRect: NSRect) {
        hostingView = NSHostingView(rootView: ToolbarFanGlyph(model: model))
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Mac Fan")
        addSubview(hostingView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        hostingView.frame = bounds
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var statusView: FanStatusView!
    private var popover: NSPopover!
    private let model = FanModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusView = FanStatusView(model: model, frame: NSRect(x: 0, y: 0, width: 22, height: 22))
        statusView.onClick = { [weak self] in self?.togglePopover() }
        statusItem.view = statusView
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 370, height: 430)
        popover.contentViewController = NSHostingController(rootView: ContentView(model: model) {
            NSApp.terminate(nil)
        })
        model.start()
    }

    @objc private func togglePopover() {
        guard let statusView else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            // Keep a small breathing gap below the menu bar, matching native macOS popovers.
            let anchor = statusView.bounds.offsetBy(dx: 0, dy: -6)
            popover.show(relativeTo: anchor, of: statusView, preferredEdge: .minY)
            popover.contentViewController?.view.window?.becomeKey()
        }
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
