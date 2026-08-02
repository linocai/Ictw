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

    func publish(_ message: String, critical: Bool = false) {
        let notice = Notice(message: message, isCritical: critical)
        current = notice
        history.append(notice)
        if history.count > 30 {
            history.removeFirst(history.count - 30)
        }
    }

    func publish(_ error: Error) {
        let presented = LinoErrorPresenter.present(error: error)
        publish(presented.message, critical: presented.critical)
    }

    func dismiss() {
        current = nil
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
                .background(Color.black.opacity(0.82), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
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
        let item = DispatchWorkItem { bus.dismiss() }
        dismissWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6, execute: item)
    }
}
