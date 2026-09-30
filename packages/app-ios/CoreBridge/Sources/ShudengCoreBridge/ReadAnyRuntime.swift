// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import JavaScriptCore

public enum RuntimeError: Error, CustomStringConvertible {
    case contextCreationFailed
    case missingResource(String)
    case scriptFailed(String)
    case rejected(String)
    case timeout(TimeInterval)

    public var description: String {
        switch self {
        case .contextCreationFailed: "无法创建 JSContext"
        case .missingResource(let name): "缺少资源: \(name)"
        case .scriptFailed(let message): "JS 执行失败: \(message)"
        case .rejected(let message): "JS Promise 被拒绝: \(message)"
        case .timeout(let seconds): "等待 JS Promise 超时（\(seconds)s）"
        }
    }
}

/// 在 JavaScriptCore 里跑 ReadAny core 的运行时。
///
/// 用法：
/// ```swift
/// let runtime = try ReadAnyRuntime(coreScript: coreJS)
/// let value = try runtime.evaluate("ReadAnyCore.stats.ALL_BADGE_DEFINITIONS.length")?.toInt32()
/// ```
public final class ReadAnyRuntime {
    public let context: JSContext
    public let host: HostEnvironment

    public init(
        shim: String? = nil,
        coreScript: String,
        appScript: String? = nil,
        host: HostEnvironment? = nil
    ) throws {
        guard let context = JSContext() else { throw RuntimeError.contextCreationFailed }
        self.context = context
        self.host = try host ?? HostEnvironment()

        self.host.attach(to: context)
        try Self.evaluateChecked(try shim ?? Self.bundledShim(), in: context)
        try Self.evaluateChecked(coreScript, in: context)
        if let appScript {
            try Self.evaluateChecked(appScript, in: context)
        }
    }

    /// SwiftPM 构建时资源在 Bundle.module，直接编进 App target 时在 Bundle.main。
    static var resourceBundle: Bundle {
        #if SWIFT_PACKAGE
        Bundle.module
        #else
        Bundle.main
        #endif
    }

    /// bridge-shim.js 随包分发。
    public static func bundledShim() throws -> String {
        guard let url = Self.resourceBundle.url(forResource: "bridge-shim", withExtension: "js") else {
            throw RuntimeError.missingResource("bridge-shim.js")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// app-bootstrap.js：把宿主能力接给 core，并注册 ShudengApp API。
    public static func bundledAppBootstrap() throws -> String {
        guard let url = Self.resourceBundle.url(forResource: "app-bootstrap", withExtension: "js") else {
            throw RuntimeError.missingResource("app-bootstrap.js")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    public static func bundledCoreScript(at url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    @discardableResult
    public func evaluate(_ script: String) throws -> JSValue? {
        try Self.evaluateChecked(script, in: context)
    }

    /// 把 JS 侧的 Promise 顶点映射成 Swift 的阻塞等待（内部跑 RunLoop，保持 JS 回调可执行）。
    @discardableResult
    public func wait(for promise: JSValue, timeout: TimeInterval = 60) throws -> JSValue {
        var settled = false
        var result: JSValue?
        var failure: Error?

        let onFulfilled: @convention(block) (JSValue?) -> Void = { value in
            result = value
            settled = true
        }
        let onRejected: @convention(block) (JSValue?) -> Void = { error in
            failure = RuntimeError.rejected(error?.toString() ?? "unknown")
            settled = true
        }

        promise.invokeMethod("then", withArguments: [
            JSValue(object: onFulfilled, in: context) as Any,
            JSValue(object: onRejected, in: context) as Any,
        ])

        let deadline = Date().addingTimeInterval(timeout)
        while !settled, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }

        if let failure { throw failure }
        guard settled, let result else { throw RuntimeError.timeout(timeout) }
        return result
    }

    @discardableResult
    private static func evaluateChecked(_ script: String, in context: JSContext) throws -> JSValue? {
        let value = context.evaluateScript(script)
        if let exception = context.exception {
            context.exception = nil
            let message = exception.toString() ?? "unknown"
            let stack = exception.objectForKeyedSubscript("stack")?.toString() ?? ""
            throw RuntimeError.scriptFailed(stack.isEmpty ? message : "\(message)\n\(stack)")
        }
        return value
    }
}
