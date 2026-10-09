// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest

/// 书灯 · 「普通用户」视角界面走查。
/// 只截图 + 记录，不做断言、不中断：宗旨是拿到一整套真实界面截图，
/// 用来评界面、文案和操作流程（不是功能验收）。
final class ShudengUXWalkthrough: XCTestCase {

    private var app: XCUIApplication!
    private var missed: [String] = []

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    private var isSimulator: Bool {
        ProcessInfo.processInfo.environment["SIMULATOR_UDID"] != nil
    }

    private func makeApp(onboarding: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-shudeng.onboarded", onboarding ? "NO" : "YES"]
        guard isSimulator else { return app }
        app.launchEnvironment["SHUDENG_SEED_SAMPLE_BOOK"] = "1"
        app.launchEnvironment["SHUDENG_SEED_SAMPLE_BOOK_EN"] = "1"
        app.launchEnvironment["SHUDENG_SEED_SAMPLE_PDF"] = "1"
        app.launchEnvironment["SHUDENG_AI_BASE_URL"] = "http://127.0.0.1:8799/v1"
        app.launchEnvironment["SHUDENG_AI_MODEL"] = "mock-model"
        app.launchEnvironment["SHUDENG_AI_API_KEY"] = "mock-key"
        return app
    }

    // MARK: - 工具

    private func snap(_ name: String, of target: XCUIApplication? = nil) {
        let attachment = XCTAttachment(screenshot: (target ?? app).screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func miss(_ what: String) {
        missed.append(what)
        print("UXWALK-MISS: \(what)")
    }

    private func log(_ text: String) {
        print("UXWALK: \(text)")
    }

    private func tap(_ element: XCUIElement, _ timeout: TimeInterval = 8, _ what: String) {
        guard element.waitForExistence(timeout: timeout) else {
            miss("找不到 \(what)")
            return
        }
        element.tap()
    }

    private func pause(_ seconds: TimeInterval = 0.8) {
        Thread.sleep(forTimeInterval: seconds)
    }

    private func dismissKeyboard() {
        guard app.keyboards.firstMatch.exists else { return }
        if app.buttons["chat.dismissKeyboard"].exists {
            app.buttons["chat.dismissKeyboard"].tap()
        } else {
            app.typeText("\n")
        }
        if !app.keyboards.firstMatch.waitForNonExistence(timeout: 5) {
            miss("收起操作后键盘仍遮挡界面")
        }
    }

    private func bookCover(in target: XCUIApplication, title: String) -> XCUIElement {
        target.buttons
            .matching(identifier: "library.book")
            .matching(NSPredicate(format: "label CONTAINS %@", title))
            .firstMatch
    }

    private func footer(_ target: XCUIApplication) -> String {
        "\(target.staticTexts["reader.progress"].label) | \(target.staticTexts["reader.percent"].label)"
    }

    private func tapCenter(_ target: XCUIApplication) {
        target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    // MARK: - 走查

    func testUserWalkthrough() throws {
        // ---------- 1. 第一次打开 ----------
        app = makeApp(onboarding: true)
        app.launch()
        pause(0.4)
        snap("01-splash")
        if app.buttons["onboarding.start"].waitForExistence(timeout: 25) {
            snap("02-onboarding")
            app.buttons["onboarding.start"].tap()
        } else {
            miss("首启引导页没出现")
        }
        _ = app.buttons["library.import"].waitForExistence(timeout: 30)
        snap("03-library-just-entered")
        if app.buttons.matching(identifier: "library.book").firstMatch.waitForExistence(timeout: 60) {
            pause(2)
            snap("04-library")
        } else {
            miss("样例书没导进来")
        }

        // ---------- 2. 书库：长按菜单 / 搜索 / 筛选 / 排序 ----------
        let firstBook = app.buttons.matching(identifier: "library.book").firstMatch
        if firstBook.exists {
            firstBook.press(forDuration: 1.2)
            pause(1.2)
            snap("05-book-longpress-menu")
            // 点顶部状态栏只会滚回顶部、关不掉长按菜单；点菜单下方的空白处才会收起。
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.80)).tap()
            pause()
        }

        let searchField = app.textFields["搜索书名 / 作者"]
        if searchField.waitForExistence(timeout: 8) {
            searchField.tap()
            searchField.typeText("投资")
            pause(2)
            snap("06-library-search")
            if app.buttons["library.searchClear"].exists {
                app.buttons["library.searchClear"].tap()
                pause()
            }
        } else {
            miss("书库没有搜索框")
        }

        tap(app.buttons["未读"].firstMatch, 5, "「未读」筛选")
        pause(1.2)
        snap("07-library-filter-unread")
        tap(app.buttons["全部"].firstMatch, 5, "「全部」筛选")
        pause()

        // 排序菜单
        let sortCandidates = ["最近阅读", "最近添加", "书名", "作者", "阅读进度"]
        for title in sortCandidates where app.buttons[title].exists {
            app.buttons[title].tap()
            pause(1.2)
            snap("08-library-sort-menu")
            // 选择当前项关闭菜单；点状态栏不会可靠关闭系统菜单。
            let option = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title))
                .allElementsBoundByIndex.first(where: \.isHittable)
            if let option { option.tap() } else { miss("排序菜单里没有当前项") }
            break
        }
        pause()

        // ---------- 3. 读书 ----------
        let book = bookCover(in: app, title: "书灯测试样书")
        if book.waitForExistence(timeout: 30) {
            book.tap()
        } else {
            miss("书库里没有中文样书")
        }
        guard app.staticTexts["reader.progress"].waitForExistence(timeout: 60) else {
            miss("阅读器没渲染出来，后面的阅读流程全跳过")
            return
        }
        pause(1.5)
        snap("09-reader-open")

        // 点击中间：工具栏收起 / 展开
        tapCenter(app)
        pause()
        snap("10-reader-immersive")
        let before = footer(app)
        log("点右边缘前：\(before)")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
        pause(1.2)
        let afterRight = footer(app)
        log("点右边缘后：\(afterRight)")
        snap("11-probe-tap-right-edge")
        tapCenter(app)
        pause()
        app.swipeLeft()
        pause(1.2)
        snap("12-reader-after-swipe")
        log("左滑后：\(footer(app))")

        // 目录
        tap(app.buttons["reader.toc"], 8, "目录按钮")
        if app.navigationBars["目录"].waitForExistence(timeout: 12) {
            pause()
            snap("13-toc")
            tap(app.buttons["完成"], 5, "目录-完成")
        }
        pause()

        // 书内搜索
        tap(app.buttons["reader.search"], 8, "搜索按钮")
        if app.textFields["reader.searchField"].waitForExistence(timeout: 10) {
            app.textFields["reader.searchField"].tap()
            app.textFields["reader.searchField"].typeText("投资\n")
            _ = app.staticTexts["结果"].waitForExistence(timeout: 20)
            pause()
            snap("14-reader-search")
            tap(app.buttons["完成"], 5, "搜索-完成")
        } else {
            miss("书内搜索面板没打开")
        }
        pause()

        // 阅读设置
        tap(app.buttons["reader.settings"], 8, "阅读设置按钮")
        if app.navigationBars["阅读设置"].waitForExistence(timeout: 12) {
            pause()
            snap("15-reader-settings")
            app.swipeUp()
            pause()
            snap("16-reader-settings-bottom")
            tap(app.buttons["完成"], 5, "阅读设置-完成")
        } else {
            miss("阅读设置没打开")
        }
        pause()

        // 选中一段：高亮 / 翻译 / 写笔记
        let selectionBar = app.descendants(matching: .any).matching(identifier: "reader.selectionBar").firstMatch
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.42)).press(forDuration: 1.2)
        if selectionBar.waitForExistence(timeout: 10) {
            snap("17-selection-bar")
            let yellow = app.buttons["reader.highlight.yellow"]
            if yellow.exists {
                yellow.tap()
                pause(1.2)
                snap("18-highlight-saved")
            }
            if app.buttons["reader.selectionClose"].exists {
                app.buttons["reader.selectionClose"].tap()
                pause()
            }

            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)).press(forDuration: 1.2)
            if selectionBar.waitForExistence(timeout: 10) {
                tap(app.buttons["reader.selectionTranslate"], 5, "翻译")
                if app.navigationBars["翻译"].waitForExistence(timeout: 12) {
                    pause(3)
                    snap("19-translate")
                    tap(app.buttons["完成"], 5, "翻译-完成")
                }
            } else {
                miss("第二次长按没唤出选中条")
            }

            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.62)).press(forDuration: 1.2)
            if selectionBar.waitForExistence(timeout: 10) {
                tap(app.buttons["reader.selectionNote"], 5, "写笔记")
                let noteInput = app.textFields["reader.noteEditor"]
                if noteInput.waitForExistence(timeout: 8) {
                    noteInput.tap()
                    noteInput.typeText("UX 走查：这段记一下")
                    pause()
                    snap("20-note-editor")
                    app.buttons["reader.noteSave"].tap()
                    pause(1.5)
                    snap("21-after-note")
                }
            }
        } else {
            miss("长按正文没有唤出选中条")
        }

        // 阅读器里的 AI
        tap(app.buttons["reader.chat"], 8, "阅读器 AI 按钮")
        if app.textFields["chat.input"].waitForExistence(timeout: 15) {
            pause()
            snap("22-reader-ai")
            app.textFields["chat.input"].tap()
            app.textFields["chat.input"].typeText("这一页讲了什么？")
            if app.buttons["chat.send"].isEnabled { app.buttons["chat.send"].tap() }
            let bubble = app.descendants(matching: .any).matching(identifier: "chat.assistantBubble").firstMatch
            _ = bubble.waitForExistence(timeout: 60)
            pause(3)
            snap("23-reader-ai-answer")
            tap(app.buttons["reader.chat.close"], 8, "关闭阅读器 AI")
            XCTAssertTrue(app.textFields["chat.input"].waitForNonExistence(timeout: 10), "阅读器 AI 弹层未关闭")
            XCTAssertTrue(app.buttons["reader.speech"].isHittable, "朗读按钮被弹层遮挡")
        } else {
            miss("阅读器里的 AI 面板没打开")
        }

        // 朗读 + 睡眠定时器
        tap(app.buttons["reader.speech"], 8, "朗读按钮")
        pause(2)
        snap("24-speaking")
        tap(app.buttons["reader.sleepTimer"], 8, "睡眠定时器")
        if app.buttons["15 分钟后停"].waitForExistence(timeout: 8) {
            snap("25-sleep-timer-menu")
            app.buttons["15 分钟后停"].tap()
            pause(1.5)
            snap("26-sleep-armed")
        } else {
            miss("睡眠定时器菜单没出现")
        }
        if app.buttons["reader.stopSpeech"].exists {
            app.buttons["reader.stopSpeech"].tap()
        } else {
            tap(app.buttons["reader.speech"], 5, "再次点击朗读按钮停止")
        }
        pause(1.5)

        // 深色阅读
        tap(app.buttons["reader.settings"], 8, "阅读设置（深色）")
        if app.navigationBars["阅读设置"].waitForExistence(timeout: 12) {
            app.swipeUp()
            pause()
            if app.buttons["黑"].exists {
                app.buttons["黑"].tap()
                pause()
            }
            tap(app.buttons["完成"], 5, "阅读设置-完成（深色）")
            pause(1.2)
            snap("27-reader-dark")
            tap(app.buttons["reader.settings"], 8, "阅读设置（切回白）")
            if app.navigationBars["阅读设置"].waitForExistence(timeout: 12) {
                app.swipeUp()
                pause()
                if app.buttons["白"].exists { app.buttons["白"].tap() }
                tap(app.buttons["完成"], 5, "阅读设置-完成（白）")
            }
        }
        pause()
        tap(app.buttons["reader.close"], 8, "关闭阅读器")
        _ = app.buttons["library.import"].waitForExistence(timeout: 12)
        pause()
        snap("28-library-after-reading")

        // ---------- 4. AI 页 ----------
        tap(app.tabBars.buttons["AI"], 10, "AI Tab")
        pause(1.5)
        snap("29-ai-tab")
        // 加号直接进新对话（历史就是 AI 栏首屏，不再有单独的会话 sheet）。
        tap(app.buttons["chat.newThread"], 10, "新对话")
        pause(1.5)
        snap("30-new-chat")
        if app.textFields["chat.input"].waitForExistence(timeout: 12) {
            app.textFields["chat.input"].tap()
            app.textFields["chat.input"].typeText("暗号：mermaid")
            if app.buttons["chat.send"].isEnabled { app.buttons["chat.send"].tap() }
            let diagram = app.descendants(matching: .any).matching(identifier: "chat.mermaid").firstMatch
            _ = diagram.waitForExistence(timeout: 90)
            pause(2)
            snap("31-ai-mermaid")

            // 技能菜单
            tap(app.buttons["chat.skills"], 8, "技能菜单")
            pause(1.2)
            snap("32-skills-menu")
            let mindmap = app.buttons["chat.skill.mindmap"]
            if mindmap.waitForExistence(timeout: 6) {
                mindmap.tap()
                let canvas = app.descendants(matching: .any).matching(identifier: "mindmap.canvas").firstMatch
                if canvas.waitForExistence(timeout: 90) {
                    _ = app.descendants(matching: .any).matching(identifier: "mindmap.node").firstMatch
                        .waitForExistence(timeout: 60)
                    pause(2)
                    snap("33-mindmap")
                    tap(app.buttons["完成"], 6, "思维导图-完成")
                } else {
                    miss("思维导图没画出来")
                }
            } else {
                miss("技能菜单里没有思维导图")
            }
            pause()
            snap("34-ai-after-skills")
        } else {
            miss("AI 输入框没出现")
        }

        // ---------- 5. 笔记 ----------
        dismissKeyboard()
        tap(app.tabBars.buttons["笔记"], 10, "笔记 Tab")
        _ = app.buttons["notes.export"].waitForExistence(timeout: 20)
        pause(1.5)
        snap("35-notes")
        if app.buttons["notes.export"].waitForExistence(timeout: 8) {
            app.buttons["notes.export"].tap()
            pause(1.2)
            snap("36-notes-export-menu")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)).tap()
            pause()
        } else {
            miss("笔记页没有导出按钮")
        }

        // ---------- 6. 我的 / 统计 / 设置 ----------
        dismissKeyboard()
        tap(app.tabBars.buttons["我的"], 10, "我的 Tab")
        _ = app.buttons["profile.appearance"].waitForExistence(timeout: 20)
        pause()
        snap("37-profile")

        tap(app.staticTexts["阅读统计"].firstMatch, 8, "阅读统计")
        if app.navigationBars["阅读统计"].waitForExistence(timeout: 15) {
            pause(2)
            snap("38-stats")
            if app.buttons["stats.badges"].waitForExistence(timeout: 8) {
                app.buttons["stats.badges"].tap()
                if app.navigationBars["徽章"].waitForExistence(timeout: 12) {
                    pause(1.5)
                    snap("39-badges")
                    app.navigationBars["徽章"].buttons.firstMatch.tap()
                    pause()
                }
            }
            if app.buttons["stats.report"].waitForExistence(timeout: 8) {
                app.buttons["stats.report"].tap()
                if app.navigationBars["阅读报告"].waitForExistence(timeout: 15) {
                    pause(2)
                    snap("40-reading-report")
                    if app.buttons["report.ai"].waitForExistence(timeout: 6) {
                        app.buttons["report.ai"].tap()
                        pause(5)
                        snap("41-report-ai")
                    }
                    app.navigationBars["阅读报告"].buttons.firstMatch.tap()
                    pause()
                }
            }
            app.navigationBars["阅读统计"].buttons.firstMatch.tap()
            pause()
        } else {
            miss("阅读统计没打开")
        }

        for title in ["外观", "AI 设置", "语义检索", "关于书灯"] {
            let entry = title == "外观"
                ? app.buttons["profile.appearance"]
                : app.staticTexts[title].firstMatch
            tap(entry, 8, title)
            let bar = app.navigationBars[title]
            if bar.waitForExistence(timeout: 15) {
                pause(1.2)
                snap("42-settings-\(title)")
                if title == "外观", app.buttons["深色"].exists {
                    app.buttons["深色"].firstMatch.tap()
                    pause(1.5)
                    snap("43-appearance-dark")
                    app.buttons["跟随系统"].firstMatch.tap()
                    pause()
                }
                if title == "语义检索" {
                    if app.buttons["vector.probe"].exists { app.buttons["vector.probe"].tap(); pause(3) }
                    snap("44-vector-model")
                }
                bar.buttons.firstMatch.tap()
                pause()
            } else {
                miss("\(title) 没打开")
                snap("42-missing-\(title)")
            }
            if !app.buttons["profile.appearance"].waitForExistence(timeout: 8) {
                log("从 \(title) 返回后不在「我的」页")
                break
            }
        }

        // 深色外观下看一圈书库和阅读器
        tap(app.staticTexts["外观"].firstMatch, 8, "外观（深色）")
        if app.navigationBars["外观"].waitForExistence(timeout: 15) {
            if app.buttons["深色"].exists { app.buttons["深色"].firstMatch.tap() }
            pause(1.2)
            app.navigationBars["外观"].buttons.firstMatch.tap()
            pause()
            tap(app.tabBars.buttons["书架"], 8, "书架 Tab（深色）")
            pause(1.5)
            snap("45-library-dark")
            tap(app.tabBars.buttons["我的"], 8, "我的 Tab（恢复外观）")
            tap(app.staticTexts["外观"].firstMatch, 8, "外观（恢复）")
            if app.navigationBars["外观"].waitForExistence(timeout: 15) {
                if app.buttons["跟随系统"].exists { app.buttons["跟随系统"].firstMatch.tap() }
                pause()
                app.navigationBars["外观"].buttons.firstMatch.tap()
                pause()
            }
        }

        // ---------- 7. PDF ----------
        dismissKeyboard()
        tap(app.tabBars.buttons["书架"], 8, "书架 Tab（PDF）")
        pause(1.5)
        let pdf = app.buttons
            .matching(identifier: "library.book")
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "pdf"))
            .firstMatch
        if pdf.waitForExistence(timeout: 15) {
            pdf.tap()
            if app.staticTexts["reader.progress"].waitForExistence(timeout: 60) {
                pause(2)
                snap("46-pdf-open")
                app.swipeLeft()
                pause(1.5)
                snap("47-pdf-after-swipe")
                log("PDF 翻页后：\(footer(app))")
                tap(app.buttons["reader.close"], 8, "关闭 PDF")
                pause()
            } else {
                miss("PDF 没渲染出来")
                snap("46-pdf-stuck")
            }
        } else {
            miss("书库里没有 PDF 书")
        }

        // ---------- 8. 语义索引（长按建索引，看进度与搜索结果） ----------
        pause()
        let epub = bookCover(in: app, title: "书灯测试样书")
        if epub.waitForExistence(timeout: 15) {
            epub.press(forDuration: 1.2)
            pause(1.2)
            snap("48-index-context-menu")
            if app.buttons["建立语义索引"].exists {
                app.buttons["建立语义索引"].tap()
                pause(2)
                snap("49-indexing")
                Thread.sleep(forTimeInterval: 20)
                snap("50-index-progress")
            } else if app.buttons["重建语义索引"].exists {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.80)).tap()
                pause()
            }
        }
        pause()
        let field = app.textFields["搜索书名 / 作者"]
        if field.waitForExistence(timeout: 8) {
            field.tap()
            field.typeText("怎么调朗读的语速")
            pause(2.5)
            snap("51-semantic-search")
            if app.buttons["library.searchClear"].exists { app.buttons["library.searchClear"].tap() }
        }

        snap("99-final")
        log("走查结束；未能完成的步骤：\(missed.isEmpty ? "无" : missed.joined(separator: " / "))")
    }
}
