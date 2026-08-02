import SwiftUI

struct LinoICharactersPane: View {
    @EnvironmentObject private var characters: CharactersStore
    @State private var showingNewCharacter = false
    @State private var showingImport = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .bottom, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("人物")
                        .font(LinoType.paneTitle)
                        .foregroundStyle(LinoTheme.ink)
                    Text("固定设定你维护，动态字段由 Extractor 更新")
                        .font(LinoType.ui(12))
                        .foregroundStyle(LinoTheme.muted)
                }
                Spacer()
                Menu {
                    Button("新建人物", systemImage: "plus") { showingNewCharacter = true }
                    Button("导入人物卡", systemImage: "square.and.arrow.down") { showingImport = true }
                } label: {
                    Label("新建", systemImage: "plus")
                        .font(LinoType.ui(12.5, .semibold))
                        .foregroundStyle(LinoTheme.accentText)
                        .padding(.horizontal, 13)
                        .frame(height: 32)
                        .background(LinoTheme.accent, in: Capsule())
                }
            }
            .padding(.horizontal, 4)

            if characters.characters.isEmpty && !characters.isLoading {
                LinoIEmptyCard(
                    title: "还没有人物",
                    subtitle: "可以从已有的人物卡文本导入，也可以先建一个空人物。",
                    actionTitle: "导入人物卡"
                ) {
                    showingImport = true
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(characters.characters.enumerated()), id: \.element.id) { offset, character in
                        LinoICharacterListRow(
                            character: character,
                            selected: character.id == characters.selected?.id
                        ) {
                            characters.selectedCharacterId = character.id
                        }
                        if offset != characters.characters.count - 1 {
                            Divider().overlay(LinoTheme.line).padding(.leading, 60)
                        }
                    }
                }
                .background(LinoTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(LinoTheme.line, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .linoAnimation(LinoMotion.listItem, value: characters.characters.map(\.id))

                if let selected = characters.selected {
                    LinoICharacterCard(character: selected)
                }
            }
        }
        .sheet(isPresented: $showingNewCharacter) {
            LinoINewCharacterSheet()
                .presentationDetents([.height(250)])
                .presentationCornerRadius(20)
        }
        .sheet(isPresented: $showingImport) {
            LinoIImportCharacterSheet()
                .presentationDetents([.large])
                .presentationCornerRadius(20)
        }
    }
}

private struct LinoICharacterListRow: View {
    let character: Character
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                LinoIAvatar(name: character.name, size: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(character.name.isEmpty ? "未命名" : character.name)
                        .font(LinoType.serif(15, .semibold))
                        .foregroundStyle(LinoTheme.ink)
                        .lineLimit(1)
                    Text(character.role.isEmpty ? "未填写身份" : character.role)
                        .font(LinoType.caption)
                        .foregroundStyle(LinoTheme.muted)
                        .lineLimit(1)
                }
                Spacer()
                Text("\(character.events.count) 条")
                    .font(LinoType.caption)
                    .foregroundStyle(LinoTheme.faint)
            }
            .padding(.horizontal, 14)
            .frame(height: 58)
            .background(selected ? LinoTheme.surface2 : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(selected ? "已选择" : "未选择")
    }
}

private struct LinoICharacterCard: View {
    @EnvironmentObject private var characters: CharactersStore
    @State private var name = ""
    @State private var role = ""
    @State private var fixedProfile = ""
    @State private var loadedId: String?
    @State private var confirmingDelete = false

    let character: Character

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                LinoIAvatar(name: name.isEmpty ? character.name : name, size: 46)
                VStack(alignment: .leading, spacing: 2) {
                    TextField("姓名", text: $name)
                        .textFieldStyle(.plain)
                        .font(LinoType.serif(18, .bold))
                        .foregroundStyle(LinoTheme.ink)
                    TextField("身份 / 职能", text: $role)
                        .textFieldStyle(.plain)
                        .font(LinoType.ui(12))
                        .foregroundStyle(LinoTheme.muted)
                }
                Spacer()
                Menu {
                    Button("保存人物", systemImage: "checkmark") { Task { await save() } }
                    Button("删除人物", systemImage: "trash", role: .destructive) { confirmingDelete = true }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .foregroundStyle(LinoTheme.muted)
                }
            }
            .padding(16)

            Divider().overlay(LinoTheme.line).padding(.horizontal, 16)

            VStack(alignment: .leading, spacing: 10) {
                LinoISectionLabel("固定设定")
                TextEditor(text: $fixedProfile)
                    .scrollContentBackground(.hidden)
                    .font(LinoType.serif(14))
                    .lineSpacing(11)
                    .foregroundStyle(LinoTheme.ink2)
                    .frame(minHeight: 120)
                Button("保存人物卡") { Task { await save() } }
                    .font(LinoType.ui(13, .semibold))
                    .foregroundStyle(LinoTheme.accent)
                    .buttonStyle(.plain)
            }
            .padding(16)

            dynamicFieldsSection
            storylineSection
        }
        .background(LinoTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(LinoTheme.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onAppear(perform: sync)
        .onChange(of: character.id) { _, _ in sync() }
        .confirmationDialog("删除这个人物？", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) { Task { await characters.delete(character) } }
            Button("取消", role: .cancel) {}
        }
    }

    private var dynamicFieldsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                LinoISectionLabel("动态字段 · EXTRACTOR")
                Spacer()
            }
            .padding(.horizontal, 16)

            if character.dynamicFields.isEmpty {
                Text("还没有 Extractor 维护的动态状态。")
                    .font(LinoType.ui(12))
                    .foregroundStyle(LinoTheme.faint)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
            } else {
                VStack(spacing: 1) {
                    ForEach(character.dynamicFields.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                        HStack(alignment: .top, spacing: 10) {
                            Text(key)
                                .font(LinoType.ui(12, .semibold))
                                .foregroundStyle(LinoTheme.muted)
                                .frame(width: 60, alignment: .leading)
                            Text(value.description.isEmpty ? "空" : value.description)
                                .font(LinoType.serif(13.5))
                                .foregroundStyle(LinoTheme.ink2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .background(LinoTheme.surface2)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
    }

    private var storylineSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                LinoISectionLabel("人物故事线")
                Spacer()
                Text("\(character.events.count) 条")
                    .font(LinoType.caption)
                    .foregroundStyle(LinoTheme.faint)
            }
            .padding(.horizontal, 16)

            if character.events.isEmpty {
                Text("接受章节后，Extractor 会把本人物的大事和故事线写到这里。")
                    .font(LinoType.ui(12))
                    .foregroundStyle(LinoTheme.faint)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(character.events.enumerated()), id: \.element.id) { offset, event in
                        LinoICharacterEventRow(event: event, isLast: offset == character.events.count - 1)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
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

private struct LinoICharacterEventRow: View {
    @EnvironmentObject private var characters: CharactersStore
    @State private var isEditing = false
    @State private var draftText = ""
    @State private var confirmingDelete = false

    let event: CharacterEvent
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 0) {
                Circle()
                    .fill(event.chapterIndex == nil ? LinoTheme.line2 : LinoTheme.accent)
                    .frame(width: 7, height: 7)
                if !isLast {
                    Rectangle().fill(LinoTheme.line2).frame(width: 1, height: 66)
                }
            }
            .frame(width: 16)
            .padding(.top, 5)

            VStack(alignment: .leading, spacing: 7) {
                Text(event.chapterIndex.map { "第 \($0) 章" } ?? "章节")
                    .font(LinoType.ui(11, .semibold))
                    .foregroundStyle(LinoTheme.muted)

                if isEditing {
                    TextEditor(text: $draftText)
                        .scrollContentBackground(.hidden)
                        .font(LinoType.serif(13.5))
                        .lineSpacing(8)
                        .foregroundStyle(LinoTheme.ink2)
                        .frame(minHeight: 72)
                        .padding(8)
                        .background(LinoTheme.surface2, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    HStack(spacing: 8) {
                        Button("取消") { draftText = event.eventText; isEditing = false }
                            .buttonStyle(LinoITintButtonStyle(compact: true))
                        Button("保存") {
                            Task { await characters.updateEvent(event, text: draftText); isEditing = false }
                        }
                        .buttonStyle(LinoIPrimaryButtonStyle(compact: true))
                    }
                } else {
                    Text(event.eventText)
                        .font(LinoType.serif(13.5))
                        .lineSpacing(8)
                        .foregroundStyle(LinoTheme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)
            if !isEditing {
                Menu {
                    Button("编辑", systemImage: "pencil") { draftText = event.eventText; isEditing = true }
                    Button("删除", systemImage: "trash", role: .destructive) { confirmingDelete = true }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .foregroundStyle(LinoTheme.muted)
                }
            }
        }
        .onAppear { draftText = event.eventText }
        .confirmationDialog("删除这条故事线？", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) { Task { await characters.deleteEvent(event) } }
            Button("取消", role: .cancel) {}
        }
    }
}

private struct LinoINewCharacterSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var characters: CharactersStore
    @State private var name = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                LinoITextField("姓名", text: $name)
                Text("建好后可以在人物卡里补固定设定。")
                    .font(LinoType.ui(12))
                    .foregroundStyle(LinoTheme.muted)
                Spacer()
                Button("创建人物") {
                    let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task { await characters.create(name: value.isEmpty ? "未命名人物" : value); dismiss() }
                }
                .buttonStyle(LinoIPrimaryButtonStyle())
            }
            .padding(18)
            .navigationTitle("新建人物")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .background(LinoTheme.bg.ignoresSafeArea())
        }
    }
}

private struct LinoIImportCharacterSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var characters: CharactersStore
    @State private var name = ""
    @State private var role = ""
    @State private var text = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                LinoITextField("姓名", text: $name)
                LinoITextField("身份 / 职能（可选）", text: $role)
                LinoIEditor(
                    title: "人物卡文本",
                    text: $text,
                    minHeight: 330,
                    placeholder: "粘贴你已有的人物卡。第一版按纯文本保存为固定设定。"
                )
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
                .buttonStyle(LinoIPrimaryButtonStyle())
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(18)
            .navigationTitle("导入人物卡")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .background(LinoTheme.bg.ignoresSafeArea())
        }
    }
}
