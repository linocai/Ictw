import SwiftUI

/// 左栏章节列表：宽 `LinoMacMetrics.sidebarWidth`，`.linoSidebarGlass`。header
/// （kicker「章节」+「N 章 · N 人物」+ 新建章节钮）；行 = 序号封面块 + 标题
/// （Songti SC）+ `LinoIStatusPill`，选中态 accent 底/描边。复用
/// `WorkspaceStore.chapters` / `createChapter`；删除入口保持与 iOS 一致，留在
/// 编辑器主区（不在侧栏放右键删除，避免两套确认文案分叉）。
struct MacChapterSidebar: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var characters: CharactersStore

    @Binding var selectedChapterId: String?
    @State private var isCreating = false

    var body: some View {
        VStack(spacing: 0) {
            header
            list
        }
        .frame(maxHeight: .infinity)
        .linoSidebarGlass()
        .overlay(alignment: .trailing) {
            Rectangle().fill(LinoMacMetrics.hairline).frame(width: LinoMacMetrics.hairlineWidth)
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                LinoISectionLabel("章节")
                Text("\(workspace.chapters.count) 章 · \(characters.characters.count) 人物")
                    .font(.system(size: 12))
                    .foregroundStyle(LinoTheme.muted)
            }
            Spacer()
            Button {
                createChapter()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(LinoTheme.accentDeep)
                    .frame(width: 28, height: 28)
                    .background(Color.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(LinoMacMetrics.hairline, lineWidth: LinoMacMetrics.hairlineWidth))
            }
            .buttonStyle(.plain)
            .disabled(isCreating)
            .help("新建章节")
            .onHover { pointer($0 && !isCreating) }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(workspace.chapters) { chapter in
                    MacChapterRow(
                        chapter: chapter,
                        selected: selectedChapterId == chapter.id
                    ) {
                        selectedChapterId = chapter.id
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .padding(.bottom, 12)
        }
        .frame(maxHeight: .infinity)
    }

    private func createChapter() {
        guard !isCreating else { return }
        isCreating = true
        Task {
            await workspace.createChapter()
            if let created = workspace.chapterPath.last {
                selectedChapterId = created.id
            }
            isCreating = false
        }
    }
}

private struct MacChapterRow: View {
    let chapter: ChapterSummary
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text("\(chapter.index)")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 40)
                    .background(LinoTheme.coverGradient(chapter.id), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 5) {
                    Text(chapter.title.isEmpty ? "第 \(chapter.index) 章" : chapter.title)
                        .font(.custom("Songti SC", size: 14.5).weight(.semibold))
                        .foregroundStyle(selected ? LinoTheme.accentDeep : LinoTheme.ink)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    LinoIStatusPill(text: chapter.status.linoStatusLabel, status: chapter.status)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(selected ? LinoTheme.accent.opacity(0.10) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(selected ? LinoTheme.accent.opacity(0.32) : Color.clear, lineWidth: 0.6)
            )
        }
        .buttonStyle(.plain)
        .onHover { pointer($0) }
    }
}
