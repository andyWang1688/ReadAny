# 本轮模拟器验收

当前：按用户2026-10-11最新要求停止验收，拆分本地提交，不push，提交后暂停目标等待omo接手。闭环26–29、31–32已按各自断言完成；闭环30搜索异常恢复源码及构建通过，真实UI恢复未验证；闭环33网络补验尚未完成。涉及键盘输入的验收暂缓，朗读排除。iPhone17/iOS26.5，当前系统light、字号large，最新构建PID64326；前台本周阅读报告。临时索引/文件故障已清理，LLDB断点已删除并detach，无XCTest/live驱动。

## 闭环 2：真实选文翻译与返回
- 范围：合成样书第二章片段，中译英；没有读取、更改 Key。
- 已验证：reader.selectionTranslate 存在；“翻译”导航栏出现；真实译文以“Responsible for running the core logic; Swift handles networking, the database, and file I/O”开头，包含 SSE/UTF-8/SQLite 对应内容。通过。
- 关闭“完成”、reader.selectionClose 后，reader.progress=第 2 / 5 节、reader.percent=全书 41%，第一段仍 y181，和翻译前一致。通过。
- 截图：work/evidence/03-real-translation.jpg（MCP 800px状态图）；work/evidence/04-translation-return.png（旧驱动原图）。
- 待验证：书架/笔记/设置本轮走查。
- 未验证：长译文滚动到底、各种语言质量、中文iOS语义成功路径、朗读、真机、发布。

环境：ReadAny，HEAD 6727b53d；iPhone 17 / iOS 26.5。范围：现有功能走查，跳过朗读，真实 AI 仅发送合成样书/问题，不读取或更改真实 Key。

## 闭环 1：真实 AI 导图
- 已验证：书灯测试样书第二章「宿主桥接」真实生成导图；`mindmap.canvas` 存在，`mindmap.node` 共 36 个，内容包含 JavaScriptCore、Swift、SQLite、SSE，与合成样书一致。原图人工检查节点未裁切。通过。
- 截图：`work/evidence/01-real-mindmap.png`（1206×2622，原 XCTest 截图）。
- 工具：build_run_sim 成功；初始 snapshot_ui 返回 count=1/targets=[]，随后 wait_for_ui(label=书架) 原报错 `WAIT_TIMEOUT: Timed out after 15000ms waiting for UI predicate 'exists'.`。此前已回退老 ShudengUXDriver，没有新增或改写 XCTest。
- 用户补充规则后：wait_for_ui(predicate=settled) 与 snapshot_ui 连续成功，count=164，targets=31，返回 `chat.input`、`reader.chat.close` 等；恢复 MCP 操作，结束老交互驱动。
- 待验证：MCP 操作选文翻译、阅读位置保持，以及书架/笔记/设置本轮走查。
- 未验证：中文 iOS 语义成功路径、朗读、真机、发布；此前证据不当作本轮新验收。

## MCP 操作故障与兜底依据
- 冷启动 seq18 空快照不计失败；间隔2秒的 seq19/20 均 `count=1,targets=[],scroll=[]`。截图 `work/evidence/02-mcp-empty-snapshot-library.jpg` 显示书架可见。
- 旧驱动启动后 MCP snapshot 恢复95元素。两次 MCP tap(e47, library.book) 返回成功，wait_for_ui(reader.progress) 连续两次 `WAIT_TIMEOUT: Timed out after 8000ms waiting for UI predicate 'exists'.`，画面仍在书架。旧驱动同一书籍操作成功。
- MCP long_press(e110) 后 reader.selectionTranslate 两次等待均 `WAIT_TIMEOUT: Timed out after 6000ms waiting for UI predicate 'exists'.`；旧驱动长按后存在该按钮。
- MCP tap(e129, reader.selectionTranslate) 返回成功，两次等待“翻译”均 `WAIT_TIMEOUT: Timed out after 6000ms waiting for UI predicate 'textContains'.`。本轮动作通道持续不生效，余下使用原 live-ui/ShudengUXDriver，MCP用于快照和截图。未增加或改写 XCTest。
- 首次 test_sim 工具300秒超时，但原始 test_sim 日志最终 TEST EXECUTE SUCCEEDED；这是交互驱动结束，不能当作产品断言全部通过。第二次驱动 shell 沙箱无法连接 CoreSimulator，升级权限后已成功启动。

## 闭环 3：笔记短高亮回跳
- 范围：已有合成样书高亮“存在”，只读走查。
- 已验证：笔记列表对应按钮“第二章 宿主桥接, 10/09, 存在”可打开原文；reader.toc=书灯测试样书, 第二章 宿主桥接，reader.progress=第 2 / 5 节；原文“文件系统提供读写、存在性判断…”获焦，黄色高亮可见。通过。
- 截图：work/evidence/05-note-return.jpg（MCP状态图）。
- 待验证：设置持久化本轮复核。
- 未验证：本轮没有新增/编辑/删除笔记，没有重跑导出；先前验收不能替代本轮新证据。

## 闭环 4：设置持久化与本轮收尾
- 范围：本轮多次重启后的设置，只读检查，不点击 Key 显示按钮、不改配置。
- 已验证：服务商按钮=服务商, DeepSeek；ai.model=deepseek-flash；连接地址=https://api.deepseek.com；ai.apiKey 为 SecureTextField、内容掩码。服务商/模型/Key 首屏可见。通过。
- 截图：work/evidence/06-settings-persisted.jpg（MCP 800px状态图，非像素级设计评审）。
- 待验证：本轮计划内无剩余；交互驱动已发 stop，等待退出确认。
- 未验证：中文 iOS 语义检索成功路径、朗读（按要求排除）、真机、发布、完整无缺陷保证。没有重复此前全套验收，没有新改应用或测试代码。
- MCP限制：构建、启动、截图有效；运行快照依赖当前状态，有时为空；tap/long_press多次返回成功但界面不变。根因未确认，不把这些工具失败判为应用产品缺陷。旧驱动只作为兜底。
- 收尾确认：fallback-live-authorized.log 最终 TEST EXECUTE SUCCEEDED，驱动 exit0；此结果仅确认交互驱动正常结束，产品通过依据以上各项截图/元素断言。git status --short 无输出，git diff --check 通过，HEAD仍6727b53d。

## 闭环 5进行中：真实摘要排版
- 范围：聊天/翻译/报告共用 MarkdownText 的显示层；不改存储、请求或用户能力。
- 复现：真实第二章摘要截图 work/evidence/07-summary-before.png（simctl原图）；chat.assistantBubble 单块高度548.7，标题/段落/列表全部粘连。抽取真实 attributed 函数运行 work/markdown-repro.swift，输出“核心主题第一段。主要要点网络：SSE 分片。存储：SQLite。”并报 FAIL: paragraph boundaries collapsed。
- 根因：Foundation full解析生成presentationIntent结构，SwiftUI Text未把它转换为布局；系统保留header/listItem/paragraph元数据但字符间无换行。
- 修复：MarkdownBlock.attributedProse统一把系统块结构转为换行、列表标记/缩进、标题强调，保留链接/行内强调；MarkdownText加4pt行距，代码/mermaid通道保持原路径。
- 已验证：swift test --package-path packages/app-ios/CoreBridge --filter MarkdownBlocksTests 修前9项4失败，修后9项0失败；包括标题/段落/嵌套列表/延续段落/引用表格/链接/行内代码/流式半截/代码围栏。git diff --check通过。
- 待验证：重新构建并用同一条真实历史摘要复核、长文滚动、流式回答、关闭重开持久化。
- 未验证：尚不能把函数测试当作模拟器产品验收；整体产品目标仍active。

## 闭环 5完成：摘要结构显示修复
- 已验证：MCP build_run_sim成功；同一条真实第二章摘要现在有“核心主题”“主要要点”等独立加粗标题与分段，列表有项目符号；assistantBubble高度从548.7变为919.0。原图：work/evidence/07-summary-before.png、08-summary-after.png（simctl，1206×2622）。
- MCP swipe(e141)成功滚至“结论 / 启示”及完整结尾；没有以长文截断冒充排版完成。
- 新真实DeepSeek请求仅发送本轮合成“小猫读书计划”指令/合成书上下文；返回两个标题、两项编号、结尾文本。原图09-real-reply-after.png；历史消息与新消息均用真实模型文本，未使用mock。
- 模型原文第二项后只有单换行，结尾属于Markdown列表续行；显示规则遵守原文，没有把模型未生成空行说成独立段落成功。补testParagraphAfterListRequiresMarkdownBlankLine确认空行后才分段。
- MCP touch(delay=0.15,down+up)发送、收键盘、关聊天、重开聊天均成功。重开后MCP快照包含“小猫读书计划”和完整回答；原图10-reply-reopened.png。读取合成消息：assistant id=3C223901-3BC8-453B-B4B5-13E3DD87DCB0，user id=1F1BD270-19CD-4971-B0AB-D5B0694BA7EE，各1条，数据库持久化存在。
- MCP输入限制：中文type_text原报错ACTION_FAILED: Text contains characters unsupported by AXe typing. AXe type supports US keyboard characters only. 英文typing在拼音键盘被IME改写，精确value两次WAIT_TIMEOUT(2000ms)，未发送；旧驱动全选替换为合成中文，快照确认后才MCP发送。未改用户键盘设置。
- 定向函数测试：swift test --package-path packages/app-ios/CoreBridge --filter MarkdownBlocksTests，最终10项0失败，work/markdown-tests-final.log。此前4条失败对应分段/列表/引用表格/标题强调现均通过。代码围栏、链接、行内样式、流式半截保持。
- 原交互驱动已stop并exit0，没有新增UI XCTest、没有修改旧驱动。改动仅MarkdownBlocks.swift、MarkdownBlocksTests.swift、MarkdownText.swift，未提交/发布。
- 待验证：下一轮继续审查其余页面视觉/错误与恢复路径；目标active。
- 未验证：修复后的报告页面、翻译页面专项UI回归，完整流式逐帧过程、极端动态字号；中文iOS语义检索成功路径、真机、发布仍未验证；朗读继续排除。

## 闭环 6：真实阅读报告及区间切换
- 范围：修复后的MarkdownText报告路径；输入仅两本合成样书及模拟器验收生成的阅读数字。
- 已验证：本周71分钟/4天/247页；点击report.ai，MCP seq151捕获“正在生成…”；尚在生成时切本月，seq154本月日期2026-10-01–10-31且无周解读；切回本周，seq157显示report.aiRegenerate及真实回答“你这周最大的进步是习惯在成形…”。未串到其他区间。通过。
- 截图：work/evidence/11-real-report.png（simctl原图）；12-report-month-no-bleed.jpg（MCP状态图）。
- 工具：冷启动seq138/139均count1/targets[]后启旧驱动；后续所有导航/生成/切区间均MCP touch(delay0.15)。
- 待验证：翻译成功与失败恢复专项UI。
- 未验证：报告退出页面后的结果持久化（当前是页面内缓存）、报告网络错误专项、极端动态字号。

## 闭环7进行中：翻译错误与重试
- 真实成功态：MCP触摸选文、翻译，合成词“数据”真实DeepSeek返回“Data”；截图13-translation-real-current.png。
- 真实失败复现：AISettings现有usesTestOverrides分支已确认任何SHUDENG_AI_*仅当前进程生效、不读写Defaults/Keychain。MCP启动指定127.0.0.1:8798（lsof无监听）、failure-check、虚构Key；实际连接失败，屏幕显示“翻译失败：Connection error.”；MCP wait_for_ui enabled(复制)成功，无重试按钮。截图14-translation-error-before.png。
- 根因：ReaderScreen.translate把JSON异常、服务错误和空响应都赋给translatedText；复制按钮仅检查非空，因此错误被当成译文。
- 修复：独立translationError；无有效译文时复制禁用；错误态保留原文、显示重试；重试走同一requestTranslation与generation校验，避免旧回调覆盖；空白结果也判失败。
- 已验证：扩展已有test-translation-state.mjs（不是新增UI驱动），修前8断言失败，修后19checks通过；MCP build_run_sim成功。
- 待验证：修后模拟器失败复制禁用/原文重试/恢复真实配置成功。
- 未验证：尚未完成本项UI闭环。报告旧驱动已exit0且TEST EXECUTE SUCCEEDED，但xcresult保存报mkstemp错误；保留实际MCP快照和simctl原图，不依赖该损坏结果包。

## 工作方式更新（用户本轮补充，覆盖旧回退规则）
- MCP 与 XCTest live 不得同时驱动：MCP交互前先结束旧xcodebuild；旧驱动运行时不发MCP tap/type/snapshot。
- 空AX需同刻截图，并每隔2秒重试snapshot_ui最多5次；启动页/黑屏继续等，不算MCP故障。
- 只有5次均空且正常App界面截图存在，才能记AX未就绪/被占用并回退；记录时间、命令、原始返回、截图及前台App。
- 前述旧驱动常驻时的MCP证据如实保留，但不能作为两个客户端可并用的依据；后续按新规则复核。
- 翻译重试当前证据：seq245 reader.translationRetry enabled；seq251 reader.translationCopy enabled等待2000ms超时、候选e146 action=none；旧AX原始树明确Disabled（work/translation-final-ax.txt）。seq253附近重试后真实UI出现“正在翻译…”，本机故障端点收到user.content=数据、model=failure-check（work/translation-retry-requests.log）。端点只返回400错误，未伪造成功；原图work/evidence/16-translation-retry-final.png、17-translation-retry-loading.png。
- 待验证：遵循自动化客户端互斥后，恢复真实服务成功态、复制可用、关闭返回位置。
- 未验证：同一弹层由网络故障恢复到真实成功（状态函数测试已通过，UI尚未覆盖）。

### 新规则下的独占回退证据
- 时间：2026-10-10T09:44:57.775Z–09:45:13.655Z（UTC）。前台：书灯 com.wangxinxin.readany.personal，书架内容正常。
- XCTest session89983 已exit0；故障端点session78772已exit130；MCP stop_app_sim→launch_app_sim(env:{})，真实配置恢复且未读取Key。
- 初次snapshot seq255空；同刻MCP screenshot与simctl原图work/evidence/18-mcp-only-ax-initial.png显示正常书架。每次调用前等2秒的5次snapshot_ui({})：seq256、257、258、259、260全部count=1,targets=[],scroll=[]。完整原始记录work/mcp-exclusive-five-retries.json。
- 最后一次空快照后立即执行xcrun simctl io A1CD94D7-2F21-48F5-8EE1-6A558ADA77C9 screenshot work/evidence/19-mcp-only-ax-five-retries.png；原图显示正常书架（无启动页、无黑屏）。
- 判定：AX未就绪/被占用，具体原因未确认；符合5次回退条件。后续只使用旧驱动，不再并发MCP tap/type/snapshot。

### 空快照归因更正（用户最新复验）
- 用户已复验MCP正常返回178元素/39 targets，且testInteractiveDrive同时在跑。此前“被占用”不作为根因结论，按用户证据归因冷启动时序。
- 恢复MCP主通道，XCTest仅断言兜底；再次空快照先等2–3秒或wait_for_ui(predicate:settled)再snapshot。保留历史原始空返回及截图，但不据此宣称占用或MCP不可用。

## 闭环7：翻译错误隔离、重试和真实成功回归
- 范围：翻译结果/错误状态与错误恢复，保持原请求与存储架构；真实AI仅合成词“数据”。
- 已修复：错误不再写入译文；无有效译文时复制禁用；失败保留原文并提供重试；空白响应视为错误；旧回调不能覆盖新请求。错误标题与重试按钮分别使用reader.translationError / reader.translationRetry，避免父容器ID覆盖。
- 已验证：19项函数回归通过（含错误/无效JSON/空白结果/重试/乱序/关闭后回调）；最后MCP build_run_sim成功，git diff --check通过。
- 已验证UI错误与重试：reader.translationError=暂时无法翻译；reader.translationRetry=重试且enabled；reader.translationCopy=复制且Disabled（原始AX树work/translation-final-ax.txt）。MCP点重试后“正在翻译…”出现；本机故障端点实际收到合成user.content=数据（work/translation-retry-requests.log），仅返回400故障，没有伪造成功回答。截图16-translation-retry-final.png、17-translation-retry-loading.png。
- 已验证真实成功：清除进程覆盖后，由真实已保存配置翻译“数据”→“Data”；reader.translationCopy无Disabled，点复制后xcrun simctl pbpaste实际输出Data。原始树work/translation-exclusive-result.txt，原图work/evidence/21-translation-real-final.png。
- 已验证返回：完成→关闭选文；reader.progress=第2/5节、reader.percent=全书41%，首段JavaScriptCore坐标仍{{25,181},{352,71}}，与翻译前相同。原始树work/translation-exclusive-return.txt，原图22-translation-return-final.png。
- 待验证：继续整体产品视觉一致性及其他错误恢复路径；整体目标active。
- 未验证：同一弹层内网络恢复后真实重试成功（函数状态已覆盖；真实服务成功UI来自重启后新翻译）；中文iOS语义成功路径、极端动态字号、真机、发布。朗读按要求排除。

### MCP主通道恢复复验
- 旧驱动session60758已exit0，translation-exclusive-live.log最终TEST EXECUTE SUCCEEDED；此结果仅说明驱动结束。
- 随后MCP原报错：Failed to poll runtime UI snapshot；snapshot明确模拟器Shutdown / not booted。重新build_run_sim成功后等2.5秒，wait_for_ui(settled)与snapshot分别seq262/263，均count95/targets18。
- MCP用新快照元素touch打开“书灯测试样书”，wait_for_ui(identifier:reader.progress,role:text)通过，实际第2/5节，count122。截图outputs/evidence/23-mcp-recovered-reader.png；主通道已恢复，当前无常驻XCTest。

### 最新设备规则
- 旧驱动启动前先确认设备Booted；空快照先查设备状态，不记成AX故障。用户说明xcodebuild只会在结束时关闭它自己启动的设备。
- 当前报告排查继续用MCP，seq295实际96元素；已复现“解读失败：Connection error.”，截图work/evidence/24-report-error-before.png。

## 闭环8：阅读报告错误恢复与重新生成
- 范围：AI解读错误/重试/加载/已有结果保留；不改报告聚合、存储或用户能力。全程MCP，无新旧UI XCTest启动。
- 复现：seq295文字“解读失败：Connection error.”，report.ai仍为“让AI说两句”；原图work/evidence/24-report-error-before.png。已有解读时原代码优先显示禁用的重新生成按钮，不展示加载状态。
- 根因：ReadingInsightsView.generate直接拼接服务错误；aiEntryRow无错误分支且已有文本分支早于isGenerating。report函数回归修前3项失败（重复请求、中文连接错误、无效内容文案）。
- 修复：明确重试入口report.aiRetry；错误report.aiError紧随AI入口；isGenerating优先显示report.aiLoading并保留原解读；请求层拒绝重复触发；无效/空白内容提示重试。应用层AIServiceError共用报告/翻译错误文案，无重复连接错误映射。
- 已验证：24项报告状态回归通过、19项翻译状态回归通过，MCP build_run_sim成功，git diff --check通过。
- 已验证UI失败：seq315 report.aiRetry=重试且enabled；report.aiError=无法连接AI服务，请检查网络或服务地址后重试。原图25-report-error-after.png。MCP点击重试出现report.aiLoading=正在生成…；本机故障端点收到合成阅读记录（4天/248页/测试书），只返回400错误、没有mock成功。原图26-report-retry-loading.png，work/report-retry-requests.log。
- 已验证真实AI成功：清除进程覆盖，真实保存配置生成解读；再点report.aiRegenerate，report.aiLoading与上一段“连续4天有阅读…”同时存在；新回答“本周连续4天阅读…”成功替换，按钮恢复enabled。原图27-report-regenerate-preserved.png、28-report-real-after.png；结构证据work/report-recovery-mcp-evidence.json。
- 原图人工检查：数字/错误/重试/书目均未裁切，错误位于AI入口正下方，真实解读也位于对应入口下方。
- 待验证：新发现报告与统计时长取整不一致（报告71分钟，统计72分钟，AI提示平均0分钟但对比行1分钟）；下一闭环追溯实际聚合与格式化，不先改统计口径。
- 未验证：同一页面真实网络失败后恢复成功（本轮故障→重试失败与真实重新生成成功分开验证）；重新生成失败保留旧解读仅函数回归；报告结果退出页面持久化、中文语义检索成功、极端字号、真机、发布。朗读排除，目标active。

## 闭环9：统计与报告时长显示一致
- 范围：分钟格式化（统计页、报告数字、书目时长、AI输入），不改数据库或core聚合。
- 源记录：模拟器readany.db.reading_sessions，2026-10-05至10-11本地日历周（设备+08），130次、4290822毫秒=71.5137分钟，平均0.5501053846分钟，最长6.6540666667分钟、248页。ui-test-sample-pdf单条24067毫秒=0.4011166667分钟，业务键与记录ID保存在work/report-rounding-source.txt。
- 血缘：reading_sessions.total_active_time→readingStatsService.getDailyStats及readingReportsService→buildDailyReadingFacts→buildStatsSummary→app-bootstrap stats/report→SwiftUI。两边均按毫秒/60000求和，无当前样本聚合差异。
- 根因：StatsView.minutesText四舍五入；ReadingInsightsView.metricsCard/topBooks/aiPrompt直接Int截断，而ReportComparison.formattedValue再次四舍五入。因此71.5137显示71/72，平均0.5501在AI同一提示里显示0/1分钟，样书24秒显示0分钟。
- 修复：ReadingDuration共用格式，正值不足一分钟显示<1，其余分钟四舍五入；零仍为0。统计页/报告/提示/对比均复用。不改阅读时长、会话数、页数、书数或权限。
- 已验证：MCP build_run_sim通过；seq352统计本周72；seq356报告本期72、最长7、书灯样书54、导入样书17、PDF<1分钟；报告仍4天/248页/3本。原图work/evidence/29-stats-rounding-after.png、30-report-rounding-after.png。
- 已验证：现有test-report-state.mjs最终32项通过（work/report-duration-final.log），直接编译真实aiPrompt，确认平均每次与对比均<1分钟、最长7、合成PDF<1；19项翻译回归通过，git diff --check通过。
- 待验证：继续整体产品一致性与剩余失败路径。整体目标active。
- 未验证：本次取整修复后未再次请求真实AI（此前真实解读/重新生成已验证；本项AI提示由实际函数回归覆盖）；极端字号、中文iOS语义检索成功、真机、发布，朗读排除。

## 闭环10：最大辅助功能字号的统计/报告布局
- 范围：content_size由large临时切至accessibility-extra-extra-extra-large；统计数字、报告数字、行布局和趋势轴日期。恢复large仍待执行。
- 复现：32-stats-ax5-before.png中72被拆成7/2、1.2拆成1./2；31-report-ax5-before.png中标题放大而指标仍固定19/11字号、比较行拥挤。
- 修复：ScaledMetric缩放数值；辅助功能字号下指标/日期/比较/AI入口纵排；报告数字单列；趋势日期使用动态caption2并允许横向滚动。
- 已验证：MCP构建通过，最大字号72、1.2整行；趋势横滚后看到最后日期6/7/8/9/10；stats.report可打开，报告数值72/4/248可见，滚至report.ai=让AI说两句且enabled。截图33-stats-ax5-after.png、34-stats-ax5-chart.png、35-report-ax5-after.png、36-report-ax5-actions.png。
- 待验证：补默认字号回归、报告纵排左对齐修正后的复验。
- 未验证：其他设备尺寸与VoiceOver逐项读序。

## 闭环11进行中：大字号笔记回原文与阅读器控制栏
- 已验证：笔记“查询”可回到第二章宿主桥接，reader.progress=本章1/2；37-notes-ax5.png、38-reader-ax5-from-note.png。
- 新复现：阅读器顶部固定30高/28宽的按钮使用可无限放大的body图标，最大字号下目录/搜索/书签/朗读/AI/设置重叠；底部状态挤断。笔记章节名也被单行截断。
- 已改：大字号标题/动作分两行，图标有44点触控区且最大28点符号；增加中文操作标签；底部状态纵排；正文保持用户独立阅读字号。构建通过。
- 待验证：大字号阅读器目录/搜索/设置真实操作、恢复默认字号回归；笔记章节名截断待修复。
- 未验证：朗读按要求排除，其他系统字号仍需复核。

## 闭环11完成：最大辅助功能字号的笔记与阅读控制
- 范围：content_size=accessibility-extra-extra-extra-large；不测试朗读行为，仅检查入口可见和可操作。
- 复现：38-reader-ax5-from-note.png顶部按钮重叠、底部状态挤断；37-notes-ax5.png章节标题单行截断。
- 修复：ReaderScreen在辅助功能字号下标题/控制分两行，按钮44点触控区、图标不超过28点，新增中文VoiceOver标签；底部进度纵排。NotesView章节标题/日期纵排，默认字号保持原布局。
- 已验证：MCP最新快照seq409显示reader.tocButton=目录、reader.search=查找正文、reader.bookmark=添加书签、reader.speech=开始朗读、reader.chat=AI助手、reader.settings=阅读设置；reader.progress=本章1/2、reader.percent=全书31%、reader.remaining=还剩3分钟。原图40-reader-ax5-after.png。
- 已验证：MCP点击目录，出现reader.tocRow=第一章/第二章/第三章；点击完成后查找正文出现reader.searchField=书内搜索、清除、完成。原图41-reader-ax5-toc.png、42-reader-ax5-search.png。
- 已验证：笔记“查询”入口仍可回到正文；最大字号下列表保留完整章节名和日期。原图39-notes-ax5-after.png、38-reader-ax5-from-note.png。
- 已验证：统计/报告大字号布局：数字完整、报告入口可达、趋势图横向滚动可看到日期10；原图33/34/35/36。
- 已验证：MCP构建通过；报告状态32项、翻译状态19项通过；git diff --check通过。执行xcrun simctl ui ... content_size large恢复默认字号命令成功返回。
- 未验证：独立VoiceOver朗读顺序、iPad/小屏设备、其它辅助功能字号档位；朗读行为按要求排除。

## 闭环12：报告大幅增长文案
- 范围：报告环比显示及同一 aiPrompt 文案；不改 reading_sessions、core 聚合或比较口径。默认字号 large。
- 根因：deltaText 把所有非零变化直接拼成百分比，真实本周 +2476% 显示“阅读时长 增加 2476%”，普通读者难以理解。
- 修复：正增长 >=1000% 显示“约为上期 N 倍”，倍率 = 1 + delta / 100，再四舍五入；+2476% → 26 倍，+1359% → 15 倍。其余增长/减少仍用百分比，+∞ 仍为“上期为 0”，零变化“持平”。不把增加倍率误写成当前总倍率。
- 已验证：node packages/app-ios/scripts/test-report-state.mjs → 36 checks 通过（含真实 +2476%、+1359%、1000% 边界、999%、+50%、-50%、零基期及持平）；翻译 19 checks 通过；git diff --check 通过。日志 work/report-comparison-regression.log、work/translation-comparison-regression.log。
- 已验证：MCP build_run_sim 成功；wait_for_ui(settled) 冷启动正常返回 95 元素/18 targets，无空快照；当前没有常驻 XCTest。
- 已验证 UI：MCP seq444 wait_for_ui(identifier:report.comparison,predicate:textContains,text:约为上期 26 倍) 成功；e47 实际“阅读时长 约为上期 26 倍”。本期数值仍为 72 分钟/4 天/248 页/3 本/最长 7 分钟；合成 PDF <1 分钟。通过。
- 截图：outputs/evidence/43-report-growth-ratio.png（xcrun simctl io A1CD94D7-2F21-48F5-8EE1-6A558ADA77C9 screenshot 原图，1206×2622）；MCP JPEG 只用作状态确认。
- 工具记录：一次 tap 使用过期 ref 返回 SNAPSHOT_EXPIRED（snapshotAgeMs=96338），刷新后恢复；另一次 tap 返回 SUCCEEDED 但仍在书架，最新 elementRef 的 MCP touch(down:true,up:true,delay:0.15) 能真实导航。没有回退 XCTest，未归因为 AX 故障。
- 已验证：最大字号 seq449 report.comparison=阅读时长 约为上期 26 倍，原图44-report-growth-largest.png文字完整换行；已恢复 large，seq451 默认数字/比较完整。seq455 本月选中且日期2026-10-01–10-31，比较仍正确为26倍，原图45-report-growth-month.png。切全部后 wait_for_ui(gone,report.comparison) 成功，无比较残留，原图46-report-all-no-comparison.png。
- 待验证：闭环12范围内无剩余；最大字号新增发现 AI 入口居中，转闭环13。
- 已验证：后续闭环13实际点击 report.ai，真实服务生成合成阅读记录解读；seq489 含“连续 4 天阅读”“130 次平均不足 1 分钟”，不再出现平均0分钟；没有读取、更改或输出真实 Key。
- 未验证：中文 iOS 语义成功路径、独立 VoiceOver 读序、iPad/小屏、真机/发布；朗读按要求排除。整体目标 active。

## 闭环13：最大字号报告 AI 入口对齐
- 范围：ReadingInsightsView.aiEntryRow 的布局宽度；不改请求/状态/数据。
- 复现：outputs/evidence/44-report-growth-largest.png 中“和上一期比”左对齐，但“AI 解读”被置于更窄的居中列。
- 根因：aiEntryRow 在大字号切为 VStack 后保持内容自然宽度，父 VStack 默认居中；比较行已经显式 maxWidth=infinity/leading，AI 行缺少该约束。
- 修复：aiEntryRow 增加同一 maxWidth/leading 约束；默认 HStack 保持原来 Spacer 行为。
- 已验证：MCP build_run_sim 成功；最大字号下“AI 解读”及“让 AI 说两句”与上一行同一左边界，原图47-report-ai-leading-largest.png、48-report-ai-action-largest.png。MCP seq476 report.ai enabled；seq479 按钮完整可见，实际点击后成功生成回答。
- 已验证：恢复 large 后 seq488 report.aiRegenerate=重新生成且 enabled；seq489 textContains(连续 4 天阅读) 成功，实际全文“连续 4 天阅读、时长和本数都比上期大幅上升，习惯正在起步，值得肯定。但 130 次平均不足 1 分钟，碎片化明显，容易被手机打断，也导致一本未完。建议每天固定一个 15 分钟时段，只读当前一本，读完再换。”；原图49-report-ai-success-largest.png、50-report-ai-default-after.png。输入仅合成样书与验收阅读数字。
- 工具实际返回：wait_for_ui(exists,report.aiLoading,4000ms) 报 WAIT_TIMEOUT: Timed out after 4000ms waiting for UI predicate 'exists'.；同次返回已显示 report.aiRegenerate 和上述真实回答。没有捕获本次短暂加载态，不能算加载态验收通过；这不是空快照或 AX 故障。
- 已验证：git diff --check 通过；本闭环只增加一行布局宽度/对齐约束，无请求和状态逻辑改动。
- 待验证：本项范围内无剩余；整体产品验收继续。
- 未验证：本次最大字号短暂加载态未捕获；独立 VoiceOver、iPad/小屏、其它字号档位、真机与发布。朗读按要求排除。

## 闭环14：阅读报告解读离开后丢失（修复并验收）
- 范围：已有 AI 阅读解读的本地保留、周期隔离、数据更新提示及请求生命周期；不新增报告历史入口，不改统计或真实 Key。
- 复现：MCP seq490 原文“连续 4 天阅读…”存在、report.aiRegenerate=重新生成；点 BackButton→stats.report，seq497 原文消失且 report.ai=让 AI 说两句。原图 outputs/evidence/50-report-ai-default-after.png → 51-report-reopened-before.png。
- 根因：ReadingReportView 的 aiText 为页面 @State，离开 NavigationLink 后销毁；ReportStore/aiReport 均没有保存或恢复结果。
- 修复：RootView 持有 ReportAIStore；周/月/全部各保存最近一次解读，按周期键与起止日期隔离，原子写入 reading-report-ai.json；页面关闭不销毁请求。保留失败结果、保存重试和旧数据提示；不新增历史入口或改变统计聚合。
- 已验证：seq561 report.aiLoading=正在生成… 时离开；seq566 返回后 report.aiRegenerate=重新生成且真实解读存在。截图 outputs/evidence/55-report-persisted-after-departure.png。通过。
- 已验证：强制结束再启动，新进程 PID80267；seq583 正文全文与离开前相同。截图56-report-restored-after-restart.png。seq586 本月 report.ai 存在、无周解读，切回本周正文保留。通过。
- 已验证：仅在合成报告缓存路径注入真实文件写入失败；seq595 report.aiSaveError=解读暂存在当前应用，尚未保存到本地；关闭应用可能丢失，请重试保存。report.aiSaveRetry=重试保存 enabled，新正文仍在。撤销故障后点击重试，seq598 保存错误消失、新正文完全相同。截图57-report-save-error.png、58-report-save-recovered.png。通过。
- 已验证：当前重新构建启动后容器路径变为 DA50DF35-3A60-44DD-871A-74D485D1540D；磁盘 week.text 与 seq598 新正文逐字相等；isFile=true，.acceptance-backup 不存在，故障目录没有遗留。通过。
- 已验证：实际打开合成书灯样书，MCP swipe 左翻页；seq608 reader.progress=第3/5节、全书63%；关闭后报告 seq630 本周73分钟/4天/262页/3本（缓存源261页/131次）。report.aiStale=阅读数据已更新，解读仍基于上次记录。旧正文全文仍相同，report.aiRegenerate 可用。原图 outputs/evidence/59-report-data-updated-retained.png。通过。
- 已验证：实际 ReportAIStore 定向回归51 checks、翻译回归19 checks；MCP构建成功，git diff --check通过。原始MCP证据 work/inherited-mcp-evidence.json、work/report-persistence-final-ui.json；函数通过不替代以上 UI 验收。
- 工具记录：一次已过期 ref touch 返回 SNAPSHOT_EXPIRED（snapshotAgeMs=101697）；刷新后导航成功。不是空快照或 AX 故障，没有回退 XCTest。
- 待验证：本项真实UI范围内无剩余；继续整体布局及主流程检查。
- 未验证：模拟器跨周/跨月切换尚未真实执行（新周期隔离已由实际 store 测试覆盖），损坏缓存仅函数验证；独立VoiceOver、iPad/小屏、其他字号、真机/发布。朗读按要求排除。整体目标仍 active，未提交/发布。

## 闭环15：AI 列表重复搜索入口（用户截图指出）
- 范围：ChatListView 的重复搜索按钮；保留原生常驻搜索框、排序、新对话和现有筛选逻辑。
- 根因：页面已有 .searchable(placement:navigationBarDrawer(displayMode:always))，又手写 topBarLeading 的 chat.search 图标，两个入口指向同一搜索状态。
- 修复：删除重复 ToolbarItem 及其孤立 showSearch 状态/isPresented 参数；书架和笔记没有同一手写重复按钮。
- 已验证：MCP build_run_sim 成功；seq516 搜索框 e23=搜索对话仍存在，chat.sort=分组排序、chat.newThread=新对话仍存在；wait_for_ui(gone,chat.search) 成功。原图 outputs/evidence/52-chat-single-search-field.png。
- 已验证：seq528 输入框实际 value=1629，chat.threadRow 仅1条“挂书测试b1629A”；不是新造回复，只对已有合成测试历史作本地筛选。原图53-chat-search-filter.png。
- 已验证：输入00000999出现“没有找到匹配的对话”，零匹配；原图54-chat-search-empty.png。清空并关闭搜索后恢复完整列表；git diff --check 通过。
- 工具限制：ASCII Shudeng 被当前拼音键盘组合为 S hu deng，未把该输入当成精确检索验收；改用数字输入，实际 value 已断言。没有启动 XCTest 或修改用户键盘。
- 工具限制：type_text(replaceExisting:true,text:00000999) 第一次实际追加为162900000999；清空后重新输入，已用 exists(role:text-field,value:00000999) 精确确认，零匹配提示通过。原始追加返回保留，不把工具替换失败记成应用筛选错误。
- 待验证：本项范围内无剩余；返回闭环14报告保留验收。
- 未验证：中文搜索输入的 MCP 自动化路径；本项不是 AI 服务成功路径验收，不用旧“模拟回复”证明真实 AI 成功。
- 布局补验：补 navigationTitle=对话，使用现有 inline 导航样式；顶部为页面标题+排序/新建，第二行为唯一搜索框。seq635 exists(label:对话)通过；seq636 chat.search不存在、搜索对话输入框与chat.sort/chat.newThread仍在。MCP构建成功、git diff --check通过；原图 outputs/evidence/60-chat-title-single-search.png 已人工确认标题与右侧按钮没有重叠。默认字号large；其他字号标题本轮未验证。

## 闭环16：对话列表可读预览
- 范围：只改列表展示摘要，不修改会话/消息存储，不发送AI请求；使用既有真实合成“小猫读书计划”及导图历史。
- 复现：seq636 与 outputs/evidence/60-chat-title-single-search.png 显示“## 小猫读书计划 ## 每日安排”和“```mermaid graph TD ...”；标题/正文原格式被列表接口提前压成一行，直接 Text(last) 显示源码。
- 修复：listThreads 返回的60字符摘要保留换行；ChatListView复用既有MarkdownBlock解析为单行正文，mermaid摘要显示“思维导图”；搜索仍把摘要空白折为单空格后匹配。没有另写Markdown解析器，没有改历史消息。
- 已验证：MCP seq642 小猫预览实际“小猫读书计划 每日安排 1. 午后，橘猫豆豆翻三页绘本，用爪印当书签。 2. 遇见鱼形插图就喵一声，算作打卡”，不含##；导图预览实际“先看这张图： 思维导图”，不含代码围栏/graph源码。两项断言true。原图 outputs/evidence/61-chat-preview-readable.png。通过。
- 已验证：seq652 搜索输入实际value=1629，chat.threadRow仅1条“挂书测试b1629A”；标题搜索回归通过。原图62-chat-preview-search-regression.png。本地历史mock文案不作为AI成功证据。
- 已验证：关闭搜索、重开同一真实历史，seq678 chat.assistantBubble仍有两个标题、两项编号及完整结尾“自称阅读推广喵。”；已有摘要结尾亦保留。原图63-chat-original-reopened.png。通过。
- 已验证：MCP构建成功；node --check app-bootstrap.js、git diff --check通过。本轮没有新增或重构XCTest；原始证据work/chat-preview-ui-evidence.json。
- 工具限制：selector-free textContains首次返回TARGET_AMBIGUOUS（父chat.threadRow和子text均匹配），改用新snapshot实际元素断言；focused返回TARGET_NOT_ACTIONABLE: The matched runtime UI element does not expose focus state. 两次输入1.工具返回SUCCEEDED但实际搜索框仍为空，精确value等待WAIT_TIMEOUT，因此正文关键词搜索本轮未通过自动化验收，不能归因App筛选错误。1629实际输入/筛选已通过；没有回退旧驱动。
- 待验证：继续笔记保存/回跳及其余布局主流程。
- 未验证：正文跨行关键词的UI输入、仅代码/截断格式的全部预览组合、此页其他字号/设备、中文自动化输入。独立VoiceOver、中文语义检索成功、真机/发布仍未验证；朗读按要求排除。

## 闭环17：笔记保存、回原文及重启
- 范围：已有合成“书灯测试样书”第二章“查询”高亮，原笔记为空；仅写入临时数字20261010，不涉及真实内容或Key，没有修改代码。
- 已验证：MCP drag(最新行ref,right,distance0.7)显示“编辑”；seq704 notes.editor实际value=20261010。点击notes.save后seq710笔记分类选中，行实际“第二章 宿主桥接, 10/10, 查询, 20261010”。原图 outputs/evidence/64-note-saved-in-notes.png。通过。
- 已验证：点击该笔记后seq712 reader.toc=书灯测试样书,第二章宿主桥接，reader.progress=第2/5节、reader.percent=全书41%；原图65-saved-note-return-to-text.png显示原文“查询”处定位线，原有“文件/存在”黄色高亮仍在。通过；没有把蓝色查询高亮说成黄色。
- 已验证：关闭阅读器后MCP stop→launch，新PID204；seq720及后续复核存在text=20261010。截图 outputs/evidence/66-note-restored-after-restart.jpg（MCP状态图，仅用来确认保留，不做像素评审）。通过。
- 清理：MCP空字符串type_text原报错MCP error -32602: Input validation error: Invalid arguments for tool type_text: Text cannot be empty at text；改用key_sequence八次Backspace。seq750 notes.editor=想法…，确认空草稿后才保存；seq752 20261010不存在、两个原“查询”高亮行仍在，编辑页已关闭。图67-note-test-text-cleaned.jpg。只移除本轮写入的文字，没有删除高亮或旧笔记。通过。
- 工具记录：本轮全程MCP，无XCTest；横滑使用drag定位行，swipe仅可用于快照列出的scroll refs。一次原图采集前前台已变为“我的”，错误命名截图移入work/evidence/66-state-changed-before-capture.png，不作为笔记持久化证据；刷新后重新采集上述正确MCP状态图。状态变化原因未确认，不记AX或App故障。
- 证据：work/notes-save-return-ui-evidence.json保留原始返回；此前其他来源的模拟回复不当作本轮AI证据。
- 待验证：本项范围内无剩余；总体继续其余布局和失败恢复检查。
- 未验证：本轮没有注入笔记写入失败；中文长笔记输入、未保存草稿退出、VoiceOver、其他尺寸/字号、真机/发布未验证，朗读排除。

## 闭环18：笔记未保存退出保护及真实保存失败恢复
- 范围：合成样书现有空笔记，输入18181010；两处编辑器共用NoteCancelButton退出确认，不改保存数据路径。
- 复现：seq771 notes.editor=18181010；拖动“编辑笔记”标题向下后seq775编辑器消失，无确认；重新打开seq780 notes.editor=想法…。草稿丢失。图 outputs/evidence/68-note-draft-lost-before.jpg。
- 修复：有修改时interactiveDismissDisabled；取消按钮通过原生alert提供“继续编辑/放弃修改”，无修改直接关闭；阅读器与笔记列表共用同一按钮组件。
- 已验证列表：seq817实际note.keepEditing=继续编辑、note.discard=放弃修改均存在；图71-note-exit-alert.jpg（MCP状态图）。seq820点击继续编辑后notes.editor仍为18181010；seq823同样下拉后编辑器与草稿仍存在。通过。
- 已验证列表：seq828明确放弃后编辑器关闭，18181010未写入列表；seq833再次打开为想法…；seq835空草稿取消直接关闭，不出现确认。通过。
- 已验证：MCP构建通过；现有reader-note-state 5 checks、existing-reader-annotation 10 checks通过；没有新增/重构XCTest。
- 已验证阅读器：实际长按合成样书“数据”，reader.noteOriginal=数据；seq868确认框提供继续编辑/放弃修改，reader.noteEditor=18181010。seq871继续编辑后18181010保留；seq874下拉后草稿与编辑页保留；seq879明确放弃后编辑页关闭，未新建高亮。图74-reader-note-exit-alert.jpg、75-reader-note-draft-protected.jpg（MCP状态图）。通过。
- 已验证真实失败：对readany.db添加临时BEFORE UPDATE OF note触发器，仅匹配书灯测试样书“查询”且NEW.note=19191010，RAISE(ABORT,UX_ACCEPTANCE_NOTE_SAVE_FAILURE)。seq848显示“操作没能保存到本地，请检查存储空间后重试。”，notes.editor仍为19191010；磁盘两条原笔记分别空字符串/null，没有写入错误结果。图72-note-real-save-failure.jpg。通过。
- 已验证真实恢复：立即撤销触发器，再点击同一notes.save；seq851列表出现19191010、编辑器关闭且错误消失；磁盘hl-1791600556158-j6y9.note=19191010，另一条原记录仍null，注入触发器count=0。图73-note-real-save-recovered.jpg。通过。
- 清理验证：从UI重新编辑该合成笔记，八次Backspace后确认空草稿再保存；seq892 19191010不存在。磁盘hl-1791600556158-j6y9.note恢复空字符串、hl-1791600347455-p9g6.note仍null；temporary_notes(18181010/19191010)=0、injected_trigger_count=0。原高亮未删除。
- 代码与证据：NotesView/ReaderScreen各保留现有存储路径，共用DesignSystem/NoteCancelButton.swift；现有notes-persistence 10 checks、reader-note-state 5 checks、existing-reader-annotation 10 checks通过，MCP构建通过。work/note-draft-and-save-evidence.json保存原始结果。无新增/重构XCTest。
- 待验证：本项真实UI范围内无剩余；继续整体页面层级检查。
- 未验证：进程被系统终止前尚未保存的草稿；本改动只保护界面退出，不声明草稿已持久化。朗读排除，整体active。

## 闭环19：根页面标题与搜索/操作层级
- 范围：书架、笔记、我的补inline页面标题；对话页复核重复搜索已移除。默认字号large，iPhone 17 / iOS 26.5。
- 已验证：MCP build_run_sim成功，PID10901；进程检查没有testInteractiveDrive/xcodebuild测试/live-ui/ShudengUXDriver。全程MCP。
- 已验证书架：seq904 exists(role:other,label:书架)命中e15；library.import=导入书籍、library.refresh=刷新书架、搜索书名 / 作者、全部/在读/未读/读完和library.sort均存在。原图outputs/evidence/79-library-header-final.png；人工检查无重叠。通过。
- 已验证我的：seq906 exists(role:other,label:我的)命中e15；profile.appearance=外观、profile.ai=AI设置、profile.vector=语义检索、profile.about=关于书灯均可见。原图80-profile-title-final.png，人工检查标题和内容层级正常。未进入AI设置、不读取Key。通过。
- 已验证笔记：seq908 exists(role:other,label:笔记)命中e15；notes.export=导出、搜索高亮/笔记/书名、高亮/笔记/书签均存在。原图81-notes-header-final.png（布局与已人工查看的78相同）。通过。
- 已验证对话：seq910 exists(role:other,label:对话)命中e15；seq911 gone(identifier:chat.search)通过；唯一搜索字段=搜索对话，chat.sort=分组排序和chat.newThread=新对话均存在。原图82-chat-header-final.png；人工检查重复左上角按钮已消失、标题/搜索/操作无重叠。通过。
- 证据：work/root-header-mcp-evidence.json保存原始MCP返回；79-82为simctl原图，不是MCP压缩图。未新增或重构XCTest。
- 待验证：上述默认字号范围内无剩余；继续根页面最大辅助字号布局复核。
- 未验证：本闭环未验证最大字号、独立VoiceOver、iPad/小屏、真机/发布；朗读排除，整体active。

## 闭环20：根页面最大字号布局及默认字号书封对齐
- 范围：content_size从large临时切accessibility-extra-extra-extra-large；书架搜索/筛选/书名，对话标题/预览/日期，我的标题/状态。功能和存储冻结，无新XCTest、无AI请求、不进入Key设置。
- 复现：83-chat-ax5-layout.png中“总结本章讲了什么”被时间挤成“总结本…”；84-library-ax5-before.png中搜索框固定38pt导致文字/图标溢出、排序图标过大、三列书名无法辨认；91-profile-ax5-header.png中阅读统计拆成三行、今日时长与外观状态横向挤压。均为simctl原图。
- 修复：LibraryView搜索按文字自然增高，辅助字号短占位符“搜索书籍”并保留AX标签“搜索书名或作者”；辅助字号改单列缩略封面+完整书名、阅读筛选改原生菜单，排序触控区44pt并限制装饰图标尺寸。ChatListView辅助字号标题/摘要/日期纵排，完整标题与两行摘要。ProfileView辅助字号标题/状态纵排，模型名允许换行；默认字号保留原横排。
- 已验证书架：seq919 library.searchField=搜索书籍、library.filter=筛选/全部、library.sort=最近阅读；85-library-ax5-after.png人工确认无溢出、四本书名完整。seq921筛选菜单“全部/在读/未读/读完”四个按钮均存在；seq925选择未读后library.book仅1个Shudeng Test Book。通过。
- 已验证书架搜索：seq952 library.searchField实际值Shudeng，library.book仅1个Shudeng Test Book；86-library-ax5-search.png。seq956点击library.searchClear后恢复4本，筛选为全部。通过。
- 已验证对话：seq959完整标题“总结本章讲了什么”、日期11:52存在；88-chat-ax5-after.png人工确认标题完整、摘要两行、日期另起一行。seq965搜索值1629，chat.threadRow仅1个“挂书测试b1629A”；89-chat-ax5-search.png。batch清空并关闭搜索后seq967/969恢复首屏。通过。旧“模拟回复”仅作现有列表内容，没有作为真实AI成功证据。
- 已验证笔记：seq972高亮/笔记/书签、notes.export=导出、搜索高亮/笔记/书名均可见；90-notes-ax5-header.png人工确认无重叠。通过。
- 已验证我的：seq982阅读统计/今天24分钟、外观/跟随系统、profile.ai存在；92-profile-ax5-after.png人工确认标题与状态完整分行。滚动后seq985 profile.vector=语义检索、profile.about=关于书灯可见；93-profile-ax5-lower.png模型deepseek-flash完整换行、入口可达。通过，未进入AI设置。
- 已验证默认字号：恢复large命令成功；94-profile-large-final.png、96-chat-large-final.png人工确认原横排正常，chat.search不存在、唯一搜索框=搜索对话、chat.sort/chat.newThread存在。seq990书架四分类和4本均在；默认三列图仍保留。通过。
- 默认字号额外复现及修复：95-library-large-final.png同一行书封因书名行数不同而上下居中错位；GridItem新增alignment:.top。最终MCP build_run_sim成功、PID13709；seq995为96元素，97-library-large-top-aligned.png人工确认三个书封顶边/底边齐平。git diff --check通过。
- 工具记录：wait_for_ui(focused,library.searchField)原返回TARGET_NOT_ACTIONABLE: The matched runtime UI element does not expose focus state. 改用实际输入值/截图断言；一次Shudeng未提交时实际值S hu deng，exists(value:Shudeng)原返回WAIT_TIMEOUT（6000ms）；提交后seq952实际值Shudeng且匹配1本。没有空快照、没有回退XCTest，没有把焦点状态未暴露记为AX故障。一次simctl截图审批审核超时，按工具提示重试一次成功，无遗留阻塞。
- 证据：work/root-accessibility-layout-evidence.json包含8项实际断言（全部passed=true）及原始返回；work/root-final-grid-evidence.json包含最终构建与书架/对话返回。83-97均为simctl原图；87为聚焦排查图，不替代搜索成功证据。86已用真正匹配截图覆盖初次未输入成功图。
- 待验证：本闭环范围无剩余；整体目标保持active，继续其它现有功能/错误恢复。
- 未验证：独立VoiceOver读序、iPad/小屏/真机、其它字号档位、中文iOS语义成功、未保存草稿跨进程、发布。朗读排除。

## 闭环21：导出面板与真实失败恢复
- 范围：笔记Markdown/HTML导出文件、导出面板最大字号、真实缓存写入失败/连续重试/恢复；没有AI请求或Key访问，无XCTest。
- 复现：99-notes-export-ax5-before.png固定320pt面板截断文件名/分享按钮/说明；seq1030真实目录写入故障显示英文NSCocoaErrorDomain Code516及完整沙箱路径，100-notes-export-error-before.png。
- 修复：可滚动面板与medium/large高度，完整文件名、短按钮“分享或保存”，明确“全部高亮、笔记和书签”。首次alert重试方案在连续失败时被系统关闭回写覆盖（seq1077等待重试6000ms超时，106-notes-export-retry-lost-error.png），最终以页面内错误和单一failedExportFormat状态替代；该alert中间方案不是最终验收。
- 已验证最终失败：seq1088 notes.exportError=未能生成导出文件。原内容已保留，请稍后重试。；notes.exportRetry/notes.exportDismissError存在，原高亮可见。107-notes-export-error-final.png。seq1091在故障仍在时再点重试，错误继续存在。通过。
- 已验证最终恢复：立即撤销故障并还原导出缓存目录，点击同一重试；seq1094 notes.exportFile=书灯笔记-2026-10-11.md、错误不存在。108-notes-export-recovered-final.png。通过。
- 已验证面板：seq1043文件名完整，seq1046上滑可达notes.exportShare=分享或保存且完整说明；102/103原图。点击ShareLink系统分享面板实际显示文本文件/3KB预览，104-notes-system-share-ax5.png；MCP运行快照此时仍描述宿主App，系统面板断言只以原图为依据，未回退XCTest。随后MCP停/启清除分享状态，未声称已保存到系统文件。
- 已验证最终深色：ShareLink按钮文字由白底白字改为systemBackground反色；110-notes-export-dark-contrast.png和111-notes-export-ax5-dark-final.png确认默认/最大字号文字清楚，文件名和分享按钮完整可达。字号恢复large，深色保留；最终颜色构建PID18466，后续书签命中区构建PID19405也保留该修复。
- 已验证文件：UI重新生成MD/HTML，当前源42高亮、18非空笔记、1书签；实际文件3056/5802 bytes，内容/次数与只读SQLite来源一致，9断言全部true。书签实际正文“第二章 宿主桥接”；原始报告work/notes-export-content-evidence.json、原始MCP返回work/notes-export-mcp-evidence.json及work/bookmark-mcp-evidence.json，原图118-markdown-bookmark-export.png/119-html-bookmark-export.png。
- 当前：2026-10-11，深色、字号large；所有临时故障已撤销，缓存目录恢复。书签通过UI清理，来源恢复原SHA256；导出文件保留生成当时的1书签快照。无XCTest、无AI请求。
- 待验证：本闭环实际文件生成/面板/失败恢复范围内无剩余；继续书内搜索。
- 未验证：系统文件应用最终保存、iPad/小屏/真机/VoiceOver；朗读排除，整体active。

## 闭环22：书签保存、回原文与卡片点击区域
- 范围：仅合成样书UI添加/删除本轮1书签、笔记书签列表、两种格式导出；不改旧高亮/笔记，不发AI。
- 已验证新增：seq1148 reader.bookmark=移除书签/已加书签；磁盘id=bm-1791650757523-ddlv、book_id=ui-test-sample、cfi=epubcfi(/6/4!/4,/2,/18/1:22)、chapter_title=第二章 宿主桥接、label=41%。113-reader-bookmark-added.png。
- 已验证列表：seq1156书签分类选中，按钮实际“书灯测试样书, 第二章 宿主桥接, 10/11”；114-notes-bookmark-list.png。通过。
- 实际复现：点击卡片中央x201/y288连续不进入阅读器，wait(reader.bookmark)原返回WAIT_TIMEOUT: Timed out after 8000ms waiting for UI predicate exists，seq1171仍79元素的书签列表；115-bookmark-return-reader.png实际为未跳转状态。点书名文字x71/y279后seq1177即返回第二章41%，证明路由/数据有效。不是空快照或AX故障。
- 修复：NotesView书签按钮label仅补contentShape(Rectangle())，让Spacer空白也参与命中。MCP构建成功PID19405；seq1203同一卡片中央x201/y288点击后wait(reader.bookmark,value:已加书签)实际SUCCEEDED，reader.toc=第二章宿主桥接、reader.progress=第2/5节、reader.percent=全书41%。117-bookmark-center-return-fixed.png。通过。
- 已验证导出：MD/HTML均包含该非零书签，章名和数量与只读来源一致；内容9断言true，118/119原图。通过。
- 清理：仅UI移除本轮书签，reader.bookmark=未加书签；磁盘bookmarks=0、highlights=42、notes=18，SHA256恢复0fd3cd5c0bdf45fd5678631dd6dff5b37e1ad3dd353f52b54f308c87b8f0aae3，与添加前完全相同。120-bookmark-cleaned.png；work/bookmark-cleanup-evidence.json passed=true。通过。
- 工具记录：一次错误复用切页前e76，新快照该ref已指向高亮文字，误打开阅读器；立即关闭，后续每步重新取ref，未修改内容。一次等待“暂无书签”超时，实际空状态文案为“读到一半想标记，点书签按钮，就会收在这里。”，改为实际label断言成功。不当作应用故障。
- 证据：work/bookmark-mcp-evidence.json、work/notes-export-content-evidence.json、work/bookmark-cleanup-evidence.json；git diff --check通过，无新增/重构XCTest。
- 待验证：本闭环范围内无剩余；继续书内搜索。
- 未验证：书签多章/多本组合、书签列表最大字号、独立VoiceOver、小屏/iPad/真机/发布；朗读排除，整体active。

## 闭环23：书内搜索反馈、导航、清除与最大字号
- 范围：合成“书灯测试样书”，数字00000999零匹配、Swift三处匹配；现有书内检索能力不变，无AI/Key访问、无XCTest。
- 复现：真正点击软件键盘“搜索”后seq1296输入值00000999仍显示“输入关键词后回车，会跳到第一处并高亮。”；124-reader-zero-real-submit-before.png。此前SQLite真正提交已有1/1结果，证明书内检索引擎能完成；早期Return仅提交拼音候选的121/122/123/127图不作为搜索提交成功或失败证据。
- 修复：ReaderScreen以idle/searching/complete/failed区分输入、加载、零匹配和失败；结果有标识，首尾导航按钮禁用，并使用borderless保证同行按钮独立触发；搜索面板medium/large可扩展。Swift请求id与reader模板事件对应，清除/编辑后旧完成与错误不能覆盖当前状态；每次检索局部收集结果，代次匹配后才替换当前结果。
- 正式来源：packages/app-expo/assets/reader/reader.template.html及其生成reader.html；node scripts/build-reader.js→node ../app-ios/scripts/sync-app-assets.mjs完成重新生成/同步。最初修改的是被忽略的iOS资源，已将同一搜索改动落回正式模板并重建，不保留生成物专属修复。
- 已验证默认零匹配：seq1325 reader.searchField=00000999，reader.searchEmpty=没有找到匹配的正文，试试其他关键词。通过；126-reader-zero-final.png。
- 已验证真实导航：seq1343 reader.searchResult=结果,1/3；seq1345/1347点击下一个为2/3、3/3，末项reader.searchNext不再是可操作target；seq1349/1351点击上一个回2/3、1/3，首项reader.searchPrevious不再是可操作target。128-reader-swift-results-final.png、129-reader-search-last.png、130-reader-search-first.png。通过；截图确认灰色禁用按钮与各自独立点击。
- 已验证最大字号/最终构建：PID22548，seq1369零匹配完整反馈；133-reader-zero-ax5-final.png。seq1383 Swift=结果,2/3，reader.searchPrevious/reader.searchNext均可点击；135-reader-search-ax5-navigation.png，人工确认计数纵排、两个按钮完整无裁切。通过；已恢复large。
- 已验证关闭/重新打开/清除：seq1387默认字号回1/3，完成后第二章全书41%、正文Swift真实高亮；136-reader-search-return-match.png。seq1392重新打开保留1/3；seq1394清除后reader.searchField=书内搜索、结果/导航消失、初始提示恢复。关闭后137-reader-search-clear-return.png确认Swift搜索框线消失，原查询/JSON/文件/存在黄色高亮仍在，reader.progress=第2/5节、reader.percent=全书41%。通过。
- 代码级验证：work/verify-reader-search-state.mjs执行真实模板函数，12断言通过，覆盖零结果、分组计数、第一/下一处、旧检索隔离、清除后无响应/导航、旧错误隔离；work/reader-search-state-evidence.json。函数验证不替代上述MCP实测，也不声明UI真实搜索异常已经复现。
- 证据：work/reader-search-mcp-evidence.json含最终构建和原始步骤；126/128-137为simctl原图。一次137原图命令自动权限审核超时，原返回“The automatic permission approval review did not finish before its deadline…You may retry once”；按提示重试一次成功。没有空快照/AX故障或旧驱动兜底。
- 验证命令：node scripts/build-reader.js、node ../app-ios/scripts/sync-app-assets.mjs、node work/verify-reader-search-state.mjs、git diff --check均成功；没有新增/重构XCTest。
- 待验证：书内搜索真实运行时异常提示/重试，用户快速连续操作的端到端竞态；继续其余原有功能验收，整体active。
- 未验证：以上真实异常/竞态、超长书检索耗时、Expo端UI、独立VoiceOver、小屏/iPad/真机/发布；本轮没有AI请求，朗读排除。
- 收尾复核当前构建：chat.search不存在；唯一文本字段value=搜索对话，chat.sort=分组排序、chat.newThread=新对话均存在，3项MCP断言SUCCEEDED；138-chat-single-search-final.png人工确认左上角无重复图标、标题和右侧操作无重叠。work/root-final-single-search-evidence.json保留原始返回。设备content_size实际large，当前前台对话页，深色保留；git diff --check通过。

## 闭环24：英文端侧语义检索与书架输入焦点
- 范围：仅既有合成Shudeng Test Book建索引、attention/database检索与回原文；不触发朗读，不访问Key，不发AI请求。
- 当前语言边界：seq1409 vector.status=端侧向量模型可用（只支持英文内容）；model=apple-nl-word-en、300维；vector.probe说明zh-Hans句/词向量无、上下文512维未下载。139-vector-current-language-boundary.png。中文成功仍未验证，不用英文结果代替。
- 已验证索引：UI长按英文样书→建立语义索引；按钮实际“Shudeng Test Book，Shudeng，未读，已建语义索引”。140-english-index-built.png。当前readany_local.db有ui-test-sample-en出处apple-nl-word-en、300维，5章/5向量；4独立数据断言全部true，work/semantic-source-evidence.json。
- 实际复现输入焦点：连续点击搜索框再MCP type_text，工具返回SUCCEEDED但实际field仍placeholder、键盘消失，seq1465及145-library-search-focus-before.png；没有旧XCTest进程。原因是ScrollView.simultaneousGesture同一点击末尾写searchFocused=false，覆盖TextField焦点。修改仅将取消焦点手势放到背景，保留scrollDismissesKeyboard和onSubmit。
- 已验证修复：MCP构建成功PID25353；同一0.15秒触摸后attention精确value断言SUCCEEDED、首位真实命中Chapter Three — Investing in Time。146-attention-search-after-focus-fix.png。再次清空→点击→输入database，value精确通过，首位Chapter Two — The Host Bridge。148-semantic-repeat-input-scroll.png。没有IME组合文本冒充正确输入。
- 已验证回原文：点击attention首位命中，reader.toc=Shudeng Test Book, Chapter Three — Investing in Time；reader.progress=第3/5节、reader.percent=全书61%；147-attention-return-original.png正文包含“Reading is an investment of attention…”。通过。
- 工具/取证修正：最初独立脚本把1200个存储字节当作维度，误报2断言false；db-core.ts实际序列化Float32并以JSON字节数组保存。按真实格式解码后每条300维、范数0.999999996至1.000000002，4断言true；错误验收报告保留work/semantic-source-byte-parsing-before.json，不当作应用缺陷。
- 工具记录：两次swipe(e26)返回SUCCEEDED但keyboard.delete仍存在，等待gone原WAIT_TIMEOUT，148图确认键盘仍在；不声明滚动收键盘通过。Return第一下只提交拼音候选，第二下执行onSubmit，keyboard.delete消失。当前未回退XCTest，无空快照或AX故障。
- 补验：PID28510及30178重启后均有“已建语义索引”；seq1562英文样书仍带索引标记，attention检索实际返回第三章。UI删除本轮索引后chunks/provenance均0，原42高亮/18笔记/0书签SHA恢复一致，outputs/evidence/semantic-cleanup-evidence.json三断言true。
- 待验证：本闭环英文建立/检索/跨进程/清理范围无剩余；段落预览与布局见闭环25。
- 未验证：中文资源/成功、检索质量全量评估、搜索运行时失败与快速连续操作、空白背景点按收键盘、滚动收键盘、小屏/iPad/VoiceOver/真机/发布。整体active。

## 闭环25：语义结果预览、回原文与最大字号
- 范围：仅现有语义结果显示/回跳、零匹配反馈、搜索键文案；无新能力、无向量排序/阈值改动，无AI/Key访问、无XCTest。
- 复现：148-semantic-repeat-input-scroll.png中metadata已有第二章，预览又从章名开始，前三行看不到database命中段；SemanticHit.jumpText取chunk第一行（章名），导致回跳也使用章名。155-semantic-ax5-before.png确认固定1行章节名被截断。
- 修复：LibraryStore.SemanticHit.snippet(matching:)在真实原文里排除重复章名，字面匹配优先、否则首正文段；预览和pendingSnippet调用同一方法。LibraryView新增library.semanticEmpty反馈及submitLabel(.search)，辅助字号metadata允许换行，预览保持3行上限。
- 已验证实际预览：seq1538仅正文text为“The database is SQLite owned by the host, and the core talks to it through a small synchronous bridge.”；152-semantic-database-preview-final.png章名未重复，SQLite段完整可见。通过。
- 已验证回原文：seq1540 reader.toc=Shudeng Test Book, Chapter Two — The Host Bridge，reader.progress=第2/5节、reader.percent=全书44%；153-semantic-database-return-final.png可见同一SQLite段。最终构建attention命中打开reader.toc=Chapter Three — Investing in Time。通过；不声称跳转正文顶边的像素位置已验证。
- 已验证零匹配：seq1552 library.searchField实际00000999，library.semanticHit=0，library.semanticEmpty=没有找到匹配的段落，试试其他关键词。154-semantic-zero-final.png。通过。更早一次replaceExisting返回成功但实际database00000999，只作工具取证；随后明确清空并重新输入，最终纯数字断言通过。
- 已验证搜索键：seq1527 keyboard target e182 label=搜索，id=Search；此前为换行/Return。本次后半段软件键盘未显示，未额外宣称新提交/滚动收键盘通过。
- 已验证最大字号：最终构建PID30178，seq1566第一项Chapter Three — Investing in Time；156-semantic-ax5-final.png完整章名换行、书名可辨、预览无重叠，预览仍按3行省略。已恢复large。通过。
- 清理：UI只删除本轮英文索引，seq1577英文样书无已建索引标记；157-semantic-index-cleaned.png。只读核对chunks=0/provenance=0、42高亮/18笔记/0书签；SHA256=0fd3cd5c0bdf45fd5678631dd6dff5b37e1ad3dd353f52b54f308c87b8f0aae3，和清理前基准一致，三断言true。
- 最终复核：seq1579 chat.search不存在，唯一文本框value=搜索对话；chat.sort=分组排序、chat.newThread=新对话，158-chat-single-search-final.png。通过。
- 工具记录：一次宽泛textContains原返回“The wait selector matched multiple runtime UI elements.”（button和text都匹配），改role:text。其后一次5000ms exists超时，等待期树出现数字空状态、同刻151-foreground-changed-to-profile.png为我的页，状态变化来源未确认；恢复书架后seq1538精确正文断言通过。不归因AX/设备故障，没有空快照或旧驱动兜底。
- 证据：outputs/evidence/semantic-layout-mcp-evidence.json保留最终构建/全部原始步骤；8项机器断言+1项原图人工布局断言均true。work/semantic-focus-full-evidence.json保留闭环24完整过程；4项向量来源断言在outputs/evidence/semantic-source-evidence.json。git diff --check通过。
- 待验证：本闭环展示/回原文/空状态/最大字号/清理范围无剩余；整体产品目标active，未提交/发布。
- 未验证：中文语义成功（设备仅英文300维可用）、语义检索真实运行时异常/重试、快速连续操作端到端竞态、语义质量全量评估、空白点击/滚动收键盘、VoiceOver/小屏/iPad/真机/发布。朗读排除。


## 闭环26：笔记草稿跨进程与真实文件故障恢复
- 范围：合成样书两条原空笔记；按bookId/cfi独立原子保存未提交草稿，不自动提交正式笔记，不发AI、不触及Key，无XCTest。
- 复现：未保存26261011终止/重启后回到想法…；160-note-unsaved-before-kill.png、161-note-unsaved-lost-after-kill.png。
- 修复：Core/NoteDrafts.swift保存基线与草稿；两编辑器恢复/明确放弃/保存后清理；正式内容变更时不恢复旧草稿；删书与删标注清理关联草稿，失败给中文反馈。
- 已验证列表：重启恢复notes.editor=26261011，note.draftRestored=已恢复未保存的内容；显式保存列表出现26261011，磁盘草稿清除；27271011明确放弃后重开为想法…。163/165原图、note-draft-before-save-source.json。
- 已验证真实故障：完整备份草稿目录后用文件阻塞目录写入，notes.editor=27271011保留，note.draftError=草稿暂时无法保留，离开前请保存笔记。撤销故障后同一编辑器保存，列表出现27271011且草稿清除；166-note-real-draft-failure-final.png、167-note-draft-failure-recovered.png。164不是有效故障证据。
- 清理：仅SQL恢复本轮两条合成note字段，原值由基准SHA匹配后更新；没有声称UI删除通过。42高亮/18笔记/0书签，SHA恢复0fd3cd5c0bdf45fd5678631dd6dff5b37e1ad3dd353f52b54f308c87b8f0aae3，草稿0/故障备份不存在。重启后seq1721列表无两个测试值；168-note-test-content-cleaned.png。
- 代码验证：现有reader-note-state 5 checks、草稿独立进程/中文多行/基线隔离/清理/真实读写失败12 checks；notes-persistence扩充关联删除后13 checks通过；MCP最终构建9.4秒/PID42645，git diff --check通过。
- 原始证据：outputs/evidence/note-draft-mcp-evidence.json；8项UI实际断言在note-draft-ui-assertions.json；来源/清理断言分别note-draft-saved-source.json、note-draft-cleanup-evidence.json。所有引用图片在outputs/evidence。
- 工具记录：tap(e76)返回SUCCEEDED但仍书架、wait(notes.export)6000ms原WAIT_TIMEOUT；新快照同一tab改touch(delay0.15)成功，149元素/46 targets。非空编辑器type_text多次返回成功但实际值未变；本轮故障验证采用空白笔记。无空快照/旧驱动。
- 待验证：阅读器草稿跨进程UI恢复/保存/放弃正在补验；整体目标active，未提交/发布。
- 未验证：自动聚焦、草稿清理/损坏错误的UI、真实系统强杀（目前MCP终止）、其他设备/VoiceOver；朗读排除。


## 闭环27：阅读器草稿恢复、放弃、显式保存与UI清理
- 范围：合成样书第二章长按“数据”；28281011未提交草稿、29291011本轮新增笔记。全程MCP，无XCTest、AI或Key访问。
- 已验证跨进程：seq1739 reader.noteEditor=28281011；MCP stop/launch后同一选文重开seq1749仍28281011。原图169-reader-unsaved-before-restart.png、170-reader-draft-restored.png。
- 实际复现/修复：重启恢复值已正确但原文与恢复提示首次没有渲染，wait(note.draftRestored)2500ms原WAIT_TIMEOUT；将恢复初始化同步放入阅读器弹层onAppear。最终seq1763 reader.noteOriginal=数据、reader.noteEditor=28281011、note.draftRestored=已恢复未保存的内容；171-reader-draft-restoration-notice-final.png。通过。
- 已验证明确放弃：点击note.cancel→note.discard后编辑器关闭；同一选文重开reader.noteEditor=想法…；未保存28281011未形成标注。172-reader-draft-discarded.png。通过。
- 已验证保存：实际新输入29291011，点击reader.noteSave后关闭；seq1779列表存在“第二章 宿主桥接, 10/11, 数据, 29291011”。只读DB唯一id=hl-1791685897535-e8f2/book_id=ui-test-sample/text=数据/note=29291011；43高亮/19笔记且草稿0。173/174原图，reader-note-saved-source.json三断言true。
- 已验证清理：只对本轮新建行左滑→最新删除按钮→touch；seq1788 gone(text:29291011)通过。只读来源恢复42高亮/18笔记/0书签，SHA=0fd3cd5c0bdf45fd5678631dd6dff5b37e1ad3dd353f52b54f308c87b8f0aae3，草稿0；reader-note-cleanup-source.json三断言true，175-reader-note-ui-cleaned.png。没有删除旧高亮。
- 代码验证：最终构建15.2秒/PID43713；现有reader-note-state 5 checks通过，关联删除13 checks仍为本轮已通过证据，git diff --check通过。没有新增/重构XCTest。
- 工具记录：MCP structured capture部分漏列弹层工具栏，而同一次content文本包含最新note.cancel/reader.noteSave refs；按该最新snapshot文本refs操作成功。空字段初次type_text返回成功但实际想法…，显式touch(0.15)聚焦后实际值通过；不宣称自动聚焦通过。左滑第一步只收起编辑操作，第二步才暴露删除，均用刷新refs。无空快照或旧驱动。
- 证据：outputs/evidence/reader-note-draft-mcp-evidence.json、reader-note-draft-ui-assertions.json（9项实际UI断言）；169–175为simctl原图。
- 待验证：本轮草稿生命周期范围内无剩余；整体继续真实异常恢复验收，active、未提交/发布。
- 未验证：自动聚焦、已保存非空笔记输入修改、草稿损坏/清理失败UI、真实系统强杀/真机/VoiceOver；朗读排除。


## 闭环28：语义搜索真实读取失败与同页恢复
- 范围：仅本轮新建ui-test-sample-en英文5章索引；database搜索与00000999零匹配，未发AI、不读Key、无XCTest。
- 实际复现：`node work/semantic-db-fault.mjs apply`备份本轮本地索引后执行`ALTER TABLE vector_index_provenance RENAME TO ux_acceptance_provenance_hold;`，SQL原返回`Parse error in 3rd command line argument: no such table: vector_index_provenance`/exit1。seq1807 library.searchField=database，却显示library.semanticEmpty=没有找到匹配的段落，试试其他关键词。原图176-semantic-read-failure-hidden-before.png。
- 已确认原因：app-bootstrap.js semanticSearch→availableIndexByBook→core.db.getAvailableVectorIndexProvenances在逐书try/catch外读取来源表；RuntimeHost.callAsync把拒绝转成error JSON，LibraryStore.searchSemantics解码Response失败后清空两数组却不记录失败，UI把它当零结果。
- 修复：LibraryStore独立semanticError；无效/失败响应显示“段落搜索暂时失败，书籍和索引已保留，请重试。”；LibraryView保留当前关键词提供同页重试。新请求/清空清除旧错误，原代次继续隔离过时回调；不改变向量模型、检索阈值或索引数据。
- 已验证最终故障：seq1815 library.semanticError为上述中文，library.semanticRetry=重试；故障仍在时点击后seq1816错误仍可见，没有退回零匹配。177-semantic-read-error-final.png。通过。
- 已验证恢复：立即`node work/semantic-db-fault.mjs restore`恢复原表名，索引内容SHA前后ea82adf7006e649812582982804d13c4d9058f17ac811aa861efbb9a5dc59469一致。保持database，点击同一重试；seq1818 library.semanticHit实际“The database is SQLite owned by the host…”/Chapter Two — The Host Bridge，semanticError消失。178-semantic-same-query-recovered.png。通过。
- 已验证合法零匹配：清空重输00000999，seq1824精确值通过；library.semanticEmpty正确且semanticError不存在。179-semantic-valid-zero-after-recovery.png。
- 清理：UI删除本轮新建英文索引；chunks=0/provenance=0/faultTable=0；原42高亮/18笔记/0书签SHA不变、草稿0。180-semantic-error-test-cleaned.png；semantic-error-cleanup-source.json、reader-note-cleanup-source.json均true。所有临时故障已撤销。
- 代码验证：MCP构建13.5秒通过；生产方法函数回归scripts/test-semantic-search-state.mjs 9 checks通过（失败/无效响应/重试/零匹配/逐书失败/旧失败/清空），git diff --check通过。首次验收函数编译漏-parse-as-library已修正，属于验收脚本问题。
- 证据：outputs/evidence/semantic-search-error-mcp-evidence.json保留原始返回；semantic-search-error-ui-assertions.json共11实际断言（2复现、9最终行为）全部true；semantic-db-fault-restoration.json保留故障时间/SQL/原报错/前后SHA。截图均simctl原图。
- 待验证：本闭环全局语义搜索读取失败/重试/恢复范围内无剩余；继续书内搜索异常与逐书错误恢复。整体active，未提交/发布。
- 未验证：中文语义成功、单书索引不兼容UI、真实快速输入竞态、超长书搜索、VoiceOver/真机/其他设备/发布；朗读排除。


## 闭环29：单书语义索引不可用的定位与UI重建恢复
- 范围：本轮新建英文合成5章索引；将唯一ui-test-sample-en来源model_id暂改ux-acceptance-missing-model，使实际nativeEmbed报系统语言模型不可用。不发AI、不访问Key、无XCTest。
- 复现：seq1841只显示“这本书的索引要重建：这本书使用的系统语言模型暂不可用，请稍后重试”，没有书名/恢复操作，database过滤后也没有可长按的书封。181-semantic-book-error-before.png；原表值立即恢复的校验在semantic-book-model-fault-restored.json。
- 修复：错误指向具体书名，说明原书和笔记保留，并复用既有重建能力；按钮标签最小44pt、原生bordered风格，与全局重试一致。索引集合或建索引状态变化触发同一当前关键词检索，修复同一本书重建后count不变导致旧错误留在页面的问题。
- 已验证最终错误：seq1849 library.searchField=database，library.semanticBookError=《Shudeng Test Book》的索引暂时无法使用。，library.semanticRebuild=重建索引。182-semantic-book-recovery-action-final.png人工确认文案完整、按钮清楚、未重叠。
- 已验证真实UI恢复：点击该重建按钮，不改关键词、不手动恢复模型字段；seq1851 database仍在，library.semanticHit第一项Chapter Two — The Host Bridge/The database is SQLite owned by the host…，逐书错误消失。183-semantic-book-ui-rebuilt-search-recovered.png。只读来源apple-nl-word-en/300维/5章，created_at=1791687646288；semantic-book-model-rebuilt-source.json true。
- 清理：UI只删本轮英文索引；chunks/provenance/faultTable均0，42高亮/18笔记/0书签，原SHA=0fd3cd5c0bdf45fd5678631dd6dff5b37e1ad3dd353f52b54f308c87b8f0aae3。184-semantic-book-error-test-cleaned.png、semantic-book-error-cleanup-source.json true。临时模型故障已由真实重建清除。
- 代码验证：MCP构建10.4秒/PID48106；9项semantic-search-state函数回归及git diff --check通过。全局重试本次只改按钮样式/标签命中区，逻辑仍为闭环28已验证路径，未重复整套失败注入。
- 工具记录：首次long_press原报SNAPSHOT_EXPIRED，刷新snapshot后重试成功；无空快照/旧驱动。原始MCP返回semantic-book-error-mcp-evidence.json，7项最终实际断言semantic-book-error-ui-assertions.json全true；181–184均simctl原图。
- 待验证：本轮单书不可用/书名定位/同页重建自动恢复范围内无剩余；继续书内检索异常、实际快速操作及整体验收。active、未提交/发布。
- 未验证：多书同时失败、重建过程中失败/取消的本轮UI、中文语义成功、全局重试新样式故障原图、VoiceOver/其他设备/真机/发布；朗读排除。


## 闭环30：书内搜索异常恢复（UI验收暂缓）
- 范围：检索枚举失败、第一处/下一处定位失败的持久错误与同页重试；不发AI、不访问Key、无新增XCTest。
- 已复现：旧构建真实Swift结果1/3，临时撤除实际foliate-view.goTo后点击下一个仍1/3，无持久错误或重试。185-reader-navigation-failure-hidden-before.png是有效原图；恢复真实方法后同一操作达到2/3，原始日志reader-search-fault-before-logs.txt。故障已撤销。
- 修复：搜索/定位错误分别携带context与requestId，定位失败保留结果和失败index；搜索与跳转提供各自中文错误/重试，正在定位禁用导航；内部index仅成功后更新，旧请求错误继续隔离。
- 已验证：正式模板生成→iOS资源同步成功；MCP build_run_sim 11.9秒/PID52286通过；真实生产JS函数21项检查通过（检索失败/重试、首处与下一处失败/重试、旧错误隔离），git diff --check通过。尚不能据此声明真实UI恢复通过。
- UI取证：当前Swift精确输入值存在，但MCP Return未提交、没有reader.searchResult；两次wait(exists)原WAIT_TIMEOUT（12000/6000ms），快照非空234/214元素，状态截图为隐藏软件键盘的输入界面。此为工具输入probe，不作应用检索故障证据。随后用户要求涉及键盘的先不测，停止相关操作。
- 证据：outputs/evidence/reader-search-recovery-partial.json、reader-search-recovery-state-evidence.json；有效复现截图185。没有旧驱动回退。
- 待验证：真实检索失败/导航失败的中文提示、连续重试、同页成功恢复；按用户要求暂缓涉及输入的UI验收，转向无需键盘的索引失败/恢复。
- 未验证：以上真实恢复、快速输入竞态、最大字号新错误排版、其他设备/VoiceOver/真机/发布；朗读排除，整体active。

## 闭环31：建立索引真实文件失败、连续重试与同页恢复
- 范围：只对合成ui-test-sample-en文件临时重命名；无需键盘输入，无AI/Key访问、无XCTest。
- 复现：node work/semantic-build-file-fault.mjs apply，UI建立语义索引后原文“《Shudeng Test Book》建索引失败：文件操作失败: 文件不存在: /Users/.../Documents/books/ui-test-sample-en.epub”，无直接重试；186-semantic-build-missing-file-before.png。故障随后restore，文件SHA恢复一致。
- 原因/修复：LibraryStore buildIndex回调和pollIndexStatus都直接拼接底层message，LibraryView.notices仅Text。两处统一记录具体失败书籍并转换文件/语言模型/其他失败提示，提供同页重试；新任务清理旧失败、旧代次不回写，删书/删除对应索引清理失败目标。
- 已验证失败：library.indexError=《Shudeng Test Book》无法读取书籍文件，请确认文件可用后重试。已保存的笔记不受影响。；library.retryIndexBuild=重试建立索引。187原图确认两行说明与按钮，无内部路径；故障仍在时点重试后错误及按钮仍在。通过。
- 已验证恢复：立即restore原文件，再点同一重试，library.book含Shudeng Test Book，Shudeng，已读 61%，已建语义索引，错误/重试消失。188原图；只读DB确认唯一apple-nl-word-en/300维/5章，真实构建。通过。
- 已验证清理：UI删除仅本轮新建英文索引，chunks=0/provenance=0、heldFile=false；原42高亮/18笔记/0书签SHA仍0fd3cd5c0bdf45fd5678631dd6dff5b37e1ad3dd353f52b54f308c87b8f0aae3，草稿0。189原图、semantic-build-recovery-cleanup.json true。
- 验证：MCP build_run_sim12.9秒/PID55780；既有test-index-task-state.mjs直接编译Foundation函数8场景/45检查通过（没有XCTest），git diff --check通过。7项实际UI断言全true。
- 证据：outputs/semantic-build-recovery.md及outputs/evidence/semantic-build-recovery-mcp-evidence.json、semantic-build-recovery-ui-assertions.json、semantic-build-retry-source.json、semantic-build-file-fault-restoration.json、semantic-build-recovery-cleanup.json。186–189均simctl原PNG。
- 工具：long_press一次返回成功但快照未settle提示，按提示刷新成功；全程快照非空，无旧驱动回退。后续不再测试键盘输入；此前Device Hub的CUA请求未获批准，未改变设置。
- 待验证：本闭环文件失败/连续重试/同页真实恢复范围无剩余；搜索真实UI恢复按用户要求暂缓。整体active，未提交/发布。
- 未验证：新错误最大字号、中文语言模型成功、多书同时失败、索引运行中失败/取消、VoiceOver/其他设备/真机/发布；朗读排除。
- 关联验证补充：test-index-persistence.mjs抽取的真实方法新增依赖同步后，原持久化/删除失败/重试检查仍通过；保持Foundation函数验证，未启动模拟器测试驱动。

## 闭环32：最大字号书籍卡片命中、索引模型失败与重试对比度
- 范围：现有合成中文/英文样书；最大辅助功能字号的卡片长按、原生菜单、真实中文模型失败提示/连续重试、另一书籍建索引和清理；无键盘输入、AI/Key访问或XCTest。
- 复现：MCP long_press(1000ms)在普通字号出现菜单，最大字号卡片中央x188/y377却打开阅读器，reader.close存在、建立语义索引菜单不存在；191-library-max-long-press-before.png。首次错点settings的工具probe已关闭，不当作应用设置缺陷，未改设置值。
- 修复/验证：LibraryView书籍label仅加contentShape(Rectangle())；修后最大字号同一长按出现开始阅读/建立语义索引/从书库删除，reader.close不存在；192-library-max-context-menu-after.png。最终构建重复该操作仍通过。初始命中假设已由单行修复前后真实行为确认。
- 真实模型失败：最大字号library.indexError=《书灯测试样书》系统语言模型暂时无法处理这本书，请稍后重试。已保存的笔记不受影响。；library.retryIndexBuild=重试建立索引，enabled谓词SUCCEEDED；连续点击后失败说明与可用按钮保留。190为修前灰色按钮，193为最终primary文字，无截断；未把中文模型失败冒充成功。
- 对比度修复：notices外层foregroundStyle(.secondary)被新重试按钮继承；仅在该按钮覆盖foregroundStyle(.primary)。193原PNG确认可用按钮黑色文字清楚。
- 后续任务验证：滚动后长按英文样书，真实建立apple-nl-word-en/300维/5章索引；library.book含已建语义索引，旧错误/重试消失。194-library-max-other-book-success.png及index-accessibility-source.json passed=true。
- 清理：UI仅删除本轮英文索引；chunks=0/provenance=0，原42高亮/18笔记/0书签SHA仍0fd3cd5c0bdf45fd5678631dd6dff5b37e1ad3dd353f52b54f308c87b8f0aae3，草稿0；字号恢复large。195-library-default-after-cleanup.png、index-accessibility-cleanup.json true。系统本轮开始已是light，保持该现状，没有按旧记录强改dark。
- 验证：最终MCP构建11.6秒/PID64326、8项实际UI断言全true、git diff --check通过；未为低影响命中/颜色修改新增测试。
- 证据：outputs/index-accessibility-acceptance.md、index-accessibility-mcp-evidence.json、index-accessibility-ui-assertions.json、index-accessibility-source.json、index-accessibility-cleanup.json；190–195均simctl原PNG。
- 工具：全程快照非空，没有回退旧驱动；最初失效长按由恢复普通字号对照后定位卡片命中，而非AX占用。一次校验误传旧脚本verify参数原返回apply/restore/rebuilt required，随后新独立只读查询通过，不作产品失败。
- 待验证：本闭环范围内无剩余；继续同页AI网络失败恢复/主流程验收。涉及键盘的搜索真实UI恢复仍按用户要求暂缓。整体active，未提交/发布。
- 未验证：中文语义成功、多书同时失败、索引运行中失败/取消、VoiceOver/其他设备/真机/发布；朗读排除。

## 交接停点：闭环33未完成，用户要求本地拆分提交并暂停
- 时间：2026-10-11 15:20（北京时间）。范围为无需键盘的本周报告真实网络中断恢复；全4本均为合成样书，未读取/显示/修改真实Key。
- 实际操作：在StreamBridge.swift:57已解析断点暂停真实请求，LLDB执行`expression -- task.cancel()`，随后`breakpoint delete 1`及debug_detach均成功。没有改源码、没有伪造响应。
- 实际结果：wait_for_ui(exists, report.aiError, 10000ms)原返回WAIT_TIMEOUT；同次非空快照seq99/count106显示report.aiRegenerate=重新生成，以及真实新正文“这周连续5天阅读、总时长5小时，最长一次128分钟，专注力有亮点…”。取消首个网络任务未得到期望的错误状态，最终请求真实成功；不得宣称已验证同页失败后重试。
- 截图：outputs/evidence/196-report-before-network-interruption.png、197-report-after-cancel-auto-retry.png；原始工具返回：outputs/evidence/report-network-partial-handoff.json。
- 已验证：断点删除、debugger detached；本轮没有启用XCTest/live驱动。没有残留网络故障或临时配置覆盖。
- 待验证/未验证：重新生成真实失败后保留旧解读及同页成功恢复、同页翻译网络恢复；书内搜索异常UI/快速输入按用户要求暂缓。中文模型成功、多书失败、索引运行中失败/取消、VoiceOver/其他设备/真机/发布仍未验证；朗读排除。
- 交接：将现有生产改动按布局/笔记/AI报告翻译/搜索索引拆分提交，交接记录另提交；不push、不发布，提交后目标paused，停手等待omo。
