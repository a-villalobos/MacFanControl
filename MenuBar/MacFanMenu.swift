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
    @Published var authorized = false
    @Published var authorizationMessage: String?
    @Published var errorMessage: String?
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

struct FanRow: View {
    let fan: FanReading
    let model: FanModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                FanGlyph(isRunning: fan.actual > 0, rpm: fan.actual, size: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(fan.name)
                        .font(.headline)
                    Text(fan.mode == "MANUAL" ? "Manual control" : "macOS automatic")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(fan.actual) RPM")
                        .font(.system(.body, design: .rounded).weight(.semibold))
                    Text("target \(fan.target)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            ProgressView(value: Double(fan.actual), total: Double(max(fan.max, 1)))
                .tint(fan.mode == "MANUAL" ? .orange : .blue)
            HStack(spacing: 10) {
                Slider(
                    value: Binding(
                        get: { model.draft(for: fan) },
                        set: { model.updateDraft(fan, value: $0) }
                    ),
                    in: Double(fan.min)...Double(fan.max),
                    step: 100,
                    onEditingChanged: { active in
                        if !active {
                            model.set(fan, rpm: Int(model.draft(for: fan).rounded()))
                        }
                    }
                )
                .tint(fan.mode == "MANUAL" ? .orange : .blue)
                .accessibilityLabel("\(fan.name) target speed")
                .accessibilityValue("\(Int(model.draft(for: fan).rounded())) RPM")
                Text("\(Int(model.draft(for: fan).rounded()))")
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .frame(width: 48, alignment: .trailing)
                    .monospacedDigit()
            }
            HStack {
                Text("\(fan.min) RPM")
                Spacer()
                Text("\(fan.max) RPM")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .disabled(model.isWorking)
            .opacity(model.isWorking ? 0.55 : 1)
        }
        .padding(.vertical, 10)
    }
}

struct ContentView: View {
    @ObservedObject var model: FanModel
    let close: () -> Void

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Mac Fan")
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
            }
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            ForEach(model.fans) { fan in
                FanRow(fan: fan, model: model)
            }
            Divider()
            HStack(spacing: 10) {
                Button {
                    model.automatic()
                } label: {
                    Label("Return to macOS control", systemImage: "arrow.uturn.backward.circle")
                }
                    .buttonStyle(.bordered)
                    .tint(.secondary)
                    .disabled(model.isWorking)
                Spacer()
                Menu {
                    Button("Quit Mac Fan", role: .destructive) { close() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                }
                .menuStyle(.borderlessButton)
                .help("More options")
            }
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
}

final class FanStatusView: NSView {
    private let imageView = NSImageView()
    var onClick: (() -> Void)?
    var angle: CGFloat = 0 {
        didSet {
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Mac Fan")
        imageView.image = NSImage(systemSymbolName: "fanblades", accessibilityDescription: "Mac Fan")
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.contentTintColor = .labelColor
        imageView.wantsLayer = true
        imageView.layer?.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        addSubview(imageView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        imageView.frame = bounds.insetBy(dx: 3, dy: 3)
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
    private var spinTimer: Timer?
    private var iconAngle: CGFloat = 0
    private var lastSpin = Date()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusView = FanStatusView(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
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
        spinTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            guard let self else { return }
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                self.iconAngle = 0
                self.statusView.angle = 0
                return
            }
            let rpm = self.model.fans.map(\.actual).max() ?? 0
            if rpm > 0 {
                let duration = max(0.45, 1.8 - (Double(rpm) / 6800.0) * 1.35)
                let elapsed = Date().timeIntervalSince(self.lastSpin)
                self.lastSpin = Date()
                self.iconAngle += CGFloat((elapsed / duration) * 2.0 * Double.pi)
                self.statusView.angle = self.iconAngle
            } else {
                self.iconAngle = 0
                self.lastSpin = Date()
                self.statusView.angle = 0
            }
        }
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
