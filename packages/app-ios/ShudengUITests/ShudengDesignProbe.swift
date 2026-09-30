// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest

/// 设计迭代用的简易通道：脚本从 /private/tmp/shudeng-design-script.txt 读，
/// 每步截图写到 /private/tmp/shudeng-design-out/。只给改版视觉检查用，不参与断言。
final class ShudengDesignProbe: XCTestCase {

    private let outDir = "/private/tmp/shudeng-design-out"
    private let scriptPath = "/private/tmp/shudeng-design-script.txt"

    func testShots() throws {
        continueAfterFailure = true
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        let script = (try? String(contentsOfFile: scriptPath, encoding: .utf8)) ?? "wait 8\nshot 00-default\n"
        print("PROBE script:\n\(script)")

        var app: XCUIApplication?

        func launched() -> XCUIApplication {
            if let app { return app }
            let fresh = XCUIApplication()
            // /private/tmp/shudeng-design-env.txt 里一行一个 KEY=VALUE，可以顶掉下面的默认值
            // （SHUDENG_SEED_SAMPLE_BOOK=0 看空书库、SHUDENG_ONBOARDED=NO 看引导页）。
            var extra: [String: String] = [:]
            if let text = try? String(contentsOfFile: "/private/tmp/shudeng-design-env.txt", encoding: .utf8) {
                for line in text.split(separator: "\n") {
                    let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
                    guard parts.count == 2 else { continue }
                    extra[parts[0]] = parts[1]
                }
            }
            fresh.launchArguments += ["-shudeng.onboarded", extra["SHUDENG_ONBOARDED"] ?? "YES"]
            fresh.launchEnvironment["SHUDENG_SEED_SAMPLE_BOOK"] = "1"
            fresh.launchEnvironment["SHUDENG_SEED_SAMPLE_BOOK_EN"] = "1"
            fresh.launchEnvironment["SHUDENG_SEED_SAMPLE_PDF"] = "1"
            fresh.launchEnvironment["SHUDENG_AI_BASE_URL"] = "http://127.0.0.1:8799/v1"
            fresh.launchEnvironment["SHUDENG_AI_MODEL"] = "mock-model"
            fresh.launchEnvironment["SHUDENG_AI_API_KEY"] = "mock-key"
            for (key, value) in extra where key != "SHUDENG_ONBOARDED" {
                if value == "0" { fresh.launchEnvironment.removeValue(forKey: key) }
                else { fresh.launchEnvironment[key] = value }
            }
            fresh.launch()
            app = fresh
            return fresh
        }

        for raw in script.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let target = launched()
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            let verb = parts[0]
            let arg = parts.count > 1 ? parts[1] : ""

            switch verb {
            case "wait":
                Thread.sleep(forTimeInterval: Double(arg) ?? 2)
            case "tab":
                target.tabBars.buttons[arg].firstMatch.tap()
                Thread.sleep(forTimeInterval: 1.2)
            case "tap":
                let node = element(target, spec: arg)
                if node.waitForExistence(timeout: 10) {
                    node.tap()
                } else {
                    print("PROBE missing element: \(arg)")
                }
                Thread.sleep(forTimeInterval: 1.2)
            case "press":
                let node = element(target, spec: arg)
                if node.waitForExistence(timeout: 10) {
                    node.press(forDuration: 1.2)
                } else {
                    print("PROBE missing element: \(arg)")
                }
                Thread.sleep(forTimeInterval: 1.0)
            case "back":
                let node = target.navigationBars.buttons.firstMatch
                if node.exists { node.tap() }
                Thread.sleep(forTimeInterval: 1.5)
            case "type":
                target.typeText(arg)
                Thread.sleep(forTimeInterval: 1.5)
            case "tapxy":
                // 正文没有可点元素，用归一化坐标点页面中间（切上下栏 / 翻页）：
                // "tapxy 0.5 0.5"。
                let nums = arg.split(separator: " ").compactMap { Double($0) }
                let x = nums.count > 0 ? nums[0] : 0.5
                let y = nums.count > 1 ? nums[1] : 0.5
                target.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y)).tap()
                Thread.sleep(forTimeInterval: 1.2)
            case "tapshots":
                // 点一下立刻连拍，用来确认翻页是不是有过渡动画：tapshots 0.86 0.5 30-burst。
                let parts = arg.split(separator: " ").map(String.init)
                guard parts.count >= 3 else { break }
                let x = Double(parts[0]) ?? 0.5
                let y = Double(parts[1]) ?? 0.5
                let name = parts[2]
                target.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y)).tap()
                for index in 0..<6 {
                    let png = target.screenshot().pngRepresentation
                    try? png.write(to: URL(fileURLWithPath: "\(outDir)/\(name)-\(index).png"))
                }
                Thread.sleep(forTimeInterval: 1.0)
            case "drag":
                // "drag 0.5 0.78 0.5 0.22 slow"，归一化起终点 + 速度档（slow/default/fast）。
                let parts = arg.split(separator: " ").map(String.init)
                let nums = parts.compactMap { Double($0) }
                guard nums.count >= 4 else { print("PROBE bad drag: \(arg)"); break }
                let velocity: XCUIGestureVelocity =
                    parts.count > 4 && parts[4] == "slow" ? .slow :
                    parts.count > 4 && parts[4] == "fast" ? .fast : .default
                let from = target.coordinate(withNormalizedOffset: CGVector(dx: nums[0], dy: nums[1]))
                let to = target.coordinate(withNormalizedOffset: CGVector(dx: nums[2], dy: nums[3]))
                from.press(forDuration: 0.1, thenDragTo: to, withVelocity: velocity, thenHoldForDuration: 0)
                Thread.sleep(forTimeInterval: 2.6)
            case "swipeleft":
                target.swipeLeft()
                Thread.sleep(forTimeInterval: 1.0)
            case "swiperight":
                target.swipeRight()
                Thread.sleep(forTimeInterval: 1.0)
            case "swipeup":
                target.swipeUp()
                Thread.sleep(forTimeInterval: 1.0)
            case "swipedown":
                target.swipeDown()
                Thread.sleep(forTimeInterval: 1.0)
            case "shot":
                let png = target.screenshot().pngRepresentation
                try? png.write(to: URL(fileURLWithPath: "\(outDir)/\(arg).png"))
                print("PROBE shot \(arg)")
            case "dump":
                let text = target.debugDescription
                try? text.write(toFile: "\(outDir)/\(arg).txt", atomically: true, encoding: .utf8)
                print("PROBE dump \(arg)")
            default:
                print("PROBE skip unknown: \(line)")
            }
        }
        print("PROBE done")
    }

    private func element(_ app: XCUIApplication, spec: String) -> XCUIElement {
        if spec.hasPrefix("id:") {
            let id = String(spec.dropFirst(3))
            return app.descendants(matching: .any).matching(identifier: id).firstMatch
        }
        if spec.hasPrefix("text:") {
            let label = String(spec.dropFirst(5))
            let button = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", label)).firstMatch
            if button.exists { return button }
            return app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", label)).firstMatch
        }
        if spec.hasPrefix("field:") {
            let label = String(spec.dropFirst(6))
            let byID = app.textFields[label]
            if byID.exists { return byID }
            return app.textFields.matching(
                NSPredicate(format: "label CONTAINS %@ OR placeholderValue CONTAINS %@", label, label)
            ).firstMatch
        }
        return app.descendants(matching: .any).matching(identifier: spec).firstMatch
    }
}
