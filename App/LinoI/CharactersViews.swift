import SwiftUI

struct LinoICharactersPane: View {
    @EnvironmentObject private var characters: CharactersStore
    @State private var showingNewCharacter = false
    @State private var showingImport = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("人物")
                        .font(.title3.bold())
                        .foregroundStyle(LinoTheme.ink)
                    Text("固定设定由你维护，动态字段和故事线由 Extractor 更新。")
                        .font(.caption)
                        .foregroundStyle(LinoTheme.muted)
                }
                Spacer()
                Menu {
                    Button("新建人物", systemImage: "plus") { showingNewCharacter = true }
                    Button("导入人物卡", systemImage: "square.and.arrow.down") { showingImport = true }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .semibold))
                }
                .buttonStyle(LinoITintButtonStyle(compact: true))
            }

            if characters.characters.isEmpty && !characters.isLoading {
                LinoIEmptyCard(
                    title: "还没有人物",
                    subtitle: "可以从你已有的人物卡文本导入，也可以先建一个空人物。",
                    actionTitle: "导入人物卡"
                ) {
                    showingImport = true
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(characters.characters) { character in
                            LinoICharacterChip(
                                character: character,
                                selected: character.id == characters.selected?.id
                            ) {
                                characters.selectedCharacterId = character.id
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }

                if let selected = characters.selected {
                    LinoICharacterCard(character: selected)
                }
            }
        }
        .padding(.top, 8)
        .sheet(isPresented: $showingNewCharacter) {
            LinoINewCharacterSheet()
                .presentationDetents([.height(230)])
        }
        .sheet(isPresented: $showingImport) {
            LinoIImportCharacterSheet()
                .presentationDetents([.large])
        }
    }
}

private struct LinoICharacterChip: View {
    let character: Character
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                LinoIAvatar(name: character.name, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(character.name.isEmpty ? "未命名" : character.name)
                        .font(.system(size: 13, weight: .semibold))
                    if !character.role.isEmpty {
                        Text(character.role)
                            .font(.caption2)
                            .foregroundStyle(selected ? .white.opacity(0.72) : LinoTheme.muted)
                    }
                }
            }
            .foregroundStyle(selected ? .white : LinoTheme.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(LinoTheme.accentGradient)
                } else {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(0.72))
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(LinoTheme.hairline, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
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
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                LinoIAvatar(name: name.isEmpty ? character.name : name, size: 52)
                VStack(alignment: .leading, spacing: 8) {
                    LinoITextField("姓名", text: $name)
                    LinoITextField("身份 / 职能", text: $role)
                }
                Menu {
                    Button("删除人物", systemImage: "trash", role: .destructive) {
                        confirmingDelete = true
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .foregroundStyle(LinoTheme.muted)
            }

            LinoIEditor(
                title: "固定设定",
                text: $fixedProfile,
                minHeight: 240,
                placeholder: "自由文本人物卡：外貌、背景、性格、关系、说话方式、禁忌等。"
            )

            HStack(spacing: 10) {
                Button {
                    Task { await save() }
                } label: {
                    Label("保存人物卡", systemImage: "checkmark")
                }
                .buttonStyle(LinoIPrimaryButtonStyle())
            }

            dynamicFieldsSection
            storylineSection
        }
        .padding(14)
        .linoGlass(cornerRadius: 20)
        .onAppear(perform: sync)
        .onChange(of: character.id) { _, _ in sync() }
        .confirmationDialog("删除这个人物？", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                Task { await characters.delete(character) }
            }
            Button("取消", role: .cancel) {}
        }
    }

    private var dynamicFieldsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            LinoISectionLabel("动态字段")
            if character.dynamicFields.isEmpty {
                Text("还没有 Extractor 维护的动态状态。")
                    .font(.footnote)
                    .foregroundStyle(LinoTheme.faint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.white.opacity(0.5), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                VStack(spacing: 8) {
                    ForEach(character.dynamicFields.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(key)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(LinoTheme.accentDeep)
                            Text(value.description.isEmpty ? "空" : value.description)
                                .font(.footnote)
                                .foregroundStyle(LinoTheme.body)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(11)
                        .background(Color.white.opacity(0.54), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
            }
        }
    }

    private var storylineSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            LinoISectionLabel("人物故事线")
            if character.events.isEmpty {
                Text("接受章节后，Extractor 会把本人物的大事和故事线写到这里。")
                    .font(.footnote)
                    .foregroundStyle(LinoTheme.faint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.white.opacity(0.5), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(character.events) { event in
                        LinoICharacterEventRow(event: event)
                    }
                }
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

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(event.chapterIndex.map { "第 \($0) 章" } ?? "章节")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(LinoTheme.accent, in: Capsule())

            if isEditing {
                VStack(alignment: .leading, spacing: 8) {
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $draftText)
                            .frame(minHeight: 70)
                            .scrollContentBackground(.hidden)
                            .font(.footnote)
                            .foregroundStyle(LinoTheme.body)
                            .padding(6)
                    }
                    .background(Color.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(LinoTheme.hairline, lineWidth: 0.5))
                    HStack(spacing: 8) {
                        Button("取消") {
                            draftText = event.eventText
                            isEditing = false
                        }
                        .buttonStyle(LinoITintButtonStyle(compact: true))
                        Button("保存") {
                            Task {
                                await characters.updateEvent(event, text: draftText)
                                isEditing = false
                            }
                        }
                        .buttonStyle(LinoIPrimaryButtonStyle(compact: true))
                    }
                }
            } else {
                Text(event.eventText)
                    .font(.footnote)
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
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .foregroundStyle(LinoTheme.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(Color.white.opacity(0.54), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onAppear { draftText = event.eventText }
        .confirmationDialog("删除这条故事线？", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                Task { await characters.deleteEvent(event) }
            }
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
                    .font(.footnote)
                    .foregroundStyle(LinoTheme.muted)
                Spacer()
                Button("创建人物") {
                    let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task {
                        await characters.create(name: value.isEmpty ? "未命名人物" : value)
                        dismiss()
                    }
                }
                .buttonStyle(LinoIPrimaryButtonStyle())
            }
            .padding(18)
            .navigationTitle("新建人物")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .background(LinoTheme.background.ignoresSafeArea())
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
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .background(LinoTheme.background.ignoresSafeArea())
        }
    }
}
