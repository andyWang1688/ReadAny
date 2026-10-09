// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import UIKit

final class ReaderAnnotationUITests: XCTestCase {
    func testExistingAnnotationCanBeReadEditedAndDeleted() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-shudeng.onboarded", "YES"]
        app.launchEnvironment["SHUDENG_SEED_SAMPLE_BOOK"] = "1"
        app.launch()
        let book = app.buttons.matching(identifier: "library.book")
            .matching(NSPredicate(format: "label CONTAINS %@", "书灯测试样书")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 30))
        book.tap()
        XCTAssertTrue(app.buttons["reader.speech"].waitForExistence(timeout: 40))
        let ready = NSPredicate(format: "enabled == true")
        expectation(for: ready, evaluatedWith: app.buttons["reader.speech"])
        waitForExpectations(timeout: 40)
        app.buttons["reader.toc"].tap()
        let chapter = app.buttons.matching(identifier: "reader.tocRow").firstMatch
        XCTAssertTrue(chapter.waitForExistence(timeout: 10))
        chapter.tap()
        XCTAssertTrue(app.navigationBars["目录"].waitForNonExistence(timeout: 10))

        let point = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.42))
        point.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["reader.selectionNote"].waitForExistence(timeout: 10))
        app.buttons["reader.selectionNote"].tap()
        let input = app.textFields["reader.noteEditor"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        let note = "annotation-" + String(UUID().uuidString.prefix(8))
        input.tap()
        if let existing = input.value as? String, !existing.isEmpty, existing != "想法…" {
            input.press(forDuration: 1.1)
            let selectAll = [app.menuItems["全选"], app.menuItems["Select All"],
                             app.buttons["全选"], app.buttons["Select All"]]
                .first(where: { $0.exists })
            XCTAssertNotNil(selectAll, "已有笔记输入框没有全选菜单")
            selectAll?.tap()
        }
        input.typeText(note)
        app.buttons["reader.noteSave"].tap()
        XCTAssertTrue(input.waitForNonExistence(timeout: 10))
        let original = app.staticTexts["reader.noteOriginal"]
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.42)).tap()
        if !input.waitForExistence(timeout: 3) { try tapHighlight(in: app, near: 0.42) }
        XCTAssertTrue(input.waitForExistence(timeout: 10), "点击已有标注没有打开笔记面板")
        XCTAssertTrue(original.exists && !original.label.isEmpty, "缺少标注原文")
        XCTAssertEqual(input.value as? String, note, "显示的不是已有笔记")
        input.tap()
        input.press(forDuration: 1.1)
        let selectAll = [app.menuItems["全选"], app.menuItems["Select All"],
                         app.buttons["全选"], app.buttons["Select All"]]
            .first(where: { $0.exists })
        XCTAssertNotNil(selectAll, "笔记输入框没有全选菜单")
        selectAll?.tap()
        input.typeText(note + "-edited")
        app.buttons["reader.noteSave"].tap()
        XCTAssertTrue(input.waitForNonExistence(timeout: 10))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.42)).tap()
        if !input.waitForExistence(timeout: 3) { try tapHighlight(in: app, near: 0.42) }
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        XCTAssertEqual(input.value as? String, note + "-edited", "编辑没有更新原标注")
        app.buttons["reader.annotationDelete"].tap()
        XCTAssertTrue(input.waitForNonExistence(timeout: 10))
        app.buttons["reader.close"].tap()
        XCTAssertTrue(app.buttons["library.import"].waitForExistence(timeout: 10))
        app.tabBars.buttons["笔记"].tap()
        XCTAssertTrue(app.buttons["notes.export"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.staticTexts[note + "-edited"].exists, "删除后笔记仍在列表")
    }

    /// Choose the colored annotation nearest the line we selected, excluding toolbars.
    private func tapHighlight(in app: XCUIApplication, near targetY: Double) throws {
        guard let image = app.screenshot().image.cgImage,
              let bytes = image.dataProvider?.data as Data? else { throw XCTSkip("无法读取截图") }
        let pixelBytes = max(1, image.bitsPerPixel / 8)
        let target = Int(Double(image.height) * targetY)
        var hit: (x: Int, y: Int)?
        for distance in 0..<Int(Double(image.height) * 0.15) {
            for y in [target + distance, target - distance] where y >= 0 && y < image.height {
                for x in stride(from: Int(Double(image.width) * 0.35), to: Int(Double(image.width) * 0.65), by: 2) {
                    let offset = y * image.bytesPerRow + x * pixelBytes
                    guard offset + 2 < bytes.count else { continue }
                    let channels = [Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2])]
                    if channels.max()! - channels.min()! > 30 {
                        hit = (x, y)
                        break
                    }
                }
                if hit != nil { break }
            }
            if hit != nil { break }
        }
        guard let hit else {
            XCTFail("选中附近未找到已保存的高亮颜色")
            return
        }
        app.coordinate(withNormalizedOffset: CGVector(dx: Double(hit.x) / Double(image.width), dy: Double(hit.y) / Double(image.height))).tap()
    }
}
