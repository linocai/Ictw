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
    case accept
    case acceptWithWarning
    case startNextChapter
    case retryGeneration
    case retryArchive
    case openSettings
    case none

    var title: String {
        switch self {
        case .generate: "生成这一章"
        case .cancelGeneration: "取消生成"
        case .rerunChecker: "重新复查"
        case .accept: "接受这一章"
        case .acceptWithWarning: "仍然接受"
        case .startNextChapter: "开始下一章"
        case .retryGeneration: "重试"
        case .retryArchive: "重试整理"
        case .openSettings: "去设置"
        case .none: ""
        }
    }

    var requiresConfirmation: Bool {
        self == .acceptWithWarning
    }
}

enum V2DeskBannerKind: Equatable, Sendable {
    case writing
    case checking
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
    let reason: String

    init(_ issue: CheckerIssue) {
        id = issue.id
        kind = issue.kind
        draftEvidence = issue.draftEvidence
        bibleEvidence = issue.bibleEvidence
        reason = issue.reason
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

    init(
        chapter: Chapter?,
        writingPhase: ChapterWritingPhase,
        checkerResult: CheckerResult?,
        checkerAppliesToVisibleDraft: Bool,
        checkerRefreshing: Bool,
        staleCheckedSnapshot: CheckedDraftSnapshot?,
        saveState: ChapterSaveState,
        connectionInterrupted: Bool
    ) {
        self.chapter = chapter
        self.writingPhase = writingPhase
        self.checkerResult = checkerResult
        self.checkerAppliesToVisibleDraft = checkerAppliesToVisibleDraft
        self.checkerRefreshing = checkerRefreshing
        self.staleCheckedSnapshot = staleCheckedSnapshot
        self.saveState = saveState
        self.connectionInterrupted = connectionInterrupted
    }
}

struct V2DeskSnapshot: Equatable, Sendable {
    let chapterID: String?
    let title: String
    let characterCount: Int
    let chapterState: V2DeskChapterState
    let marker: V2DeskMarker
    let primaryAction: V2DeskPrimaryAction
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
            return .complete(factCount: archive.facts.count, stateDeltaCount: archive.stateDeltaCount)
        case "partial", "failed", "stale":
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
        if isAccepted { return .startNextChapter }
        if case .failed(let code, _, let stage) = source.writingPhase {
            if stage == .extraction { return .retryArchive }
            return needsSettings(code) ? .openSettings : .retryGeneration
        }
        if case .cancelled = source.writingPhase { return .generate }
        if source.checkerRefreshing { return .none }
        guard hasDraft else { return .generate }
        guard hasCurrentChecker else { return .rerunChecker }
        switch currentVerdict {
        case .passed: return .accept
        case .suspect, .violation: return .acceptWithWarning
        case .unavailable: return .rerunChecker
        }
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
                text: "任务状态暂时无法更新，正文仍保留在这里",
                action: nil
            )
        }
        if source.writingPhase.isGenerating {
            return V2DeskTaskBanner(kind: .writing, tone: .accent, text: "正在写这一章", action: .cancelGeneration)
        }
        if source.checkerRefreshing {
            return V2DeskTaskBanner(kind: .checking, tone: .accent, text: "正在复查这一章", action: nil)
        }
        if case .cancelled = source.writingPhase {
            return V2DeskTaskBanner(kind: .cancelled, tone: .neutral, text: "已取消，正文没有变化", action: .generate)
        }
        if case .failed(let code, _, let stage) = source.writingPhase {
            if stage == .extraction || isAccepted {
                return V2DeskTaskBanner(kind: .archiveFailed, tone: .warning, text: "记忆没能整理，这一章仍然是完成的", action: .retryArchive)
            }
            if needsSettings(code) {
                return V2DeskTaskBanner(kind: .generationFailed, tone: .danger, text: "还没有可用的模型", action: .openSettings)
            }
            return V2DeskTaskBanner(
                kind: .generationFailed,
                tone: .danger,
                text: hasDraft ? "没能写出这一章，正文没有变化" : "没能开始写这一章",
                action: .retryGeneration
            )
        }
        if hasUnavailableCurrentChecker {
            return V2DeskTaskBanner(
                kind: .checkerUnavailable,
                tone: .warning,
                text: "这次没能检查",
                action: .acceptWithWarning
            )
        }
        if isAccepted {
            switch archive {
            case .pending:
                return V2DeskTaskBanner(kind: .archiving, tone: .accent, text: "正在整理这一章的记忆", action: nil)
            case .attention:
                return V2DeskTaskBanner(kind: .archiveFailed, tone: .warning, text: "记忆需要重新整理，这一章仍然是完成的", action: .retryArchive)
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
        if source.writingPhase.isFailed { return .failed }
        if isAccepted { return .accepted }
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
