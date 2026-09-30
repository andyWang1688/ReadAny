// SPDX-License-Identifier: GPL-3.0-or-later
// 书灯 iOS 宿主 glue：把 Swift 注入的原语包成 core 需要的 IPlatformService，并暴露 App 级 API。
// 必须在 core.js 之后加载。
(() => {
  const core = globalThis.ReadAnyCore;
  if (!core) throw new Error("app-bootstrap.js 必须在 core.js 之后加载");

  const services = core.services;
  if (!services || typeof services.setPlatformService !== "function") {
    throw new Error("core bundle 没有导出 services，检查 scripts/core-entry.ts");
  }

  const paths = JSON.parse(__nativePaths());

  function hostFs(op, path, payload) {
    const raw = __nativeFs(op, String(path), payload == null ? "" : String(payload));
    const result = JSON.parse(raw || "{}");
    if (result.error) throw new Error(result.error);
    return result;
  }

  function hostKv(op, key, value) {
    const result = JSON.parse(
      __nativeKv(op, String(key), value == null ? "" : String(value)) || "{}",
    );
    if (result.error) throw new Error(result.error);
    return result;
  }

  const notSupported = (what) => () => {
    throw new Error(`${what} 在书灯 iOS 宿主里还没实现`);
  };

  // core 的 builtin skills 只有英文文案；书灯只留中 / 英，这里补一份中文名和说明。
  // needsInput 的技能（要指定概念 / 人物 / 术语）用输入框里那段文字当第一个必填参数。
  const SKILL_TEXT = {
    zh: {
      summarizer: { name: "智能摘要", desc: "总结本章讲了什么" },
      "concept-explainer": { name: "概念解释", desc: "讲清一个概念或抽象说法", needsInput: "要解释的概念" },
      "argument-analyzer": { name: "论证分析", desc: "拆出论点、论据和逻辑跳步" },
      "character-tracker": { name: "人物追踪", desc: "梳理人物关系与出场线索", needsInput: "要追踪的人物" },
      "quote-collector": { name: "金句收集", desc: "挑出值得抄下来的句子" },
      "reading-guide": { name: "阅读引导", desc: "带着问题读这一章" },
      translator: { name: "翻译助手", desc: "把这段译成另一种语言", needsInput: "要翻译的段落" },
      "vocabulary-helper": { name: "术语助手", desc: "讲一个词在书里的意思", needsInput: "要查的词" },
    },
    en: {
      summarizer: { name: "Smart Summary", desc: "Summarize this chapter" },
      "concept-explainer": { name: "Concept Explainer", desc: "Explain a concept", needsInput: "Concept" },
      "argument-analyzer": { name: "Argument Analyzer", desc: "Break down the argument" },
      "character-tracker": { name: "Character Tracker", desc: "Track characters", needsInput: "Character" },
      "quote-collector": { name: "Quote Collector", desc: "Collect quotable lines" },
      "reading-guide": { name: "Reading Guide", desc: "Guide me through this chapter" },
      translator: { name: "Translator", desc: "Translate this passage", needsInput: "Passage" },
      "vocabulary-helper": { name: "Vocabulary", desc: "Explain a term", needsInput: "Term" },
    },
  };

  /// 给模型的思维导图指令：只要 Markdown 大纲，界面自己画成导图。
  const MINDMAP_PROMPT = [
    "你是阅读思维导图助手。根据用户给出的书籍内容生成一张思维导图。",
    "只输出 Markdown 大纲，不要任何解释、前言或代码块：",
    "# 主题",
    "## 一级分支",
    "### 二级分支",
    "- 叶子要点",
    "要求：3-6 个一级分支；叶子用短句；最多 4 层；语言跟内容一致（中文内容用中文）。",
  ].join("\n");

  function openDatabase(path) {
    // Uint8Array / ArrayBuffer 参数（chunk embedding）没法走 JSON：直接丢过去宿主只会
    // bind NULL，向量被静默丢掉。统一转成「JSON 字节数组字符串」——core 的
    // deserializeEmbedding 认这种持久化形态（桌面 Tauri 插件就是这个行为）。
    const encodeParam = (value) => {
      if (value instanceof Uint8Array) return JSON.stringify(Array.from(value));
      if (value instanceof ArrayBuffer) return JSON.stringify(Array.from(new Uint8Array(value)));
      return value;
    };
    const query = (sql, params) => {
      const raw = __nativeDbQuery(
        String(path),
        String(sql),
        JSON.stringify((params || []).map(encodeParam)),
      );
      const result = JSON.parse(raw || "{}");
      if (result.error) throw new Error(result.error);
      return result.rows || [];
    };
    return {
      async execute(sql, params) {
        query(sql, params);
      },
      async select(sql, params) {
        return query(sql, params);
      },
      async close() {
        __nativeDbClose(String(path));
      },
    };
  }

  /// 文件内容指纹（导入去重用）。宿主没提供原语时退化成空，导入照常走。
  function readFileDigest(path) {
    if (!path || typeof __nativeFileDigest !== "function") return {};
    try {
      const raw = JSON.parse(__nativeFileDigest(String(path)) || "{}");
      return raw.error ? {} : raw;
    } catch (error) {
      console.warn("file digest failed:", error);
      return {};
    }
  }

  const platform = {
    platformType: "mobile",
    isMobile: true,
    isDesktop: false,

    async getLocale() {
      return paths.locale || "zh-CN";
    },

    // ---- 文件系统 ----
    async readFile(path) {
      return globalThis.__b64.decode(hostFs("read", path).base64 || "");
    },
    async writeFile(path, data) {
      hostFs("write", path, globalThis.__b64.encode(data));
    },
    async readTextFile(path) {
      return hostFs("readText", path).text || "";
    },
    async writeTextFile(path, content) {
      hostFs("writeText", path, content);
    },
    async mkdir(path) {
      hostFs("mkdir", path);
    },
    async exists(path) {
      return Boolean(hostFs("exists", path).exists);
    },
    async deleteFile(path) {
      hostFs("delete", path);
    },
    async getAppDataDir() {
      return paths.appData;
    },
    async getDataDir() {
      return paths.appData;
    },
    async joinPath(...parts) {
      const joined = parts
        .filter((part) => part != null && part !== "")
        .map((part, index) =>
          index === 0 ? String(part).replace(/\/+$/, "") : String(part).replace(/^\/+|\/+$/g, ""),
        )
        .join("/");
      return joined || "/";
    },
    convertFileSrc(path) {
      return path;
    },

    // ---- 数据库 ----
    // 旧版 ReadAny（React Native）把 SQLite 放在 <数据目录>/SQLite/ 下。
    // 这里沿用同一位置，升级到书灯后旧书库 / 阅读统计 / 高亮都能直接读到。
    async loadDatabase(path) {
      const name = String(path || "");
      const legacy = name && !name.includes("/") ? `SQLite/${name}` : null;
      const target = legacy && hostFs("exists", legacy).exists ? legacy : name;
      return openDatabase(target);
    },

    // ---- 网络 ----
    fetch(url, options) {
      return globalThis.fetch(url, options);
    },

    // ---- 应用信息 ----
    async getAppVersion() {
      return paths.appVersion || "0.1.0";
    },

    // ---- 键值存储 ----
    async kvGetItem(key) {
      const value = hostKv("get", key).value;
      return value == null ? null : String(value);
    },
    async kvSetItem(key, value) {
      hostKv("set", key, value);
    },
    async kvRemoveItem(key) {
      hostKv("remove", key);
    },
    async kvGetAllKeys() {
      return hostKv("keys", "").keys || [];
    },

    // ---- 暂未实现的宿主能力（后续按功能补） ----
    pickFile: notSupported("文件选择"),
    createWebSocket: notSupported("WebSocket"),
    copyToClipboard: notSupported("剪贴板写入"),
    shareOrDownloadFile: notSupported("分享/导出"),
  };

  let bootstrapPromise = null;

  function bootstrap() {
    if (!bootstrapPromise) {
      bootstrapPromise = (async () => {
        services.setPlatformService(platform);
        await core.db.initDatabase();
        // 端侧向量资源（Apple NLEmbedding / 上下文向量）缺的时候系统要下载，
        // 启动就先要一次，等用户真的建索引时基本已经就绪。
        try {
          if (typeof __nativeEmbedPrepare === "function") __nativeEmbedPrepare();
        } catch (error) {
          // 拿不到就算了：真正用的时候还会再试。
        }
        return {
          appData: paths.appData,
          version: paths.appVersion || "0.1.0",
        };
      })();
    }
    return bootstrapPromise;
  }

  function toJSON(value) {
    return JSON.stringify(value ?? null);
  }

  const chatModels = new Map();
  const chatControllers = new Map();
  // 用户可能在模型还没建好时就点了「停止」，先记下来，等 controller 建好立刻中断。
  const pendingChatAborts = new Set();

  async function modelFor(endpoint, model) {
    const key = [endpoint.baseUrl, endpoint.apiKey, endpoint.provider, model].join("|");
    const cached = chatModels.get(key);
    if (cached) return cached;

    const instance = await core.ai.createChatModelFromEndpoint(endpoint, model);
    chatModels.set(key, instance);
    return instance;
  }

  function emitChat(requestId, event) {
    __nativeChatEvent(String(requestId), JSON.stringify(event));
  }

  // ---- 端侧向量（语义检索）----
  // 模型是系统自带的 Apple NLEmbedding：不出网、不用下模型文件。

  function nativeEmbed(texts, modelId) {
    const payload = modelId ? { texts, modelId } : texts;
    const raw = JSON.parse(__nativeEmbed(JSON.stringify(payload)) || "{}");
    if (raw.error) throw new Error(String(raw.error));
    return raw;
  }

  // 探测文本用一句正文长度的话：太短的（两个字）可能在句向量模型上出不来向量。
  const EMBED_PROBE = "书灯是一盏照书的灯，照亮读不懂的地方。";
  const EMBED_PROBE_EN = "The lamp shines on the page, and the reader follows the light.";

  let embeddingIdentity = null;
  const embeddingServices = new Map();

  /// modelId 为空 = 让端侧自己挑一档；给了就锁死这一档（同一本书建索引和查询必须一致）。
  function embeddingService(modelId) {
    const key = modelId || "";
    // 锁定模型的服务可以缓存；自动挑的那种每次重新探测（端侧资源可能是刚下好的）。
    if (key) {
      const cached = embeddingServices.get(key);
      if (cached) return cached;
    }
    const probe = nativeEmbed([EMBED_PROBE], key);
    const identity = { modelId: probe.modelId, dimensions: probe.dimensions };
    const service = {
      provenance: { kind: "builtin", modelId: identity.modelId, dimensions: identity.dimensions },
      async embed(text) {
        const out = nativeEmbed([String(text || "")], identity.modelId);
        return out.vectors[0] || [];
      },
    };
    if (key) embeddingServices.set(key, service);
    return service;
  }

  /// 建索引进度：界面每 300ms 拉一次，比推事件简单，也不怕界面刚重建。
  let vectorizeState = { status: "idle", bookId: null, progress: 0, chunks: 0, error: null };

  function vectorizeSnapshot() {
    return { ...vectorizeState, embedding: embeddingIdentity };
  }

  globalThis.ShudengApp = {
    bootstrap,

    async info() {
      const info = await bootstrap();
      return toJSON({
        ...info,
        namespaces: Object.keys(core).sort(),
        badges: core.stats.ALL_BADGE_DEFINITIONS.length,
      });
    },

    async listBooks() {
      await bootstrap();
      const books = await core.db.getBooks();
      return toJSON(books);
    },

    async bookCount() {
      await bootstrap();
      const rows = await core.db.getBooks();
      return String(rows.length);
    },

    /// 导入：文件已经由 Swift 复制进 App 数据目录，这里只做元数据抽取 + 落库。
    async importBook(input) {
      const payload = typeof input === "string" ? JSON.parse(input) : input || {};
      await bootstrap();

      const format = String(payload.format || "epub").toLowerCase();
      // 重复导入去重（沿用旧版 ReadAny 的行为）：按文件内容哈希比对书库，
      // 命中就直接返回，Swift 侧会把刚复制进来的文件删掉。
      const digest = readFileDigest(payload.path);
      if (digest.sha256) {
        const books = await core.db.getBooks();
        const duplicate = core.importDedupe.findDuplicateBookByHash(
          core.importDedupe.createImportDuplicateIndex(books),
          digest.sha256,
        );
        if (duplicate) return toJSON({ duplicate: true, book: duplicate });
      }

      const bytes = await platform.readFile(payload.path);
      const meta = await core.bookImport.extractBookMetadata(
        bytes,
        format,
        payload.fileName || payload.path,
      );

      const now = Date.now();
      let coverUrl = null;
      if (meta.coverBytes && meta.coverBytes.length > 0) {
        const ext = String(meta.coverMimeType || "").includes("png") ? "png" : "jpg";
        coverUrl = `covers/${payload.id}.${ext}`;
        await platform.writeFile(coverUrl, meta.coverBytes);
      }

      const book = {
        id: payload.id,
        filePath: payload.path,
        format,
        meta: {
          title: meta.title || payload.fileName || "未命名",
          author: meta.author || "",
          publisher: meta.publisher,
          language: meta.language,
          isbn: meta.isbn,
          description: meta.description,
          publishDate: meta.publishDate,
          subjects: meta.subjects,
          coverUrl,
        },
        addedAt: now,
        updatedAt: now,
        lastOpenedAt: now,
        progress: 0,
        fileHash: digest.sha256 || undefined,
        isVectorized: false,
        vectorizeProgress: 0,
        tags: [],
        syncStatus: "local",
      };

      await core.db.insertBook(book);
      return toJSON({ duplicate: false, book });
    },

    /// 更新阅读进度 / 最近阅读位置。
    async saveProgress(input) {
      const payload = typeof input === "string" ? JSON.parse(input) : input || {};
      await bootstrap();
      const updates = {
        lastOpenedAt: Date.now(),
        updatedAt: Date.now(),
      };
      if (payload.progress != null)
        updates.progress = Math.min(1, Math.max(0, Number(payload.progress)));
      if (payload.cfi) updates.currentCfi = String(payload.cfi);
      await core.db.updateBook(String(payload.bookId), updates);
      return "ok";
    },

    /// 记录一次阅读会话（统计页的数据来源）。
    async recordSession(input) {
      const payload = typeof input === "string" ? JSON.parse(input) : input || {};
      await bootstrap();
      const totalActiveTime = Math.round(Number(payload.totalActiveTime || 0));
      if (!payload.bookId || totalActiveTime < 1000) return "skipped";

      const startedAt = Number(payload.startedAt || Date.now() - totalActiveTime);
      const session = {
        id: String(payload.id || `s-${startedAt}-${Math.random().toString(36).slice(2, 7)}`),
        bookId: String(payload.bookId),
        state: "STOPPED",
        startedAt,
        endedAt: startedAt + totalActiveTime,
        totalActiveTime,
        pagesRead: Math.max(0, Math.round(Number(payload.pagesRead || 0))),
        charactersRead: Math.max(0, Math.round(Number(payload.charactersRead || 0))),
      };
      if (payload.startCfi) session.startCfi = String(payload.startCfi);
      if (payload.endCfi) session.endCfi = String(payload.endCfi);

      await core.db.insertReadingSession(session);
      return "ok";
    },

    /// 阅读统计：今日 / 本周 / 累计 + 每日柱状 + 书目排行。
    async stats(input) {
      const payload = typeof input === "string" ? JSON.parse(input) : input || {};
      await bootstrap();

      const days = Math.min(365, Math.max(7, Number(payload.days || 14)));
      const service = core.stats.readingStatsService;
      const now = new Date();

      const todayStart = new Date(now);
      todayStart.setHours(0, 0, 0, 0);
      const weekStart = new Date(todayStart);
      weekStart.setDate(weekStart.getDate() - ((weekStart.getDay() + 6) % 7));
      const rangeStart = new Date(todayStart);
      rangeStart.setDate(rangeStart.getDate() - (days - 1));

      const daily = await service.getDailyStats(rangeStart, now);
      const today = await service.getDailyStats(todayStart, now);
      const week = await service.getDailyStats(weekStart, now);
      const overall = await service.getOverallStats();
      const periodBooks = await service.getBookStatsForPeriod(rangeStart, now);
      const books = await core.db.getBooks();

      const total = (rows) => rows.reduce((sum, row) => sum + (row.totalTime || 0), 0);
      const pages = (rows) => rows.reduce((sum, row) => sum + (row.pagesRead || 0), 0);
      const bookIndex = new Map(books.map((book) => [book.id, book]));

      return toJSON({
        days,
        daily,
        today: { minutes: total(today), pages: pages(today) },
        week: { minutes: total(week), pages: pages(week) },
        overall,
        topBooks: periodBooks.slice(0, 8).map((row) => ({
          ...row,
          coverUrl: row.coverUrl || bookIndex.get(row.bookId)?.meta?.coverUrl || null,
        })),
        bookCount: books.length,
        readingNow: books.filter((book) => (book.progress || 0) > 0 && (book.progress || 0) < 1)
          .length,
      });
    },

    // ---- 统计：徽章（core 里 39 个定义，按每日事实现算，不落库） ----
    async badges() {
      await bootstrap();
      const facts = await core.stats.readingReportsService.getAllDailyFacts();
      const summary = core.stats.buildStatsSummary(facts);
      const earnedIds = new Set(
        core.stats.evaluateBadges(facts, summary).map((badge) => badge.id),
      );
      // 徽章名只有中 / 英两套（core 的 stats 语言包），跟着设备语言挑一份。
      let locale = "";
      try {
        locale = String((await platform.getLocale()) || "");
      } catch {}
      const lang = locale.toLowerCase().startsWith("en") ? "en" : "zh";
      const table = (core.badgeText && (core.badgeText[lang] || core.badgeText.zh)) || {};
      const translate = (key, fallback) => {
        // core 里的 key 是 stats.desktop.xxx，语言表就是 desktop 那一层。
        const value = table[String(key).replace(/^stats\.desktop\./, "")];
        return value ? String(value) : fallback;
      };
      const badges = core.stats.ALL_BADGE_DEFINITIONS.map((def) => ({
        id: def.id,
        icon: def.icon,
        tier: def.tier,
        category: def.category,
        number: core.stats.BADGE_NUMBERS[def.id] || "",
        earned: earnedIds.has(def.id),
        title: translate(`stats.desktop.badge_${def.id}_title`, def.id),
        desc: translate(`stats.desktop.badge_${def.id}_desc`, ""),
      }));
      return toJSON({
        earned: badges.filter((badge) => badge.earned).length,
        total: badges.length,
        categories: core.stats.BADGE_CATEGORIES.map((entry) => ({
          key: entry.key,
          title: translate(entry.titleKey, entry.key),
        })),
        badges,
      });
    },

    // ---- 统计：区间报告（周 / 月 / 全部）。insights 是 core 里的英文文案，
    //      界面这边只取数字，中文在 Swift 侧拼。 ----
    async report(input) {
      const payload = typeof input === "string" ? JSON.parse(input) : input || {};
      await bootstrap();
      const period = String(payload.period || "week");
      const service = core.stats.readingReportsService;
      const now = new Date();
      const report =
        period === "month"
          ? await service.getMonthReport(now)
          : period === "lifetime"
            ? await service.getLifetimeReport()
            : await service.getWeekReport(now);

      return toJSON({
        dimension: report.dimension,
        period: report.period,
        summary: report.summary,
        topBooks: (report.topBooks || []).slice(0, 5).map((book) => ({
          bookId: book.bookId,
          title: book.title,
          author: book.author || "",
          totalTime: book.totalTime,
          pagesRead: book.pagesRead,
          progress: book.progress ?? null,
        })),
        previous: (report.previousPeriodComparison || []).map((row) => ({
          label: row.label,
          value: row.value,
          delta: row.delta ?? null,
          deltaLabel: row.deltaLabel || "",
        })),
      });
    },

    // ---- AI 阅读报告：把本地统计交给模型写一段解读（非流式，返回全文） ----
    async aiReport(input) {
      const payload = typeof input === "string" ? JSON.parse(input) : input || {};
      await bootstrap();
      core.ai.setStreamingFetch(globalThis.fetch);

      const endpoint = {
        id: "ios",
        name: "iOS",
        provider: payload.provider || "openai",
        apiKey: payload.apiKey || "",
        baseUrl: payload.baseUrl || "",
        models: [payload.model],
        modelsFetched: true,
      };

      try {
        const model = await modelFor(endpoint, payload.model);
        const messages = [];
        if (payload.system) messages.push(new core.messages.SystemMessage(String(payload.system)));
        messages.push(new core.messages.HumanMessage(String(payload.text || "")));

        let text = "";
        const stream = await model.stream(messages, {});
        for await (const chunk of stream) {
          const piece = chunk && typeof chunk.content === "string" ? chunk.content : "";
          if (piece) text += piece;
        }
        return toJSON({ text });
      } catch (error) {
        return toJSON({ error: String((error && error.message) || error) });
      }
    },

    // ---- 标注：高亮 / 书签 ----
    async listHighlights(input) {
      const payload = typeof input === "string" ? JSON.parse(input) : input || {};
      await bootstrap();
      const rows = payload.bookId
        ? await core.db.getHighlights(String(payload.bookId))
        : await core.db.getAllHighlightsWithBooks(Number(payload.limit || 500));
      return toJSON(rows);
    },

    async addHighlight(input) {
      const payload = typeof input === "string" ? JSON.parse(input) : input || {};
      await bootstrap();
      const now = Date.now();
      const highlight = {
        id: String(payload.id || `hl-${now}-${Math.random().toString(36).slice(2, 6)}`),
        bookId: String(payload.bookId),
        cfi: String(payload.cfi || ""),
        text: String(payload.text || ""),
        color: payload.color || "yellow",
        note: payload.note ? String(payload.note) : undefined,
        chapterTitle: payload.chapterTitle ? String(payload.chapterTitle) : undefined,
        createdAt: now,
        updatedAt: now,
      };
      await core.db.insertHighlight(highlight);
      return toJSON(highlight);
    },

    async updateHighlight(input) {
      const payload = typeof input === "string" ? JSON.parse(input) : input || {};
      await bootstrap();
      const updates = { updatedAt: Date.now() };
      if (payload.color) updates.color = String(payload.color);
      if (payload.note !== undefined) updates.note = String(payload.note);
      await core.db.updateHighlight(String(payload.id), updates);
      return "ok";
    },

    async deleteHighlight(input) {
      const payload = typeof input === "string" ? JSON.parse(input) : input || {};
      await bootstrap();
      await core.db.deleteHighlight(String(payload.id));
      return "ok";
    },

    async listBookmarks(input) {
      const payload = typeof input === "string" ? JSON.parse(input) : input || {};
      await bootstrap();
      if (payload.bookId) {
        return toJSON(await core.db.getBookmarks(String(payload.bookId)));
      }
      // 不带 bookId：一次拿全部书签（笔记页用），避免 Swift 侧按书循环调用。
      const books = await core.db.getBooks();
      const groups = await Promise.all(books.map((book) => core.db.getBookmarks(book.id)));
      const rows = groups.flat().sort((left, right) => (right.createdAt || 0) - (left.createdAt || 0));
      return toJSON(rows);
    },

    async addBookmark(input) {
      const payload = typeof input === "string" ? JSON.parse(input) : input || {};
      await bootstrap();
      const now = Date.now();
      const bookmark = {
        id: String(payload.id || `bm-${now}-${Math.random().toString(36).slice(2, 6)}`),
        bookId: String(payload.bookId),
        cfi: String(payload.cfi || ""),
        label: payload.label ? String(payload.label) : undefined,
        chapterTitle: payload.chapterTitle ? String(payload.chapterTitle) : undefined,
        createdAt: now,
      };
      await core.db.insertBookmark(bookmark);
      return toJSON(bookmark);
    },

    async deleteBookmark(input) {
      const payload = typeof input === "string" ? JSON.parse(input) : input || {};
      await bootstrap();
      await core.db.deleteBookmark(String(payload.id));
      return "ok";
    },

    async deleteBook(input) {
      const payload = typeof input === "string" ? JSON.parse(input) : input || {};
      await bootstrap();
      await core.db.deleteBook(String(payload.id), { preserveData: false });
      return "ok";
    },

    /// 选中文本翻译：走和对话同一个端点（core 的 aiTranslate）。
    async translate(input) {
      const payload = typeof input === "string" ? JSON.parse(input) : input || {};
      await bootstrap();
      const text = String(payload.text || "");
      if (!text.trim()) return toJSON({ translated: "" });

      try {
        const [translated] = await core.translation.aiTranslate(
          [text],
          "AUTO",
          String(payload.targetLang || "zh"),
          String(payload.apiKey || ""),
          String(payload.baseUrl || ""),
          String(payload.model || ""),
        );
        return toJSON({ translated: translated || "" });
      } catch (error) {
        return toJSON({ error: String((error && error.message) || error) });
      }
    },

    // ---- 会话线程（对话记忆，落 core 的 threads / messages 表） ----
    async listThreads(input) {
      const payload = typeof input === "string" ? JSON.parse(input) : input || {};
      await bootstrap();
      const rows = await core.db.getThreads(payload.bookId ? String(payload.bookId) : undefined);
      return toJSON(
        rows.map((thread) => ({
          id: thread.id,
          title: thread.title,
          bookId: thread.bookId || null,
          updatedAt: thread.updatedAt,
          messageCount: (thread.messages || []).length,
          lastMessage: (thread.messages || []).length
            ? String(thread.messages[thread.messages.length - 1].content || "").slice(0, 60)
            : "",
        })),
      );
    },

    async loadThread(input) {
      const payload = typeof input === "string" ? JSON.parse(input) : input || {};
      await bootstrap();
      const thread = await core.db.getThread(String(payload.id || ""));
      if (!thread) return toJSON({ id: payload.id || "", title: "", messages: [] });
      return toJSON({
        id: thread.id,
        title: thread.title,
        bookId: thread.bookId || null,
        updatedAt: thread.updatedAt,
        messages: (thread.messages || []).map((message) => ({
          id: message.id,
          role: message.role,
          content: message.content,
          createdAt: message.createdAt,
        })),
      });
    },

    async createThread(input) {
      const payload = typeof input === "string" ? JSON.parse(input) : input || {};
      await bootstrap();
      const now = Date.now();
      const thread = {
        id: String(payload.id || `th-${now}-${Math.random().toString(36).slice(2, 7)}`),
        bookId: payload.bookId ? String(payload.bookId) : undefined,
        title: String(payload.title || "新对话").slice(0, 40),
        messages: [],
        createdAt: now,
        updatedAt: now,
      };
      await core.db.insertThread(thread);
      return toJSON({ id: thread.id, title: thread.title, bookId: thread.bookId || null, updatedAt: now });
    },

    async appendMessage(input) {
      const payload = typeof input === "string" ? JSON.parse(input) : input || {};
      await bootstrap();
      const now = Date.now();
      const message = {
        id: String(payload.id || `msg-${now}-${Math.random().toString(36).slice(2, 7)}`),
        threadId: String(payload.threadId),
        role: payload.role === "assistant" ? "assistant" : "user",
        content: String(payload.content || ""),
        createdAt: now,
      };
      await core.db.insertMessage(message);
      if (payload.title) {
        await core.db.updateThreadTitle(message.threadId, String(payload.title).slice(0, 40));
      }
      return toJSON({ id: message.id, createdAt: now });
    },

    async deleteThread(input) {
      const payload = typeof input === "string" ? JSON.parse(input) : input || {};
      await bootstrap();
      await core.db.deleteThread(String(payload.id || ""));
      return "ok";
    },

    /// 端侧向量模型信息（设置页显示用）。
    async embeddingInfo() {
      let diagnostics = "";
      try {
        diagnostics = String(__nativeEmbedDiagnostics() || "");
      } catch (error) {
        diagnostics = "";
      }
      const attempt = (text) => {
        try {
          return nativeEmbed([text]);
        } catch (error) {
          return { error: String((error && error.message) || error) };
        }
      };
      // 先问中文：中文能用就是满配。中文出不来向量、英文能出（模拟器上只有英文词向量）时就标 latinOnly。
      const zh = attempt(EMBED_PROBE);
      if (!zh.error) {
        return toJSON({ available: true, modelId: zh.modelId, dimensions: zh.dimensions, diagnostics });
      }
      const en = attempt(EMBED_PROBE_EN);
      if (!en.error) {
        return toJSON({
          available: true,
          latinOnly: true,
          modelId: en.modelId,
          dimensions: en.dimensions,
          diagnostics,
        });
      }
      return toJSON({ available: false, error: String(zh.error), diagnostics });
    },

    /// 语义索引进度：界面轮询这个。
    async vectorizeStatus() {
      return toJSON(vectorizeSnapshot());
    },

    /// 建 / 重建一本书的语义索引：抽章节 → 切块 → 端侧向量 → 落库。
    async vectorizeBook(input) {
      const payload = typeof input === "string" ? JSON.parse(input) : input || {};
      const bookId = String(payload.bookId || "");
      if (!bookId) return toJSON({ error: "缺少 bookId" });
      if (vectorizeState.status === "running") {
        return toJSON({ error: `正在给《${vectorizeState.title || vectorizeState.bookId}》建索引` });
      }
      await bootstrap();

      const books = await core.db.getBooks();
      const book = books.find((item) => String(item.id) === bookId);
      if (!book) return toJSON({ error: "书库里没这本书" });

      const title = (book.meta && book.meta.title) || book.title || "";
      vectorizeState = { status: "running", bookId, title, progress: 0, chunks: 0, error: null };
      try {
        const bytes = await platform.readFile(book.filePath);
        const chapters = core.epubText.extractEpubChapters(bytes);
        // 探测用的是这本书自己的正文：短句能出向量、正文出不来，是最坑的一种情况。
        const sample = String((chapters[0] && chapters[0].content) || title).trim().slice(0, 200) || EMBED_PROBE;
        const probe = nativeEmbed([sample]);
        const modelId = probe.modelId;
        await core.rag.triggerVectorizeBook(
          bookId,
          chapters,
          {
            vectorModelEnabled: true,
            vectorModelMode: "builtin",
            selectedBuiltinModelId: null,
            remoteModel: null,
            nativeEmbedder: {
              modelId,
              dimensions: probe.dimensions,
              embed: async (texts) => nativeEmbed(texts, modelId).vectors,
            },
          },
          {
            onBookUpdate(id, update) {
              // 书本状态写库是异步的，界面靠 vectorizeStatus 轮询，这里不阻塞流水线。
              core.db.updateBook(String(id), update).catch(() => {});
            },
          },
          (progress) => {
            const total = progress.totalChunks || 0;
            vectorizeState = {
              ...vectorizeState,
              status: vectorizeState.status === "error" ? "error" : "running",
              progress: total > 0 ? Math.min(1, progress.processedChunks / total) : 0,
              chunks: progress.processedChunks || vectorizeState.chunks,
            };
          },
        );
        embeddingIdentity = { modelId, dimensions: probe.dimensions };
        vectorizeState = { ...vectorizeState, status: "done", progress: 1 };
        return toJSON({ ok: true, chapters: chapters.length, chunks: vectorizeState.chunks });
      } catch (error) {
        const message = String((error && error.message) || error);
        vectorizeState = { ...vectorizeState, status: "error", error: message };
        return toJSON({ error: message });
      }
    },

    /// 已经建过索引的书（带向量模型出处）。
    async vectorizedBooks() {
      await bootstrap();
      const books = await core.db.getBooks();
      const rows = [];
      for (const book of books) {
        const id = String(book.id);
        const provenance = await core.db.getVectorIndexProvenance(id);
        if (!provenance && book.isVectorized !== true) continue;
        rows.push({
          bookId: id,
          title: (book.meta && book.meta.title) || book.title || "",
          modelId: provenance ? provenance.modelId : "",
          dimensions: provenance ? provenance.dimensions : 0,
          isVectorized: book.isVectorized === true,
        });
      }
      return toJSON(rows);
    },

    /// 跨书库语义检索：每本已建索引的书跑一遍混合检索（向量 + BM25），再合并排序。
    async semanticSearch(input) {
      const payload = typeof input === "string" ? JSON.parse(input) : input || {};
      const query = String(payload.query || "").trim();
      if (!query) return toJSON({ results: [], errors: [], scanned: 0 });
      await bootstrap();

      const books = await core.db.getBooks();
      const wanted = Array.isArray(payload.bookIds) && payload.bookIds.length
        ? new Set(payload.bookIds.map(String))
        : null;
      const targets = books.filter((book) =>
        wanted ? wanted.has(String(book.id)) : book.isVectorized === true
      );

      const topK = Math.max(1, Math.min(20, Number(payload.topK) || 8));
      const results = [];
      const errors = [];

      for (const book of targets) {
        try {
          // 每本书按自己索引里记的模型算查询向量：不同书可能是不同档的端侧模型。
          const provenance = await core.db.getVectorIndexProvenance(String(book.id));
          const service = embeddingService(provenance ? String(provenance.modelId || "") : "");
          core.rag.configureSearch(service, service.provenance);
          const hits = await core.rag.search({
            bookId: String(book.id),
            query,
            mode: "hybrid",
            topK,
            threshold: 0.2,
          });
          for (const hit of hits) {
            results.push({
              bookId: String(book.id),
              bookTitle: (book.meta && book.meta.title) || book.title || "",
              chapterIndex: hit.chunk.chapterIndex,
              chapterTitle: hit.chunk.chapterTitle,
              content: hit.chunk.content,
              startCfi: hit.chunk.startCfi || "",
              score: hit.score,
              matchType: hit.matchType || "hybrid",
            });
          }
        } catch (error) {
          errors.push({ bookId: String(book.id), message: String((error && error.message) || error) });
        }
      }
      results.sort((left, right) => right.score - left.score);
      return toJSON({ results: results.slice(0, topK), errors, scanned: targets.length });
    },

    /// 删掉一本书的语义索引（换模型、书删了都要用）。
    async deleteVectors(input) {
      const payload = typeof input === "string" ? JSON.parse(input) : input || {};
      const bookId = String(payload.bookId || "");
      if (!bookId) return toJSON({ error: "缺少 bookId" });
      await bootstrap();
      await core.db.deleteChunks(bookId);
      await core.db.deleteVectorIndexProvenance(bookId);
      await core.db.updateBook(bookId, { isVectorized: false, vectorizeProgress: 0 });
      core.rag.invalidateChunkCache(bookId);
      if (vectorizeState.bookId === bookId) {
        vectorizeState = { status: "idle", bookId: null, progress: 0, chunks: 0, error: null };
      }
      return toJSON({ ok: true });
    },

    /// AI 技能清单（core 的 builtin skills + 中文文案），界面拿去列菜单。
    async skills(input) {
      const payload = typeof input === "string" ? JSON.parse(input) : input || {};
      await bootstrap();
      const table = SKILL_TEXT[String(payload.language || "zh").startsWith("en") ? "en" : "zh"];
      return toJSON(
        core.skills.builtinSkills.map((skill) => {
          const text = table[skill.id] || {};
          const params = (skill.parameters || []).map((param) => ({
            name: param.name,
            type: param.type,
            required: param.required === true,
            default: param.default ?? null,
          }));
          const required = (skill.parameters || []).find(
            (param) => param.required && (param.default == null || param.default === ""),
          );
          return {
            id: skill.id,
            name: text.name || skill.name,
            desc: text.desc || skill.description || "",
            needsInput: text.needsInput || null,
            inputParam: required ? required.name : null,
            params,
          };
        }),
      );
    },

    /// 思维导图：一次性（非流式）问模型要一份 Markdown 大纲，界面自己排版成导图。
    async mindmap(input) {
      const payload = typeof input === "string" ? JSON.parse(input) : input || {};
      await bootstrap();
      core.ai.setStreamingFetch(globalThis.fetch);

      const endpoint = {
        id: "ios",
        name: "iOS",
        provider: payload.provider || "openai",
        apiKey: payload.apiKey || "",
        baseUrl: payload.baseUrl || "",
        models: [payload.model],
        modelsFetched: true,
      };

      try {
        const model = await modelFor(endpoint, payload.model);
        const human = [
          payload.title ? `书名：《${payload.title}》` : "",
          payload.chapterTitle ? `章节：${payload.chapterTitle}` : "",
          "内容：",
          String(payload.text || "").slice(0, 12000),
        ]
          .filter(Boolean)
          .join("\n");
        const response = await model.invoke([
          new core.messages.SystemMessage(MINDMAP_PROMPT),
          new core.messages.HumanMessage(human),
        ]);
        const text = typeof response.content === "string" ? response.content : "";
        return toJSON({ text });
      } catch (error) {
        return toJSON({ error: String((error && error.message) || error) });
      }
    },

    /// Mermaid 图表 → SVG 字符串（beautiful-mermaid，纯 JS 无 DOM 依赖）。
    async renderMermaid(input) {
      const payload = typeof input === "string" ? JSON.parse(input) : input || {};
      const text = String(payload.text || "").trim();
      if (!text) return toJSON({ error: "空图表" });
      const dark = payload.dark !== false;
      const colors = dark
        ? { bg: "#0b0b0e", fg: "#f2f2f7", line: "#8e8e93", accent: "#f2f2f7", muted: "#a1a1aa", surface: "#1c1c21", border: "#3a3a40" }
        : { bg: "#ffffff", fg: "#111114", line: "#8e8e93", accent: "#111114", muted: "#6b6b73", surface: "#f4f4f6", border: "#d8d8dd" };
      try {
        const svg = core.diagram.renderMermaidSVG(text, { ...colors, font: "PingFang SC", padding: 24 });
        return toJSON({ svg });
      } catch (error) {
        return toJSON({ error: String((error && error.message) || error) });
      }
    },

    /// 流式对话：Token 通过 __nativeChatEvent 推给 Swift，返回时对话已结束。
    async chat(input) {
      const payload = typeof input === "string" ? JSON.parse(input) : input || {};
      const requestId = String(payload.requestId || Date.now());
      let controller = null;

      try {
        await bootstrap();
        core.ai.setStreamingFetch(globalThis.fetch);

        const endpoint = {
          id: "ios",
          name: payload.name || "iOS",
          provider: payload.provider || "openai",
          apiKey: payload.apiKey || "",
          baseUrl: payload.baseUrl || "",
          models: [payload.model],
          modelsFetched: true,
        };
        const model = await modelFor(endpoint, payload.model);

        // 技能（core 的 builtin skills）：prompt 走 system，参数跟用户输入一起走 human，
        // 跟 core 的 SkillExecutor 拼法保持一致，桌面端和 iOS 的产出才一样。
        const skill = payload.skillId ? core.skills.getBuiltinSkill(String(payload.skillId)) : null;
        const skillParams = payload.skillParams && typeof payload.skillParams === "object"
          ? payload.skillParams
          : {};
        const paramLines = Object.keys(skillParams)
          .filter((key) => skillParams[key] != null && String(skillParams[key]) !== "")
          .map((key) => `- ${key}: ${skillParams[key]}`);

        const systemParts = [];
        if (skill) {
          systemParts.push(skill.prompt);
          if (paramLines.length) systemParts.push(`## Skill parameters\n${paramLines.join("\n")}`);
        }
        systemParts.push(
          core.ai.buildSystemPrompt({
            book: payload.book || null,
            semanticContext: null,
            enabledSkills: skill ? [skill.id] : [],
            isVectorized: false,
            userLanguage: payload.language || "zh",
          }),
        );
        if (payload.contextText) {
          systemParts.push(`【读者当前看到的正文】\n${String(payload.contextText).slice(0, 6000)}`);
        }

        // 书建过语义索引就先在书里捞几段原文：读者问「作者怎么论证的」这种问题时，
        // 模型手里有原文，不会只凭书名瞎编。检索失败不影响正常对话。
        if (payload.book && payload.book.id && payload.semantic !== false) {
          try {
            const library = await core.db.getBooks();
            const target = library.find((item) => String(item.id) === String(payload.book.id));
            if (target?.isVectorized === true) {
              // 用这本书索引里记的模型算查询向量（书是用哪一档建的，就问哪一档）。
              const provenance = await core.db.getVectorIndexProvenance(String(target.id));
              const service = embeddingService(provenance ? String(provenance.modelId || "") : "");
              core.rag.configureSearch(service, service.provenance);
              const hits = await core.rag.search({
                bookId: String(target.id),
                query: String(payload.text || ""),
                mode: "hybrid",
                topK: 4,
                threshold: 0.2,
              });
              const passages = hits.filter((hit) => hit.chunk && hit.chunk.content);
              if (passages.length) {
                const lines = passages.map(
                  (hit, index) =>
                    `[${index + 1}] ${hit.chunk.chapterTitle || "正文"}\n${String(hit.chunk.content).slice(0, 700)}`,
                );
                systemParts.push(
                  `【从这本书里检索到的原文】\n回答时优先用这些原文，引用就说出处章节名，不要编造原文里没有的内容。\n\n${lines.join("\n\n")}`,
                );
                emitChat(requestId, {
                  type: "context",
                  count: passages.length,
                  chapters: passages.map((hit) => hit.chunk.chapterTitle || ""),
                });
              }
            }
          } catch (error) {
            console.warn("[Chat] 语义检索跳过：", String((error && error.message) || error));
          }
        }

        const messages = [new core.messages.SystemMessage(systemParts.join("\n\n"))];
        for (const item of payload.history || []) {
          if (!item || !item.text) continue;
          messages.push(
            item.role === "user"
              ? new core.messages.HumanMessage(String(item.text))
              : new core.messages.AIMessage(String(item.text)),
          );
        }
        let humanText = String(payload.text || "");
        if (skill) {
          const header = `Execute skill: ${skill.name}`;
          const withParams = paramLines.length
            ? `${header}\n\nParameters:\n${paramLines.join("\n")}`
            : header;
          humanText = humanText ? `${withParams}\n\n${humanText}` : withParams;
        }
        messages.push(new core.messages.HumanMessage(humanText));

        controller = new AbortController();
        chatControllers.set(requestId, controller);
        if (pendingChatAborts.delete(requestId)) controller.abort();

        const stream = await model.stream(messages, { signal: controller.signal });
        // 思考过程单独发一条事件，界面折起来展示，正文里不留 think 标签。
        // 有的模型把推理放在 additional_kwargs.reasoning_content 里，有的放在 content 的内容块里，
        // 有的直接写在正文的 think 标签中，三种都拆开。
        const thinkTag = { open: "<think>", close: "</think>" };
        let thinkMode = "text";
        let thinkCarry = "";
        const emitReasoning = (text) => {
          if (text) emitChat(requestId, { type: "reasoning", text });
        };
        const splitThinkTags = (input) => {
          thinkCarry += input;
          const events = [];
          while (thinkCarry) {
            const tag = thinkMode === "text" ? thinkTag.open : thinkTag.close;
            const nextMode = thinkMode === "text" ? "reasoning" : "text";
            const at = thinkCarry.indexOf(tag);
            if (at >= 0) {
              if (at > 0) events.push([thinkMode, thinkCarry.slice(0, at)]);
              thinkCarry = thinkCarry.slice(at + tag.length);
              thinkMode = nextMode;
              continue;
            }
            let keep = 0;
            for (let length = Math.min(thinkCarry.length, tag.length - 1); length > 0; length--) {
              if (thinkCarry.endsWith(tag.slice(0, length))) {
                keep = length;
                break;
              }
            }
            const safe = thinkCarry.slice(0, thinkCarry.length - keep);
            if (safe) events.push([thinkMode, safe]);
            thinkCarry = thinkCarry.slice(thinkCarry.length - keep);
            break;
          }
          return events;
        };
        const emitStreamEvents = (events) => {
          for (const [mode, text] of events) {
            if (mode === "reasoning") emitReasoning(text);
            else emitChat(requestId, { type: "chunk", text });
          }
        };
        const takeChunkContent = (chunk) => {
          const content = chunk ? chunk.content : "";
          if (typeof content === "string") return content ? splitThinkTags(content) : [];
          if (!Array.isArray(content)) return [];
          const events = [];
          for (const block of content) {
            if (!block) continue;
            if (block.type === "thinking") {
              const thinking = [block.text, block.thinking, block.content].find(
                (value) => typeof value === "string" && value.length > 0,
              );
              if (thinking) events.push(["reasoning", thinking]);
            } else if (typeof block.text === "string" && block.text) {
              events.push(...splitThinkTags(block.text));
            }
          }
          return events;
        };
        for await (const chunk of stream) {
          if (controller.signal.aborted) break;
          const reasoningRaw = chunk && chunk.additional_kwargs ? chunk.additional_kwargs.reasoning_content : null;
          if (typeof reasoningRaw === "string") {
            emitReasoning(reasoningRaw);
          } else if (Array.isArray(reasoningRaw)) {
            for (const part of reasoningRaw) {
              if (typeof part === "string") emitReasoning(part);
              else if (part && typeof part.text === "string") emitReasoning(part.text);
            }
          }
          emitStreamEvents(takeChunkContent(chunk));
        }
        if (thinkCarry) {
          const tail = thinkCarry;
          thinkCarry = "";
          if (thinkMode === "reasoning") emitReasoning(tail);
          else emitChat(requestId, { type: "chunk", text: tail });
        }

        emitChat(requestId, { type: "done", aborted: controller.signal.aborted === true });
        return "ok";
      } catch (error) {
        // 用户点「停止」触发的 abort 不是错误，别在界面上弹报错。
        if (controller && controller.signal.aborted) {
          emitChat(requestId, { type: "done", aborted: true });
          return "aborted";
        }
        emitChat(requestId, { type: "error", message: String((error && error.message) || error) });
        return "error";
      } finally {
        chatControllers.delete(requestId);
      }
    },

    abortChat(requestId) {
      const key = String(requestId);
      const controller = chatControllers.get(key);
      if (controller) {
        controller.abort();
        return "aborted";
      }
      pendingChatAborts.add(key);
      if (pendingChatAborts.size > 32) {
        pendingChatAborts.delete(pendingChatAborts.values().next().value);
      }
      return "pending";
    },
  };
})();
