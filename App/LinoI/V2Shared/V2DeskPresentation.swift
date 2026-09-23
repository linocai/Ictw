import Foundation

/// The three chapter faces retain the same author-facing vocabulary on both
/// platforms. macOS can show two at once; iOS pages between them.
enum V2DeskChapterFace: String, CaseIterable, Equatable, Sendable {
    case intent
    case manuscript
    case evidence

    var title: String {
        switch self {
        case .intent: "本章意图"
        case .manuscript: "正文"
        case .evidence: "证据"
        }
    }
}

enum V2DeskTone: Equatable, Sendable {
    case neutral
    case accent
    case success
    case warning
    case danger
    case stale
}

/// Shape communicates the meaning even where color is unavailable.
enum V2DeskMarkerKind: Equatable, Sendable {
    case solidDot
    case hollowRing
    case striped
    case hidden
}

struct V2DeskMarker: Equatable, Sendable {
    let kind: V2DeskMarkerKind
    let tone: V2DeskTone

    static let confirmed = V2DeskMarker(kind: .solidDot, tone: .success)
    static let notYetHappened = V2DeskMarker(kind: .hollowRing, tone: .accent)
    static let unreliable = V2DeskMarker(kind: .striped, tone: .stale)
}

enum V2DeskPrimaryAction: Equatable, Sendable {
    case generate
    case cancelGeneration
    case rerunChecker
    case retryGeneratedCandidateChecker
    case accept
    case acceptWithWarning
    /// This is a deliberate creation command at the end of the book. Reading
    /// order is modelled separately by `V2DeskReadingOrder` and must never
    /// reuse a creation action.
    case startNewChapter
    case retryGeneration
    case retryArchive
    case refreshTaskStatus
    case openSettings
    case none

    var title: String {
        switch self {
        case .generate: "生成这一章"
        case .cancelGeneration: "取消生成"
        case .rerunChecker: "重新复查"
        case .retryGeneratedCandidateChecker: "重试检查生成稿"
        case .accept: "接受这一章"
        case .acceptWithWarning: "仍然接受"
        case .startNewChapter: "开始新一章"
        case .retryGeneration: "重试"
        case .retryArchive: "重试整理"
        case .refreshTaskStatus: "刷新任务状态"
        case .openSettings: "去设置"
        case .none: ""
        }
    }

    var requiresConfirmation: Bool {
        self == .acceptWithWarning
    }
}

/// The only possible forward moves from a reader. The existing chapter cases
/// are navigation; only the final case may create a chapter.
enum V2DeskReadingNextStep: Equatable, Sendable {
    case read(ChapterSummary)
    case write(ChapterSummary)
    case startNewChapter
}

/// Pure reading-order policy shared by iOS and macOS. The caller supplies the
/// chapter list it currently has; this policy deliberately does not infer a
/// missing current chapter as permission to create a new one.
enum V2DeskReadingOrder {
    static func next(after chapterID: String, in chapters: [ChapterSummary]) -> V2DeskReadingNextStep? {
        let ordered = orderedChapters(chapters)
        guard let currentIndex = ordered.firstIndex(where: { $0.id == chapterID }) else { return nil }
        let nextIndex = ordered.index(after: currentIndex)
        guard nextIndex < ordered.endIndex else { return .startNewChapter }

        let next = ordered[nextIndex]
        return next.status == "finalized" ? .read(next) : .write(next)
    }

    /// Backward navigation always stays within existing chapters and never
    /// creates a chapter, even when the source list is stale or incomplete.
    static func previous(after chapterID: String, in chapters: [ChapterSummary]) -> ChapterSummary? {
        let ordered = orderedChapters(chapters)
        guard let currentIndex = ordered.firstIndex(where: { $0.id == chapterID }), currentIndex > ordered.startIndex else {
            return nil
        }
        return ordered[ordered.index(before: currentIndex)]
    }

    private static func orderedChapters(_ chapters: [ChapterSummary]) -> [ChapterSummary] {
        chapters.sorted {
            if $0.index != $1.index { return $0.index < $1.index }
            return $0.id < $1.id
        }
    }
}

enum V2DeskBannerKind: Equatable, Sendable {
    case writing
    case checking
    case accepting
    case proseUpdated
    case cancelled
    case generationFailed
    case checkerUnavailable
    case archiving
    case archiveFailed
    case localSaveNeedsAttention
    case connectionInterrupted
}

struct V2DeskTaskBanner: Equatable, Sendable {
    let kind: V2DeskBannerKind
    let tone: V2DeskTone
    let text: String
    /// Banner actions are compact secondary affordances. If this equals the
    /// bottom `primaryAction`, platforms must render it in only one location.
    let action: V2DeskPrimaryAction?
    var detail: String? = nil
}

enum V2DeskCheckerVerdict: Equatable, Sendable {
    case passed
    case suspect
    case violation
    case unavailable

    init(_ raw: String?) {
        switch raw {
        case "passed": self = .passed
        case "suspect": self = .suspect
        case "violation": self = .violation
        default: self = .unavailable
        }
    }
}

struct V2DeskEvidenceItem: Identifiable, Equatable, Sendable {
    let id: String
    let kind: String
    let draftEvidence: String
    let bibleEvidence: String
    let sourceKind: String
    let sourceEvidence: String
    let reason: String

    init(_ issue: CheckerIssue) {
        id = issue.id
        kind = issue.kind
        draftEvidence = issue.draftEvidence
        bibleEvidence = issue.bibleEvidence
        sourceKind = issue.sourceKind
        sourceEvidence = issue.sourceEvidence
        reason = issue.reason
    }
}

/// Converts the public Checker source type into author-facing copy. Source
/// IDs deliberately have no presentation here: they are wire identifiers,
/// not evidence an author can act on.
enum CheckerEvidenceSourcePresentation {
    static func label(for sourceKind: String) -> String? {
        switch sourceKind {
        case "bible": return "本章意图"
        case "world", "world_setting": return "世界观"
        case "character", "character_card": return "人物卡"
        case "prior_state", "chapter_state": return "章前状态"
        case "history", "memory": return "历史记忆"
        case "draft", "manuscript": return "正文"
        case "authorization", "character_authorization": return "人物授权"
        default: return nil
        }
    }
}

/// Archive uncertainties are deliberately shown as reported rather than
/// converted into a guessed state. This formatter removes wire identifiers
/// while retaining the person, state slot, conflicting values and recovery
/// instruction an author can use.
enum ArchiveDiagnosticPresentation {
    static func title(for item: ChapterArchiveDiagnostic) -> String {
        let names = [item.characterName, item.otherCharacterName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let subject = names.isEmpty ? scopeLabel(item.scope) : names.joined(separator: "与")
        let slot = slotLabel(item.slot)
        return slot.isEmpty ? subject : "\(subject)的\(slot)"
    }

    static func variantLabel(_ variant: ChapterArchiveDiagnostic.Variant) -> String {
        let operation: String
        switch variant.operation {
        case "set", "replace", "add": operation = "记录为"
        case "remove": operation = "曾记录为"
        default: operation = "出现过"
        }
        return "\(operation)：\(variant.value)"
    }

    private static func scopeLabel(_ scope: String) -> String {
        switch scope {
        case "character_state": return "人物状态"
        case "relationship": return "人物关系"
        case "chapter_state": return "本章状态"
        default: return "这部分状态"
        }
    }

    private static func slotLabel(_ slot: String) -> String {
        switch slot {
        case "relationship": return "关系"
        case "location": return "位置"
        case "goal": return "目标"
        case "emotion": return "心境"
        case "status": return "状态"
        default: return slot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "状态项"
        }
    }
}

enum V2DeskEvidenceState: Equatable, Sendable {
    case none
    case current(verdict: V2DeskCheckerVerdict, issues: [V2DeskEvidenceItem])
    /// A local historical snapshot can explain what changed but never enables
    /// acceptance. Sentence marking is exposed only when there is a real,
    /// deterministic local baseline.
    case stale(
        verdict: V2DeskCheckerVerdict,
        issues: [V2DeskEvidenceItem],
        canMarkChangedSentences: Bool
    )
    case unavailable

    var isCurrent: Bool {
        if case .current = self { return true }
        return false
    }
}

struct V2DeskInactiveArchivePreview: Equatable, Sendable {
    let status: String
    let factCount: Int
    let stateDeltaCount: Int
}

enum V2DeskArchiveState: Equatable, Sendable {
    case notStarted
    case pending
    case complete(factCount: Int, stateDeltaCount: Int)
    /// Facts remain usable, while an independently reported state gap or a
    /// newer failed attempt still needs attention and recovery.
    case usableWithAttention(factCount: Int, stateGapCount: Int, detail: String?)
    /// Inactive previews are display-only and remain separate from active
    /// facts. Retry capability still comes from the actual archive contract.
    case attention(canRetry: Bool, inactivePreview: V2DeskInactiveArchivePreview?)
}

enum V2DeskChapterState: Equatable, Sendable {
    case empty
    case drafting
    case generating
    case checked
    case needsRecheck
    case accepted
    case failed
}

/// Secondary chapter-scope commands. Deliberately excluded from
/// `primaryAction`: v2.0.1 collapsed the primary chain to review → accept,
/// and rewrite/delete must never compete with it for that slot.
struct V2DeskChapterCommands: Equatable, Sendable {
    let canRewrite: Bool
    let canDelete: Bool
}

/// Pure last-chapter policy shared by iOS and macOS so neither platform
/// computes "is this the last chapter" on its own.
enum V2DeskChapterPosition {
    /// An empty list, or an id absent from it, always returns `false`: if it
    /// cannot be proven last, the delete command must not be offered.
    static func isLastChapter(_ chapterID: String?, in chapters: [ChapterSummary]) -> Bool {
        guard let chapterID, let maxIndex = chapters.map(\.index).max() else { return false }
        guard let chapter = chapters.first(where: { $0.id == chapterID }) else { return false }
        return chapter.index == maxIndex
    }
}

/// The one sentence that reports downstream cascade impact. Reopen and
/// rewrite both trigger the identical server-side cascade, so they must
/// describe it with the identical sentence; keeping it here means neither
/// confirmation can be edited without the other following.
private enum V2DeskCascadeSentence {
    /// `nil` when the preview came back and confirmed nothing downstream is
    /// affected — silence is the honest answer there, and a reassuring
    /// sentence would be indistinguishable from the failed-preview case.
    static func make(affected: [RewriteImpactChapter], previewUnavailable: Bool) -> String? {
        if !affected.isEmpty {
            let numbers = affected.sorted { $0.index < $1.index }.map { String($0.index) }.joined(separator: "、")
            return "第 \(numbers) 章的记忆会被标为不再可靠，需要重新整理。"
        }
        if previewUnavailable {
            return "没能取到影响范围；这一章之后的章节记忆可能不再可靠。"
        }
        return nil
    }
}

/// Confirmation copy for "重写本章", shared verbatim by both platforms so a
/// destructive-sounding action is explained identically everywhere it
/// appears. `message` is a pure function of what the backend preview found;
/// it never guesses at cascade impact the client cannot compute on its own.
enum V2DeskRewriteConfirmation {
    static let title = "重写这一章？"

    static func message(
        isAccepted: Bool,
        affected: [RewriteImpactChapter],
        previewUnavailable: Bool
    ) -> String {
        var sentences: [String] = []
        if isAccepted {
            sentences.append("这一章会回到可编辑状态，本章已整理的记忆立即作废。")
        }
        sentences.append("本章意图、标题、出场人物、豁免名单与备注都会保留，只重写正文。")
        sentences.append("新正文要先通过确定性校验与 Bible 检查才会替换当前正文；失败时当前正文原样保留。")
        if let cascade = V2DeskCascadeSentence.make(affected: affected, previewUnavailable: previewUnavailable) {
            sentences.append(cascade)
        }
        return sentences.joined(separator: "\n")
    }
}

/// Confirmation copy for "重新编辑" (reopen without regenerating). This used to
/// be hand-written inside the macOS view while iOS carried a hard-coded older
/// sentence, so the two platforms described the same destructive action
/// differently and only one of them was covered by the copy tests. Reopen
/// keeps the prose, so it deliberately omits the rewrite copy's sentences
/// about overwriting the draft.
enum V2DeskReopenConfirmation {
    static let title = "重新编辑这一章？"

    static func message(affected: [RewriteImpactChapter], previewUnavailable: Bool) -> String {
        var sentences = ["正文与本章意图会保留，这一章回到可编辑状态，本章已整理的记忆立即作废。"]
        if let cascade = V2DeskCascadeSentence.make(affected: affected, previewUnavailable: previewUnavailable) {
            sentences.append(cascade)
        }
        return sentences.joined(separator: "\n")
    }
}

/// Confirmation copy for "删除这一章". The body is static because the outcome
/// is unconditional: every author-owned field on the chapter is removed, so
/// there is no partial-loss variant left to describe.
enum V2DeskDeleteConfirmation {
    static let title = "删除这一章？"
    static let message = "这一章的正文、本章意图、标题、出场人物、豁免名单、备注，以及已经整理好的记忆，都会一起删除。此操作无法撤销。"
}

/// A deliberately narrow, read-only bridge. Platform views assemble it from
/// the existing ChapterEditorStore; this layer neither owns a store nor starts
/// requests, so it cannot drift from the backend task contract.
struct V2DeskEditorSource {
    let chapter: Chapter?
    let writingPhase: ChapterWritingPhase
    let checkerResult: CheckerResult?
    let checkerAppliesToVisibleDraft: Bool
    let checkerRefreshing: Bool
    let staleCheckedSnapshot: CheckedDraftSnapshot?
    let saveState: ChapterSaveState
    let connectionInterrupted: Bool
    /// A stopped or retrying local job monitor. The backend job itself is not
    /// inferred failed from this value.
    let taskMonitoringMessage: String?
    /// A `/check` preflight that contains only server-overridable length
    /// rules. It enables one explicitly confirmed accept, never a default
    /// bypass or a character-attribution override.
    let preflightAcceptanceMessage: String?
    let canRetryGeneratedCandidateChecker: Bool
    /// Computed by each platform from its own `workspace.chapters` via
    /// `V2DeskChapterPosition.isLastChapter` — never derived in here.
    ///
    /// Deliberately has no default. A default of `false` would compile at a
    /// call site that forgot it and silently withhold the delete action
    /// forever, which is exactly how the chapter actions went missing in the
    /// v2 rewrite. Every construction site must state its answer, even the
    /// ones that only read `evidence` and never look at `commands`.
    let isLastChapterInBook: Bool

    init(
        chapter: Chapter?,
        writingPhase: ChapterWritingPhase,
        checkerResult: CheckerResult?,
        checkerAppliesToVisibleDraft: Bool,
        checkerRefreshing: Bool,
        staleCheckedSnapshot: CheckedDraftSnapshot?,
        saveState: ChapterSaveState,
        connectionInterrupted: Bool,
        taskMonitoringMessage: String? = nil,
        preflightAcceptanceMessage: String? = nil,
        canRetryGeneratedCandidateChecker: Bool = false,
        isLastChapterInBook: Bool
    ) {
        self.chapter = chapter
        self.writingPhase = writingPhase
        self.checkerResult = checkerResult
        self.checkerAppliesToVisibleDraft = checkerAppliesToVisibleDraft
        self.checkerRefreshing = checkerRefreshing
        self.staleCheckedSnapshot = staleCheckedSnapshot
        self.saveState = saveState
        self.connectionInterrupted = connectionInterrupted
        self.taskMonitoringMessage = taskMonitoringMessage
        self.preflightAcceptanceMessage = preflightAcceptanceMessage
        self.canRetryGeneratedCandidateChecker = canRetryGeneratedCandidateChecker
        self.isLastChapterInBook = isLastChapterInBook
    }
}

struct V2DeskSnapshot: Equatable, Sendable {
    let chapterID: String?
    let title: String
    let characterCount: Int
    let chapterState: V2DeskChapterState
    let marker: V2DeskMarker
    let primaryAction: V2DeskPrimaryAction
    /// Secondary commands (rewrite/delete). Must never be read as an
    /// alternative to `primaryAction`, and must never influence it.
    let commands: V2DeskChapterCommands
    let taskBanner: V2DeskTaskBanner?
    let evidence: V2DeskEvidenceState
    let archive: V2DeskArchiveState
    let isBodyReadOnly: Bool
    /// Writing remains editable while the server job runs, per the current
    /// client/backend contract. A later result must still pass the ownership
    /// guard before it can replace this body.
    let isBodyEditableWhileGenerating: Bool
    /// A content concern, never a command to open a panel. macOS and iOS keep
    /// the actual panel/page selection locally under author control.
    let contextNeedsAttention: Bool
    let showsUnsavedLocalDraft: Bool
}

enum V2DeskPresentation {
    static func make(_ source: V2DeskEditorSource) -> V2DeskSnapshot {
        let chapter = source.chapter
        let hasDraft = !(chapter?.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let isAccepted = chapter?.status == "finalized"
        let currentVerdict = V2DeskCheckerVerdict(source.checkerResult?.displayVerdict)
        let hasCurrentChecker = source.checkerAppliesToVisibleDraft
            && source.checkerResult?.hasConcreteVerdict == true
        let hasUnavailableCurrentChecker = source.checkerAppliesToVisibleDraft
            && source.checkerResult != nil
            && source.checkerResult?.hasConcreteVerdict == false
            && !source.checkerRefreshing
        let hasStaleSnapshot = CheckerSnapshotPresentationPolicy.shouldShowStaleSnapshot(
            hasConcreteSnapshot: source.staleCheckedSnapshot?.checkerResult.hasConcreteVerdict == true,
            checkerAppliesToVisibleDraft: source.checkerAppliesToVisibleDraft,
            currentCheckerResult: source.checkerResult
        )
        let evidence = makeEvidence(
            source: source,
            hasCurrentChecker: hasCurrentChecker,
            hasStaleSnapshot: hasStaleSnapshot,
            hasUnavailableCurrentChecker: hasUnavailableCurrentChecker
        )
        let archive = makeArchive(chapter?.archive)
        let primaryAction = makePrimaryAction(
            source: source,
            hasDraft: hasDraft,
            isAccepted: isAccepted,
            hasCurrentChecker: hasCurrentChecker,
            currentVerdict: currentVerdict
        )
        let commands = makeCommands(source: source, hasDraft: hasDraft)
        let taskBanner = makeBanner(
            source: source,
            hasDraft: hasDraft,
            isAccepted: isAccepted,
            archive: archive,
            hasUnavailableCurrentChecker: hasUnavailableCurrentChecker
        )
        let chapterState = makeChapterState(
            source: source,
            hasDraft: hasDraft,
            isAccepted: isAccepted,
            hasCurrentChecker: hasCurrentChecker,
            currentVerdict: currentVerdict,
            hasStaleSnapshot: hasStaleSnapshot
        )

        return V2DeskSnapshot(
            chapterID: chapter?.id,
            title: chapter?.title ?? "",
            characterCount: chapter?.draftText.filter { !$0.isWhitespace }.count ?? 0,
            chapterState: chapterState,
            marker: marker(for: chapterState),
            primaryAction: primaryAction,
            commands: commands,
            taskBanner: taskBanner,
            evidence: evidence,
            archive: archive,
            isBodyReadOnly: isAccepted,
            isBodyEditableWhileGenerating: source.writingPhase.isGenerating,
            contextNeedsAttention: (chapter?.userPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                || hasCurrentChecker
                || hasStaleSnapshot,
            showsUnsavedLocalDraft: isUnsaved(source.saveState)
        )
    }

    private static func makeEvidence(
        source: V2DeskEditorSource,
        hasCurrentChecker: Bool,
        hasStaleSnapshot: Bool,
        hasUnavailableCurrentChecker: Bool
    ) -> V2DeskEvidenceState {
        if hasCurrentChecker, let result = source.checkerResult {
            return .current(
                verdict: V2DeskCheckerVerdict(result.displayVerdict),
                issues: (result.issues ?? []).map(V2DeskEvidenceItem.init)
            )
        }
        if hasStaleSnapshot, let snapshot = source.staleCheckedSnapshot {
            let hasProvableDiff = !CheckedDraftSentenceDiff.changedRanges(
                previous: snapshot.draftText,
                current: source.chapter?.draftText ?? ""
            ).isEmpty
            return .stale(
                verdict: V2DeskCheckerVerdict(snapshot.checkerResult.displayVerdict),
                issues: (snapshot.checkerResult.issues ?? []).map(V2DeskEvidenceItem.init),
                canMarkChangedSentences: hasProvableDiff
            )
        }
        if source.checkerRefreshing || hasUnavailableCurrentChecker { return .unavailable }
        return .none
    }

    private static func makeArchive(_ archive: ChapterArchive?) -> V2DeskArchiveState {
        guard let archive else { return .notStarted }
        switch archive.status {
        case "pending", "extracting": return .pending
        case "complete":
            if archive.effectiveStatus == "with_state_gaps"
                || !archive.stateUncertainties.isEmpty
                || archive.latestAttempt?.status == "failed"
                || archive.latestAttemptStatus == "failed" {
                return .usableWithAttention(
                    factCount: archive.facts.count,
                    stateGapCount: archive.stateUncertainties.count,
                    detail: archive.attentionSummary
                )
            }
            return .complete(factCount: archive.facts.count, stateDeltaCount: archive.stateDeltaCount)
        case "partial", "failed", "stale":
            if archive.hasUsableMemory {
                return .usableWithAttention(
                    factCount: archive.facts.count,
                    stateGapCount: archive.stateUncertainties.count,
                    detail: archive.attentionSummary
                )
            }
            // A fresh chapter can legitimately carry the Backend's placeholder
            // `stale` archive with `can_retry == false`. It has no revision
            // lifecycle to surface, even when an old display preview exists.
            guard archive.canRetry else { return .notStarted }
            let preview = archive.inactivePreview.map { inactive in
                V2DeskInactiveArchivePreview(
                    status: inactive.status,
                    factCount: inactive.factCount,
                    stateDeltaCount: inactive.stateDeltaCount
                )
            }
            return .attention(canRetry: archive.canRetry, inactivePreview: preview)
        default:
            return .notStarted
        }
    }

    private static func makePrimaryAction(
        source: V2DeskEditorSource,
        hasDraft: Bool,
        isAccepted: Bool,
        hasCurrentChecker: Bool,
        currentVerdict: V2DeskCheckerVerdict
    ) -> V2DeskPrimaryAction {
        if source.writingPhase.isGenerating { return .cancelGeneration }
        // Extraction and accept acknowledgement have no cancellation route.
        // Keeping their primary action empty prevents a duplicate accept or a
        // premature “start next chapter” while the server state is pending.
        if source.writingPhase.isActive { return .none }
        if isAccepted { return .startNewChapter }
        if case .failed(let code, _, let stage) = source.writingPhase {
            if source.canRetryGeneratedCandidateChecker { return .retryGeneratedCandidateChecker }
            if stage == nil { return .refreshTaskStatus }
            if stage == .extraction { return .retryArchive }
            if stage == .acceptance {
                if needsSettings(code) { return .openSettings }
                return code == "checker_override_required" ? .rerunChecker : .none
            }
            return needsSettings(code) ? .openSettings : .retryGeneration
        }
        if case .cancelled = source.writingPhase { return .generate }
        if source.checkerRefreshing { return .none }
        guard hasDraft else { return .generate }
        if source.preflightAcceptanceMessage != nil { return .acceptWithWarning }
        guard hasCurrentChecker else { return .rerunChecker }
        switch currentVerdict {
        case .passed: return .accept
        case .suspect, .violation: return .acceptWithWarning
        case .unavailable: return .rerunChecker
        }
    }

    /// The only place `canRewrite`/`canDelete` are computed. Accepted and
    /// unaccepted chapters with prose are both rewritable — a draft that was
    /// never accepted must not lose the ability to be rewritten just because
    /// it already has text (that gap is exactly the capability v2 clean-room
    /// lost). Delete never requires prose: an accidentally created blank
    /// final chapter must still be removable.
    private static func makeCommands(
        source: V2DeskEditorSource,
        hasDraft: Bool
    ) -> V2DeskChapterCommands {
        V2DeskChapterCommands(
            canRewrite: source.chapter != nil
                && hasDraft
                && !source.writingPhase.isActive
                && !source.checkerRefreshing,
            canDelete: source.chapter != nil
                && source.isLastChapterInBook
                && !source.writingPhase.isActive
        )
    }

    private static func makeBanner(
        source: V2DeskEditorSource,
        hasDraft: Bool,
        isAccepted: Bool,
        archive: V2DeskArchiveState,
        hasUnavailableCurrentChecker: Bool
    ) -> V2DeskTaskBanner? {
        if source.connectionInterrupted {
            return V2DeskTaskBanner(
                kind: .connectionInterrupted,
                tone: .warning,
                text: source.writingPhase.currentStage == .acceptance
                    ? "接受结果暂未确认，正文仍保留在这里"
                    : "任务状态暂未确认，正文仍保留在这里",
                action: .refreshTaskStatus,
                detail: source.taskMonitoringMessage
            )
        }
        if case .accepting = source.writingPhase {
            return V2DeskTaskBanner(kind: .accepting, tone: .accent, text: "正在确认接受正文", action: nil)
        }
        if case .extracting = source.writingPhase {
            return V2DeskTaskBanner(kind: .archiving, tone: .accent, text: "正在整理这一章的记忆", action: nil)
        }
        if source.writingPhase.isGenerating {
            return V2DeskTaskBanner(kind: .writing, tone: .accent, text: "正在写这一章", action: .cancelGeneration)
        }
        if source.checkerRefreshing {
            return V2DeskTaskBanner(kind: .checking, tone: .accent, text: "正在复查这一章", action: nil)
        }
        if let message = source.preflightAcceptanceMessage {
            return V2DeskTaskBanner(
                kind: .checkerUnavailable,
                tone: .warning,
                text: "正文较短，需要明确确认后接受",
                action: .acceptWithWarning,
                detail: message
            )
        }
        if case .cancelled = source.writingPhase {
            return V2DeskTaskBanner(kind: .cancelled, tone: .neutral, text: "已取消，正文没有变化", action: .generate)
        }
        if case .failed(let code, let message, let stage) = source.writingPhase {
            if stage == nil {
                return V2DeskTaskBanner(
                    kind: .connectionInterrupted,
                    tone: .warning,
                    text: "任务中断，尚不清楚停在哪一步",
                    action: .refreshTaskStatus,
                    detail: message
                )
            }
            if stage == .extraction || isAccepted {
                return V2DeskTaskBanner(kind: .archiveFailed, tone: .warning, text: "记忆没能整理，这一章仍然是完成的", action: .retryArchive, detail: message)
            }
            if stage == .acceptance {
                let action: V2DeskPrimaryAction?
                if needsSettings(code) {
                    action = .openSettings
                } else if code == "checker_override_required" {
                    action = .rerunChecker
                } else {
                    action = nil
                }
                return V2DeskTaskBanner(
                    kind: .generationFailed,
                    tone: .danger,
                    text: "接受正文未完成，正文没有变化",
                    action: action,
                    detail: message
                )
            }
            if needsSettings(code) {
                return V2DeskTaskBanner(kind: .generationFailed, tone: .danger, text: "模型配置需要处理", action: .openSettings, detail: message)
            }
            if source.canRetryGeneratedCandidateChecker {
                return V2DeskTaskBanner(
                    kind: .generationFailed, tone: .warning,
                    text: "生成稿没有通过检查，正文没有变化",
                    action: .retryGeneratedCandidateChecker, detail: message
                )
            }
            return V2DeskTaskBanner(
                kind: .generationFailed,
                tone: .danger,
                text: (stage == .bibleChecking ? "正文检查未通过" : "\(stage?.label ?? "任务")未完成") + (hasDraft ? "，正文没有变化" : ""),
                action: .retryGeneration,
                detail: message
            )
        }
        if hasUnavailableCurrentChecker {
            let detail = source.checkerResult.map { LinoErrorPresenter.present(checkerUnavailable: $0).message }
            return V2DeskTaskBanner(
                kind: .checkerUnavailable,
                tone: .warning,
                text: "这次没能检查",
                action: .rerunChecker,
                detail: detail
            )
        }
        if isAccepted {
            switch archive {
            case .pending:
                return V2DeskTaskBanner(kind: .archiving, tone: .accent, text: "正在整理这一章的记忆", action: nil)
            case .attention:
                return V2DeskTaskBanner(kind: .archiveFailed, tone: .warning, text: "记忆需要重新整理，这一章仍然是完成的", action: .retryArchive, detail: source.chapter?.archive?.errorMessage)
            case .usableWithAttention(_, _, let detail):
                return V2DeskTaskBanner(kind: .archiveFailed, tone: .warning, text: "记忆可用，仍有待整理项", action: .retryArchive, detail: detail)
            default:
                return nil
            }
        }
        return nil
    }

    private static func makeChapterState(
        source: V2DeskEditorSource,
        hasDraft: Bool,
        isAccepted: Bool,
        hasCurrentChecker: Bool,
        currentVerdict: V2DeskCheckerVerdict,
        hasStaleSnapshot: Bool
    ) -> V2DeskChapterState {
        if source.writingPhase.isGenerating { return .generating }
        // Extraction is independent of acceptance. Once prose is accepted,
        // an Extractor configuration or archive failure must not erase the
        // reader/rewriting affordances; its failure remains in the banner.
        if isAccepted { return .accepted }
        if source.writingPhase.isFailed { return .failed }
        if hasStaleSnapshot { return .needsRecheck }
        if hasCurrentChecker, currentVerdict == .passed { return .checked }
        return hasDraft ? .drafting : .empty
    }

    private static func marker(for state: V2DeskChapterState) -> V2DeskMarker {
        switch state {
        case .accepted: return .confirmed
        case .empty, .drafting, .checked, .generating: return .notYetHappened
        case .needsRecheck: return .unreliable
        case .failed: return V2DeskMarker(kind: .solidDot, tone: .danger)
        }
    }

    private static func needsSettings(_ code: String?) -> Bool {
        [
            "not_configured",
            "bad_url",
            "unauthorized",
            "llm_profile_not_configured",
            "llm_profile_missing",
        ].contains(code) || (code?.hasSuffix("_thinking_not_disableable") == true)
    }

    private static func isUnsaved(_ state: ChapterSaveState) -> Bool {
        switch state {
        case .synced: false
        case .unsaved, .savingLocally, .localDraft, .localSaveFailed, .restoredLocalDraft,
             .savingRemotely, .remoteSaveFailed: true
        }
    }
}
