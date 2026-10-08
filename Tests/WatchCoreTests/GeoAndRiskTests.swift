import XCTest
@testable import WatchCore

final class GeoAndRiskTests: XCTestCase {
    func testChineseLocationAndUnknownCity() throws {
        let data = Data(#"{"ip":"1.1.1.1","success":true,"country_code":"US","region":"哥伦比亚特区","city":"華盛頓哥倫比亞特區","postal":"20511","timezone":{"id":"America/New_York"},"connection":{"asn":3257,"isp":"Example"}}"#.utf8)
        let geo = try GeoParser.parse(data, ip: "1.1.1.1")
        XCTAssertEqual(GeoPresentation.location(geo), "美国 · 哥伦比亚特区 · 华盛顿哥伦比亚特区")
        XCTAssertEqual(geo.postal, "20511")
        XCTAssertEqual(geo.timezone, "America/New_York")
        XCTAssertThrowsError(try GeoParser.parse(data, ip: "8.8.8.8"))
        XCTAssertEqual(GeoPresentation.location(Geo(ip: "1.1.1.1", country: "US", asn: 1, isp: "Example")), "美国")
    }

    func testMissingRiskFlagsStayUnknownAndWrongIPIsRejected() throws {
        let data = Data(#"{"ip":"1.1.1.1","risk":{"is_vpn":false,"is_datacenter":true}}"#.utf8)
        let risk = try IPRisk.parse(data, ip: "1.1.1.1")
        XCTAssertEqual(IPRisk.label(risk.vpn), "情报库未标记")
        XCTAssertEqual(IPRisk.label(risk.datacenter), "情报库已标记")
        XCTAssertEqual(IPRisk.label(risk.proxy), "未知")
        XCTAssertThrowsError(try IPRisk.parse(data, ip: "8.8.8.8"))
        XCTAssertThrowsError(try IPRisk.parse(Data(#"{"ip":"1.1.1.1","risk":{}}"#.utf8), ip: "1.1.1.1"))
        XCTAssertThrowsError(try IPRisk.parse(Data(#"{"error":"rate limited"}"#.utf8), ip: "1.1.1.1"))
    }

    func testOldStateDecodesAndAddedDetailsDoNotChangeBaselineComparison() throws {
        let data = Data(#"{"date":0,"endpoints":[{"host":"claude.ai","ip":"1.1.1.1","country":"US"}],"geo":{"1.1.1.1":{"ip":"1.1.1.1","country":"US","asn":3257,"isp":"Example","checkedAt":0}},"geoErrors":{}}"#.utf8)
        let old = try JSONDecoder().decode(Snapshot.self, from: data)
        XCTAssertNil(old.geo["1.1.1.1"]?.city)
        XCTAssertNil(old.risks)
        var current = old
        current.geo["1.1.1.1"]?.city = "华盛顿"
        current.riskErrors = ["1.1.1.1": "HTTP 429"]
        XCTAssertTrue(Comparison.issues(current, baseline: old, settings: WatchSettings()).isEmpty)
    }

    func testTimezoneUsesDateForDaylightSavingAndUnknownIsNotLocalTimezone() {
        let formatter = ISO8601DateFormatter()
        let summer = formatter.date(from: "2026-07-01T12:00:00Z")!
        let winter = formatter.date(from: "2026-01-01T12:00:00Z")!
        XCTAssertTrue(GeoPresentation.timezone("America/New_York", at: summer).contains("UTC−04:00"))
        XCTAssertTrue(GeoPresentation.timezone("America/New_York", at: winter).contains("UTC−05:00"))
        XCTAssertEqual(GeoPresentation.timezone(nil), "未知")
        XCTAssertEqual(GeoPresentation.timezone("invalid"), "未知")
    }
}
