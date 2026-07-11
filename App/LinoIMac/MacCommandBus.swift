import SwiftUI

/// macOS-only 跨视图指令总线：⌘ 快捷键 / 菜单命令（`LinoIMacApp.commands`）
/// 经它派发到具体承载视图（书架的新建书 sheet、工作台的新建章节、`MacShell`
/// 的设置 sheet），避免菜单层直接触碰各视图的本地 `@State`。三个都是「一次性
/// 意图」开关：`showSettings` 直接双向绑定给 `.sheet(isPresented:)`；
/// `showNewBook`/`showNewChapter` 由承载视图的 `.onChange` 消费后自行复位为
/// false（承载视图未挂载时，命令是无害的 no-op，不做跨层强制路由）。
@MainActor
final class MacCommandBus: ObservableObject {
    @Published var showNewBook = false
    @Published var showNewChapter = false
    @Published var showSettings = false
}
