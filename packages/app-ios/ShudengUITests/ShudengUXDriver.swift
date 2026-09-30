// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest

/// 书灯 · 交互式操作通道：脚本从磁盘读，动作一条条执行，截图写回磁盘。
/// 目的：让「操作 App」变成 点一下 → 看结果 → 再点一下 的过程，而不是一次性跑死脚本。
final class ShudengUXDriver: XCTestCase {

    private var app: XCUIApplication!
    private var outDir: URL!
    private var log: [String] = []

    private let hostDir = "/private/tmp/shudeng-ux"

    func testDrive() throws {
        continueAfterFailure = true

        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        outDir = URL(fileURLWithPath: hostDir + "/out")
        if (try? fm.createDirectory(at: outDir, withIntermediateDirectories: true)) == nil
            || (try? "probe".write(to: outDir.appendingPathComponent("probe.txt"), atomically: true, encoding: .utf8)) == nil {
            outDir = docs
        }

        var script = (try? String(contentsOfFile: hostDir + "/script.txt", encoding: .utf8)) ?? ""
        if script.isEmpty {
            script = (try? String(contentsOf: docs.appendingPathComponent("script.txt"), encoding: .utf8)) ?? ""
        }
        say("driver out=\(outDir.path) scriptChars=\(script.count)")

        for rawLine in script.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            run(line)
        }
        say("DONE \(log.joined(separator: " | "))")
        try? log.joined(separator: "\n").write(
            to: outDir.appendingPathComponent("last-log.txt"), atomically: true, encoding: .utf8
        )
    }

    // MARK: - 指令

    private func run(_ line: String) {
        let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        let cmd = String(parts[0])
        let arg = parts.count > 1 ? String(parts[1]) : ""
        switch cmd {
        case "launch":
            app = makeApp(fresh: arg.contains("fresh"), aiDead: arg.contains("ai-dead"))
            app.launch()
            say("launched")
        case "shot":
            shot(arg)
        case "wait":
            Thread.sleep(forTimeInterval: Double(arg) ?? 1)
            say("waited \(arg)")
        case "tap":
            tap(arg)
        case "longpress":
            longPress(arg)
        case "swipe":
            swipe(arg)
        case "type":
            app.typeText(arg)
            say("typed \(arg)")
        case "controls":
            setControls(want: arg == "on")
        case "key":
            app.typeKey(keyCode(arg), modifierFlags: [])
            say("key \(arg)")
        case "dump":
            dumpTree()
        case "report":
            report(arg)
        default:
            say("unknown: \(line)")
        }
    }

    // MARK: - 动作

    /// 阅读器点中间会收起 / 展开工具栏；按需切到目标状态。
    private func setControls(want: Bool) {
        let visible = app.buttons["reader.toc"].isHittable
        if visible == want {
            say("controls already \(want ? "on" : "off")")
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            say("controls turned \(want ? "on" : "off")")
        }
        Thread.sleep(forTimeInterval: 0.9)
    }

    private func tap(_ spec: String) {
        guard let element = resolve(spec) else {
            if let point = point(spec) {
                app.coordinate(withNormalizedOffset: point).tap()
                say("tap \(spec) (coordinate)")
            } else {
                say("MISS tap \(spec)")
            }
            return
        }
        if element.waitForExistence(timeout: 6) {
            let hittable = element.isHittable
            element.tap()
            say("tap \(spec) hittable=\(hittable)")
        } else {
            say("MISS(no element) tap \(spec)")
        }
    }

    private func longPress(_ spec: String) {
        let bits = spec.split(separator: " ")
        let target = String(bits[0])
        let duration = bits.count > 1 ? (Double(bits[1]) ?? 1.2) : 1.2
        guard let element = resolve(target) else {
            if let point = point(target) {
                app.coordinate(withNormalizedOffset: point).press(forDuration: duration)
                say("longpress \(target) (coordinate)")
            } else {
                say("MISS longpress \(target)")
            }
            return
        }
        if element.waitForExistence(timeout: 6) {
            element.press(forDuration: duration)
            say("longpress \(target)")
        } else {
            say("MISS(no element) longpress \(target)")
        }
    }

    private func swipe(_ spec: String) {
        let bits = spec.split(separator: " ")
        let direction = String(bits[0])
        let target: XCUIElement = bits.count > 1 ? (resolve(String(bits[1])) ?? app) : app
        switch direction {
        case "left": target.swipeLeft()
        case "right": target.swipeRight()
        case "up": target.swipeUp()
        case "down": target.swipeDown()
        default: say("MISS swipe \(spec)"); return
        }
        say("swipe \(spec)")
    }

    private func shot(_ name: String) {
        let file = outDir.appendingPathComponent("\(name).png")
        do {
            try app.screenshot().pngRepresentation.write(to: file)
            say("shot \(name)")
        } catch {
            say("SHOT-FAIL \(name) \(error.localizedDescription)")
        }
    }

    private func dumpTree() {
        let text = app.debugDescription
        try? text.write(to: outDir.appendingPathComponent("tree.txt"), atomically: true, encoding: .utf8)
        say("dump \(text.count) chars")
    }

    private func report(_ name: String) {
        let file = outDir.appendingPathComponent("\(name).txt")
        try? app.debugDescription.write(to: file, atomically: true, encoding: .utf8)
        say("report \(name)")
    }

    // MARK: - 解析

    private func resolve(_ spec: String) -> XCUIElement? {
        if spec.hasPrefix("id:") {
            let id = String(spec.dropFirst(3))
            return app.descendants(matching: .any).matching(identifier: id).firstMatch
        }
        if spec.hasPrefix("button:") {
            let label = String(spec.dropFirst(7))
            return app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
        }
        if spec.hasPrefix("text:") {
            let label = String(spec.dropFirst(5))
            return app.staticTexts.matching(NSPredicate(format: "label == %@", label)).firstMatch
        }
        if spec.hasPrefix("cell:") {
            let label = String(spec.dropFirst(5))
            return app.cells.matching(NSPredicate(format: "label CONTAINS %@", label)).firstMatch
        }
        if spec.hasPrefix("book:") {
            let label = String(spec.dropFirst(5))
            return app.buttons
                .matching(identifier: "library.book")
                .matching(NSPredicate(format: "label CONTAINS %@", label))
                .firstMatch
        }
        if spec.hasPrefix("field:") {
            let label = String(spec.dropFirst(6))
            return app.textFields.matching(
                NSPredicate(format: "label CONTAINS %@ OR placeholderValue CONTAINS %@", label, label)
            ).firstMatch
        }
        return nil
    }

    private func point(_ spec: String) -> CGVector? {
        let bits = spec.split(separator: ",")
        if bits.count == 2, let x = Double(bits[0]), let y = Double(bits[1]) {
            return CGVector(dx: x, dy: y)
        }
        switch spec {
        case "center": return CGVector(dx: 0.5, dy: 0.5)
        case "top": return CGVector(dx: 0.5, dy: 0.08)
        case "bottom": return CGVector(dx: 0.5, dy: 0.94)
        case "left": return CGVector(dx: 0.08, dy: 0.5)
        case "right": return CGVector(dx: 0.92, dy: 0.5)
        default: return nil
        }
    }

    private func keyCode(_ name: String) -> XCUIKeyboardKey {
        switch name {
        case "Return", "Enter": return .return
        case "Delete": return .delete
        case "Escape": return .escape
        case "Tab": return .tab
        case "Space": return .space
        default: return XCUIKeyboardKey(rawValue: name)
        }
    }

    private func say(_ text: String) {
        log.append(text)
        print("UXDRV: \(text)")
    }

    private func makeApp(fresh: Bool, aiDead: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-shudeng.onboarded", fresh ? "NO" : "YES"]
        let isSimulator = ProcessInfo.processInfo.environment["SIMULATOR_UDID"] != nil
        if isSimulator {
            app.launchEnvironment["SHUDENG_SEED_SAMPLE_BOOK"] = "1"
            app.launchEnvironment["SHUDENG_SEED_SAMPLE_BOOK_EN"] = "1"
            app.launchEnvironment["SHUDENG_SEED_SAMPLE_PDF"] = "1"
            app.launchEnvironment["SHUDENG_AI_BASE_URL"] = aiDead
                ? "http://127.0.0.1:8798/v1"
                : "http://127.0.0.1:8799/v1"
            app.launchEnvironment["SHUDENG_AI_MODEL"] = "mock-model"
            app.launchEnvironment["SHUDENG_AI_API_KEY"] = "mock-key"
        }
        return app
    }
}
