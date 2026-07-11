import SwiftUI

/// ⌘, 打开的设置 sheet：内嵌连接段（`MacConnectionView(firstRun: false)`，与
/// 首启连接页共用同一张卡片/同一套保存逻辑）。由 `MacShell` 经
/// `MacCommandBus.showSettings` 呈现；书架 ⚙ 与工作台 ⚙ 也经同一个 bus
/// 打开这张 sheet。Esc 关闭：`.onExitCommand` + `.onKeyPress(.escape)`
/// 双保险——`TextField`/`SecureField` 持有第一响应者时，普通
/// `.keyboardShortcut(.escape)`（隐藏按钮）会被输入框的 `cancelOperation:`
/// 吞掉，实测根本不触发；`onKeyPress` 是更底层的按键钩子，在响应链更早的
/// 位置拦截，两者一起挂对焦点态最稳。
struct MacSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                MacConnectionView(firstRun: false)
            }
        }
        .frame(width: 560, height: 480)
        .background(LinoTheme.background)
        .onExitCommand { dismiss() }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
    }

    private var header: some View {
        HStack {
            Text("设置")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(LinoTheme.ink)
            Spacer()
            LinoMacIconButton(systemName: "xmark", size: 26, fontSize: 11, help: "关闭（Esc）") {
                dismiss()
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 4)
    }
}
