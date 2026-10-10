// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import UIKit

/// 书灯真机 UI 冒烟测试：书库加载 → 开书 → 左滑翻页 → 加/删书签 → 关闭回书库。
final class ShudengUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = makeApp()
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - 工具

    private var isSimulator: Bool {
        ProcessInfo.processInfo.environment["SIMULATOR_UDID"] != nil
    }

    /// 模拟器上不碰真机的书库与 API Key：用包内样例书 + 本地 mock 端点（见 scripts/mock-llm-server.mjs）。
    private func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        // 引导页只在首次启动出现；UI 测试直接跳过（专门的 test16 会自己打开）。
        app.launchArguments += ["-shudeng.onboarded", "YES"]
        guard isSimulator else { return app }
        app.launchEnvironment["SHUDENG_SEED_SAMPLE_BOOK"] = "1"
        app.launchEnvironment["SHUDENG_AI_BASE_URL"] = "http://127.0.0.1:8799/v1"
        app.launchEnvironment["SHUDENG_AI_MODEL"] = "mock-model"
        app.launchEnvironment["SHUDENG_AI_API_KEY"] = "mock-key"
        return app
    }

    private func snap(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// 给「另一份 XCUIApplication 实例」截图（首次启动引导用的是新实例）。
    private func snap(_ name: String, of target: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: target.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// 正文区里「带颜色」的像素行号：阅读界面本身是黑白的，正文里出现彩色只可能来自高亮。
    /// 取样范围只留正文栏（左右各切掉边距与工具栏图标，上下避开状态栏与页码栏）。
    private func highlightRows() -> Set<Int> {
        guard let image = app.screenshot().image.cgImage,
              let data = image.dataProvider?.data as Data?
        else { return [] }

        let bytesPerRow = image.bytesPerRow
        let bytesPerPixel = max(1, image.bitsPerPixel / 8)
        let left = Int(Double(image.width) * 0.12)
        let right = Int(Double(image.width) * 0.72)
        let top = Int(Double(image.height) * 0.08)
        let bottom = Int(Double(image.height) * 0.88)

        var rows: Set<Int> = []
        var y = top
        while y < bottom {
            var x = left
            while x < right {
                let offset = y * bytesPerRow + x * bytesPerPixel
                guard offset + 2 < data.count else { break }
                let red = Int(data[offset]), green = Int(data[offset + 1]), blue = Int(data[offset + 2])
                if max(red, max(green, blue)) - min(red, min(green, blue)) > 24 {
                    rows.insert(y)
                    break
                }
                x += 4
            }
            y += 4
        }
        return rows
    }

    private func openFirstBook() throws {
        let first = app.buttons.matching(identifier: "library.book").firstMatch
        guard first.waitForExistence(timeout: 30) else {
            snap("library-empty")
            throw XCTSkip("书库里没有书，先导入一本 EPUB 再跑这条用例")
        }
        first.tap()
    }

    /// 按书名开书：书库里可能同时躺着别的样书（默认排序是「最近阅读」，第一本不一定是中文样书）。
    private func openBook(titled title: String) throws {
        let cell = bookCover(in: app, title: title)
        guard cell.waitForExistence(timeout: 30) else {
            snap("library-empty")
            throw XCTSkip("书库里没有《\(title)》，先导入再跑这条用例")
        }
        cell.tap()
    }

    /// 按书名找书封（书名是部分匹配）。
    private func bookCover(in target: XCUIApplication, title: String) -> XCUIElement {
        target.buttons
            .matching(identifier: "library.book")
            .matching(NSPredicate(format: "label CONTAINS %@", title))
            .firstMatch
    }

    /// 栏目级标题按需求去掉了，导航栏里查不到「书库 / 笔记 / 我的」，
    /// 换成页面里独有的元素当锚点（书库的导入按钮、笔记的导出、我的的外观入口）。
    @discardableResult
    private func waitForLibrary(_ target: XCUIApplication? = nil, timeout: TimeInterval = 30) -> Bool {
        (target ?? app).buttons["library.import"].waitForExistence(timeout: timeout)
    }

    @discardableResult
    private func waitForNotes(timeout: TimeInterval = 20) -> Bool {
        app.buttons["notes.export"].waitForExistence(timeout: timeout)
    }

    @discardableResult
    private func waitForProfile(_ target: XCUIApplication? = nil, timeout: TimeInterval = 15) -> Bool {
        (target ?? app).buttons["profile.appearance"].waitForExistence(timeout: timeout)
    }

    private func waitForProgressChange(from old: String, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let progress = app.staticTexts["reader.progress"].label
            let percent = app.staticTexts["reader.percent"].label
            let current = "\(progress)|\(percent)"
            if current != "|", current != old { return true }
            usleep(200_000)
        }
        return false
    }

    private func footerProgress() -> String {
        "\(app.staticTexts["reader.progress"].label)|\(app.staticTexts["reader.percent"].label)"
    }

    /// 从页脚读出（本章第几页，本章共几页），格式随底栏文案变化也不影响判断。
    private func footerPages(_ target: XCUIApplication? = nil) -> (current: Int, total: Int)? {
        let label = (target ?? app).staticTexts["reader.progress"].label
        let parts = label.split(whereSeparator: { !$0.isNumber }).map(String.init)
        guard parts.count == 2, let current = Int(parts[0]), let total = Int(parts[1]) else { return nil }
        return (current, total)
    }

    /// 页脚左边是「本章第几页 / 本章共几页」，分页模式写作「本章 2 / 5」，
    /// 章节还没分好页时退化成「第 3 / 7 节」。两种都要能读出两个数字。
    private func assertFooterPagesAreSane(_ context: String) {
        let label = app.staticTexts["reader.progress"].label
        let parts = label
            .split(whereSeparator: { !$0.isNumber })
            .map(String.init)
        guard parts.count == 2, let current = Int(parts[0]), let total = Int(parts[1]) else {
            return XCTFail("页脚不是「本章页码 / 本章总页数」：\(label)（\(context)）")
        }
        XCTAssertGreaterThanOrEqual(current, 1, "页码小于 1：\(label)（\(context)）")
        XCTAssertGreaterThanOrEqual(total, 1, "总页数小于 1：\(label)（\(context)）")
        XCTAssertLessThanOrEqual(current, total, "页码超过总页数：\(label)（\(context)）")
    }

    private func goToFirstChapter() throws {
        app.buttons["reader.toc"].tap()
        let first = app.buttons.matching(identifier: "reader.tocRow").firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        first.tap()
        XCTAssertTrue(app.navigationBars["目录"].waitForNonExistence(timeout: 10))
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if footerPages()?.current == 1 { return }
            usleep(200_000)
        }
        XCTFail("目录跳转后没有回到第一章起点")
    }

    // MARK: - 用例

    func test01LibraryLoads() throws {
        XCTAssertTrue(waitForLibrary(timeout: 30), "书库没有加载出来")
        let importButton = app.buttons["library.import"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 30), "导入按钮没出现")
        XCTAssertTrue(importButton.isEnabled, "运行时还没准备好，导入按钮被禁用")
        snap("01-library")

        // 搜索框的键盘靠点空白处收起（不额外加「收起键盘」按钮）。
        let search = app.textFields["搜索书名 / 作者"]
        XCTAssertTrue(search.waitForExistence(timeout: 10), "搜索框没出现")
        search.tap()
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 5), "点了搜索框键盘没起来")
        // 搜索框和筛选行之间那条空白，点上以后键盘要自己收回去。
        let blank = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: search.frame.midX, dy: search.frame.maxY + 22))
        blank.tap()
        XCTAssertTrue(app.keyboards.element.waitForNonExistence(timeout: 5), "点空白处没收起键盘")
    }

    func test02ReaderTurnPageAndToggleBookmark() throws {
        try openBook(titled: "书灯测试样书")
        let progress = app.staticTexts["reader.progress"]
        XCTAssertTrue(progress.waitForExistence(timeout: 40), "阅读器没有渲染出进度")
        try goToFirstChapter()
        let before = footerProgress()
        let pageBefore = try XCTUnwrap(footerPages(), "分页尚未就绪")
        snap("02-reader-before-turn")

        // 用坐标拖拽翻页：比 swipeLeft 可控，一次拖拽对应一次明确的翻页。
        let pageStart = app.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.5))
        let pageEnd = app.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.5))
        pageStart.press(forDuration: 0.05, thenDragTo: pageEnd, withVelocity: .slow, thenHoldForDuration: 0)
        XCTAssertTrue(waitForProgressChange(from: before), "左滑之后底部进度没变（页码/百分比应随翻页变）")
        assertFooterPagesAreSane("左滑翻页后")
        // 一次翻页只该前进一页：页码要跟着手势走，不能被一次手势带飞好几页。
        let pageAfter = footerPages()
        XCTAssertEqual(
            pageAfter?.current,
            pageBefore.current + 1,
            "左滑一页该只前进一页，实际从 \(pageBefore.current) 变成 \(pageAfter?.current ?? -1)"
        )
        snap("02-reader-after-turn")

        let bookmark = app.buttons["reader.bookmark"]
        XCTAssertTrue(bookmark.waitForExistence(timeout: 10), "书签按钮没出现")
        let originalState = try XCTUnwrap(bookmark.value as? String)
        XCTAssertTrue(["已加书签", "未加书签"].contains(originalState))
        let toggledState = originalState == "已加书签" ? "未加书签" : "已加书签"
        bookmark.tap()
        XCTAssertTrue(waitForValue("reader.bookmark", toggledState, timeout: 8), "点击没有切换书签状态")
        snap("02-reader-bookmark-toggled")
        bookmark.tap()
        XCTAssertTrue(waitForValue("reader.bookmark", originalState, timeout: 8), "再次点击没有恢复原书签状态")

        app.buttons["reader.close"].tap()
        XCTAssertTrue(waitForLibrary(timeout: 10), "关闭阅读器没有回到书库")
    }

    func test03ChatInputIsUsable() throws {
        app.tabBars.buttons["AI"].tap()
        // AI 栏首屏是会话列表，右上角的加号开一段新对话。
        let compose = app.buttons["chat.newThread"]
        XCTAssertTrue(compose.waitForExistence(timeout: 15), "AI 会话列表没加载")
        compose.tap()
        let input = app.textFields["chat.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 15), "AI 输入框没出现")
        input.tap()
        input.typeText("hello")
        XCTAssertEqual(input.value as? String, "hello")
        let send = app.buttons["chat.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5), "发送按钮没出现")
        XCTAssertTrue(send.isEnabled, "有内容时发送键应该可用")
        snap("03-chat-input")

        // 键盘靠点正文收起，不再往键盘上塞单独的「收起键盘」按钮。
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 5), "点了输入框键盘没起来")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()
        XCTAssertTrue(app.keyboards.element.waitForNonExistence(timeout: 5), "点正文没收起键盘")
    }

    func test04ReaderTOCSearchAndSettings() throws {
        try openBook(titled: "书灯测试样书")
        XCTAssertTrue(app.staticTexts["reader.progress"].waitForExistence(timeout: 40), "阅读器没有渲染出进度")

        // 目录
        app.buttons["reader.toc"].tap()
        XCTAssertTrue(app.navigationBars["目录"].waitForExistence(timeout: 15), "目录面板没打开")
        XCTAssertTrue(
            app.buttons.matching(identifier: "reader.tocRow").firstMatch.waitForExistence(timeout: 15),
            "目录是空的"
        )
        snap("04-toc")
        app.buttons["完成"].tap()

        // 书内搜索：输入关键词回车，等 core 回结果
        app.buttons["reader.search"].tap()
        let field = app.textFields["reader.searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "搜索面板没打开")
        field.tap()
        field.typeText("投资\n")
        XCTAssertTrue(app.staticTexts["结果"].waitForExistence(timeout: 20), "书内搜索没有返回结果")
        snap("04-search")
        app.buttons["完成"].tap()

        // 阅读设置：切连续滚动再切回分页
        app.buttons["reader.settings"].tap()
        XCTAssertTrue(app.navigationBars["阅读设置"].waitForExistence(timeout: 10), "阅读设置没打开")
        app.buttons["连续滚动"].tap()
        XCTAssertTrue(app.buttons["连续滚动"].isSelected, "切连续滚动没生效")
        app.buttons["分页"].tap()
        XCTAssertTrue(app.buttons["分页"].isSelected, "切回分页没生效")
        app.buttons["完成"].tap()

        XCTAssertTrue(app.staticTexts["reader.progress"].waitForExistence(timeout: 10), "设置页关掉后阅读器没恢复")
    }

    func test05NotesAndStatsTabs() throws {
        app.tabBars.buttons["笔记"].tap()
        XCTAssertTrue(waitForNotes(timeout: 20), "笔记页没加载")
        snap("05-notes")

        app.tabBars.buttons["我的"].tap()
        XCTAssertTrue(waitForProfile(timeout: 10), "我的页没加载")
        app.staticTexts["阅读统计"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["阅读统计"].waitForExistence(timeout: 15), "统计页没打开")
        XCTAssertTrue(app.staticTexts["今天"].waitForExistence(timeout: 30), "统计没加载出来")
        XCTAssertTrue(app.staticTexts["连续"].exists, "统计卡片缺连续阅读")
        snap("05-stats")
    }

    func test06TTSAndReaderAISheet() throws {
        try openFirstBook()
        let speech = app.buttons["reader.speech"]
        XCTAssertTrue(speech.waitForExistence(timeout: 40), "朗读按钮没出现")
        XCTAssertTrue(waitForEnabled("reader.speech", timeout: 40), "当前页一直没取到正文，朗读按钮不可用")
        speech.tap()
        XCTAssertTrue(waitForValue("reader.speech", "speaking", timeout: 20), "点朗读后没有进入朗读状态")
        snap("06-speaking")
        app.buttons["reader.speech"].tap()
        XCTAssertTrue(waitForValue("reader.speech", "idle", timeout: 15), "再点没有停止朗读")

        app.buttons["reader.chat"].tap()
        XCTAssertTrue(app.textFields["chat.input"].waitForExistence(timeout: 15), "阅读器里的 AI 面板没打开")
        snap("06-reader-chat")
        app.swipeDown()
        XCTAssertTrue(app.staticTexts["reader.progress"].waitForExistence(timeout: 10), "AI 面板没关掉")
    }

    func testMindMapInitiallyFitsAndNodesDoNotClip() throws {
        try openBook(titled: "书灯测试样书")
        XCTAssertTrue(waitForEnabled("reader.speech", timeout: 30))
        app.buttons["reader.chat"].tap()
        app.buttons["chat.skills"].tap()
        app.buttons["chat.skill.mindmap"].tap()
        let nodes = app.buttons.matching(identifier: "mindmap.node")
        XCTAssertTrue(nodes.firstMatch.waitForExistence(timeout: 30))
        let canvas = app.descendants(matching: .any).matching(identifier: "mindmap.canvas").firstMatch
        let bounds = canvas.frame.insetBy(dx: -1, dy: -1)
        let count = nodes.count
        XCTAssertGreaterThan(count, 3)
        for node in nodes.allElementsBoundByIndex {
            XCTAssertTrue(bounds.contains(node.frame), "导图节点被屏幕裁切：\(node.label)")
            let title = node.staticTexts.matching(NSPredicate(format: "label == %@", node.label)).firstMatch
            if title.exists {
                XCTAssertTrue(node.frame.insetBy(dx: -1, dy: -1).contains(title.frame), "节点文字超出背景：\(node.label)")
            }
        }
        let shortTitle = app.staticTexts["相对论"]
        XCTAssertLessThanOrEqual(shortTitle.frame.height, 18, "短标题被图标挤成竖排")
        let root = nodes.matching(NSPredicate(format: "label == %@", "时间简史")).firstMatch
        root.tap()
        XCTAssertEqual(nodes.count, 1)
        // 单节点时系统会把画布手势区域合到按钮，点击可见标题验证实际命中。
        app.staticTexts["时间简史"].tap()
        XCTAssertEqual(nodes.count, count)
        snap("mindmap-fitted")
        let originalWidth = shortTitle.frame.width
        canvas.pinch(withScale: 1.5, velocity: 1)
        XCTAssertGreaterThan(shortTitle.frame.width, originalWidth * 1.2)
        let originalX = shortTitle.frame.midX
        canvas.swipeRight()
        XCTAssertGreaterThan(shortTitle.frame.midX, originalX + 20)
        snap("mindmap-zoomed-panned")
    }

    func testContinuousScrollResumesSameChapterAndPosition() throws {
        try openBook(titled: "书灯测试样书")
        XCTAssertTrue(waitForEnabled("reader.speech", timeout: 30))
        app.buttons["reader.settings"].tap()
        app.sliders.firstMatch.adjust(toNormalizedSliderPosition: 0.2)
        app.swipeUp()
        app.buttons["连续滚动"].tap()
        app.buttons["完成"].tap()
        app.buttons["reader.toc"].tap()
        app.buttons.matching(identifier: "reader.tocRow").firstMatch.tap()
        sleep(2)
        for _ in 0..<4 {
            app.swipeUp()
            sleep(2)
            if app.buttons["reader.toc"].label.contains("第二章") { break }
        }
        let chapter = app.buttons["reader.toc"].label
        XCTAssertTrue(chapter.contains("第二章"), chapter)
        let progress = app.staticTexts["reader.percent"].label
        let reference = app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "文件系统提供读写")).firstMatch
        XCTAssertTrue(reference.exists)
        let originalY = reference.frame.minY
        snap("scroll-before-close")
        app.buttons["reader.close"].tap()
        XCTAssertTrue(waitForLibrary())
        app.terminate()
        app.launch()
        try openBook(titled: "书灯测试样书")
        XCTAssertTrue(waitForEnabled("reader.speech", timeout: 30))
        sleep(3)
        snap("scroll-after-reopen")
        XCTAssertTrue(reference.exists)
        let restoredY = reference.frame.minY
        print("Scroll resume paragraph Y: \(originalY) -> \(restoredY)")
        XCTAssertEqual(restoredY, originalY, accuracy: 25, "续读时正文偏移超过一行")
        XCTAssertEqual(app.buttons["reader.toc"].label, chapter, "连续滚动续读跳回了上一章")
        func percent(_ text: String) -> Int { Int(text.filter(\.isNumber)) ?? -100 }
        XCTAssertLessThanOrEqual(abs(percent(app.staticTexts["reader.percent"].label) - percent(progress)), 1)
        app.buttons["reader.settings"].tap()
        app.swipeUp()
        app.buttons["分页"].tap()
        app.buttons["完成"].tap()
    }

    func testReaderControlsDoNotCoverTextOrMoveIt() throws {
        try openBook(titled: "书灯测试样书")
        XCTAssertTrue(waitForEnabled("reader.speech", timeout: 30))
        try goToFirstChapter()
        let reader = app.webViews.firstMatch
        let originalFrame = reader.frame
        let progress = footerProgress()
        snap("controls-visible-content-bounds")
        XCTAssertGreaterThanOrEqual(originalFrame.minY, app.buttons["reader.close"].frame.maxY, "顶部工具栏盖住正文")
        XCTAssertLessThanOrEqual(originalFrame.maxY, app.staticTexts["reader.percent"].frame.minY, "底部进度栏盖住正文")
        tapBodyToSetToolbar(hidden: true)
        XCTAssertTrue(waitForHittable("reader.progress", false, timeout: 6))
        XCTAssertEqual(reader.frame, originalFrame, "隐藏工具栏改变了正文版式")
        tapBodyToSetToolbar(hidden: false)
        XCTAssertTrue(waitForHittable("reader.progress", true, timeout: 6))
        XCTAssertEqual(reader.frame, originalFrame)
        XCTAssertEqual(footerProgress(), progress)
        snap("controls-restored-content-bounds")
    }

    func testReaderKeyboardPreservesPageAndContext() throws {
        try openBook(titled: "书灯测试样书")
        XCTAssertTrue(app.buttons["reader.toc"].waitForExistence(timeout: 30))
        app.buttons["reader.toc"].tap()
        let chapter = app.buttons.matching(identifier: "reader.tocRow")
            .matching(NSPredicate(format: "label == %@", "第三章 投资与阅读")).firstMatch
        XCTAssertTrue(chapter.waitForExistence(timeout: 10))
        chapter.tap()
        XCTAssertTrue(app.navigationBars["目录"].waitForNonExistence(timeout: 10))
        XCTAssertTrue(waitForEnabled("reader.speech", timeout: 15))
        let reader = app.webViews.firstMatch
        let readerFrame = reader.frame
        let progress = footerProgress()
        app.buttons["reader.chat"].tap()
        let preview = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "当前位置：")).firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        let context = preview.label
        XCTAssertTrue(context.contains("当前页正文"))
        let input = app.textFields["chat.input"]
        for _ in 0..<2 {
            input.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
            input.typeText("键盘检查")
            XCTAssertEqual(reader.frame.height, readerFrame.height, accuracy: 1, "聊天键盘改变了正文布局")
            XCTAssertEqual(preview.label, context, "键盘改变了 AI 阅读上下文")
            XCTAssertTrue(app.buttons["chat.send"].isHittable)
            XCTAssertLessThanOrEqual(input.frame.maxY, app.keyboards.firstMatch.frame.minY + 1)
            app.buttons["chat.dismissKeyboard"].tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
            XCTAssertEqual(preview.label, context)
        }
        app.buttons["reader.chat.close"].tap()
        XCTAssertTrue(input.waitForNonExistence(timeout: 10))
        XCTAssertEqual(footerProgress(), progress)
    }

    func testReaderChatReplyCanBeClosed() throws {
        try openBook(titled: "书灯测试样书")
        XCTAssertTrue(app.staticTexts["reader.progress"].waitForExistence(timeout: 30))
        app.buttons["reader.chat"].tap()
        let input = app.textFields["chat.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap()
        input.typeText("这一页讲了什么？")
        app.buttons["chat.send"].tap()
        let reply = app.descendants(matching: .any).matching(identifier: "chat.assistantBubble").firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 30))
        let streaming = app.descendants(matching: .any).matching(identifier: "chat.streaming").firstMatch
        XCTAssertTrue(streaming.waitForNonExistence(timeout: 30))
        let close = app.buttons["reader.chat.close"]
        XCTAssertTrue(close.isHittable)
        close.tap()
        XCTAssertTrue(input.waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.buttons["reader.speech"].isHittable)
    }

    func test07ChatStreamsAnswerAndSavesThread() throws {
        app.tabBars.buttons["AI"].tap()
        // AI 栏首屏就是会话列表；新开一段对话，避免打断已有历史。
        let compose = app.buttons["chat.newThread"]
        XCTAssertTrue(compose.waitForExistence(timeout: 15), "AI 会话列表没加载")
        snap("07-thread-list")
        compose.tap()

        let input = app.textFields["chat.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10), "输入框没出现")
        input.tap()
        // 末尾带上思考暗号：mock 会先流一段 think 标签，正文再给答案。
        // 每轮换一个标记：上一次跑剩下的同名会话会让「滑删之后没了」的断言假过。
        let token = "t" + String(UUID().uuidString.prefix(5))
        let title = "只回复两个字：收到\(token)"
        input.typeText("\(title)（simulate thinking）")
        let send = app.buttons["chat.send"]
        XCTAssertTrue(send.isEnabled, "有内容时发送键应该可用")
        send.tap()

        let bubble = app.descendants(matching: .any).matching(identifier: "chat.assistantBubble").firstMatch
        XCTAssertTrue(bubble.waitForExistence(timeout: 60), "助手气泡没出现")

        // 等到生成结束：要么气泡有内容且「正在生成」消失，要么「正在生成」出现过又消失（空回答也要报出来）。
        var sawStreaming = false
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            let label = bubble.label
            let streaming = app.descendants(matching: .any).matching(identifier: "chat.streaming").firstMatch.exists
            if streaming { sawStreaming = true }
            if !label.isEmpty, label != "…", !streaming { break }
            if sawStreaming, !streaming { break }
            usleep(500_000)
        }
        let answer = bubble.label
        snap("07-chat-answer")
        XCTAssertFalse(answer.isEmpty || answer == "…", "模型没有返回内容：\(answer)")
        if isSimulator {
            XCTAssertTrue(answer.contains("收到"), "模拟端点应返回固定文案，实际是：\(answer)")
        }

        // 思考过程：默认折叠成一行「已思考 N 秒」，点开才看推理原文。
        let thinking = app.buttons["chat.thinking"]
        XCTAssertTrue(thinking.waitForExistence(timeout: 15), "回答里没有思考过程折叠条")
        snap("07-thinking-collapsed")
        thinking.tap()
        XCTAssertTrue(
            app.staticTexts["chat.thinkingText"].waitForExistence(timeout: 10),
            "点开折叠条没显示思考过程正文"
        )
        snap("07-thinking-expanded")

        // 回 AI 会话列表：刚存下来的这段对话应该在里面，滑删之后要真的消失
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["chat.newThread"].waitForExistence(timeout: 10), "没回到 AI 会话列表")
        // 临时对话组排在书籍组下面，历史较多时新会话会离屏；先搜索唯一标记。
        app.buttons["chat.search"].tap()
        let threadSearch = app.searchFields.firstMatch
        XCTAssertTrue(threadSearch.waitForExistence(timeout: 10))
        threadSearch.tap()
        threadSearch.typeText(token)
        // 按内容认这一行：光数行数会被「列表还没刷新出来」骗过去。
        var row = app.buttons
            .matching(identifier: "chat.threadRow")
            .matching(NSPredicate(format: "label CONTAINS %@", title))
            .firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "刚存下来的会话没进列表")
        row.swipeLeft()
        app.buttons["重命名"].firstMatch.tap()
        let rename = app.textFields["chat.renameEditor"]
        XCTAssertTrue(rename.waitForExistence(timeout: 10), "重命名编辑面板没出现")
        rename.tap()
        rename.press(forDuration: 1.2)
        let selectAll = [app.menuItems["全选"], app.menuItems["Select All"],
                         app.buttons["全选"], app.buttons["Select All"]]
            .first { $0.waitForExistence(timeout: 1) }
        XCTAssertNotNil(selectAll, "重命名字段没有全选菜单")
        selectAll?.tap()
        let renamedTitle = "已改名\(token)"
        rename.typeText(renamedTitle)
        XCTAssertEqual(rename.value as? String, renamedTitle, "全选后应替换整个标题")
        app.buttons["chat.renameSave"].tap()
        XCTAssertTrue(rename.waitForNonExistence(timeout: 10), "保存后编辑面板未关闭")
        row = app.buttons.matching(identifier: "chat.threadRow")
            .matching(NSPredicate(format: "label CONTAINS %@", renamedTitle)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "列表标题未更新")
        app.terminate()
        app.launch()
        XCTAssertTrue(waitForLibrary(timeout: 30))
        app.tabBars.buttons["AI"].tap()
        XCTAssertTrue(app.buttons["chat.search"].waitForExistence(timeout: 15))
        app.buttons["chat.search"].tap()
        XCTAssertTrue(threadSearch.waitForExistence(timeout: 10))
        threadSearch.tap()
        threadSearch.typeText(token)
        XCTAssertTrue(waitForLabel(row, contains: "已改名", timeout: 10), "重启后标题丢失")
        row.tap()
        XCTAssertTrue(bubble.waitForExistence(timeout: 15), "打开历史后没有原回答")
        XCTAssertEqual(bubble.label, answer, "打开历史加载了错误内容")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.swipeLeft()
        let deleteButton = app.buttons["删除"].firstMatch
        let englishDelete = app.buttons["Delete"].firstMatch
        let target = deleteButton.waitForExistence(timeout: 5) ? deleteButton : englishDelete
        XCTAssertTrue(target.waitForExistence(timeout: 5), "左滑没有出现删除按钮")
        target.tap()

        snap("07-thread-deleted")
        XCTAssertTrue(row.waitForNonExistence(timeout: 15), "滑删之后会话还留在列表里")
    }

    private func waitForValue(_ identifier: String, _ expected: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = app.buttons[identifier].value as? String, value == expected { return true }
            usleep(200_000)
        }
        return false
    }

    private func waitForEnabled(_ identifier: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let button = app.buttons[identifier]
            if button.exists, button.isEnabled { return true }
            usleep(200_000)
        }
        return false
    }

    /// 等某个元素的文案里出现关键词（流式回答要等生成完才判断）。
    private func waitForLabel(_ element: XCUIElement, contains keyword: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists, element.label.contains(keyword) { return true }
            usleep(300_000)
        }
        return false
    }

    /// 走一遍我自己会用的动作：点正文收工具条 → 长按选中 → 高亮 → 改字号 → 连续滚动 → 重启看进度还在不在。
    func test08WalkthroughToolbarSelectionSettingsAndRelaunch() throws {
        try openBook(titled: "书灯测试样书")
        XCTAssertTrue(app.staticTexts["reader.progress"].waitForExistence(timeout: 40), "阅读器没有渲染出进度")
        let readyDeadline = Date().addingTimeInterval(60)
        while Date() < readyDeadline && (app.staticTexts["reader.progress"].label == "—" || !app.buttons["reader.speech"].isEnabled) { usleep(300_000) }
        XCTAssertNotEqual(app.staticTexts["reader.progress"].label, "—", "正文尚未就绪")
        XCTAssertTrue(app.buttons["reader.speech"].isEnabled, "正文尚未绑定朗读")
        let progressBefore = footerProgress()

        // 点正文：工具条收起，正文不许跟着跳
        snap("08-before-toolbar-hide")
        print("READER-CHECK: progress=\(app.staticTexts["reader.progress"].label) speechEnabled=\(app.buttons["reader.speech"].isEnabled)")
        tapBodyToSetToolbar(hidden: true)
        snap("08-after-toolbar-hide")
        XCTAssertTrue(waitForHittable("reader.progress", false, timeout: 6), "点正文后上下工具条没有收起")
        snap("08-toolbar-hidden")
        XCTAssertEqual(footerProgress(), progressBefore, "收起工具条时正文位置变了")

        tapBodyToSetToolbar(hidden: false)
        XCTAssertTrue(waitForHittable("reader.progress", true, timeout: 6), "再点正文工具条没有回来")
        snap("08-toolbar-shown")

        // 长按选中 → 选中工具栏 → 高亮
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.42)).press(forDuration: 1.2)
        let selectionBar = app.descendants(matching: .any).matching(identifier: "reader.selectionBar").firstMatch
        XCTAssertTrue(selectionBar.waitForExistence(timeout: 10), "长按正文没有唤出选中工具栏")
        snap("08-selection-bar")
        let blue = app.buttons["reader.highlight.blue"]
        XCTAssertTrue(blue.waitForExistence(timeout: 6), "选中工具栏里没有高亮按钮")
        // 选中文档刚弹出来时会飘一下，等它可点再按，免得点空。
        let blueDeadline = Date().addingTimeInterval(6)
        while !blue.isHittable, Date() < blueDeadline { usleep(200_000) }
        blue.tap()
        let savedToast = app.staticTexts["已高亮"]
        let failedToast = app.staticTexts["高亮没保存上，再试一次"]
        let toastDeadline = Date().addingTimeInterval(15)
        while Date() < toastDeadline, !savedToast.exists, !failedToast.exists { usleep(200_000) }
        XCTAssertTrue(
            savedToast.exists,
            failedToast.exists ? "高亮没有保存：core 落库失败" : "高亮没有保存：没有出现保存提示"
        )
        snap("08-highlighted")

        // 设置：字号拉到最大附近 + 切连续滚动再切回
        app.buttons["reader.settings"].tap()
        XCTAssertTrue(app.navigationBars["阅读设置"].waitForExistence(timeout: 10), "阅读设置没打开")
        let fontSlider = app.sliders.firstMatch
        XCTAssertTrue(fontSlider.waitForExistence(timeout: 6), "字号滑杆没出现")
        fontSlider.adjust(toNormalizedSliderPosition: 0.9)
        snap("08-settings-fontsize")
        app.buttons["连续滚动"].tap()
        XCTAssertTrue(app.buttons["连续滚动"].isSelected, "切连续滚动没生效")
        app.buttons["完成"].tap()
        XCTAssertTrue(app.staticTexts["reader.progress"].waitForExistence(timeout: 10), "设置关掉后阅读器没恢复")
        app.swipeUp()
        snap("08-scroll-mode")
        app.buttons["reader.settings"].tap()
        app.buttons["分页"].tap()
        XCTAssertTrue(app.buttons["分页"].isSelected, "切回分页没生效")
        fontSlider.adjust(toNormalizedSliderPosition: 0.25)
        app.buttons["完成"].tap()
        XCTAssertTrue(app.staticTexts["reader.progress"].waitForExistence(timeout: 10), "切回分页后阅读器没恢复")
        snap("08-back-to-paged")

        // 退出重进：书和进度要还在
        let progressBeforeClose = footerProgress()
        app.buttons["reader.close"].tap()
        XCTAssertTrue(waitForLibrary(timeout: 10), "关闭阅读器没有回到书库")

        app.tabBars.buttons["笔记"].tap()
        XCTAssertTrue(waitForNotes(timeout: 20), "笔记页没加载")
        XCTAssertTrue(app.staticTexts["书灯测试样书"].firstMatch.waitForExistence(timeout: 20), "刚存的高亮没进笔记页")
        snap("08-notes-after-highlight")

        app.terminate()
        app.launch()
        try openFirstBook()
        XCTAssertTrue(app.staticTexts["reader.progress"].waitForExistence(timeout: 40), "重启后阅读器没起来")
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, footerProgress() != progressBeforeClose {
            usleep(300_000)
        }
        XCTAssertEqual(footerProgress(), progressBeforeClose, "重启后没有回到上次读到的位置")
        snap("08-relaunch-restored")
    }

    private func waitForHittable(_ identifier: String, _ hittable: Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.staticTexts[identifier].firstMatch.isHittable == hittable { return true }
            usleep(150_000)
        }
        return false
    }

    /// 点正文切换工具条：开书那一下的余波偶尔会吃掉或多算一次点击，
    /// 所以最多点两下，只要最终状态对就算过（单跑必过，整轮偶尔会抖）。
    private func tapBodyToSetToolbar(hidden: Bool, timeout: TimeInterval = 4) {
        let center = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
        for _ in 0..<2 {
            center.tap()
            if waitForHittable("reader.progress", !hidden, timeout: timeout) { return }
        }
    }

    private func waitForLabelChange(_ identifier: String, from old: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let label = app.staticTexts[identifier].label
            if !label.isEmpty, label != old { return true }
            usleep(300_000)
        }
        return false
    }

    /// 朗读迷你条 + 睡眠定时器 + 深色阅读背景。
    func test09SpeechSleepTimerAndDarkReader() throws {
        try openFirstBook()
        let speech = app.buttons["reader.speech"]
        XCTAssertTrue(speech.waitForExistence(timeout: 40), "朗读按钮没出现")
        XCTAssertTrue(waitForEnabled("reader.speech", timeout: 40), "正文没取到，朗读按钮不可用")
        speech.tap()
        XCTAssertTrue(waitForValue("reader.speech", "speaking", timeout: 20), "点朗读后没有进入朗读状态")

        let status = app.staticTexts["reader.speechStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 8), "朗读时没有出现朗读迷你条")
        snap("09-speaking-bar")

        app.buttons["reader.sleepTimer"].tap()
        let option = app.buttons["15 分钟后停"]
        XCTAssertTrue(option.waitForExistence(timeout: 8), "睡眠定时器菜单没打开")
        snap("09-sleep-menu")
        option.tap()
        XCTAssertTrue(status.label.contains("还有"), "选了 15 分钟迷你条没有显示倒计时：\(status.label)")
        snap("09-sleep-armed")

        let armed = status.label
        XCTAssertTrue(waitForLabelChange("reader.speechStatus", from: armed, timeout: 10), "睡眠倒计时没有在走")

        app.buttons["reader.stopSpeech"].tap()
        XCTAssertTrue(waitForValue("reader.speech", "idle", timeout: 10), "点停止后没有停朗读")
        XCTAssertFalse(app.staticTexts["reader.speechStatus"].exists, "停了以后朗读迷你条还在")
        snap("09-speech-stopped")

        // 深色阅读背景
        app.buttons["reader.settings"].tap()
        XCTAssertTrue(app.navigationBars["阅读设置"].waitForExistence(timeout: 10), "阅读设置没打开")
        app.swipeUp()
        snap("09-settings-theme")
        app.buttons["黑"].tap()
        app.buttons["完成"].tap()
        XCTAssertTrue(app.staticTexts["reader.progress"].waitForExistence(timeout: 10), "设置关掉后阅读器没恢复")
        snap("09-dark-reader")

        app.buttons["reader.settings"].tap()
        app.swipeUp()
        app.buttons["白"].tap()
        app.buttons["完成"].tap()
        app.buttons["reader.close"].tap()
        XCTAssertTrue(waitForLibrary(timeout: 10), "关闭阅读器没有回到书库")
    }

    /// 通过真实搜索定位笔记，兼容 List 中尚未挂载的屏幕外条目。
    private func searchNotes(containing text: String) {
        let mode = app.segmentedControls.buttons["笔记"]
        XCTAssertTrue(mode.waitForExistence(timeout: 10), "笔记页没有笔记模式")
        mode.tap()
        let search = app.searchFields["搜索高亮、笔记或书名"]
        XCTAssertTrue(search.waitForExistence(timeout: 10), "笔记页搜索框没出现")
        search.tap()
        search.typeText(text + "\n")
    }

    /// 选中 → 翻译、选中 → 写笔记、笔记页跳回原文。
    func test10SelectionTranslateNoteAndJumpBack() throws {
        try openBook(titled: "书灯测试样书")
        XCTAssertTrue(app.staticTexts["reader.progress"].waitForExistence(timeout: 40), "阅读器没有渲染出进度")

        let selectionPoint = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.42))
        let selectionBar = app.descendants(matching: .any).matching(identifier: "reader.selectionBar").firstMatch

        selectionPoint.press(forDuration: 1.2)
        XCTAssertTrue(selectionBar.waitForExistence(timeout: 10), "长按正文没有唤出选中工具栏")
        app.buttons["reader.selectionTranslate"].tap()
        XCTAssertTrue(app.navigationBars["翻译"].waitForExistence(timeout: 15), "翻译面板没打开")
        XCTAssertTrue(
            app.staticTexts["收到，这是模拟回复。"].waitForExistence(timeout: 40),
            "翻译没有拿到译文（mock 端点应回「收到，这是模拟回复。」）"
        )
        snap("10-translation")
        app.buttons["完成"].tap()
        XCTAssertTrue(
            app.navigationBars["翻译"].waitForNonExistence(timeout: 10),
            "翻译面板没关掉"
        )

        // 先收掉上一次的选中工具栏，再重新选一段来写笔记
        app.buttons["reader.selectionClose"].tap()
        XCTAssertTrue(selectionBar.waitForNonExistence(timeout: 8), "选中工具栏没有收掉")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)).press(forDuration: 1.2)
        XCTAssertTrue(selectionBar.waitForExistence(timeout: 10), "第二次长按没唤出选中工具栏")
        app.buttons["reader.selectionNote"].tap()
        let noteInput = app.textFields["reader.noteEditor"]
        XCTAssertTrue(noteInput.waitForExistence(timeout: 8), "写笔记面板没出现")
        noteInput.tap()
        if let existing = noteInput.value as? String, !existing.isEmpty, existing != "想法…" {
            noteInput.press(forDuration: 1.1)
            let selectAll = [app.menuItems["全选"], app.menuItems["Select All"],
                             app.buttons["全选"], app.buttons["Select All"]]
                .first(where: { $0.exists })
            XCTAssertNotNil(selectAll, "已有笔记输入框没有全选菜单")
            selectAll?.tap()
        }
        let note = "这段要回头看-" + String(UUID().uuidString.prefix(8))
        noteInput.typeText(note)
        snap("10-note-editor")
        app.buttons["reader.noteSave"].tap()
        // 不查「笔记已保存」这个浮层：它只显示 1.4 秒，XCTest 点完弹窗后要等动画静默，
        // 等它开始查的时候浮层已经消失了（截图里有）。这里查持久化结果。
        XCTAssertTrue(noteInput.waitForNonExistence(timeout: 8), "保存后笔记面板没有关掉")
        snap("10-after-save")

        app.buttons["reader.close"].tap()
        XCTAssertTrue(waitForLibrary(timeout: 10), "关闭阅读器没有回到书库")
        app.tabBars.buttons["笔记"].tap()
        XCTAssertTrue(waitForNotes(timeout: 20), "笔记页没加载")
        searchNotes(containing: note)
        let noteRow = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", note)).firstMatch
        XCTAssertTrue(noteRow.waitForExistence(timeout: 20), "刚写的笔记没进笔记页")
        snap("10-notes-with-note")

        noteRow.swipeRight()
        app.buttons["编辑"].firstMatch.tap()
        let editor = app.textFields["notes.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "编辑笔记面板没打开")
        editor.tap()
        editor.typeText("（复核）")
        let editedNote = try XCTUnwrap(editor.value as? String)
        XCTAssertTrue(editedNote.contains("复核"))
        app.buttons["notes.save"].tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 10), "保存成功后编辑器应关闭")
        XCTAssertTrue(app.staticTexts[editedNote].firstMatch.waitForExistence(timeout: 10), "修改后的笔记未显示")
        app.terminate()
        app.launch()
        app.tabBars.buttons["笔记"].tap()
        XCTAssertTrue(waitForNotes(timeout: 20), "重启后笔记页没加载")
        searchNotes(containing: note)
        XCTAssertTrue(app.staticTexts[editedNote].firstMatch.waitForExistence(timeout: 20), "重启后修改的笔记没有保存")
        let savedRow = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", editedNote)).firstMatch
        XCTAssertTrue(savedRow.waitForExistence(timeout: 10))
        // 短文字右侧留白也属于这一条笔记，不能只有文字可点。
        savedRow.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertTrue(app.staticTexts["reader.progress"].waitForExistence(timeout: 10), "点笔记留白没有跳回阅读器")
        snap("10-jump-back")
    }

    /// 我的 → 每个设置入口都要能打开、能返回。
    func test11ProfileSettingsScreens() throws {
        app.tabBars.buttons["我的"].tap()
        XCTAssertTrue(waitForProfile(timeout: 20), "我的页没加载")
        snap("11-profile")

        // 字号 / 行距 / 朗读语速都搬进了阅读器里的「阅读设置」，这里只剩全 App 的几项。
        // 按 id 认行：分组标题也叫「外观」，用文字找会点到标题上。
        let entries = [
            ("外观", "profile.appearance"),
            ("AI 设置", "profile.ai"),
            ("关于书灯", "profile.about"),
        ]
        for (title, id) in entries {
            let row = app.buttons[id].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 10), "我的页没有「\(title)」")
            row.tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 15), "「\(title)」没打开")
            snap("11-\(title)")
            let back = app.navigationBars[title].buttons.firstMatch
            XCTAssertTrue(back.waitForExistence(timeout: 5), "「\(title)」没有返回按钮")
            back.tap()
            XCTAssertTrue(waitForProfile(timeout: 10), "从「\(title)」没回到我的")
        }

        // 深色外观也要能看：切过去截图，再切回跟随系统
        app.buttons["profile.appearance"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["外观"].waitForExistence(timeout: 15), "外观页没打开")
        app.buttons["深色"].firstMatch.tap()
        snap("11-dark-appearance")
        app.buttons["跟随系统"].firstMatch.tap()
        app.navigationBars["外观"].buttons.firstMatch.tap()
        XCTAssertTrue(waitForProfile(timeout: 10), "外观页没返回")

        // 最后一行的「关于书灯」不能被浮动标签栏压住点不到
        app.swipeUp()
        snap("11-profile-bottom")
        XCTAssertTrue(app.staticTexts["关于书灯"].firstMatch.isHittable, "「关于书灯」被标签栏挡住")
    }

    /// 书库：搜索、筛选、排序都要能用，且不能把书弄丢。
    func test12LibrarySearchFilterAndSort() throws {
        XCTAssertTrue(waitForLibrary(timeout: 30), "书库没加载")
        let book = app.buttons.matching(identifier: "library.book").firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 30), "书库里没有书")

        // 搜索：先搜一个不存在的名字（应该一本都不剩），清空后书要回来
        let search = app.textFields["搜索书名 / 作者"]
        XCTAssertTrue(search.waitForExistence(timeout: 10), "搜索框没出现")
        search.tap()
        search.typeText("zzz不存在的书名")
        XCTAssertFalse(
            app.buttons.matching(identifier: "library.book").firstMatch.waitForExistence(timeout: 3),
            "搜了不存在的书名，书还在"
        )
        snap("12-search-empty")
        let clear = app.buttons["library.searchClear"]
        XCTAssertTrue(clear.waitForExistence(timeout: 5), "搜索框没有清空按钮")
        clear.tap()
        app.swipeUp()
        XCTAssertTrue(book.waitForExistence(timeout: 10), "清空搜索后书没回来")

        // 排序菜单：换成「书名」，样书还在
        app.buttons["最近阅读"].firstMatch.tap()
        let sortItem = app.buttons["书名"].firstMatch
        XCTAssertTrue(sortItem.waitForExistence(timeout: 10), "排序菜单没打开")
        sortItem.tap()
        XCTAssertTrue(book.waitForExistence(timeout: 10), "换排序后书没了")
        snap("12-sorted-by-title")

        // 先把样书读一页，让它进「在读」，筛选才有稳定预期
        // （底栏的进度滑杆已经撤掉了，翻页就是唯一会写进度的动作）。
        // 拿中文样书来验：英文样书可能已经被别的用例读到 100%，那样它本来就该出现在「读完」里。
        let openedTitle = "书灯测试样书"
        try openBook(titled: openedTitle)
        XCTAssertTrue(app.staticTexts["reader.progress"].waitForExistence(timeout: 40), "阅读器没有渲染出进度")
        // 进度跨用例保存，样书可能已读完；先用真实目录导航恢复到第一章。
        try goToFirstChapter()
        app.swipeLeft()
        app.buttons["reader.close"].tap()
        XCTAssertTrue(waitForLibrary(timeout: 10), "关闭阅读器没有回到书库")
        // 只盯刚读过的那本：书库里还有别的书（未读的、早已读完的），不能拿「一本都没有」当预期。
        let opened = app.buttons
            .matching(identifier: "library.book")
            .matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", openedTitle, "已读"))
            .firstMatch
        XCTAssertTrue(opened.waitForExistence(timeout: 15), "读过之后书库没把这本书标成在读")

        // 筛选：读过的那本只能出现在「在读 / 全部」里
        let openedRow = app.buttons
            .matching(identifier: "library.book")
            .matching(NSPredicate(format: "label BEGINSWITH %@", openedTitle))
            .firstMatch
        app.buttons["未读"].firstMatch.tap()
        XCTAssertFalse(openedRow.waitForExistence(timeout: 3), "「未读」筛选把在读的书列出来了")
        snap("12-filter-unread")
        app.buttons["读完"].firstMatch.tap()
        XCTAssertFalse(openedRow.waitForExistence(timeout: 3), "「读完」筛选把只读了一半的书列出来了")
        app.buttons["在读"].firstMatch.tap()
        XCTAssertTrue(opened.waitForExistence(timeout: 10), "「在读」筛选把刚读过的书漏掉了")
        snap("12-filter-reading")
        app.buttons["全部"].firstMatch.tap()
        XCTAssertTrue(book.waitForExistence(timeout: 10), "切回「全部」书没了")
    }

    /// 笔记导出：文件要真的写出来，分享面板要能打开。
    func test13NotesExport() throws {
        // 独占跑这条用例时也要有内容可导：先造一条高亮
        try openFirstBook()
        XCTAssertTrue(app.staticTexts["reader.progress"].waitForExistence(timeout: 40), "阅读器没有渲染出进度")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).press(forDuration: 1.2)
        let selectionBar = app.descendants(matching: .any).matching(identifier: "reader.selectionBar").firstMatch
        XCTAssertTrue(selectionBar.waitForExistence(timeout: 10), "长按正文没有唤出选中工具栏")
        app.buttons["reader.highlight.blue"].tap()
        XCTAssertTrue(app.staticTexts["已高亮"].waitForExistence(timeout: 12), "高亮没有保存")
        app.buttons["reader.close"].tap()
        XCTAssertTrue(waitForLibrary(timeout: 10), "关闭阅读器没有回到书库")

        app.tabBars.buttons["笔记"].tap()
        XCTAssertTrue(waitForNotes(timeout: 20), "笔记页没加载")
        let exportMenu = app.buttons["notes.export"]
        XCTAssertTrue(exportMenu.waitForExistence(timeout: 10), "笔记页没有导出入口")
        XCTAssertTrue(exportMenu.isEnabled, "有高亮了导出还不可用")
        exportMenu.tap()
        let markdown = app.buttons["导出 Markdown"]
        XCTAssertTrue(markdown.waitForExistence(timeout: 10), "导出菜单没打开")
        markdown.tap()
        XCTAssertTrue(app.navigationBars["导出"].waitForExistence(timeout: 20), "导出面板没出现")
        let fileName = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH '.md'")).firstMatch
        XCTAssertTrue(fileName.waitForExistence(timeout: 10), "导出面板没显示文件名")
        snap("13-export")
        app.buttons["完成"].tap()
        XCTAssertTrue(app.navigationBars["导出"].waitForNonExistence(timeout: 10), "导出面板没关掉")
    }

    /// 统计页的徽章页 + 阅读报告 + AI 解读。
    func test14StatsBadgesAndAIReport() throws {
        // 先读几秒，保证这次跑起来有阅读事实，报告里才有数字。
        try openFirstBook()
        XCTAssertTrue(app.staticTexts["reader.progress"].waitForExistence(timeout: 40), "阅读器没有渲染出进度")
        app.swipeLeft()
        Thread.sleep(forTimeInterval: 3)
        app.buttons["reader.close"].tap()
        XCTAssertTrue(waitForLibrary(timeout: 10), "关闭阅读器没有回到书库")

        app.tabBars.buttons["我的"].tap()
        XCTAssertTrue(waitForProfile(timeout: 10), "我的页没加载")
        app.staticTexts["阅读统计"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["阅读统计"].waitForExistence(timeout: 15), "统计页没打开")
        XCTAssertTrue(app.staticTexts["今天"].waitForExistence(timeout: 30), "统计没加载出来")

        // 徽章：卡片 → 徽章页 → 39 个定义里至少能看到具体某一枚
        app.swipeUp()
        snap("14-stats-bottom")
        let badgeCard = app.buttons["stats.badges"].firstMatch
        XCTAssertTrue(badgeCard.waitForExistence(timeout: 15), "统计页没有徽章卡")
        badgeCard.tap()
        XCTAssertTrue(app.navigationBars["徽章"].waitForExistence(timeout: 15), "徽章页没打开")
        XCTAssertTrue(app.staticTexts["起步"].waitForExistence(timeout: 15), "徽章页没列出徽章定义")
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '阅读天数'")).firstMatch.exists,
            "徽章页没有分类标题"
        )
        snap("14-badges")
        app.navigationBars["徽章"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["阅读统计"].waitForExistence(timeout: 10), "徽章页返回失败")

        // 阅读报告：周 → 全部 → AI 解读
        let reportCard = app.buttons["stats.report"].firstMatch
        XCTAssertTrue(reportCard.waitForExistence(timeout: 15), "统计页没有阅读报告入口")
        reportCard.tap()
        XCTAssertTrue(app.navigationBars["阅读报告"].waitForExistence(timeout: 15), "阅读报告没打开")
        XCTAssertTrue(app.staticTexts["本期数字"].waitForExistence(timeout: 30), "报告没有本期数字")
        snap("14-report-week")

        app.buttons["全部"].tap()
        XCTAssertTrue(app.staticTexts["本期数字"].waitForExistence(timeout: 30), "切到全部后报告没出来")

        let aiButton = app.buttons["report.ai"]
        XCTAssertTrue(aiButton.waitForExistence(timeout: 15), "报告页没有 AI 解读按钮")
        aiButton.tap()
        XCTAssertTrue(
            app.staticTexts["收到，这是模拟回复。"].waitForExistence(timeout: 60),
            "AI 解读没有出结果（mock 端点应回「收到，这是模拟回复。」）"
        )
        snap("14-report-ai")
        app.navigationBars["阅读报告"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["阅读统计"].waitForExistence(timeout: 10), "报告页返回失败")
    }

    /// 朗读跟读高亮：读到哪句、高亮跟到哪句（两张截图之间高亮应该往前走）。
    func test15SpeechFollowHighlight() throws {
        try openFirstBook()
        let speech = app.buttons["reader.speech"]
        XCTAssertTrue(speech.waitForExistence(timeout: 40), "朗读按钮没出现")
        XCTAssertTrue(waitForEnabled("reader.speech", timeout: 40), "正文没取到，朗读按钮不可用")
        speech.tap()
        XCTAssertTrue(waitForValue("reader.speech", "speaking", timeout: 20), "点朗读后没有进入朗读状态")

        // 分段要等 reader.html 的 TTS 引擎对齐；之后按行采样，要求高亮真的换过位置。
        var samples: [Set<Int>] = []
        for _ in 0..<6 {
            Thread.sleep(forTimeInterval: 3)
            let rows = highlightRows()
            if !rows.isEmpty, samples.last != rows { samples.append(rows) }
        }
        XCTAssertGreaterThanOrEqual(
            samples.count, 2,
            "正文里没有出现跟读高亮，或者高亮一直没有跟着朗读往前走"
        )

        app.buttons["reader.stopSpeech"].tap()
        XCTAssertTrue(waitForValue("reader.speech", "idle", timeout: 10), "点停止后没有停朗读")
        Thread.sleep(forTimeInterval: 1)
        XCTAssertNotEqual(highlightRows(), samples.last, "停止朗读后高亮没有收掉")
    }

    /// 首次启动：启动动画收掉之后弹一页引导，点「开始使用」进书库，第二次启动不再弹。
    func test16OnboardingOnFirstLaunch() throws {
        let fresh = XCUIApplication()
        fresh.launchArguments += ["-shudeng.onboarded", "NO"]
        applySimulatorEnvironment(to: fresh)
        fresh.launch()
        // 启动动画只有 0.9 秒，可能已经淡出，截到就留档。
        snap("16-splash", of: fresh)

        XCTAssertTrue(fresh.buttons["onboarding.start"].waitForExistence(timeout: 30), "首次启动没有出现引导页")
        snap("16-onboarding", of: fresh)
        // 引导页要真的盖在书库上：先点一下底部「我的」Tab 的位置，别透传过去切了 Tab。
        fresh.coordinate(withNormalizedOffset: CGVector(dx: 0.875, dy: 0.965)).tap()
        XCTAssertTrue(fresh.buttons["onboarding.start"].exists, "点了一下引导页就没了")
        fresh.buttons["onboarding.start"].tap()
        XCTAssertTrue(
            waitForLibrary(fresh, timeout: 30),
            "点开始使用后没落在书库（多半是引导页没挡住下面的 Tab）"
        )
        XCTAssertFalse(fresh.buttons["onboarding.start"].exists, "点了开始使用引导页还在")
        snap("16-library", of: fresh)

        // 再启动一次（不带强制参数，读真正落盘的那份）：不该再弹引导。
        fresh.terminate()
        let relaunch = XCUIApplication()
        applySimulatorEnvironment(to: relaunch)
        relaunch.launch()
        XCTAssertTrue(waitForLibrary(relaunch, timeout: 30), "第二次启动书库没出来")
        XCTAssertFalse(
            relaunch.buttons["onboarding.start"].waitForExistence(timeout: 6),
            "第二次启动又弹引导页了"
        )
        snap("16-relaunch", of: relaunch)
    }

    /// AI 技能 / 思维导图 / Mermaid 图表：三样都要真的走通，不能只是把代码块原样贴出来。
    func test17SkillsMindMapAndMermaid() throws {
        try openFirstBook()
        XCTAssertTrue(app.staticTexts["reader.progress"].waitForExistence(timeout: 40), "阅读器没渲染出来")
        // 整章正文是阅读器里异步抽的（思维导图要用），等它抽完再离开。
        Thread.sleep(forTimeInterval: 2.5)
        app.buttons["reader.close"].tap()
        XCTAssertTrue(waitForLibrary(timeout: 10), "没回到书库")

        app.tabBars.buttons["AI"].tap()
        XCTAssertTrue(app.buttons["chat.newThread"].waitForExistence(timeout: 15), "AI 历史列表没加载")
        // 加号直接进新对话，避免和已有历史混在一起。
        app.buttons["chat.newThread"].tap()
        XCTAssertTrue(app.textFields["chat.input"].waitForExistence(timeout: 10), "新对话没打开")
        Thread.sleep(forTimeInterval: 0.6)

        let skills = app.buttons["chat.skills"]
        XCTAssertTrue(skills.waitForExistence(timeout: 20), "技能菜单没出现")
        let skillsDeadline = Date().addingTimeInterval(20)
        while !skills.isEnabled, Date() < skillsDeadline { usleep(200_000) }
        XCTAssertTrue(skills.isEnabled, "技能列表没从 core 里读出来")

        // 1. 技能：点「智能摘要」直接按当前阅读位置开问；mock 回显技能名，说明技能 prompt 真的注入了。
        let summary = chooseSkill("chat.skill.summarizer", "智能摘要")
        snap("17-skill-menu")
        summary.tap()

        let bubble = app.descendants(matching: .any).matching(identifier: "chat.assistantBubble").firstMatch
        XCTAssertTrue(bubble.waitForExistence(timeout: 60), "技能没有产出回答")
        XCTAssertTrue(waitForLabel(bubble, contains: "技能答复", timeout: 90), "技能没被注入进请求：\(bubble.label)")
        snap("17-skill-answer")

        // 2. Mermaid：mock 见到暗号就回一个 ```mermaid 块，界面要画成图表。
        let input = app.textFields["chat.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10), "输入框不见了")
        input.tap()
        input.typeText("暗号：mermaid")
        app.buttons["chat.send"].tap()

        let diagram = app.descendants(matching: .any).matching(identifier: "chat.mermaid").firstMatch
        XCTAssertTrue(diagram.waitForExistence(timeout: 90), "Mermaid 没有渲染成图表")
        snap("17-mermaid")

        // 3. 思维导图：一句话生成一张本地渲染的导图。
        let mindMapEntry = chooseSkill("chat.skill.mindmap", "思维导图")
        mindMapEntry.tap()

        let canvas = app.descendants(matching: .any).matching(identifier: "mindmap.canvas").firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 120), "思维导图没画出来")
        // 画布先出来、问模型拿大纲还要几秒，等第一个节点，别抢跑。
        let nodes = app.descendants(matching: .any).matching(identifier: "mindmap.node")
        XCTAssertTrue(nodes.firstMatch.waitForExistence(timeout: 90), "导图一个节点都没有")
        XCTAssertGreaterThanOrEqual(nodes.count, 3, "导图节点太少，多半没解析出大纲")
        snap("17-mindmap")

        app.buttons["mindmap.copy"].tap()
        app.buttons["完成"].tap()
        XCTAssertTrue(input.waitForExistence(timeout: 10), "导图关掉后没回到对话")
    }

    /// AI 栏重做后的主流程：加号直接进新对话，输入框上方的 chip 把这段对话挂到一本书上，
    /// 发完消息回到历史列表，这段对话要归在那本书的分组里。
    func test18NewChatBindsBookFromChip() throws {
        // 不需要开阅读器：书库里的样书本来就在，选书面板直接能读到。
        XCTAssertTrue(app.tabBars.buttons["AI"].waitForExistence(timeout: 40), "主界面没加载")

        app.tabBars.buttons["AI"].tap()
        let compose = app.buttons["chat.newThread"]
        XCTAssertTrue(compose.waitForExistence(timeout: 15), "AI 历史列表没加载")
        compose.tap()

        let chip = app.buttons["chat.bookChip"]
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "新对话没有上下文 chip")
        XCTAssertTrue(chip.label.contains("临时对话"), "新对话默认该是临时对话，实际：\(chip.label)")
        snap("18-new-chat-temp")

        chip.tap()
        let bookRow = app.buttons.matching(identifier: "chat.bookPicker.book").firstMatch
        XCTAssertTrue(bookRow.waitForExistence(timeout: 10), "选书面板里一本书都没有")
        let pickedTitle = bookRow.label
        XCTAssertFalse(pickedTitle.isEmpty, "选书面板里的书名读不出来")
        bookRow.tap()
        let chipDeadline = Date().addingTimeInterval(10)
        while chip.label.contains("临时对话"), Date() < chipDeadline { usleep(200_000) }
        XCTAssertFalse(chip.label.contains("临时对话"), "选完书 chip 还写着临时对话")
        snap("18-new-chat-bound")

        let token = "b" + String(UUID().uuidString.prefix(5))
        let input = app.textFields["chat.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10), "输入框没出现")
        input.tap()
        input.typeText("挂书测试\(token)")
        XCTAssertTrue(app.buttons["chat.send"].isEnabled, "有内容时发送键应该可用")
        app.buttons["chat.send"].tap()
        let bubble = app.descendants(matching: .any).matching(identifier: "chat.assistantBubble").firstMatch
        XCTAssertTrue(bubble.waitForExistence(timeout: 60), "助手气泡没出现")

        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["chat.newThread"].waitForExistence(timeout: 10), "没回到 AI 历史列表")
        let row = app.buttons.matching(identifier: "chat.threadRow")
            .matching(NSPredicate(format: "label CONTAINS %@", token))
            .firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "挂了书的对话没进历史列表")
        XCTAssertTrue(
            app.staticTexts[pickedTitle].waitForExistence(timeout: 10),
            "历史列表里没有这本书的分组头：\(pickedTitle)"
        )
        snap("18-thread-grouped")

        // 分组排序：菜单里能切正序 / 倒序。
        app.buttons["chat.sort"].tap()
        let descending = app.buttons["名称 Z → A"]
        XCTAssertTrue(descending.waitForExistence(timeout: 6), "排序菜单没出来")
        descending.tap()
    }

    func testShortHighlightEntireRowOpensReader() throws {
        try openBook(titled: "书灯测试样书")
        XCTAssertTrue(app.buttons["reader.toc"].waitForExistence(timeout: 30))
        app.buttons["reader.toc"].tap()
        app.buttons.matching(identifier: "reader.tocRow")
            .matching(NSPredicate(format: "label == %@", "第二章 宿主桥接")).firstMatch.tap()
        XCTAssertTrue(app.navigationBars["目录"].waitForNonExistence(timeout: 10))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.42)).press(forDuration: 1.2)
        let selection = app.descendants(matching: .any).matching(identifier: "reader.selectionBar").firstMatch
        XCTAssertTrue(selection.waitForExistence(timeout: 10))
        let text = selection.staticTexts.firstMatch.label
        XCTAssertFalse(text.isEmpty)
        XCTAssertLessThan(text.count, 12, "本回归需要短高亮，确保右侧存在留白")
        app.buttons["reader.highlight.blue"].tap()
        XCTAssertTrue(selection.waitForNonExistence(timeout: 10))
        app.buttons["reader.close"].tap()
        app.tabBars.buttons["笔记"].tap()
        XCTAssertTrue(waitForNotes(timeout: 20))
        app.segmentedControls.buttons["高亮"].tap()
        let search = app.searchFields["搜索高亮、笔记或书名"]
        search.tap()
        search.typeText(text + "\n")
        let row = app.buttons.matching(NSPredicate(format: "label ENDSWITH %@", ", " + text)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        snap("short-highlight-before-blank-tap")
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.65)).tap()
        XCTAssertTrue(app.buttons["reader.close"].waitForExistence(timeout: 6), "点短高亮右侧留白无响应")
        snap("short-highlight-after-blank-tap")
    }

    func testBookDeletionRequiresConfirmation() throws {
        guard isSimulator else { throw XCTSkip("只删除模拟器内置英文样书") }
        app.terminate()
        app = makeApp()
        app.launchEnvironment["SHUDENG_SEED_SAMPLE_BOOK_EN"] = "1"
        app.launch()
        let book = bookCover(in: app, title: "Shudeng Test Book")
        XCTAssertTrue(book.waitForExistence(timeout: 30))
        book.press(forDuration: 1.2)
        app.buttons["从书库删除"].tap()
        let confirmation = app.alerts["删除《Shudeng Test Book》？"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5), "删除书籍及关联数据前必须确认")
        XCTAssertTrue(confirmation.staticTexts["将同时删除这本书的高亮、笔记、书签、聊天和阅读记录，无法撤销。"].exists)
        confirmation.buttons["取消"].tap()
        app.terminate()
        app = makeApp() // 不重新补种英文样书，验证取消后原书仍在。
        app.launch()
        let retained = bookCover(in: app, title: "Shudeng Test Book")
        XCTAssertTrue(retained.waitForExistence(timeout: 30), "取消删除后书籍丢失")
        retained.press(forDuration: 1.2)
        app.buttons["从书库删除"].tap()
        let finalConfirmation = app.alerts["删除《Shudeng Test Book》？"]
        XCTAssertTrue(finalConfirmation.waitForExistence(timeout: 5))
        snap("book-delete-confirmation")
        finalConfirmation.buttons["删除"].tap()
        XCTAssertTrue(retained.waitForNonExistence(timeout: 15), "确认后书籍未删除")
        app.terminate()
        app.launch()
        XCTAssertTrue(waitForLibrary())
        XCTAssertFalse(bookCover(in: app, title: "Shudeng Test Book").exists, "删除未持久化")
    }

    /// 在 A 的阅读器停留过，再给 B 运行技能：发送的必须是 B，不得串入 A 的正文。
    func test24SkillUsesConversationBook() throws {
        guard isSimulator else { throw XCTSkip("仅使用模拟器和本地 mock 端点") }
        app.terminate()
        app = makeApp()
        app.launchEnvironment["SHUDENG_SEED_SAMPLE_BOOK_EN"] = "1"
        app.launch()
        try openBook(titled: "书灯测试样书")
        XCTAssertTrue(app.staticTexts["reader.progress"].waitForExistence(timeout: 40))
        app.buttons["reader.close"].tap()
        XCTAssertTrue(waitForLibrary())
        app.tabBars.buttons["AI"].tap()
        XCTAssertTrue(app.buttons["chat.newThread"].waitForExistence(timeout: 15))
        app.buttons["chat.newThread"].tap()
        let chip = app.buttons["chat.bookChip"]
        XCTAssertTrue(chip.waitForExistence(timeout: 10))
        chip.tap()
        let book = app.buttons.matching(identifier: "chat.bookPicker.book")
            .matching(NSPredicate(format: "label == %@", "Shudeng Test Book")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 10))
        book.tap()
        XCTAssertTrue(waitForLabel(chip, contains: "Shudeng Test Book", timeout: 10))
        chooseSkill("chat.skill.summarizer", "智能摘要").tap()
        let reply = app.descendants(matching: .any).matching(identifier: "chat.assistantBubble").firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 60))
        XCTAssertTrue(waitForLabel(reply, contains: "当前书籍：Shudeng Test Book", timeout: 60), reply.label)
        XCTAssertFalse(reply.label.contains("当前书籍：书灯测试样书"), reply.label)
    }

    /// 打开「技能」菜单并把某一项点出来。
    /// 菜单项的无障碍标识是技能 id（SwiftUI 默认会拿 SF Symbol 名当标识，App 里已显式覆盖）；
    /// 菜单弹层本身会盖住工具栏，菜单开着的时候再点按钮会点到菜单第一项，所以只在没开时才点。
    private func chooseSkill(_ identifier: String, _ title: String) -> XCUIElement {
        let item = app.buttons.matching(
            NSPredicate(format: "identifier == %@ OR label == %@", identifier, title)
        ).firstMatch
        let anySkillItem = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "chat.skill.")
        ).firstMatch
        for _ in 0..<3 {
            if item.waitForExistence(timeout: 3) { return item }
            if !anySkillItem.exists { app.buttons["chat.skills"].tap() }
        }
        XCTAssertTrue(item.waitForExistence(timeout: 3), "技能菜单里没有「\(title)」")
        return item
    }

    /// 端侧向量模型有没有：设置页必须给出「可用 / 不可用 + 具体缺什么」。
    func test19VectorModelAvailability() throws {
        try assertVectorModelAvailable()
    }

    /// 返回设置页显示的状态文案（「可用」/「可用（只支持英文内容）」）。
    @discardableResult
    private func assertVectorModelAvailable() throws -> String {
        XCTAssertTrue(waitForLibrary(timeout: 30), "书库没加载")

        // 「我的 → 语义检索」：端侧向量模型得是「可用」，否则这台机器跑不了语义索引。
        app.tabBars.buttons["我的"].tap()
        let entry = app.buttons["语义检索"].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 15), "「我的」里没有语义检索入口")
        entry.tap()
        XCTAssertTrue(app.navigationBars["语义检索"].waitForExistence(timeout: 15), "语义检索设置页没打开")
        let status = app.staticTexts["vector.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 20), "端侧向量模型状态没显示出来")
        // 状态文案要先读下来：离开这一页之后这个元素就查不到了。
        let statusLabel = status.label
        if statusLabel.contains("不可用") {
            let detail = app.staticTexts["vector.diagnostics"].label
            throw XCTSkip("这台设备没有可用的端侧向量模型：\(detail)")
        }
        XCTAssertTrue(statusLabel.contains("可用"), "端侧向量模型状态不对：\(statusLabel)")
        snap("18-vector-settings")

        app.tabBars.buttons["书架"].tap()
        return statusLabel
    }

    /// 语义检索：建索引 → 按意思找段落 → 点结果跳回原文 → 提问时自动带上原文。
    /// 模拟器上只有英文词向量，这条会跳过（英文链路见 test20）；真机上用真实书库里的书跑中文链路。
    func test18SemanticIndexFlow() throws {
        let status = try assertVectorModelAvailable()
        try XCTSkipIf(
            status.contains("只支持英文"),
            "这台设备只有英文端侧词向量，中文样书建不了索引（英文链路见 test20）"
        )
        if isSimulator {
            try semanticIndexSampleBookFlow()
        } else {
            try realDeviceSemanticIndexFlow()
        }
    }

    /// 模拟器：预置中文样书，「语速和音色」那段正好在第五章，回跳位置可以直接断言。
    private func semanticIndexSampleBookFlow() throws {
        let book = app.buttons.matching(identifier: "library.book").firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 30), "书库里没有书")

        // 建索引：长按书封。先删旧索引，保证每次跑都是真的从零建一遍。
        book.press(forDuration: 1.2)
        let build = app.buttons["建立语义索引"]
        let remove = app.buttons["删除语义索引"]
        if build.waitForExistence(timeout: 8) {
            snap("18-index-menu")
            build.tap()
        } else if remove.waitForExistence(timeout: 8) {
            remove.tap()
            book.press(forDuration: 1.2)
            XCTAssertTrue(build.waitForExistence(timeout: 8), "删掉索引后没有重建入口")
            build.tap()
        } else {
            XCTFail("长按书封没有出现语义索引菜单")
        }

        // 按意思找段落：「语速和音色」那段在第五章，正好验证回跳是不是真的跳过去了。
        let search = app.textFields["搜索书名 / 作者"]
        XCTAssertTrue(search.waitForExistence(timeout: 10), "搜索框没出现")
        search.tap()
        search.typeText("怎么调朗读的语速和音色")
        let hit = app.buttons.matching(identifier: "library.semanticHit").firstMatch
        XCTAssertTrue(hit.waitForExistence(timeout: 180), "等不到语义检索结果（建索引失败会没有结果）")
        snap("18-semantic-hits")

        // 点结果：开书并跳到那一段所在的第五章。
        hit.tap()
        XCTAssertTrue(app.staticTexts["reader.progress"].waitForExistence(timeout: 60), "点检索结果没有打开阅读器")
        let chapter = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '第五章'")).firstMatch
        XCTAssertTrue(chapter.waitForExistence(timeout: 30), "没有跳到命中的那一章")
        let percent = app.staticTexts["reader.percent"]
        XCTAssertTrue(percent.waitForExistence(timeout: 10), "阅读器没有显示进度")
        let value = Int(percent.label.split(whereSeparator: { !$0.isNumber }).first.map(String.init) ?? "") ?? 0
        XCTAssertGreaterThan(value, 40, "回跳后进度应该靠后（第五章），实际 \(percent.label)")
        snap("18-jump-to-passage")
        app.buttons["reader.close"].tap()
        XCTAssertTrue(waitForLibrary(timeout: 10), "关闭阅读器没有回到书库")

        // 对话里也要带上检索到的原文：模拟端点回固定文案，界面要显示引用提示。
        dismissKeyboard(in: app)
        app.tabBars.buttons["AI"].tap()
        XCTAssertTrue(app.buttons["chat.newThread"].waitForExistence(timeout: 15), "AI 会话列表没加载")
        app.buttons["chat.newThread"].tap()
        let input = app.textFields["chat.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 15), "输入框没出现")
        input.tap()
        input.typeText("书里怎么说朗读语速的")
        app.buttons["chat.send"].tap()
        XCTAssertTrue(
            app.staticTexts["chat.contextNote"].waitForExistence(timeout: 90),
            "提问时没有引用书里的原文"
        )
        snap("18-chat-context")
        let bubble = app.descendants(matching: .any).matching(identifier: "chat.assistantBubble").firstMatch
        XCTAssertTrue(bubble.waitForExistence(timeout: 90), "助手气泡没出现")
    }

    /// 真机：没有样书和 mock 端点，用书库里第一本真书和它书名的中文关键词，
    /// 验证端侧中文向量能建索引、能按意思找到段落、能跳回原文（不发起真实 AI 请求）。
    private func realDeviceSemanticIndexFlow() throws {
        let book = app.buttons.matching(identifier: "library.book").firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 30), "书库里没有书")
        let cellLabel = book.label

        // 没建过就现场建；已建过就重建一遍，保证验证的是这台设备上刚跑出来的索引。
        book.press(forDuration: 1.2)
        if app.buttons["建立语义索引"].waitForExistence(timeout: 8) {
            app.buttons["建立语义索引"].tap()
        } else if app.buttons["重建语义索引"].waitForExistence(timeout: 8) {
            app.buttons["重建语义索引"].tap()
        } else {
            XCTFail("长按书封没有出现语义索引菜单")
        }
        XCTAssertTrue(
            indexedBook(in: app).waitForExistence(timeout: 300),
            "建索引没有完成"
        )

        // 查询词取书名里的中文关键词：命中段落必须能被找出来并跳回去。
        let keyword = cellLabel.contains("投资") ? "投资" : String(cellLabel.prefix(2))
        let search = app.textFields["搜索书名 / 作者"]
        XCTAssertTrue(search.waitForExistence(timeout: 10), "搜索框没出现")
        search.tap()
        search.typeText(keyword)
        let hit = app.buttons.matching(identifier: "library.semanticHit").firstMatch
        XCTAssertTrue(hit.waitForExistence(timeout: 180), "中文语义检索没有结果（查询：\(keyword)）")

        hit.tap()
        XCTAssertTrue(app.staticTexts["reader.progress"].waitForExistence(timeout: 60), "点检索结果没有打开阅读器")
        XCTAssertTrue(app.staticTexts["reader.percent"].exists, "阅读器没有显示进度")
        app.buttons["reader.close"].tap()
        XCTAssertTrue(waitForLibrary(timeout: 15), "关闭阅读器没有回到书库")
        clearLibrarySearch(in: app)
        dismissKeyboard(in: app)
    }

    /// 模拟器上把 AI 端点指向 mock、书库预置样例书；真机不加这些，用真实数据。
    private func applySimulatorEnvironment(to target: XCUIApplication) {
        guard isSimulator else { return }
        target.launchEnvironment["SHUDENG_SEED_SAMPLE_BOOK"] = "1"
        target.launchEnvironment["SHUDENG_AI_BASE_URL"] = "http://127.0.0.1:8799/v1"
        target.launchEnvironment["SHUDENG_AI_MODEL"] = "mock-model"
        target.launchEnvironment["SHUDENG_AI_API_KEY"] = "mock-key"
    }

    /// 英文样书走一遍语义检索：端侧词向量在模拟器上只有英文能出向量，
    /// 正好用来验证「建索引 → 按意思找段落 → 点结果回跳 → 提问带原文」整条链路。
    func test20SemanticIndexEnglishFlow() throws {
        try XCTSkipUnless(isSimulator, "英文样书只在模拟器的 mock 环境里预置")

        // 换一份带英文样书的启动参数再启动（默认实例只预置中文样书）。
        app.terminate()
        let target = XCUIApplication()
        target.launchArguments += ["-shudeng.onboarded", "YES"]
        applySimulatorEnvironment(to: target)
        target.launchEnvironment["SHUDENG_SEED_SAMPLE_BOOK_EN"] = "1"
        app = target
        target.launch()

        XCTAssertTrue(waitForLibrary(target, timeout: 30), "书库没有加载")
        let sampleTitle = "Shudeng Test Book"
        XCTAssertTrue(
            englishSample(in: target, title: sampleTitle).waitForExistence(timeout: 60),
            "英文样书没有导进书库"
        )

        // 建索引：已经建过就先删掉，保证每次都真的从零建一遍。
        englishSample(in: target, title: sampleTitle).press(forDuration: 1.2)
        if target.buttons["删除语义索引"].waitForExistence(timeout: 8) {
            target.buttons["删除语义索引"].tap()
            englishSample(in: target, title: sampleTitle).press(forDuration: 1.2)
        }
        let build = target.buttons["建立语义索引"]
        XCTAssertTrue(build.waitForExistence(timeout: 8), "长按书封没有出现语义索引菜单")
        build.tap()
        XCTAssertTrue(
            indexedBook(in: target, title: sampleTitle).waitForExistence(timeout: 240),
            "建索引没有完成"
        )
        snap("20-indexed-en")

        // 按意思找段落：这一段在第五章，正好验证回跳是不是真的跳过去了。
        let search = target.textFields["搜索书名 / 作者"]
        XCTAssertTrue(search.waitForExistence(timeout: 10), "搜索框没出现")
        search.tap()
        search.typeText("how do I change the speech rate and voice")
        let hit = target.buttons.matching(identifier: "library.semanticHit").firstMatch
        XCTAssertTrue(hit.waitForExistence(timeout: 180), "等不到语义检索结果")
        XCTAssertTrue(hit.label.contains("Chapter Five"), "命中的不是第五章：\(hit.label)")
        snap("20-semantic-hits-en")

        // 点结果：开书并跳到那一段。
        hit.tap()
        XCTAssertTrue(target.staticTexts["reader.progress"].waitForExistence(timeout: 60), "点检索结果没有打开阅读器")
        // 标题栏的章节名要变成第五篇，进度也要真的走到书的后半段。
        let chapter = target.staticTexts
            .matching(NSPredicate(format: "label CONTAINS 'Chapter Five'"))
            .firstMatch
        XCTAssertTrue(chapter.waitForExistence(timeout: 60), "没有跳到命中的那一章")
        let percent = target.staticTexts["reader.percent"]
        XCTAssertTrue(percent.waitForExistence(timeout: 10), "阅读器没有显示进度")
        var value = 0
        for _ in 0..<60 {
            value = Int(percent.label.filter(\.isNumber)) ?? 0
            if value > 40 { break }
            usleep(500_000)
        }
        XCTAssertGreaterThan(value, 40, "回跳后进度应该靠后（第五章），实际 \(percent.label)")
        snap("20-jump-to-passage-en")
        target.buttons["reader.close"].tap()
        XCTAssertTrue(waitForLibrary(target, timeout: 10), "关闭阅读器没有回到书库")
        clearLibrarySearch(in: target)
        dismissKeyboard(in: target)

        // 对话里也要带上检索到的原文。
        target.tabBars.buttons["AI"].tap()
        let newThread = target.buttons["chat.newThread"]
        XCTAssertTrue(newThread.waitForExistence(timeout: 15), "AI 会话列表没加载")
        newThread.tap()
        let input = target.textFields["chat.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 15), "输入框没出现")
        // 新对话默认为临时对话；明确关联已建索引的英文样书。
        let chip = target.buttons["chat.bookChip"]
        XCTAssertTrue(chip.waitForExistence(timeout: 10))
        chip.tap()
        let pickerSearch = target.searchFields.firstMatch
        XCTAssertTrue(pickerSearch.waitForExistence(timeout: 10))
        pickerSearch.tap()
        pickerSearch.typeText(sampleTitle)
        let indexedBook = target.buttons.matching(identifier: "chat.bookPicker.book")
            .matching(NSPredicate(format: "label == %@", sampleTitle)).firstMatch
        XCTAssertTrue(indexedBook.waitForExistence(timeout: 10))
        XCTAssertTrue(indexedBook.isHittable, "选择器里的英文书行不可点击")
        indexedBook.tap()
        XCTAssertTrue(
            waitForLabel(chip, contains: sampleTitle, timeout: 10),
            "选书后上下文 chip 文案仍是：\(chip.label)"
        )
        input.tap()
        input.typeText("what does the book say about the speech rate")
        target.buttons["chat.send"].tap()
        XCTAssertTrue(
            target.staticTexts["chat.contextNote"].waitForExistence(timeout: 90),
            "提问时没有引用书里的原文"
        )
        snap("20-chat-context-en")

        // 收尾：把英文样书删掉，免得影响别的用例对「第一本书」的假设。
        addTeardownBlock { [self] in
            // 用例中途失败也要删：留着的话下一轮 test04 会把这本当「第一本书」。
            _ = deleteEnglishSample(in: app, title: sampleTitle)
        }
        dismissKeyboard(in: target)
        target.tabBars.buttons["书架"].tap()
        XCTAssertTrue(
            deleteEnglishSample(in: target, title: sampleTitle),
            "英文样书没删掉，会影响别的用例把「第一本书」认成它"
        )
    }

    /// 删除要真的写进库里：删完重启 App 不能又冒出来（书封消失只证明界面刷新了）。
    func test21DeletedBookStaysDeleted() throws {
        try XCTSkipUnless(isSimulator, "英文样书只在模拟器的 mock 环境里预置")
        let sampleTitle = "Shudeng Test Book"

        // 先带英文样书启动，把这本书删掉。
        app.terminate()
        let first = XCUIApplication()
        first.launchArguments += ["-shudeng.onboarded", "YES"]
        applySimulatorEnvironment(to: first)
        first.launchEnvironment["SHUDENG_SEED_SAMPLE_BOOK_EN"] = "1"
        app = first
        first.launch()
        XCTAssertTrue(waitForLibrary(first, timeout: 30), "书库没有加载")
        XCTAssertTrue(
            englishSample(in: first, title: sampleTitle).waitForExistence(timeout: 60),
            "英文样书没有导进书库"
        )
        addTeardownBlock { [self] in
            _ = deleteEnglishSample(in: app, title: sampleTitle)
        }
        clearLibrarySearch(in: first)
        XCTAssertTrue(deleteEnglishSample(in: first, title: sampleTitle), "长按删除没有把书删掉")

        // 重启（这次不预置英文样书）：删掉的书要是还在，就是只删了界面没删库。
        first.terminate()
        let second = XCUIApplication()
        second.launchArguments += ["-shudeng.onboarded", "YES"]
        applySimulatorEnvironment(to: second)
        app = second
        second.launch()
        XCTAssertTrue(waitForLibrary(second, timeout: 30), "重启后书库没有加载")
        XCTAssertFalse(
            englishSample(in: second, title: sampleTitle).waitForExistence(timeout: 15),
            "重启之后删掉的书又回来了"
        )
        XCTAssertTrue(
            englishSample(in: second, title: "书灯测试样书").waitForExistence(timeout: 15),
            "删一本书把别的书也删了"
        )
    }

    /// PDF 走 pdf.js 那条渲染路：能开、页数对、能翻页（EPUB 的用例覆盖不到这里）。
    func test22PdfBookRendersAndTurnsPages() throws {
        try XCTSkipUnless(isSimulator, "PDF 样书只在模拟器的 mock 环境里预置")
        let sampleTitle = "ui-test-sample-pdf"

        app.terminate()
        let target = XCUIApplication()
        target.launchArguments += ["-shudeng.onboarded", "YES"]
        applySimulatorEnvironment(to: target)
        target.launchEnvironment["SHUDENG_SEED_SAMPLE_PDF"] = "1"
        app = target
        target.launch()
        XCTAssertTrue(waitForLibrary(target, timeout: 30), "书库没有加载")

        // 上一轮跑完会留着进度：先删干净，让这次从「没读过」的状态开始（不然会直接续读到上次那一页）。
        clearLibrarySearch(in: target)
        _ = deleteEnglishSample(in: target, title: sampleTitle)
        target.terminate()
        target.launch()
        XCTAssertTrue(waitForLibrary(target, timeout: 30), "书库没有加载")

        let cell = bookCover(in: target, title: sampleTitle)
        XCTAssertTrue(cell.waitForExistence(timeout: 60), "PDF 样书没有导进书库")
        addTeardownBlock { [self] in
            _ = deleteEnglishSample(in: app, title: sampleTitle)
        }
        cell.tap()

        let progress = target.staticTexts["reader.progress"]
        XCTAssertTrue(progress.waitForExistence(timeout: 60), "PDF 阅读器没有渲染出来")
        var firstPage = footerPages(target)
        for _ in 0..<40 {
            firstPage = footerPages(target)
            if firstPage?.current == 1 { break }
            usleep(500_000)
        }
        // 打开就该停在第 1 页：以前 foliate 的 init 会先 next() 一次，PDF 一开就在最后一页。
        XCTAssertEqual(firstPage?.current, 1, "PDF 打开的位置不对，页脚是：\(progress.label)")
        XCTAssertTrue(target.staticTexts["reader.percent"].exists, "PDF 没有显示阅读百分比")
        snap("22-pdf-first-page", of: target)

        target.swipeLeft()
        var secondPage = firstPage
        for _ in 0..<20 {
            secondPage = footerPages(target)
            if secondPage?.current == 2 { break }
            usleep(500_000)
        }
        XCTAssertEqual(secondPage?.current, 2, "PDF 左滑之后应该到第 2 页，实际：\(progress.label)")
        snap("22-pdf-second-page", of: target)

        target.swipeRight()
        var backPage = secondPage
        for _ in 0..<20 {
            backPage = footerPages(target)
            if backPage?.current == 1 { break }
            usleep(500_000)
        }
        XCTAssertEqual(backPage?.current, 1, "PDF 右滑之后应该回到第 1 页，实际：\(progress.label)")

        // 停在「第 2 页」再退出：续读要落回这一页，才是用户要的行为。
        target.swipeLeft()
        var leavePage = backPage
        for _ in 0..<20 {
            leavePage = footerPages(target)
            if leavePage?.current == 2 { break }
            usleep(500_000)
        }
        XCTAssertEqual(leavePage?.current, 2, "PDF 左滑之后应该到第 2 页，实际：\(progress.label)")

        target.buttons["reader.close"].tap()
        XCTAssertTrue(waitForLibrary(target, timeout: 15), "关闭 PDF 没有回到书库")

        // 关掉之后要记住读到哪：PDF 以前一律记成 0%，重进又从第一页开始。
        let card = bookCover(in: target, title: sampleTitle)
        XCTAssertTrue(card.waitForExistence(timeout: 15), "关掉阅读器后书库里找不到这本 PDF")
        var cardLabel = card.label
        for _ in 0..<20 {
            cardLabel = card.label
            if cardLabel.contains("已读") { break }
            usleep(300_000)
        }
        XCTAssertTrue(cardLabel.contains("已读"), "PDF 书封上没显示已读进度：\(cardLabel)")
        XCTAssertFalse(cardLabel.contains("已读 0%"), "PDF 的阅读进度没落库：\(cardLabel)")

        card.tap()
        XCTAssertTrue(progress.waitForExistence(timeout: 60), "第二次打开 PDF 没有渲染出来")
        var resumed = footerPages(target)
        for _ in 0..<40 {
            resumed = footerPages(target)
            if resumed?.current == 2, resumed?.total == 3 { break }
            usleep(500_000)
        }
        XCTAssertEqual(resumed?.current, 2, "重开 PDF 没有回到第 2 页，实际：\(progress.label)")
        XCTAssertEqual(resumed?.total, 3, "PDF 总页数变化了")
        target.buttons["reader.close"].tap()
        XCTAssertTrue(waitForLibrary(target, timeout: 15), "关闭 PDF 没有回到书库")
    }

    /// 长按书封删掉英文样书；返回 true 表示删完（或者本来就没有）。
    @discardableResult
    private func deleteEnglishSample(in target: XCUIApplication, title: String) -> Bool {
        dismissKeyboard(in: target)
        if target.tabBars.buttons["书架"].exists { target.tabBars.buttons["书架"].tap() }
        guard waitForLibrary(target, timeout: 10) else { return false }
        // 搜索框里还有关键词时列表只剩匹配的书，书封会「找不到」；先清干净再删。
        guard clearLibrarySearch(in: target) else { return false }
        let cell = englishSample(in: target, title: title)
        guard cell.waitForExistence(timeout: 15) else { return true }
        cell.press(forDuration: 1.2)
        snap("20-delete-menu", of: target)
        let item = target.buttons["从书库删除"]
        guard item.waitForExistence(timeout: 8) else { return false }
        item.tap()
        let confirmation = target.alerts["删除《\(title)》？"]
        guard confirmation.waitForExistence(timeout: 5) else { return false }
        confirmation.buttons["删除"].tap()
        return cell.waitForNonExistence(timeout: 20)
    }

    /// 按书名找英文样书（书库里可能还躺着中文样书）。
    private func englishSample(in target: XCUIApplication, title: String) -> XCUIElement {
        bookCover(in: target, title: title)
    }

    /// 建索引完成的信号在书封的无障碍标签里（书封是 Button，不是 StaticText）。
    private func indexedBook(in target: XCUIApplication, title: String? = nil) -> XCUIElement {
        let cells = target.buttons.matching(identifier: "library.book")
        if let title {
            return cells
                .matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS '已建语义索引'", title))
                .firstMatch
        }
        return cells.matching(NSPredicate(format: "label CONTAINS '已建语义索引'")).firstMatch
    }

    /// 清空书库搜索框（空的时候 value 是占位符文案）。
    @discardableResult
    private func clearLibrarySearch(in target: XCUIApplication) -> Bool {
        let field = target.textFields["搜索书名 / 作者"]
        guard field.waitForExistence(timeout: 10) else { return false }
        for _ in 0..<3 {
            let value = (field.value as? String) ?? ""
            if value.isEmpty || value == "搜索书名 / 作者" { return true }
            if target.buttons["library.searchClear"].exists {
                target.buttons["library.searchClear"].tap()
            } else {
                field.tap()
                field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 48))
            }
            usleep(400_000)
        }
        let value = (field.value as? String) ?? ""
        return value.isEmpty || value == "搜索书名 / 作者"
    }

    /// 收起键盘：搜索框还带着焦点时键盘会盖住标签栏和书封，点不到。
    private func dismissKeyboard(in target: XCUIApplication) {
        guard target.keyboards.count > 0 else { return }
        if target.buttons["chat.dismissKeyboard"].exists {
            target.buttons["chat.dismissKeyboard"].tap()
        } else {
            target.typeText("\n")
        }
        XCTAssertTrue(target.keyboards.firstMatch.waitForNonExistence(timeout: 5), "收起操作后键盘未退出")
    }
}
