import Darwin

/// 这一段代码**自己**烧掉多少 CPU 时间。
///
/// 几个"够快吗"的断言原本量的是墙钟时间，而 Swift Testing 是并行跑用例的：
/// 同一段代码被别的用例抢占之后，耗时能差好几倍——单独跑全过、全量跑就红，
/// 而且红的是哪一个纯看当时谁抢到了核。它们想说的从来不是"这台机器现在多闲"，
/// 是"这个算法便不便宜，能不能放在剪贴板 / 交互路径上"。线程 CPU 时间正是
/// 那个量，且与调度无关。
func cpuSeconds(_ body: () -> Void) -> Double {
    let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
    body()
    let end = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
    return Double(end &- start) / 1_000_000_000
}
