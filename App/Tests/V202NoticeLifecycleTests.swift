import Foundation

@MainActor
func runV202NoticeLifecycleTests() throws {
    let ordinary = NoticeBus.Notice(message: "已保存", isCritical: false)
    let critical = NoticeBus.Notice(message: "连接失败", isCritical: true)
    let error = NoticeBus.Notice(message: "服务器返回异常", isCritical: false, tone: .error)

    guard NoticeLifecyclePolicy.automaticDismissDelay == 5 else {
        throw V202NoticeLifecycleTestError.assertion("ordinary notices must remain visible for five seconds")
    }
    guard NoticeLifecyclePolicy.dismissesAutomatically(ordinary) else {
        throw V202NoticeLifecycleTestError.assertion("ordinary notices must dismiss automatically")
    }
    guard !NoticeLifecyclePolicy.dismissesAutomatically(critical) else {
        throw V202NoticeLifecycleTestError.assertion("critical notices must remain until dismissed")
    }
    guard !NoticeLifecyclePolicy.dismissesAutomatically(error) else {
        throw V202NoticeLifecycleTestError.assertion("all errors must stay visible until dismissed")
    }
    let bus = NoticeBus()
    bus.publish("检查未通过：原因一；原因二", tone: .error, deduplicationKey: "job-1")
    let firstID = bus.current?.id
    bus.publish("检查未通过：原因一；原因二", tone: .error, deduplicationKey: "job-1", announce: false)
    guard bus.history.count == 1 && bus.current?.id == firstID else {
        throw V202NoticeLifecycleTestError.assertion("reloading the same failed job must not duplicate notices")
    }
    bus.dismiss()
    guard bus.current == nil && bus.history.count == 1 else {
        throw V202NoticeLifecycleTestError.assertion("dismissing a failure must preserve its complete history")
    }
    bus.publish("归档失败", tone: .error, deduplicationKey: "job-2", announce: false)
    guard bus.current == nil && bus.history.count == 2 else {
        throw V202NoticeLifecycleTestError.assertion("restored failures must enter history without replaying alerts")
    }
    for index in 0..<35 { bus.publish("通知 \(index)", announce: false) }
    guard bus.history.count == 30 && bus.history.first?.message == "通知 5" && bus.history.last?.message == "通知 34" else {
        throw V202NoticeLifecycleTestError.assertion("history must retain the most recent thirty notices in order")
    }
    guard ordinary.tone == .success && critical.tone == .error && error.tone == .error else {
        throw V202NoticeLifecycleTestError.assertion("notice icons must reflect success and error semantics independently of persistence")
    }
    guard NoticeLifecyclePolicy.canDismissExpiredNotice(
        noticeID: ordinary.id,
        currentNoticeID: ordinary.id,
        wasCancelled: false
    ) else {
        throw V202NoticeLifecycleTestError.assertion("the active ordinary notice must be dismissible after its timer")
    }
    guard !NoticeLifecyclePolicy.canDismissExpiredNotice(
        noticeID: ordinary.id,
        currentNoticeID: critical.id,
        wasCancelled: false
    ) else {
        throw V202NoticeLifecycleTestError.assertion("an expired earlier timer must not dismiss a replacement notice")
    }
    guard !NoticeLifecyclePolicy.canDismissExpiredNotice(
        noticeID: ordinary.id,
        currentNoticeID: ordinary.id,
        wasCancelled: true
    ) else {
        throw V202NoticeLifecycleTestError.assertion("a cancelled timer must not dismiss its notice")
    }
}

private enum V202NoticeLifecycleTestError: Error {
    case assertion(String)
}
