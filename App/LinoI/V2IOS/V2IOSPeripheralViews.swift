import SwiftUI
import UIKit

/// A compact UIKit bridge allows a sheet drag to enter the same explicit
/// unsaved-changes decision as its visible Cancel action.
private struct V2IOSDismissAttemptObserver: UIViewControllerRepresentable {
    let shouldDismiss: () -> Bool
    let onAttempt: () -> Void

    func makeUIViewController(context: Context) -> Controller {
        Controller(shouldDismiss: shouldDismiss, onAttempt: onAttempt)
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.shouldDismiss = shouldDismiss
        controller.onAttempt = onAttempt
        controller.installPresentationDelegate()
    }

    final class Controller: UIViewController, UIAdaptivePresentationControllerDelegate {
        var shouldDismiss: () -> Bool
        var onAttempt: () -> Void

        init(shouldDismiss: @escaping () -> Bool, onAttempt: @escaping () -> Void) {
            self.shouldDismiss = shouldDismiss
            self.onAttempt = onAttempt
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            installPresentationDelegate()
        }

        func installPresentationDelegate() {
            DispatchQueue.main.async { [weak self] in
                self?.parent?.presentationController?.delegate = self
            }
        }

        func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool {
            shouldDismiss()
        }

        func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
            onAttempt()
        }
    }
}

@MainActor
private final class V2IOSCharacterSheetLeaveCoordinator: ObservableObject {
    @Published private(set) var isDirty = false
    @Published private(set) var isSaving = false
    private var requestLeaveAction: (() -> Void)?

    var blocksDismissal: Bool { isDirty || isSaving }

    func register(requestLeave: @escaping () -> Void) {
        requestLeaveAction = requestLeave
    }

    func update(isDirty: Bool, isSaving: Bool) {
        if self.isDirty != isDirty { self.isDirty = isDirty }
        if self.isSaving != isSaving { self.isSaving = isSaving }
    }

    func requestLeave() {
        requestLeaveAction?()
    }

    func reset() {
        requestLeaveAction = nil
        update(isDirty: false, isSaving: false)
    }
}

struct V2IOSWorldEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var workspace: WorkspaceStore
    @FocusState private var editorFocused: Bool
    @State private var text = ""
    @State private var initialText = ""
    @State private var title = ""
    @State private var saving = false
    @State private var loaded = false
    @State private var showingLeaveConfirmation = false

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .font(V2DeskType.prose(16))
                .lineSpacing(7)
                .scrollContentBackground(.hidden)
                .focused($editorFocused)
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .accessibilityLabel("世界观")
                .accessibilityHint("可编辑整本书的世界观设定")
                .navigationTitle("世界观")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("取消", action: requestDismiss)
                            .disabled(saving)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(saving ? "保存中" : "保存", action: saveAndDismiss)
                            .disabled(saving || !isDirty)
                    }
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("完成") { editorFocused = false }
                    }
                }
        }
        .toolbar(.visible, for: .navigationBar)
        .v2IOSPage()
        .background(
            V2IOSDismissAttemptObserver(
                shouldDismiss: { !isDirty && !saving },
                onAttempt: requestDismiss
            )
        )
        .interactiveDismissDisabled(saving)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(V2DeskMetric.sheetCornerRadius)
        .confirmationDialog("保存世界观修改？", isPresented: $showingLeaveConfirmation, titleVisibility: .visible) {
            Button("保存并离开") { saveAndDismiss() }
            Button("放弃修改", role: .destructive) { dismiss() }
            Button("继续编辑", role: .cancel) {}
        } message: {
            Text("离开后，未保存的世界观修改不会保留。")
        }
        .onAppear {
            guard !loaded else { return }
            title = session.currentBook?.title ?? ""
            initialText = session.currentBook?.worldSetting ?? ""
            text = initialText
            loaded = true
        }
    }

    private var isDirty: Bool { loaded && text != initialText }

    private func requestDismiss() {
        if isDirty { showingLeaveConfirmation = true }
        else { dismiss() }
    }

    private func saveAndDismiss() {
        guard !saving, isDirty else {
            if !isDirty { dismiss() }
            return
        }
        saving = true
        Task {
            let didSave = await workspace.saveBook(title: title, world: text)
            saving = false
            guard didSave else { return }
            initialText = text
            dismiss()
        }
    }
}

struct V2IOSCharactersView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var characters: CharactersStore
    @State private var path: [V2IOSCharacterRoute] = []
    @StateObject private var leaveCoordinator = V2IOSCharacterSheetLeaveCoordinator()

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(spacing: 10) {
                    if characters.characters.isEmpty {
                        ContentUnavailableView(
                            "还没有人物",
                            systemImage: "person.2",
                            description: Text("新增人物后，可以在章节中选择他们出场。")
                        )
                        .frame(maxWidth: .infinity, minHeight: 250)
                    } else {
                        ForEach(characters.characters) { character in
                            NavigationLink(value: V2IOSCharacterRoute.existing(character)) {
                                V2IOSCharacterRow(character: character)
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("打开人物设定")
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .navigationTitle("人物")
            .toolbar {
                if path.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("完成", action: dismiss.callAsFunction)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("新增") { path.append(.new) }
                            .accessibilityLabel("新增人物")
                    }
                }
            }
            .navigationDestination(for: V2IOSCharacterRoute.self) { route in
                switch route {
                case .existing(let character): V2IOSCharacterDetailView(character: character)
                case .new: V2IOSNewCharacterView()
                }
            }
        }
        .toolbar(.visible, for: .navigationBar)
        .environmentObject(leaveCoordinator)
        .v2IOSPage()
        .background(
            V2IOSDismissAttemptObserver(
                shouldDismiss: { !leaveCoordinator.blocksDismissal },
                onAttempt: leaveCoordinator.requestLeave
            )
        )
        .interactiveDismissDisabled(leaveCoordinator.isSaving)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(V2DeskMetric.sheetCornerRadius)
        .onChange(of: path) { _, newPath in
            if newPath.isEmpty { leaveCoordinator.reset() }
        }
    }
}

private enum V2IOSCharacterRoute: Hashable {
    case existing(Character)
    case new
}

private struct V2IOSCharacterRow: View {
    let character: Character

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(character.name.v2IOSTrimmed.isEmpty ? "未命名人物" : character.name)
                    .font(V2DeskType.prose(17, weight: .medium))
                    .foregroundStyle(Color.primary)
                    .lineLimit(2)
                Text(character.role.v2IOSTrimmed.isEmpty ? archiveSummary : character.role)
                    .font(V2DeskType.control(12.5))
                    .foregroundStyle(Color.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 12)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.secondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: V2DeskMetric.mobileTapTarget + 20)
        .v2IOSPaper(.manuscriptPaper)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var archiveSummary: String {
        character.events.isEmpty ? "还没有归档记录" : "\(character.events.count) 章有归档记录"
    }
}

private struct V2IOSCharacterDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var characters: CharactersStore
    @EnvironmentObject private var sheetLeaveCoordinator: V2IOSCharacterSheetLeaveCoordinator
    @FocusState private var focusedField: V2IOSCharacterFieldID?
    @State private var original: Character
    @State private var edited: Character
    @State private var saving = false
    @State private var showingDelete = false
    @State private var showingLeaveConfirmation = false

    init(character: Character) {
        _original = State(initialValue: character)
        _edited = State(initialValue: character)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                V2IOSCharacterField(label: "姓名", text: $edited.name, field: .name, focusedField: $focusedField)
                V2IOSCharacterField(label: "身份", text: $edited.role, field: .role, focusedField: $focusedField)
                V2IOSCharacterField(label: "人物设定", text: $edited.fixedProfile, field: .profile, focusedField: $focusedField, multiline: true)
                archive
                V2IOSSecondaryButton(title: "删除人物", tone: .danger) { showingDelete = true }
                    .disabled(saving)
                    .accessibilityHint("删除人物及其归档记录，正文不会改变")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
        .navigationTitle(edited.name.v2IOSTrimmed.isEmpty ? "人物" : edited.name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isDirty)
        .toolbar {
            if isDirty {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消", action: requestDismiss)
                        .disabled(saving)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(saving ? "保存中" : "保存", action: saveAndDismiss)
                    .disabled(saving || !isDirty || edited.name.v2IOSTrimmed.isEmpty)
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { focusedField = nil }
            }
        }
        .confirmationDialog("保存人物修改？", isPresented: $showingLeaveConfirmation, titleVisibility: .visible) {
            Button("保存并离开") { saveAndDismiss() }
            Button("放弃修改", role: .destructive) { dismiss() }
            Button("继续编辑", role: .cancel) {}
        } message: {
            Text("离开后，未保存的人物修改不会保留。")
        }
        .confirmationDialog("删除“\(edited.name.v2IOSTrimmed.isEmpty ? "这个人物" : edited.name)”？", isPresented: $showingDelete, titleVisibility: .visible) {
            Button("删除人物", role: .destructive) { delete() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("人物设定和从正文整理出的归档记录都会从这本书移除；章节正文不会改变。")
        }
        .onAppear(perform: syncSheetLeaveCoordinator)
        .onChange(of: isDirty) { _, _ in syncSheetLeaveCoordinator() }
        .onChange(of: saving) { _, _ in syncSheetLeaveCoordinator() }
    }

    private var isDirty: Bool { edited != original }

    @ViewBuilder private var archive: some View {
        VStack(alignment: .leading, spacing: 10) {
            V2IOSSectionLabel(title: "整理自正文 · 只读")
            if edited.events.isEmpty {
                Text("还没有归档记录")
                    .font(V2DeskType.control(13))
                    .foregroundStyle(Color.secondary)
                    .frame(maxWidth: .infinity, minHeight: V2DeskMetric.mobileTapTarget, alignment: .leading)
                    .padding(.horizontal, 14)
                    .v2IOSPaper(.rail)
            } else {
                ForEach(edited.events) { event in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(event.eventText).font(V2DeskType.prose(14.5)).lineSpacing(4)
                        Text(event.chapterIndex.map { "第 \($0) 章" } ?? "来源章节")
                            .font(V2DeskType.control(11.5))
                            .foregroundStyle(Color.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .v2IOSPaper(.rail)
                    .overlay { if event.editable == false { V2IOSStripedSurface().opacity(0.24) } }
                    .accessibilityLabel("归档记录：\(event.eventText)")
                }
            }
        }
    }

    private func requestDismiss() {
        if isDirty { showingLeaveConfirmation = true }
        else { dismiss() }
    }

    private func syncSheetLeaveCoordinator() {
        sheetLeaveCoordinator.register(requestLeave: requestDismiss)
        sheetLeaveCoordinator.update(isDirty: isDirty, isSaving: saving)
    }

    private func saveAndDismiss() {
        guard !saving, isDirty, !edited.name.v2IOSTrimmed.isEmpty else { return }
        saving = true
        Task {
            let didSave = await characters.update(edited)
            saving = false
            guard didSave else { return }
            original = edited
            dismiss()
        }
    }

    private func delete() {
        guard !saving else { return }
        saving = true
        Task {
            let didDelete = await characters.delete(edited)
            saving = false
            if didDelete { dismiss() }
        }
    }
}

private enum V2IOSCharacterFieldID: Hashable {
    case name, role, profile
}

private struct V2IOSCharacterField: View {
    let label: String
    @Binding var text: String
    let field: V2IOSCharacterFieldID
    var focusedField: FocusState<V2IOSCharacterFieldID?>.Binding
    var multiline = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            V2IOSSectionLabel(title: label)
            if multiline {
                TextEditor(text: $text)
                    .font(V2DeskType.prose(15))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 142)
                    .padding(10)
                    .focused(focusedField, equals: field)
                    .v2IOSPaper()
                    .accessibilityLabel(label)
            } else {
                TextField(label, text: $text)
                    .font(V2DeskType.prose(16))
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 14)
                    .frame(minHeight: V2DeskMetric.mobileTapTarget)
                    .focused(focusedField, equals: field)
                    .v2IOSPaper()
                    .accessibilityLabel(label)
            }
        }
    }
}

private struct V2IOSNewCharacterView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var characters: CharactersStore
    @EnvironmentObject private var sheetLeaveCoordinator: V2IOSCharacterSheetLeaveCoordinator
    @FocusState private var focusedField: V2IOSCharacterFieldID?
    @State private var name = ""
    @State private var role = ""
    @State private var profile = ""
    @State private var saving = false
    @State private var showingLeaveConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                V2IOSCharacterField(label: "姓名", text: $name, field: .name, focusedField: $focusedField)
                V2IOSCharacterField(label: "身份", text: $role, field: .role, focusedField: $focusedField)
                V2IOSCharacterField(label: "人物设定", text: $profile, field: .profile, focusedField: $focusedField, multiline: true)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
        .navigationTitle("新增人物")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isDirty)
        .toolbar {
            if isDirty {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消", action: requestDismiss)
                        .disabled(saving)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(saving ? "创建中" : "创建", action: create)
                    .disabled(saving || name.v2IOSTrimmed.isEmpty)
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { focusedField = nil }
            }
        }
        .confirmationDialog("放弃新增人物？", isPresented: $showingLeaveConfirmation, titleVisibility: .visible) {
            Button("放弃修改", role: .destructive) { dismiss() }
            Button("继续编辑", role: .cancel) {}
        } message: {
            Text("输入的姓名、身份和设定不会保存。")
        }
        .onAppear(perform: syncSheetLeaveCoordinator)
        .onChange(of: isDirty) { _, _ in syncSheetLeaveCoordinator() }
        .onChange(of: saving) { _, _ in syncSheetLeaveCoordinator() }
    }

    private var isDirty: Bool {
        !name.v2IOSTrimmed.isEmpty || !role.v2IOSTrimmed.isEmpty || !profile.v2IOSTrimmed.isEmpty
    }

    private func requestDismiss() {
        if isDirty { showingLeaveConfirmation = true }
        else { dismiss() }
    }

    private func syncSheetLeaveCoordinator() {
        sheetLeaveCoordinator.register(requestLeave: requestDismiss)
        sheetLeaveCoordinator.update(isDirty: isDirty, isSaving: saving)
    }

    private func create() {
        guard !saving, !name.v2IOSTrimmed.isEmpty else { return }
        saving = true
        Task {
            let created = await characters.create(
                name: name.v2IOSTrimmed,
                role: role.v2IOSTrimmed,
                fixedProfile: profile
            )
            saving = false
            if created != nil { dismiss() }
        }
    }
}

struct V2IOSInspirationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var editor: ChapterEditorStore
    @EnvironmentObject private var inspiration: InspirationCreatorStore
    @State private var addingID: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                V2IOSSheetHeader(title: "找方向", dismiss: dismiss.callAsFunction)
                TextField("本章推进边界（可选）", text: $inspiration.pacingBoundary)
                    .font(V2DeskType.prose(14)).textFieldStyle(.plain).padding(13).v2IOSPaper()
                    .disabled(!canEditChapter)
                if inspiration.isLoading { ProgressView("正在找方向").frame(maxWidth: .infinity, minHeight: 120) }
                if let error = inspiration.errorMessage { Text(error).font(V2DeskType.control(13)).foregroundStyle(Color.red).padding(13).v2IOSPaper(.card) }
                ForEach(inspiration.cards) { card in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(card.body).font(V2DeskType.prose(14.5)).lineSpacing(6)
                        V2IOSSecondaryButton(title: inspiration.adoptedCardIDs.contains(card.id) || addingID == card.id ? "已加入意图" : "加入意图") { add(card) }
                            .disabled(!canEditChapter || inspiration.adoptedCardIDs.contains(card.id) || addingID == card.id)
                    }.padding(14).v2IOSPaper(.manuscriptPaper)
                }
                if inspiration.canUndo(chapterID: editor.currentChapter?.id ?? "", currentBible: editor.currentChapter?.userPrompt ?? "") {
                    V2IOSSecondaryButton(title: "撤销这次加入", tone: .accent) { undo() }
                        .disabled(!canEditChapter)
                }
                V2IOSPrimaryButton(title: inspiration.cards.isEmpty ? "开始找灵感" : "换三个", disabled: inspiration.isLoading || !canEditChapter) {
                    if let chapter = editor.currentChapter { inspiration.generate(for: chapter) }
                }
            }.padding(20)
        }.v2IOSPage()
    }

    private var canEditChapter: Bool { ChapterEditingPolicy.canEdit(editor.currentChapter) }

    private func add(_ card: InspirationCard) {
        guard let chapter = editor.currentChapter else { return }
        guard ChapterEditingPolicy.canEdit(chapter) else { return }
        addingID = card.id
        defer { addingID = nil }
        let before = chapter.userPrompt
        let after = before.v2IOSTrimmed.isEmpty ? card.body : "\(before)\n\n\(card.body)"
        editor.editString(\.userPrompt, value: after)
        inspiration.recordAdoption(card: card, chapterID: chapter.id, before: before, after: after)
    }
    private func undo() {
        guard let chapter = editor.currentChapter else { return }
        guard ChapterEditingPolicy.canEdit(chapter) else { return }
        guard let before = inspiration.consumeUndo(chapterID: chapter.id, currentBible: chapter.userPrompt) else { return }
        editor.editString(\.userPrompt, value: before)
    }
}

struct V2IOSSheetHeader: View {
    let title: String
    let dismiss: () -> Void
    var trailing: String? = nil
    var trailingAction: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            Button("取消", action: dismiss)
                .font(V2DeskType.control(13, weight: .medium))
                .frame(minWidth: V2DeskMetric.mobileTapTarget, minHeight: V2DeskMetric.mobileTapTarget)
                .buttonStyle(.plain)
                .accessibilityLabel("关闭\(title)")
            Spacer(minLength: 4)
            Text(title)
                .font(V2DeskType.prose(18, weight: .semibold))
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 4)
            if let trailing, let trailingAction {
                Button(trailing, action: trailingAction)
                    .font(V2DeskType.control(13, weight: .medium))
                    .frame(minWidth: V2DeskMetric.mobileTapTarget, minHeight: V2DeskMetric.mobileTapTarget)
                    .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: V2DeskMetric.mobileTapTarget, height: V2DeskMetric.mobileTapTarget)
            }
        }
        .padding(.horizontal, 20)
        .frame(minHeight: 52)
    }
}
