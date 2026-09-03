import Foundation
import Testing
@testable import MnemoCore

@Test("版本号比较忽略 v 前缀和缺的段")
func versionComparison() {
    #expect(AppVersion("3.0") < AppVersion("3.0.1"))
    #expect(AppVersion("v3.1") > AppVersion("3.0.9"))
    #expect(AppVersion("3.0") == AppVersion("3.0.0"))
    #expect(AppVersion("v2.10") > AppVersion("2.9"))
}

@Test("release 解析挑出 dmg 附件和版本号")
func parsesRelease() throws {
    let json = """
    {
      "tag_name": "v3.1.0",
      "name": "3.1",
      "body": "## 更新\\n- 新增合集",
      "published_at": "2026-09-04T10:00:00Z",
      "assets": [
        {"name": "Mnemo-3.1.0.dmg", "browser_download_url": "https://example.com/Mnemo-3.1.0.dmg"},
        {"name": "checksums.txt", "browser_download_url": "https://example.com/checksums.txt"}
      ]
    }
    """.data(using: .utf8)!
    let release = try ReleaseParsing.latestRelease(from: json)
    #expect(release.version == AppVersion("3.1.0"))
    #expect(release.assetName == "Mnemo-3.1.0.dmg")
    #expect(release.publishedAt != nil)
}

@Test("没有 dmg 附件的 release 不可用，不会误报有更新")
func rejectsReleaseWithoutDmg() {
    let json = """
    {"tag_name": "v9.9", "assets": [{"name": "src.zip", "browser_download_url": "https://x/1"}]}
    """.data(using: .utf8)!
    #expect(throws: ReleaseParsing.Error.self) {
        _ = try ReleaseParsing.latestRelease(from: json)
    }
}

@Test("tag 不是版本号时直接拒绝")
func rejectsNonVersionTag() {
    let json = """
    {"tag_name": "nightly", "assets": [{"name": "a.dmg", "browser_download_url": "https://x/a.dmg"}]}
    """.data(using: .utf8)!
    #expect(throws: ReleaseParsing.Error.self) {
        _ = try ReleaseParsing.latestRelease(from: json)
    }
}
