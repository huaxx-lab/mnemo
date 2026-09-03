import Darwin
import Foundation

final class SingleInstanceGuard {
    private let descriptor: Int32

    /// 拿不到锁时的重试窗口。
    ///
    /// 系统在授予"完全磁盘访问"之后会弹"退出并重新打开"，它**先拉起新进程、
    /// 旧进程才慢慢退干净**。旧进程还活着的那一瞬间锁还在它手里，新进程
    /// 一试就失败、然后 exit——用户看到的就是"点了重启，应用关掉了再也没起来"。
    ///
    /// 退出要走完 SwiftData 落盘、面板关闭、监听器注销，几百毫秒很正常。
    /// 这里给它两秒：旧进程一撒手就立刻接上；真有另一个活着的实例时，
    /// 两秒之后照样退出，不会出现两个刘海。
    private static let acquireTimeout: TimeInterval = 2
    private static let retryInterval: TimeInterval = 0.08

    init?() {
        let name = "com.pinland.app-\(getuid()).lock"
        // Bundle and command-line launches can receive different per-process temp
        // directories. A shared /tmp lock prevents two UI layers from coexisting.
        let path = "/tmp/\(name)"
        let descriptor = open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return nil }

        let deadline = Date().addingTimeInterval(Self.acquireTimeout)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard Date() < deadline else {
                close(descriptor)
                return nil
            }
            Thread.sleep(forTimeInterval: Self.retryInterval)
        }
        self.descriptor = descriptor
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

enum MnemoBuildIdentity {
    /// 菜单里显示的版本号。
    ///
    /// 只给版本本身。构建号和 commit 短哈希仍然写在 Info.plist 里（报问题时
    /// 用得上），但它们对用户没有意义——"2.0.0 (1) 622ef6c-dirty"里有三个
    /// 数字，没有一个是用户关心的那个。
    static var display: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return info["CFBundleShortVersionString"] as? String ?? "development"
    }
}
