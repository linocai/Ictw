import SwiftUI

@MainActor
final class NoticeBus: ObservableObject {
    struct Notice: Identifiable, Equatable {
        let id = UUID()
        let message: String
        let isCritical: Bool
        let timestamp = Date()
    }

    @Published var current: Notice?
    @Published private(set) var history: [Notice] = []
    private var automaticDismissTask: Task<Void, Never>?

    func publish(_ message: String, critical: Bool = false) {
        let notice = Notice(message: message, isCritical: critical)
        automaticDismissTask?.cancel()
        current = notice
        history.append(notice)
        if history.count > 30 {
            history.removeFirst(history.count - 30)
        }
        scheduleAutomaticDismiss(for: notice)
    }

    func publish(_ error: Error) {
        let presented = LinoErrorPresenter.present(error: error)
        publish(presented.message, critical: presented.critical)
    }

    /// The optional identifier prevents an expired timer for an older notice
    /// from clearing a newer one that replaced it.
    func dismiss(id: Notice.ID? = nil) {
        guard let current else { return }
        guard id == nil || current.id == id else { return }
        automaticDismissTask?.cancel()
        automaticDismissTask = nil
        self.current = nil
    }

    private func scheduleAutomaticDismiss(for notice: Notice) {
        guard NoticeLifecyclePolicy.dismissesAutomatically(notice) else { return }
        automaticDismissTask = Task { [weak self, noticeID = notice.id] in
            try? await Task.sleep(nanoseconds: NoticeLifecyclePolicy.automaticDismissDelayNanoseconds)
            guard let self else { return }
            guard NoticeLifecyclePolicy.canDismissExpiredNotice(
                noticeID: noticeID,
                currentNoticeID: self.current?.id,
                wasCancelled: Task.isCancelled
            ) else { return }
            self.dismiss(id: noticeID)
        }
    }
}

/// The notice timing and identity checks are deliberately kept outside of a
/// SwiftUI view so replacement behaviour stays deterministic across roots.
enum NoticeLifecyclePolicy {
    static let automaticDismissDelay: TimeInterval = 5
    static let automaticDismissDelayNanoseconds: UInt64 = 5_000_000_000

    static func dismissesAutomatically(_ notice: NoticeBus.Notice) -> Bool {
        !notice.isCritical
    }

    static func canDismissExpiredNotice(
        noticeID: NoticeBus.Notice.ID,
        currentNoticeID: NoticeBus.Notice.ID?,
        wasCancelled: Bool
    ) -> Bool {
        !wasCancelled && noticeID == currentNoticeID
    }
}

struct LinoIToast: View {
    @EnvironmentObject private var bus: NoticeBus
    @State private var dismissWorkItem: DispatchWorkItem?

    var body: some View {
        Group {
            if let notice = bus.current {
                HStack(spacing: 9) {
                    #if os(iOS)
                    Circle()
                        .fill(notice.isCritical ? LinoTheme.danger : LinoTheme.success)
                        .frame(width: 6, height: 6)
                    #else
                    Image(systemName: notice.isCritical ? "exclamationmark.shield.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(notice.isCritical ? LinoTheme.danger : LinoTheme.warning)
                    #endif
                    Text(notice.message)
                        .font(LinoType.ui(13.5, .medium))
                        .foregroundStyle(LinoTheme.bg)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    if notice.isCritical {
                        Button { bus.dismiss() } label: {
                            Image(systemName: "xmark")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(LinoTheme.bg.opacity(0.65))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .frame(maxWidth: 460, alignment: .leading)
                #if os(iOS)
                .background(LinoTheme.ink, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: .black.opacity(0.16), radius: 12, y: 6)
                #else
                .background(LinoTheme.ink, in: Capsule())
                .overlay(Capsule().strokeBorder(LinoTheme.line2, lineWidth: 1))
                .shadow(color: LinoTheme.hex(0x17181C, opacity: 0.16), radius: 8, y: 4)
                #endif
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .onAppear { scheduleDismiss(notice) }
                .onDisappear { dismissWorkItem?.cancel() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .linoAnimation(LinoMotion.content, value: bus.current?.id)
    }

    private func scheduleDismiss(_ notice: NoticeBus.Notice) {
        dismissWorkItem?.cancel()
        guard !notice.isCritical else { return }
        let item = DispatchWorkItem { bus.dismiss(id: notice.id) }
        dismissWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6, execute: item)
    }
}
