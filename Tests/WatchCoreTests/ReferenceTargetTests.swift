import XCTest
@testable import WatchCore

final class ReferenceTargetTests: XCTestCase {
    func testPlainIPRejectsHTMLAndDoesNotInferCountryFromSource() throws {
        let result = try ReferenceTarget.domestic.parse(Data(" 203.0.113.1\n".utf8), milliseconds: 20)
        XCTAssertEqual(result.ip, "203.0.113.1")
        XCTAssertNil(result.country, "国内参考来源不能直接推断出口在中国")
        XCTAssertThrowsError(try ReferenceTarget.overseas.parse(Data("<html>203.0.113.1</html>".utf8), milliseconds: 20))
        XCTAssertThrowsError(try ReferenceTarget.overseas.parse(Data("999.0.0.1".utf8), milliseconds: 20))
        XCTAssertEqual(try ReferenceTarget.overseas.parse(Data("2001:db8::1\n".utf8), milliseconds: 20).ip, "2001:db8::1")
        XCTAssertThrowsError(try ReferenceTarget.cloudflare.parse(Data("ip=203.0.113.1".utf8), milliseconds: 20))
    }

    func testReferenceFailuresAndDifferentIPsDoNotChangeBaselineOrAlerts() throws {
        var settings = WatchSettings(); settings.geoEnabled = false
        let baseline = Snapshot(endpoints: Endpoint.monitoredHosts.map { Endpoint(host: $0, ip: "203.0.113.1", country: "US") })
        var current = baseline
        current.referenceEndpoints = [Endpoint(host: ReferenceTarget.domestic.rawValue, ip: "198.51.100.1"), Endpoint(host: ReferenceTarget.overseas.rawValue, error: "连接超时")]
        XCTAssertTrue(current.canBaseline(settings: settings))
        XCTAssertTrue(Comparison.issues(current, baseline: baseline, settings: settings).isEmpty)
        let decoded = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(current))
        XCTAssertEqual(decoded.referenceEndpoints, current.referenceEndpoints)
        XCTAssertNil(baseline.referenceEndpoints)
        let old = Data(#"{"date":0,"endpoints":[],"geo":{},"geoErrors":{}}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(Snapshot.self, from: old).referenceEndpoints)
    }
}
