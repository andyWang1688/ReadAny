#!/usr/bin/env node
// SPDX-License-Identifier: GPL-3.0-or-later
// 本地 OpenAI 兼容 mock 端点：给模拟器上的 UI 测试用，避免每次跑测试都打真实 API。
//   node packages/app-ios/scripts/mock-llm-server.mjs [port]
// 模拟器与 Mac 共享网络栈，App 里端点填 http://127.0.0.1:<port>/v1 即可。
import { createServer } from "node:http";

const port = Number(process.argv[2] || 8799);

function textOf(content) {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content.map((part) => (typeof part === "string" ? part : (part?.text ?? ""))).join("");
  }
  return "";
}

function promptOf(payload) {
  return (payload.messages || []).map((message) => textOf(message.content)).join("\n");
}

/// 系统提示单独取出来：用来断言 App 真的没有再广播工具指令。
function systemOf(payload) {
  return (payload.messages || [])
    .filter((message) => message.role === "system")
    .map((message) => textOf(message.content))
    .join("\n");
}

/// 思考过程的暗号：正文前带一段 think 标签，验证桥接层会拆成可折叠的 reasoning 事件。
const THINKING = [
  "<think>",
  "先确认用户问的是哪一段，",
  "再看上下文里有没有原文，",
  "最后把答案压成两句话。",
  "</think>",
].join("");

/// 固定回答；如果 prompt 里带了阅读器上下文暗号，就把它回显出来（给上下文注入用例断言）。
function replyFor(payload) {
  const prompt = promptOf(payload);
  const head = /暗号：思考过程|simulate thinking/.test(prompt) ? THINKING : "";

  // 思维导图：core 的导图指令要求 Markdown 大纲，这里给一份固定大纲给用例断言节点。
  if (prompt.includes("阅读思维导图助手")) {
    return head + [
      "# 时间简史",
      "## 宇宙图像",
      "### 亚里士多德",
      "- 天球层层套叠",
      "### 牛顿",
      "- 绝对时间与绝对空间",
      "## 相对论",
      "- 光速对谁都一样",
      "## 量子力学",
      "- 不确定性原理",
    ].join("\n");
  }

  // 工具调用格式的回复（DeepSeek 系模型的 ｜DSML｜ 标记）：真机上模型在「系统提示说有工具、
  // 客户端却没绑工具」时会把工具调用当正文吐出来，用例断言客户端不会把这坨 markup 当正文显示。
  if (/暗号：工具调用/.test(prompt)) {
    const bar = "\uFF5C";
    const tag = (name) => `<${bar}${bar}DSML${bar}${bar} ${name}>`;
    const close = (name) => `</${bar}${bar}DSML${bar}${bar} ${name}>`;
    return head + [
      tag("calls"),
      tag('invoke name="getSurroundingContext"'),
      tag('parameter name="includeSelection" string="true">true'),
      close("parameter"),
      close("invoke"),
      close("calls"),
    ].join("\n");
  }

  // Mermaid：给一个流程图，用例断言对话里出现图表（不是代码块）。
  if (/暗号：mermaid/.test(prompt)) {
    return head + [
      "先看这张图：",
      "",
      "```mermaid",
      "graph TD",
      "  A[翻开书] --> B{读得下去吗}",
      "  B -->|读得下去| C[继续读]",
      "  B -->|读不下去| D[合上书]",
      "```",
      "",
      "图里就是这两个选择。",
    ].join("\n");
  }

  // 技能：core 的 SkillExecutor 会发「Execute skill: <名字>」，回显一下证明技能真的注入了。
  const skill = /Execute skill: ([^\n]+)/.exec(prompt);
  if (skill) {
    const title = /^- Title: (.+)$/m.exec(systemOf(payload))?.[1] || "无";
    return head + `技能答复：${skill[1].trim()}。当前书籍：${title}。`;
  }

  // 系统提示自检：没有工具执行器的一方不该再写「必须用工具取原文」，
  // 否则 DeepSeek 会把 ｜DSML｜ 工具调用当正文吐出来（读者看到的就是乱码）。
  if (/暗号：系统提示/.test(prompt)) {
    return systemOf(payload).includes("MUST use the provided tools")
      ? "系统提示里还有工具指令。"
      : "系统提示里没有工具指令。";
  }

  const marker = /暗号：([^。\n]+)/.exec(prompt);
  return head + (marker ? `收到，暗号是${marker[1]}。` : "收到，这是模拟回复。");
}

const sse = (text) =>
  `data: ${JSON.stringify({
    id: "mock-1",
    object: "chat.completion.chunk",
    created: Math.floor(Date.now() / 1000),
    model: "mock-model",
    choices: [{ index: 0, delta: { content: text }, finish_reason: null }],
  })}\n\n`;

const server = createServer((req, res) => {
  if (req.method === "GET") {
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ ok: true }));
    return;
  }

  console.log(`[req] ${req.method} ${req.url}`);
  let raw = "";
  req.on("data", (chunk) => {
    raw += chunk;
  });
  req.on("end", async () => {
    let payload = {};
    try {
      payload = JSON.parse(raw || "{}");
    } catch {
      payload = {};
    }

    if (!payload.stream) {
      const reply = replyFor(payload);
      res.writeHead(200, { "content-type": "application/json" });
      res.end(
        JSON.stringify({
          id: "mock-1",
          object: "chat.completion",
          created: Math.floor(Date.now() / 1000),
          model: payload.model || "mock-model",
          choices: [
            { index: 0, message: { role: "assistant", content: reply }, finish_reason: "stop" },
          ],
          usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 },
        }),
      );
      return;
    }

    res.writeHead(200, {
      "content-type": "text/event-stream",
      "cache-control": "no-cache",
      connection: "keep-alive",
    });
    const reply = replyFor(payload);
    console.log(`[stream] ${[...reply].length} chars`);
    for (const piece of [...reply]) {
      res.write(sse(piece));
      await new Promise((resolve) => setTimeout(resolve, 40));
    }
    res.write(
      `data: ${JSON.stringify({
        id: "mock-1",
        object: "chat.completion.chunk",
        created: Math.floor(Date.now() / 1000),
        model: "mock-model",
        choices: [{ index: 0, delta: {}, finish_reason: "stop" }],
      })}\n\n`,
    );
    res.write("data: [DONE]\n\n");
    res.end();
    console.log("[done]");
  });
});

server.listen(port, "127.0.0.1", () => {
  console.log(`mock llm listening on http://127.0.0.1:${port}/v1`);
});
