import AppKit
import Foundation

struct FanReading {
    let index: Int
    let name: String
    let actual: Int
    let target: Int
    let min: Int
    let max: Int
    let mode: String
}

final class FanAction: NSObject {
    let index: Int?
    let rpm: Int?
    let automatic: Bool
    let refresh: Bool
    unowned let app: App

    init(app: App, index: Int? = nil, rpm: Int? = nil, automatic: Bool = false, refresh: Bool = false) {
        self.app = app
        self.index = index
        self.rpm = rpm
        self.automatic = automatic
        self.refresh = refresh
    }

    @objc func run(_ sender: Any?) {
        if refresh { app.refresh(); return }
        if automatic { app.restoreAutomatic(); return }
        if let index, let rpm { app.setFan(index: index, rpm: rpm) }
    }
}

final class App: NSObject, NSApplicationDelegate {
    private let binary = "/Users/alexis/bin/macfan"
    private var statusItem: NSStatusItem!
    private var menu = NSMenu()
    private var readings: [FanReading] = []
    private var actionTargets: [FanAction] = []
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🌀"
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        let output = run(binary, arguments: ["--list"]) ?? ""
        readings = parse(output)
        rebuildMenu(output: output)
    }

    private func rebuildMenu(output: String) {
        menu = NSMenu()
        actionTargets.removeAll()
        let title = NSMenuItem(title: "Mac Fan Control", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())

        for fan in readings {
            let item = NSMenuItem(title: "\(fan.name): \(fan.actual) RPM · \(fan.mode)", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            item.submenu = submenu
            submenu.addItem(info("Current: \(fan.actual) RPM"))
            submenu.addItem(info("Target: \(fan.target) RPM"))
            submenu.addItem(info("Range: \(fan.min)–\(fan.max) RPM"))
            submenu.addItem(.separator())
            submenu.addItem(action("Use current RPM", index: fan.index, rpm: max(fan.actual, fan.min)))
            for rpm in [fan.min, 2500, 3500, 4500, fan.max].filter({ $0 >= fan.min && $0 <= fan.max }).reduce(into: [Int](), { if !$0.contains($1) { $0.append($1) } }) {
                submenu.addItem(action("Set \(rpm) RPM", index: fan.index, rpm: rpm))
            }
            submenu.addItem(action("Full blast (\(fan.max) RPM)", index: fan.index, rpm: fan.max))
            submenu.addItem(.separator())
            submenu.addItem(autoAction("Restore automatic control"))
            menu.addItem(item)
        }

        if let summary = output.split(separator: "\n").first(where: { $0.contains("temps:") }) {
            menu.addItem(.separator())
            menu.addItem(info(String(summary).trimmingCharacters(in: .whitespaces)))
        }
        menu.addItem(.separator())
        menu.addItem(autoAction("Restore all fans to automatic control"))
        menu.addItem(action("Refresh", refresh: true))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func info(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, index: Int? = nil, rpm: Int? = nil, refresh: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(FanAction.run(_:)), keyEquivalent: "")
        let target = FanAction(app: self, index: index, rpm: rpm, refresh: refresh)
        actionTargets.append(target)
        item.target = target
        return item
    }

    private func autoAction(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(FanAction.run(_:)), keyEquivalent: "")
        let target = FanAction(app: self, automatic: true)
        actionTargets.append(target)
        item.target = target
        return item
    }

    func setFan(index: Int, rpm: Int) {
        _ = run("/usr/bin/sudo", arguments: ["-n", "/Library/PrivilegedHelperTools/com.alexis.macfan.helper", "set", "\(index)", "\(rpm)"])
        refresh()
    }

    func restoreAutomatic() {
        _ = run("/usr/bin/sudo", arguments: ["-n", "/Library/PrivilegedHelperTools/com.alexis.macfan.helper", "auto"])
        refresh()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func run(_ path: String, arguments: [String]) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        } catch { return nil }
    }

    private func parse(_ output: String) -> [FanReading] {
        let pattern = #"^\s*(.+?)\s+(\d+) RPM\s+target\s+(\d+)\s+range\s+(\d+)[–-](\d+)\s+\[(\w+)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .anchorsMatchLines) else { return [] }
        return regex.matches(in: output, range: NSRange(output.startIndex..., in: output)).enumerated().compactMap { index, match in
            func value(_ n: Int) -> String? {
                guard let range = Range(match.range(at: n), in: output) else { return nil }
                return String(output[range]).trimmingCharacters(in: .whitespaces)
            }
            guard let name = value(1), let actual = Int(value(2) ?? ""), let target = Int(value(3) ?? ""), let min = Int(value(4) ?? ""), let max = Int(value(5) ?? ""), let mode = value(6) else { return nil }
            return FanReading(index: index, name: name, actual: actual, target: target, min: min, max: max, mode: mode)
        }
    }
}

let application = NSApplication.shared
let delegate = App()
application.delegate = delegate
application.run()
