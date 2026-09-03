import Foundation
import Testing
@testable import MnemoCore

@Test("当前版本三类未来授权能力全部从统一入口开放")
func currentEntitlementsAreOpen() {
    let gate = OpenEntitlementGate()
    #expect(EntitledFeature.allCases.allSatisfy(gate.isUnlocked))
}

@Test("首次安装版本只写一次，升级不会覆盖")
func firstInstalledVersionIsStable() {
    let suite = "MnemoTests.EarlyAccess.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    #expect(EarlyAccessMarker.recordIfNeeded(currentVersion: "2.0.0", defaults: defaults) == "2.0.0")
    #expect(EarlyAccessMarker.recordIfNeeded(currentVersion: "3.0.0", defaults: defaults) == "2.0.0")
    #expect(defaults.string(forKey: EarlyAccessMarker.defaultsKey) == "2.0.0")
}
