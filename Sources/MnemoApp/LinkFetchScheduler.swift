import Foundation

/// 出站链接抓取的总闸门。
///
/// 索引正文、封面元数据、网页配图、站点图标都必须经过这里。它们以前只是把
/// **起始时刻**错开 250ms；前一个请求若跑 8 秒，后一个 250ms 后仍会并发，
/// 所以批量补抓照样把 linux.do / 小红书打到 429。
///
/// 现在是一条真正的单通道：前一个网络操作完整结束并释放租约，后一个才开始；
/// 同域名在上一个操作结束后还留 1.5 秒。全部运行在后台索引路径，串行不会阻塞 UI。
actor LinkFetchScheduler {
    static let shared = LinkFetchScheduler()

    private static let perHostGap = Duration.milliseconds(1_500)
    private static let globalGap = Duration.milliseconds(250)

    private var isOccupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var lastFinishByHost: [String: ContinuousClock.Instant] = [:]
    private var lastGlobalFinish: ContinuousClock.Instant?

    private func acquire(host: String) async {
        if isOccupied {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
            // `release` 直接把租约交给这一位，isOccupied 仍为 true。
        } else {
            isOccupied = true
        }

        // 先占住通道再等间隔：等待期间其他调用只能排队，不可能一起醒来并发。
        let now = ContinuousClock.now
        var readyAt = now
        if let last = lastGlobalFinish {
            readyAt = max(readyAt, last.advanced(by: Self.globalGap))
        }
        if let last = lastFinishByHost[host] {
            readyAt = max(readyAt, last.advanced(by: Self.perHostGap))
        }
        if readyAt > now {
            try? await Task.sleep(for: now.duration(to: readyAt))
        }
    }

    private func release(host: String) {
        let now = ContinuousClock.now
        lastGlobalFinish = now
        lastFinishByHost[host] = now
        if waiters.isEmpty {
            isOccupied = false
        } else {
            // FIFO 交接；不把 isOccupied 置 false，避免新调用插队。
            waiters.removeFirst().resume()
        }
    }

    struct Lease: Sendable {
        fileprivate let host: String
    }

    /// 取得唯一通道的租约。网络操作仍在调用者自己的 actor 上执行——
    /// LPLinkMetadata / NSImage 都不是 Sendable，不能塞进跨 actor 闭包返回。
    static func acquire(for url: URL) async -> Lease {
        let host = url.host?.lowercased() ?? ""
        await shared.acquire(host: host)
        return Lease(host: host)
    }

    static func release(_ lease: Lease) async {
        await shared.release(host: lease.host)
    }

}
