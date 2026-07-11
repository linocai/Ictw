import SwiftUI

/// 右栏「角色」tab：人物 chips 横向选择（FlowLayout）+ 选中卡（姓名/身份/固定
/// 设定可编辑保存；动态字段只读展示；故事线 events 单条改/删）+ 新建 / 导入人物
/// 卡 sheet + 删除人物确认。全部复用 `CharactersStore`。
///
/// 关于故事线「增」：本项目数据层（`CharactersStore` / `LinoAPI`）只有
/// `updateEvent` / `deleteEvent`，人物事件由 Extractor 归档时创建，没有手动新增
/// 事件的接口——与 iOS `CharactersViews` 完全一致（iOS 也只做改/删）。本块不新增
/// 后端/store 写逻辑，故此处同样只做改/删。
struct MacCharacterTab: View {
    @EnvironmentObject private var characters: CharactersStore
    @State private var showingNewCharacter = false
    @State private var showingImport = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if characters.characters.isEmpty && !characters.isLoading {
                LinoIEmptyCard(
                    title: "还没有人物",
                    subtitle: "可以从已有人物卡文本导入，也可以先建一个空人物。",
                    actionTitle: "导入人物卡"
                ) {
                    showingImport = true
                }
            } else {
                chipRow
                if let selected = characters.selected {
                    MacCharacterCard(character: selected)
                }
            }
        }
        .sheet(isPresented: $showingNewCharacter) { MacNewCharacterSheet() }
        .sheet(isPresented: $showingImport) { MacImportCharacterSheet() }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                LinoISectionLabel("角色")
                Text("固定设定由你维护，动态字段与故事线由 Extractor 更新。")
                    .font(.system(size: 11))
                    .foregroundStyle(LinoTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Menu {
                Button("新建人物", systemImage: "plus") { showingNewCharacter = true }
                Button("导入人物卡", systemImage: "square.and.arrow.down") { showingImport = true }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 26, height: 26)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(LinoTheme.accentDeep)
            .background(Color.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(LinoMacMetrics.hairline, lineWidth: LinoMacMetrics.hairlineWidth))
            .onHover { pointer($0) }
        }
    }

    private var chipRow: some View {
        FlowLayout(spacing: 8) {
            ForEach(characters.characters) { character in
                MacCharacterChip(
                    character: character,
                    selected: character.id == characters.selected?.id
                ) {
                    characters.selectedCharacterId = character.id
                }
            }
        }
    }
}

// MARK: - Chip

private struct MacCharacterChip: View {
    let character: Character
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                LinoIAvatar(name: character.name, size: 22)
                Text(character.name.isEmpty ? "未命名" : character.name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(selected ? .white : LinoTheme.ink)
            }
            .padding(.leading, 6)
            .padding(.trailing, 11)
            .padding(.vertical, 6)
            .background {
                if selected {
                    Capsule().fill(LinoTheme.accentGradient)
                } else {
                    Capsule().fill(Color.white.opacity(0.72))
                }
            }
            .overlay(Capsule().stroke(LinoTheme.accent.opacity(selected ? 0 : 0.22), lineWidth: 0.6))
        }
        .buttonStyle(.plain)
        .onHover { pointer($0) }
    }
}

// MARK: - Selected character card

private struct MacCharacterCard: View {
    @EnvironmentObject private var characters: CharactersStore
    @State private var name = ""
    @State private var role = ""
    @State private var fixedProfile = ""
    @State private var loadedId: String?
    @State private var confirmingDelete = false

    let character: Character

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 11) {
                LinoIAvatar(name: name.isEmpty ? character.name : name, size: 40, rounded: true)
                VStack(alignment: .leading, spacing: 7) {
                    LinoITextField("姓名", text: $name)
                    LinoITextField("身份 / 职能", text: $role)
                }
                LinoMacIconButton(systemName: "trash", style: .danger, size: 30, fontSize: 13, help: "删除人物") {
                    confirmingDelete = true
                }
            }

            LinoIEditor(
                title: "固定设定",
                text: $fixedProfile,
                minHeight: 180,
                placeholder: "外貌、背景、性格、关系、说话方式、禁忌等。"
            )

            Button {
                Task { await save() }
            } label: {
                Label("保存人物卡", systemImage: "checkmark")
            }
            .buttonStyle(LinoIPrimaryButtonStyle(compact: true))
            .onHover { pointer($0) }

            dynamicFieldsSection
            storylineSection
        }
        .padding(14)
        .background(Color.white.opacity(0.66), in: RoundedRectangle(cornerRadius: LinoMacMetrics.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: LinoMacMetrics.cardRadius, style: .continuous).stroke(LinoMacMetrics.hairline, lineWidth: LinoMacMetrics.hairlineWidth))
        .onAppear(perform: sync)
        .onChange(of: character.id) { _, _ in sync() }
        .confirmationDialog("删除这个人物？", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                Task { await characters.delete(character) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("《\(character.name.isEmpty ? "未命名" : character.name)》及其故事线事件都会被删除。")
        }
    }

    private var dynamicFieldsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            LinoISectionLabel("动态字段")
            if character.dynamicFields.isEmpty {
                hint("还没有 Extractor 维护的动态状态。")
            } else {
                VStack(spacing: 8) {
                    ForEach(character.dynamicFields.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(key)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(LinoTheme.accentDeep)
                            Text(value.description.isEmpty ? "空" : value.description)
                                .font(.system(size: 12))
                                .foregroundStyle(LinoTheme.body)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(11)
                        .background(Color.white.opacity(0.54), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }
                }
            }
        }
    }

    private var storylineSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            LinoISectionLabel("人物故事线")
            if character.events.isEmpty {
                hint("接受章节后，Extractor 会把本人物的大事和故事线写到这里。")
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(character.events) { event in
                        MacCharacterEventRow(event: event)
                    }
                }
            }
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(LinoTheme.faint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.white.opacity(0.5), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private func sync() {
        guard loadedId != character.id else { return }
        loadedId = character.id
        name = character.name
        role = character.role
        fixedProfile = character.fixedProfile
    }

    private func save() async {
        var updated = character
        updated.name = name
        updated.role = role
        updated.fixedProfile = fixedProfile
        await characters.update(updated)
    }
}

// MARK: - Storyline event row (edit / delete)

private struct MacCharacterEventRow: View {
    @EnvironmentObject private var characters: CharactersStore
    @State private var isEditing = false
    @State private var draftText = ""
    @State private var confirmingDelete = false

    let event: CharacterEvent

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(event.chapterIndex.map { "第 \($0) 章" } ?? "章节")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(LinoTheme.accent, in: Capsule())

            if isEditing {
                VStack(alignment: .leading, spacing: 8) {
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $draftText)
                            .frame(minHeight: 64)
                            .scrollContentBackground(.hidden)
                            .font(.system(size: 12.5))
                            .foregroundStyle(LinoTheme.body)
                            .padding(6)
                    }
                    .background(Color.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(LinoMacMetrics.hairline, lineWidth: LinoMacMetrics.hairlineWidth))
                    HStack(spacing: 8) {
                        Button("取消") {
                            draftText = event.eventText
                            isEditing = false
                        }
                        .buttonStyle(LinoITintButtonStyle(compact: true))
                        .onHover { pointer($0) }
                        Button("保存") {
                            Task {
                                await characters.updateEvent(event, text: draftText)
                                isEditing = false
                            }
                        }
                        .buttonStyle(LinoIPrimaryButtonStyle(compact: true))
                        .onHover { pointer($0) }
                    }
                }
            } else {
                Text(event.eventText)
                    .font(.system(size: 12.5))
                    .foregroundStyle(LinoTheme.body)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            if !isEditing {
                Menu {
                    Button("编辑", systemImage: "pencil") {
                        draftText = event.eventText
                        isEditing = true
                    }
                    Button("删除", systemImage: "trash", role: .destructive) {
                        confirmingDelete = true
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 24, height: 24)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(LinoTheme.muted)
                .onHover { pointer($0) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(Color.white.opacity(0.54), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .onAppear { draftText = event.eventText }
        .confirmationDialog("删除这条故事线？", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                Task { await characters.deleteEvent(event) }
            }
            Button("取消", role: .cancel) {}
        }
    }
}

// MARK: - New character sheet

private struct MacNewCharacterSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var characters: CharactersStore
    @State private var name = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("新建人物")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(LinoTheme.ink)
            VStack(alignment: .leading, spacing: 7) {
                LinoISectionLabel("姓名")
                LinoITextField("姓名", text: $name)
                    .focused($nameFocused)
                    .onSubmit { submit() }
            }
            Text("建好后可以在人物卡里补固定设定。")
                .font(.system(size: 12))
                .foregroundStyle(LinoTheme.muted)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(LinoITintButtonStyle(compact: true))
                    .onHover { pointer($0) }
                Button("创建人物") { submit() }
                    .buttonStyle(LinoIPrimaryButtonStyle(compact: true))
                    .onHover { pointer($0) }
            }
        }
        .padding(24)
        .frame(width: 400)
        .background(LinoTheme.background)
        .onAppear { nameFocused = true }
    }

    private func submit() {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            await characters.create(name: value.isEmpty ? "未命名人物" : value)
            dismiss()
        }
    }
}

// MARK: - Import character sheet

private struct MacImportCharacterSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var characters: CharactersStore
    @State private var name = ""
    @State private var role = ""
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("导入人物卡")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(LinoTheme.ink)
            LinoITextField("姓名", text: $name)
            LinoITextField("身份 / 职能（可选）", text: $role)
            LinoIEditor(
                title: "人物卡文本",
                text: $text,
                minHeight: 240,
                placeholder: "粘贴已有的人物卡。第一版按纯文本保存为固定设定。"
            )
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(LinoITintButtonStyle(compact: true))
                    .onHover { pointer($0) }
                Button("导入人物卡") {
                    Task {
                        await characters.importCharacter(
                            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未命名人物" : name,
                            role: role,
                            text: text
                        )
                        dismiss()
                    }
                }
                .buttonStyle(LinoIPrimaryButtonStyle(compact: true))
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .onHover { pointer($0 && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(LinoTheme.background)
    }
}
