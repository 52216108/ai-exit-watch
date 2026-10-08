import XCTest
@testable import WatchCore

final class LocalIPv6Tests: XCTestCase {
    func testLinkLocalAndMissingConfigurationAreNotReportedDisabled() {
        XCTAssertEqual(LocalIPv6.configurationLabel(enabled: true, method: "LinkLocal"), "仅链路本地（未完全关闭）")
        XCTAssertEqual(LocalIPv6.configurationLabel(enabled: false, method: nil), "IPv6 已关闭")
        XCTAssertEqual(LocalIPv6.configurationLabel(enabled: true, method: "Automatic"), "IPv6 已开启（自动配置）")
        XCTAssertTrue(LocalIPv6.configurationLabel(enabled: nil, method: nil).contains("未知"))
        XCTAssertTrue(LocalIPv6.configurationLabel(enabled: true, method: nil).contains("未知"))
    }

    func testInterfaceAddressesDoNotClaimInternetConnectivityOrDisabledSettings() {
        XCTAssertTrue(LocalIPv6.addressSummary([]).contains("不等于设置已关闭"))
        XCTAssertEqual(LocalIPv6.addressSummary(["fe80::1%en1", "fd00::1"]), "仅发现链路本地／局域网地址，未发现全局单播地址")
        XCTAssertEqual(LocalIPv6.addressSummary(["fe80::1%en1", "2606:4700::1111"]), "发现 1 个全局单播地址；公网连通性尚未验证")
        XCTAssertEqual(LocalIPv6.addressSummary(["100::1"]), "存在其他 IPv6 地址；公网连通性未知")
    }
}
