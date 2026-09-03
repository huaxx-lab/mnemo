import Foundation
import Testing
@testable import MnemoCore

@Test("已经配好的机器不再弹引导，而是直接当作已完成")
func onboardingSkipsWhenAlreadyConfigured() {
    let configured = OnboardingReadiness(
        hasAccessibilityPermission: true,
        hasChatCredential: true,
        hasChatModel: true,
        hasEmbeddingModel: true
    )
    #expect(!OnboardingPresentation.shouldPresentAutomatically(
        hasCompletedOnboarding: false,
        readiness: configured
    ), "重装后钥匙串和偏好都还在，不该再走一遍空表单")
    #expect(OnboardingPresentation.canSilentlyMarkCompleted(
        hasCompletedOnboarding: false,
        readiness: configured
    ))

    // 走过一次就永远不再自动弹，哪怕后来把模型删了——那是设置页的事。
    #expect(!OnboardingPresentation.shouldPresentAutomatically(
        hasCompletedOnboarding: true,
        readiness: OnboardingReadiness()
    ))
    #expect(!OnboardingPresentation.canSilentlyMarkCompleted(
        hasCompletedOnboarding: true,
        readiness: configured
    ))
}

@Test("真的没配好才弹；Embedding 与权限缺席不算拦路")
func onboardingPresentsOnlyWhenAICannotRun() {
    // 全新安装：什么都没有。
    #expect(OnboardingPresentation.shouldPresentAutomatically(
        hasCompletedOnboarding: false,
        readiness: OnboardingReadiness()
    ))

    // 有 Key 没选模型：AI 仍然跑不起来，要引导。
    #expect(OnboardingPresentation.shouldPresentAutomatically(
        hasCompletedOnboarding: false,
        readiness: OnboardingReadiness(hasChatCredential: true)
    ))

    // 对话已经能跑，只差 Embedding 和权限：不拦，检索退化成本地也能用。
    let minimal = OnboardingReadiness(hasChatCredential: true, hasChatModel: true)
    #expect(minimal.isAIReady)
    #expect(!minimal.isFullyConfigured)
    #expect(!OnboardingPresentation.shouldPresentAutomatically(
        hasCompletedOnboarding: false,
        readiness: minimal
    ))
}

@Test("完成度按四项事实统计，用于引导页的进度显示")
func onboardingCountsEveryRequirement() {
    #expect(OnboardingReadiness().completedCount == 0)
    #expect(OnboardingReadiness(hasChatCredential: true, hasChatModel: true).completedCount == 2)

    let all = OnboardingReadiness(
        hasAccessibilityPermission: true,
        hasChatCredential: true,
        hasChatModel: true,
        hasEmbeddingModel: true
    )
    #expect(all.completedCount == all.totalCount)
    #expect(all.isFullyConfigured)
}
