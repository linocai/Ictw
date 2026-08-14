import Foundation

func runV202NoticeLifecycleTests() throws {
    let ordinary = NoticeBus.Notice(message: "已保存", isCritical: false)
    let critical = NoticeBus.Notice(message: "连接失败", isCritical: true)

    guard NoticeLifecyclePolicy.automaticDismissDelay == 5 else {
        throw V202NoticeLifecycleTestError.assertion("ordinary notices must remain visible for five seconds")
    }
    guard NoticeLifecyclePolicy.dismissesAutomatically(ordinary) else {
        throw V202NoticeLifecycleTestError.assertion("ordinary notices must dismiss automatically")
    }
    guard !NoticeLifecyclePolicy.dismissesAutomatically(critical) else {
        throw V202NoticeLifecycleTestError.assertion("critical notices must remain until dismissed")
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
