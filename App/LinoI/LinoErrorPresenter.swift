import Foundation

/// Central, pure-function Chinese error presenter shared by the iOS and
/// macOS targets (one change here reaches both apps). Every backend error
/// `code` (job failures, 409 preflight/concurrency detail) and every local
/// `APIError` case funnels through here so the two apps render identical,
/// "glance and locate" copy: which stage failed, which model, why, the raw
/// upstream detail when we have one, and what to do next.
///
/// Template: `{环节}（{模型}）{原因}：{upstream 原文}——{建议} [code]`. Any piece
/// that isn't available is dropped rather than shown blank (no model → no
/// parens; no upstream detail → no colon segment). `upstreamReason` /
/// `blockReason` are always shown verbatim, never translated or merged into
/// a generic bucket — that would disguise a content-policy block or a real
/// upstream rejection as an ordinary failure, which the v1.2.3 hard
/// constraints explicitly forbid.
enum LinoErrorPresenter {

    // MARK: - Public entry points

    /// Presents a terminal (`phase == "failed"`) `WriteJobStatus`. Reads
    /// `errorCode` + `errorContext` for the environment/model/upstream
    /// pieces, and — for `revision_failed` — folds in the
    /// `unselected_character` violation's `names` so the message names the
    /// actual character(s) instead of a generic "validation failed".
    static func present(jobFailure status: WriteJobStatus) -> (message: String, critical: Bool) {
        let code = status.errorCode
        let context = status.errorContext
        let entry = code.flatMap(tableEntry)
        let reason = annotate(
            reason: entry?.reason ?? status.errorMessage ?? "任务失败",
            code: code,
            violations: status.violations
        )
        let message = compose(
            agentRole: context?.agentRole,
            modelName: context?.modelName,
            reason: reason,
            rawDetail: context?.upstreamReason ?? context?.blockReason,
            suggestion: entry?.suggestion,
            code: code
        )
        return (message, isCritical(code: code, blockReason: context?.blockReason))
    }

    /// Presents any thrown `Error`. Specialised for `APIError` (the only
    /// error type App code throws); anything else falls back to
    /// `localizedDescription` so a stray system error never crashes the
    /// toast pipeline.
    static func present(error: Error) -> (message: String, critical: Bool) {
        guard let apiError = error as? APIError else {
            return (error.localizedDescription, false)
        }
        switch apiError {
        case .notConfigured:
            return ("请先配置后端地址和 Bearer Token", false)
        case .badURL:
            return ("后端地址无效", false)
        case .transport(let description):
            let message = compose(
                agentRole: nil, modelName: nil,
                reason: "连接后端失败", rawDetail: description,
                suggestion: "请检查网络后重试", code: nil
            )
            return (message, false)
        case .http(let statusCode, let body):
            return presentHTTP(statusCode: statusCode, body: body)
        case .validation(let code, let message, let names):
            return presentValidation(code: code, message: message, names: names)
        }
    }

    /// `runPolling`'s transient "still retrying" toast. Not a failure — kept
    /// here as a shared constant (rather than a literal at the call site) so
    /// iOS and macOS show byte-identical copy and any future wording change
    /// only happens once.
    static let connectionInterrupted = "与服务器的连接暂时中断，正在自动重试。"

    // MARK: - APIError specialisations

    /// The backend's non-structured 4xx/2-xx-adjacent detail strings: a
    /// plain string, not a `{code, message}` object, so there is no `code`
    /// to look up. `unauthorized`/known 404 nouns/the one 409 draft-text
    /// string get curated copy; 422 settings validation is already a
    /// complete, Chinese, actionable sentence and passes through unchanged;
    /// anything else falls back to the raw body untouched.
    private static func presentHTTP(statusCode: Int, body: String) -> (message: String, critical: Bool) {
        if statusCode == 401, let entry = tableEntry(for: "unauthorized") {
            let message = compose(
                agentRole: nil, modelName: nil,
                reason: entry.reason, rawDetail: nil,
                suggestion: entry.suggestion, code: "unauthorized"
            )
            return (message, isCritical(code: "unauthorized", blockReason: nil))
        }
        if statusCode == 404, let noun = notFoundNouns[body] {
            let message = compose(
                agentRole: nil, modelName: nil,
                reason: "\(noun)不存在，可能已被删除", rawDetail: nil,
                suggestion: "请刷新后重试", code: nil
            )
            return (message, false)
        }
        if statusCode == 409, body == "chapter has no draft text" {
            let message = compose(
                agentRole: nil, modelName: nil,
                reason: "本章暂无正文", rawDetail: nil,
                suggestion: "请先生成或导入正文后再接受", code: nil
            )
            return (message, false)
        }
        if statusCode == 422 {
            return (body.isEmpty ? "HTTP 422" : body, false)
        }
        return (body.isEmpty ? "HTTP \(statusCode)" : body, false)
    }

    /// The backend's structured `{code, message, details.names}` 409s
    /// (preflight/concurrency) and the optional `test_profile` 502. `names`
    /// (when present) is appended the same way the old `APIError.
    /// errorDescription` did, so nothing regresses for callers that used to
    /// read that computed property directly.
    private static func presentValidation(code: String, message: String, names: [String]) -> (message: String, critical: Bool) {
        let entry = tableEntry(for: code)
        var reason = entry?.reason ?? message
        if !names.isEmpty {
            reason += "：\(names.joined(separator: "、"))"
        }
        let composed = compose(
            agentRole: nil, modelName: nil,
            reason: reason, rawDetail: nil,
            suggestion: entry?.suggestion, code: code
        )
        return (composed, isCritical(code: code, blockReason: nil))
    }

    // MARK: - Template composition

    private static func compose(
        agentRole: String?,
        modelName: String?,
        reason: String,
        rawDetail: String?,
        suggestion: String?,
        code: String?
    ) -> String {
        var text = sectionLabel(for: agentRole)
        if let modelName, !modelName.isEmpty {
            text += "（\(modelName)）"
        }
        text += reason
        if let rawDetail, !rawDetail.isEmpty {
            text += "：\(rawDetail)"
        }
        if let suggestion, !suggestion.isEmpty {
            text += "——\(suggestion)"
        }
        if let code, !code.isEmpty {
            text += " [\(code)]"
        }
        return text
    }

    private static func sectionLabel(for agentRole: String?) -> String {
        switch agentRole {
        case "memory_selector": return "选记忆"
        case "writer": return "写正文"
        case "reviser": return "修订"
        case "extractor": return "提取归档"
        default: return "App↔后端"
        }
    }

    /// Only `revision_failed` gets annotated: it is the one job-failure code
    /// whose `violations` can carry an `unselected_character` entry with a
    /// concrete `names` list, letting the message name the actual
    /// character(s) instead of stopping at "未通过程序校验".
    private static func annotate(reason: String, code: String?, violations: [Violation]?) -> String {
        guard code == "revision_failed",
              let names = violations?.first(where: { $0.code == "unselected_character" })?.names,
              !names.isEmpty else { return reason }
        return "\(reason)，其中包含未获准人物：\(names.joined(separator: "、"))"
    }

    // MARK: - Criticality

    /// `llm_content_blocked` (content-policy block), validation exhaustion and
    /// `unauthorized` stay critical (manual dismiss, no auto-fade) — per the
    /// v1.2.3 hard constraint these must never blend into an ordinary,
    /// auto-dismissing failure toast. A `blockReason` implies a content
    /// block even if some future code path forgets to also set
    /// `llm_content_blocked`, so it is checked independently.
    private static let criticalCodes: Set<String> = [
        "llm_content_blocked", "revision_failed", "writer_expansion_failed", "unauthorized",
    ]

    private static func isCritical(code: String?, blockReason: String?) -> Bool {
        if let code, criticalCodes.contains(code) { return true }
        if blockReason != nil { return true }
        return false
    }

    // MARK: - Code → Chinese table

    private struct Entry {
        let reason: String
        let suggestion: String
    }

    /// Every backend error `code` this app can receive, enumerated once so
    /// nothing is translated ad hoc at the call site. Spot-checked against
    /// `grep -rn "code=" Backend/app` / `HTTPException(..., detail=...)` for
    /// completeness before shipping — see PROJECT_PLAN.md v1.2.3 块 B.
    private static func tableEntry(for code: String) -> Entry? {
        switch code {
        // LLM / 上游（Agent 环节，agentRole 通常随 errorContext 一起到）
        case "llm_upstream_rejected":
            return Entry(reason: "上游拒绝了这次请求", suggestion: "请检查模型 Profile 配置，或稍后重试")
        case "llm_rate_limited":
            return Entry(reason: "请求被上游限流", suggestion: "请稍后重试")
        case "llm_upstream_unavailable":
            return Entry(reason: "上游服务暂时不可用", suggestion: "请稍后重试")
        case "llm_content_blocked":
            return Entry(reason: "内容被安全策略拦截，上游拒绝生成", suggestion: "请调整本章剧情或人物描写后重试")
        case "llm_empty_candidate":
            return Entry(reason: "上游未返回有效正文内容", suggestion: "请重试；若持续出现，请检查模型配置")
        case "llm_invalid_response":
            return Entry(reason: "上游返回的数据无法解析", suggestion: "请稍后重试；若持续出现，请联系模型服务商")
        case "llm_transport":
            return Entry(reason: "连接模型服务失败", suggestion: "请检查网络后重试")
        case "llm_upstream_error":
            return Entry(reason: "上游请求处理失败", suggestion: "请重试；若持续出现，请检查模型配置")

        // 写作链 / 后端
        case "writer_expansion_failed":
            return Entry(reason: "Writer 扩写两次后仍未达到篇幅要求", suggestion: "请调整本章剧情或目标字数后重新生成")
        case "revision_failed":
            return Entry(reason: "修订两次后仍未通过程序校验", suggestion: "请调整本章剧情后重新生成，或豁免涉及人物后重试")
        case "write_failed":
            return Entry(reason: "写作任务出现意外错误", suggestion: "请重试；若持续出现，请联系管理员")
        case "extract_failed":
            return Entry(reason: "提取任务出现意外错误", suggestion: "请重试；若持续出现，请联系管理员")
        case "chapter_missing":
            return Entry(reason: "章节不存在，可能已被删除", suggestion: "请返回书架重新进入")
        case "interrupted":
            return Entry(reason: "服务重启，任务被中断", suggestion: "请重新生成")

        // 预检 / 并发（409 结构化 detail）
        case "chapter_finalized":
            return Entry(reason: "本章已完成，需先重新编辑", suggestion: "请先点击「重新编辑本章」")
        case "write_running":
            return Entry(reason: "写作正在进行中", suggestion: "请等待当前任务完成后再试")
        case "unselected_characters_in_bible":
            return Entry(reason: "本章剧情 Bible 或作者备注出现了未选择人物", suggestion: "请勾选这些人物，或从 Bible 中移除相关描写")
        case "ambiguous_character_name":
            return Entry(reason: "同书存在无法区分的重名人物", suggestion: "请先为重名人物改名或补充区分信息")
        case "bible_empty":
            return Entry(reason: "本章剧情 Bible 不能为空", suggestion: "请先填写本章剧情 Bible")

        // violations 明细 code（拼进 revision_failed 的 detail；单独枚举以便任何
        // 按 code 查表的调用点复用同一口径）
        case "unselected_character":
            return Entry(reason: "正文含未获准人物", suggestion: "可豁免这些人物后重试，或修改人物设定")
        case "ambiguous_character":
            return Entry(reason: "正文含重名人物", suggestion: "请先为重名人物改名或补充区分信息")
        case "word_count":
            return Entry(reason: "正文字数不在目标区间内", suggestion: "请调整目标字数后重新生成")
        case "empty_body":
            return Entry(reason: "正文为空", suggestion: "请重新生成")
        case "length_truncated":
            return Entry(reason: "上游因长度限制截断了输出", suggestion: "请调小目标字数后重新生成")

        // 本地合成（无后端 code=，由 401 纯串 detail 映射而来）
        case "unauthorized":
            return Entry(reason: "登录状态已失效或 Token 不正确", suggestion: "请到设置里重新填写 Token")

        default:
            return nil
        }
    }

    /// 404 plain-string details: `"\(noun) not found"` → the Chinese noun.
    /// All six span every 404 raised in `Backend/app/routers/*.py`.
    private static let notFoundNouns: [String: String] = [
        "book not found": "书籍",
        "chapter not found": "章节",
        "character not found": "人物",
        "profile not found": "模型 Profile",
        "agent role not found": "Agent 角色",
        "character event not found": "人物事件",
    ]
}
