import Foundation

/// Every export stage uses the same failure when preserving the author's
/// current input on this device fails, including native save-panel callbacks.
enum V2ExportDraftGuard {
    struct PersistenceFailure: LocalizedError {
        var errorDescription: String? {
            "本机草稿未能保存，本次未导出。请先复制保留当前稿件，检查设备可用存储空间，再重试保存和导出。"
        }
    }

    static func persist(_ save: () -> Bool) throws {
        guard save() else { throw PersistenceFailure() }
    }
}
