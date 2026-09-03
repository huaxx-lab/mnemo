import Foundation

/// 首次安装引导要检查的四件事。它只描述"现在配好了没有"，不描述界面。
///
/// 引导页的每一步都直接显示这里的事实：已经配好的项显示当前配置，不再重复追问。
public struct OnboardingReadiness: Sendable, Equatable {
    /// Command-G 读取前台选区必须要辅助功能权限，这是唯一的硬性权限。
    public var hasAccessibilityPermission: Bool
    /// 对话模型的凭据已经存进钥匙串。
    public var hasChatCredential: Bool
    /// 对话模型已经选好，功能路由不为空。
    public var hasChatModel: Bool
    /// Embedding 供应商与模型都填了，语义检索才有向量可用。
    public var hasEmbeddingModel: Bool

    public init(
        hasAccessibilityPermission: Bool = false,
        hasChatCredential: Bool = false,
        hasChatModel: Bool = false,
        hasEmbeddingModel: Bool = false
    ) {
        self.hasAccessibilityPermission = hasAccessibilityPermission
        self.hasChatCredential = hasChatCredential
        self.hasChatModel = hasChatModel
        self.hasEmbeddingModel = hasEmbeddingModel
    }

    /// AI 能不能跑起来：有凭据且选了模型。Embedding 缺席只是退化成本地检索。
    public var isAIReady: Bool { hasChatCredential && hasChatModel }
    public var isFullyConfigured: Bool {
        isAIReady && hasEmbeddingModel && hasAccessibilityPermission
    }

    public var completedCount: Int {
        [hasAccessibilityPermission, hasChatCredential, hasChatModel, hasEmbeddingModel]
            .filter { $0 }.count
    }
    public var totalCount: Int { 4 }
}

public enum OnboardingPresentation {
    /// 要不要在启动时自动弹引导。
    ///
    /// 两种情况都不弹：用户已经走过一次；或者这台机器其实已经配好了（重装、
    /// 换构建、从旧版本升级——钥匙串和偏好都还在）。后者直接当作已完成，
    /// 用户想看仍可以从菜单里打开，届时显示的是当前配置而不是空表单。
    public static func shouldPresentAutomatically(
        hasCompletedOnboarding: Bool,
        readiness: OnboardingReadiness
    ) -> Bool {
        guard !hasCompletedOnboarding else { return false }
        return !readiness.isAIReady
    }

    /// 启动时可以直接把引导标记成已完成：已经能用了就别再拦一道。
    public static func canSilentlyMarkCompleted(
        hasCompletedOnboarding: Bool,
        readiness: OnboardingReadiness
    ) -> Bool {
        !hasCompletedOnboarding && readiness.isAIReady
    }
}
