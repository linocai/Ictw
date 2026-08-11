import SwiftUI

struct MacInspirationTab: View {
    @EnvironmentObject private var editor: ChapterEditorStore
    @EnvironmentObject private var inspiration: InspirationCreatorStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if let chapter = editor.currentChapter {
                snapshotHints
                if isStale {
                    notice(
                        icon: "clock.arrow.circlepath",
                        text: "基于先前草稿。可按最新内容重想，也可仍采用。",
                        color: LinoTheme.warning
                    )
                    Button("按最新内容重想") { inspiration.generate(for: chapter) }
                        .buttonStyle(LinoIPrimaryButtonStyle(compact: true))
                }
                if editor.writingPhase.isActive {
                    notice(
                        icon: "lock",
                        text: "本章任务运行中；可以浏览，任务结束后再采用。",
                        color: LinoTheme.muted
                    )
                }
                if canUndo {
                    undoRow(chapter)
                }
                content(chapter)
            } else {
                emptyState(
                    icon: "text.book.closed",
                    title: "尚未选择章节",
                    message: "先从左栏选择一章，再让灵感创造师阅读当前 Bible。"
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            if let chapter = editor.currentChapter {
                inspiration.activate(chapter)
            }
        }
        .onChange(of: editor.currentChapter?.id) { _, id in
            inspiration.clearIfChapterChanged(to: id)
            if let chapter = editor.currentChapter {
                inspiration.activate(chapter)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(LinoTheme.accent)
                .frame(width: 28, height: 28)
                .background(LinoTheme.accentSoft, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text("灵感创造师")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(LinoTheme.ink)
                Text("只提供建议，不会自动保存")
                    .font(.system(size: 11))
                    .foregroundStyle(LinoTheme.muted)
            }
            Spacer(minLength: 4)
            if inspiration.isLoading {
                Button("停止") { inspiration.stop() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(LinoTheme.muted)
            } else if !inspiration.cards.isEmpty, let chapter = editor.currentChapter {
                Button("换一批") { inspiration.generate(for: chapter) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(LinoTheme.accent)
            }
        }
    }

    @ViewBuilder
    private var snapshotHints: some View {
        if inspiration.snapshot?.bible.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true
            || inspiration.snapshot?.selectedCharacterIDs.isEmpty == true {
            let emptyBible = inspiration.snapshot?.bible.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true
            let noCharacters = inspiration.snapshot?.selectedCharacterIDs.isEmpty == true
            notice(
                icon: "lightbulb.min",
                text: emptyBible && noCharacters
                    ? "可从空白 Bible 开始；当前无人，建议不会擅用书中角色。"
                    : (emptyBible ? "可以从空白 Bible 开始发想。" : "当前无人，建议不会擅用书中角色。"),
                color: LinoTheme.accent
            )
        }
    }

    @ViewBuilder
    private func content(_ chapter: Chapter) -> some View {
        if inspiration.isLoading {
            VStack(spacing: 12) {
                ProgressView().controlSize(.small).tint(LinoTheme.accent)
                Text("正在阅读当前快照与有效历史…")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(LinoTheme.ink2)
                Text("中央 Bible 可以继续编辑。")
                    .font(.system(size: 11))
                    .foregroundStyle(LinoTheme.muted)
                Button("停止本次") { inspiration.stop() }
                    .buttonStyle(LinoITintButtonStyle(compact: true))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 26)
        } else if let error = inspiration.errorMessage {
            VStack(alignment: .leading, spacing: 10) {
                Label("这次没有找到可用灵感", systemImage: "exclamationmark.bubble")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(LinoTheme.ink)
                Text(error)
                    .font(.system(size: 11.5))
                    .foregroundStyle(LinoTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Button("重新生成") { inspiration.generate(for: chapter) }
                    .buttonStyle(LinoIPrimaryButtonStyle(compact: true))
            }
            .padding(.vertical, 12)
        } else if inspiration.cards.isEmpty {
            emptyState(
                icon: "sparkles",
                title: "寻找几条不同方向",
                message: "每次 3–5 条；采用后只追加到本地 Bible。",
                action: { inspiration.generate(for: chapter) }
            )
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(inspiration.cards.enumerated()), id: \.element.id) { index, card in
                    if index > 0 {
                        Divider().overlay(LinoTheme.line).padding(.vertical, 14)
                    }
                    ideaRow(card, number: index + 1)
                }
            }
        }
    }

    private func ideaRow(_ card: InspirationCard, number: Int) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(String(format: "%02d", number))
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(LinoTheme.faint)
                Text(card.title)
                    .font(LinoType.serif(14.5, .semibold))
                    .foregroundStyle(LinoTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !card.historyChapterIndexes.isEmpty {
                Label(historyLabel(card.historyChapterIndexes), systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(LinoTheme.success)
            }
            Text(card.body)
                .font(LinoType.serif(13.5))
                .lineSpacing(5)
                .foregroundStyle(LinoTheme.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let basis = card.historyBasis, !basis.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("承接既有记录")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(LinoTheme.success)
                    Text(basis)
                        .font(.system(size: 11.5))
                        .foregroundStyle(LinoTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 9)
                .overlay(alignment: .leading) {
                    Rectangle().fill(LinoTheme.success.opacity(0.45)).frame(width: 2)
                }
            }
            if let note = card.note, !note.isEmpty {
                Label(note, systemImage: "note.text")
                    .font(.system(size: 11.5))
                    .foregroundStyle(LinoTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(adoptionTitle(card)) { adopt(card) }
                    .buttonStyle(LinoITintButtonStyle(compact: true))
                    .disabled(editor.writingPhase.isActive || inspiration.adoptedCardIDs.contains(card.id))
                    .help(editor.writingPhase.isActive ? "等待本章任务结束后采用" : "追加到本地 Bible，不会自动保存")
            }
        }
    }

    private func notice(icon: String, text: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 15)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(LinoTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(9)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func emptyState(
        icon: String,
        title: String,
        message: String,
        action: (() -> Void)? = nil
    ) -> some View {
        VStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(LinoTheme.faint)
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(LinoTheme.ink2)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(LinoTheme.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let action {
                Button("开始找灵感", action: action)
                    .buttonStyle(LinoIPrimaryButtonStyle(compact: true))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private func undoRow(_ chapter: Chapter) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(LinoTheme.success)
            Text("已加入本地 Bible")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(LinoTheme.ink2)
            Spacer()
            Button("撤销") {
                guard let before = inspiration.consumeUndo(
                    chapterID: chapter.id,
                    currentBible: chapter.userPrompt
                ) else { return }
                editor.editString(\.userPrompt, value: before)
            }
            .buttonStyle(.plain)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(LinoTheme.accent)
        }
        .padding(9)
        .background(LinoTheme.success.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var isStale: Bool {
        !inspiration.cards.isEmpty && inspiration.isStale(comparedTo: editor.currentChapter)
    }

    private var canUndo: Bool {
        guard let chapter = editor.currentChapter else { return false }
        return inspiration.canUndo(chapterID: chapter.id, currentBible: chapter.userPrompt)
    }

    private func adopt(_ card: InspirationCard) {
        guard !editor.writingPhase.isActive, let chapter = editor.currentChapter else { return }
        let before = chapter.userPrompt
        let after = InspirationDraftPolicy.appending(body: card.body, to: before)
        editor.editString(\.userPrompt, value: after)
        inspiration.recordAdoption(card: card, chapterID: chapter.id, before: before, after: after)
    }

    private func adoptionTitle(_ card: InspirationCard) -> String {
        if inspiration.adoptedCardIDs.contains(card.id) { return "已采用" }
        return isStale ? "仍采用" : "采用"
    }

    private func historyLabel(_ indexes: [Int]) -> String {
        "承接第 " + indexes.map(String.init).joined(separator: "、") + " 章"
    }
}
