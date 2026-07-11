import SwiftUI

/// 桌面外壳占位版。块③ 会补全为单窗状态机
/// （连接配置 → 书架 → 工作台 + reader/settings overlay）。
/// 本块只验证 macOS target 编译通过与共享设计系统（LinoTheme / linoGlass）可用。
struct MacShell: View {
    var body: some View {
        ZStack {
            LinoTheme.background.ignoresSafeArea()
            VStack(spacing: 14) {
                LinoIAvatar(name: "L", size: 64, rounded: true)
                Text("LinoI for Mac")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(LinoTheme.ink)
                Text("施工中")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(LinoTheme.muted)
            }
            .padding(48)
            .linoGlass(cornerRadius: 24)
            .padding(48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
