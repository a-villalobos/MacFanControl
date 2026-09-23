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
    // nil means all fans are selected by default; a set tracks explicit toggles.
    @Published var selectedFanIDs: Set<Int>?
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
                for fan in self.fans where fan.mode == "AUTO" {
                    self.percentDrafts[fan.id] = 0
                }
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
        applyPercent(percent, to: [fan])
    }

    func percentDraft(for fans: [FanReading]) -> Double {
        guard !fans.isEmpty else { return 0 }
        return fans.map { percentDraft(for: $0) }.reduce(0, +) / Double(fans.count)
    }

    func updatePercentDraft(_ fans: [FanReading], value: Double) {
        for fan in fans {
            percentDrafts[fan.id] = value
        }
    }

    func isSelected(_ fanID: Int) -> Bool {
        selectedFanIDs?.contains(fanID) ?? true
    }

    func toggleSelection(_ fanID: Int) {
        var selection = selectedFanIDs ?? Set(fans.map(\.id))
        if selection.contains(fanID) {
            selection.remove(fanID)
        } else {
            selection.insert(fanID)
        }
        selectedFanIDs = selection
    }

    func applyPercent(_ percent: Double, to fans: [FanReading]) {
        for fan in fans {
            percentDrafts[fan.id] = percent
        }
        for fan in fans {
            let rpm = Int((Double(fan.min) + (percent / 100) * Double(fan.max - fan.min)).rounded())
            set(fan, rpm: rpm)
        }
    }

    func automatic() {
        for fan in fans {
            percentDrafts[fan.id] = 0
        }
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
            .frame(width: 76, height: 76)
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
        .padding(.vertical, 8)
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
            VStack(spacing: 4) {
                ZStack {
                    Text("Fan")
                        .font(.title2.weight(.semibold))
                    HStack {
                        HStack(spacing: 6) {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 8))
                            Text(model.thermal?.label ?? "Reading")
                                .font(.caption.weight(.medium))
                        }
                        .foregroundStyle(model.thermal?.color ?? .secondary)
                        Spacer()
                        if model.isWorking {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .foregroundStyle(.orange)
                                .symbolEffect(.pulse, isActive: true)
                        }
                        Button { close() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .semibold))
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Close Fan")
                        .help("Close")
                    }
                }
                if let thermal = model.thermal {
                    HStack(spacing: 12) {
                        Text(String(format: "%.1f°C average", thermal.average))
                        Text("·")
                        Text(String(format: "%.1f°C hottest", thermal.hottest))
                    }
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(thermal.color)
                }
            }
            Divider()
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
                HStack(alignment: .firstTextBaseline) {
                    Text("FANS")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .tracking(1.2)
                }
                HStack(spacing: 10) {
                    ForEach(model.fans) { fan in
                        FanCard(fan: fan, selected: model.isSelected(fan.id)) {
                            model.toggleSelection(fan.id)
                        }
                    }
                }

                if !selectedFans.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(selectedFans.count == model.fans.count ? "Adjusting Both Fans" : "Adjusting \(selectedFans.map { $0.name.replacingOccurrences(of: " Fan", with: "") }.joined(separator: " + "))")
                                .font(.headline)
                            Spacer()
                            Button("Reset to Automatic") {
                                model.automatic()
                            }
                            .buttonStyle(.borderless)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        }
                        Slider(
                            value: Binding(
                                get: { model.percentDraft(for: selectedFans) },
                                set: { model.updatePercentDraft(selectedFans, value: $0) }
                            ),
                            in: 0...100,
                            step: 1,
                            onEditingChanged: { active in
                                if !active {
                                    model.applyPercent(model.percentDraft(for: selectedFans), to: selectedFans)
                                }
                            }
                        )
                        .tint(model.percentDraft(for: selectedFans) == 0 ? .blue : .orange)
                        .accessibilityLabel(selectedFans.count == model.fans.count ? "Both fans control" : "Selected fans control")
                        .accessibilityValue(model.percentDraft(for: selectedFans) == 0 ? "Idle" : "\(Int(model.percentDraft(for: selectedFans).rounded())) percent")
                        HStack {
                            Text("Idle")
                            Spacer()
                            Text("Max")
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
                } else {
                    Text("Select a fan to adjust")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
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

    private var selectedFans: [FanReading] {
        model.fans.filter { model.isSelected($0.id) }
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
        .tint(model.thermal?.color ?? .secondary)
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
            self.popover.performClose(nil)
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
