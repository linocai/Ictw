import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// A recovery surface for a deleted chapter's local input. Reading and copying
/// never submits it to the old chapter or removes the retained file.
struct V2RetainedChapterDrafts: View {
    @EnvironmentObject private var sync: ClientSyncStore
    @EnvironmentObject private var notices: NoticeBus
    @State private var drafts: [RetainedChapterDraft] = []
    @State private var selected: RetainedChapterDraft?
    @State private var readFailure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("本机保留稿").font(.headline)
                Spacer()
                Button("刷新", action: reload).buttonStyle(.plain)
            }
            Text("原章节已删除，新增输入仍保留在这台设备。查看并复制后，可手动新建一章、粘贴并保存；确认另存后再移除此副本。")
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let readFailure {
                Text(readFailure).font(.footnote).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if drafts.isEmpty, readFailure == nil {
                Text("没有需要恢复的本机保留稿。")
                    .font(.footnote).foregroundStyle(.secondary)
            } else if !drafts.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(drafts, id: \.id) { draft in
                            Button { selected = draft } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(draft.bookTitle).font(.subheadline.weight(.medium))
                                    Text(chapterLabel(draft)).font(.subheadline)
                                    Text("原章已删除 · 查看并复制")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                            }.buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 190)
            }
        }
        .onAppear(perform: reload)
        .sheet(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
            if let selected { V2RetainedChapterDraftDetail(draft: selected, removed: reload) }
        }
    }

    private func reload() {
        do {
            drafts = try sync.retainedChapterDrafts()
            readFailure = nil
            if let current = selected { selected = drafts.first { $0.id == current.id } }
        } catch {
            readFailure = "未能读取本机保留稿：\(error.localizedDescription) 请保留这些副本并重试刷新。"
            notices.publish(error)
        }
    }

    private func chapterLabel(_ draft: RetainedChapterDraft) -> String {
        let position = draft.chapterIndex.map { "第 \($0) 章" } ?? "原章节"
        return "\(position) · \(draft.chapterTitle)"
    }
}

private struct V2RetainedChapterDraftDetail: View {
    let draft: RetainedChapterDraft
    let removed: () -> Void
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var editor: ChapterEditorStore
    @EnvironmentObject private var notices: NoticeBus
    @State private var confirmingRemoval = false

    var body: some View {
        #if os(iOS)
        NavigationStack {
            content
                .navigationTitle("本机保留稿")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成", action: dismiss.callAsFunction) } }
        }
        .v2IOSNoticeOverlay()
        .confirmationDialog("已另存这份稿件？", isPresented: $confirmingRemoval, titleVisibility: .visible, actions: removalActions, message: removalMessage)
        #else
        V2MacSheetFrame(title: "本机保留稿", width: 700) {
            content.frame(height: 620)
        }
        .confirmationDialog("已另存这份稿件？", isPresented: $confirmingRemoval, actions: removalActions, message: removalMessage)
        #endif
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(draft.bookTitle).font(.title3.weight(.semibold))
                Text((draft.chapterIndex.map { "第 \($0) 章 · " } ?? "原章节 · ") + draft.chapterTitle)
                    .font(.headline)
                Text("原章已删除。这份稿件仅保留在本机，不会自动上传。复制全部稿件包含本章 Bible、作者备注和正文；请手动新建章节后粘贴、保存。")
                    .font(.footnote).foregroundStyle(.secondary)
                HStack {
                    Button("复制全部稿件") { copy(draft.copyText) }
                    Button("仅复制正文") { copy(draft.draftText) }.disabled(draft.draftText.isEmpty)
                }
                readOnlyField("本章 Bible", text: draft.userPrompt)
                readOnlyField("作者备注", text: draft.authorNote)
                readOnlyField("正文", text: draft.draftText)
                Divider()
                Text("复制不会删除这份副本。确认已在其他位置安全保存后，可移除此副本，再重新准备备份。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("已另存，移除此副本", role: .destructive, action: requestRemoval)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
    }

    private func readOnlyField(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.medium))
            Text(text.isEmpty ? "（空）" : text)
                .font(.body).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func removalActions() -> some View {
        Button("确认已另存，移除本机副本", role: .destructive, action: confirmRemoval)
        Button("继续保留", role: .cancel, action: cancelRemoval)
    }
    @ViewBuilder private func removalMessage() -> some View {
        Text("请确认正文、本章 Bible 和作者备注都已另存。此操作只移除当前本机副本，不删除服务器内容；未另存的输入可能无法恢复。")
    }

    private func copy(_ text: String) {
        guard V2RetainedDraftClipboard.write(text) else {
            notices.publish("复制失败，本机保留稿仍在。请重试，或直接选择文字复制后另存。", critical: true, tone: .error)
            return
        }
        notices.publish("已复制。请手动新建章节后粘贴并保存；本机副本仍保留。")
    }

    private func requestRemoval() { confirmingRemoval = true }
    private func cancelRemoval() { confirmingRemoval = false }
    private func confirmRemoval() {
        confirmingRemoval = false
        removeCopy()
    }

    private func removeCopy() {
        do {
            try editor.removeRetainedChapterDraft(draft)
            notices.publish("已移除这份本机副本；服务器内容未改变。")
            removed()
            dismiss()
        } catch {
            notices.publish(error)
        }
    }
}

@MainActor
private enum V2RetainedDraftClipboard {
    static func write(_ text: String) -> Bool {
        #if os(iOS)
        UIPasteboard.general.string = text
        return true
        #else
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}
