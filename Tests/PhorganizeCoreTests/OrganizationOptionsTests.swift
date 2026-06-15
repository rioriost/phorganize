import XCTest
@testable import PhorganizeCore

final class OrganizationOptionsTests: XCTestCase {
    func testDecodingOldOptionsWithoutTimezoneIdentifierUsesOffsetFallback() throws {
        let json = """
        {
          "recursive": true,
          "includeCameraFolder": false,
          "renameByDate": false,
          "extensionCase": "lower",
          "operationMode": "move",
          "timezoneOffsetHours": 9,
          "metadataConcurrency": 3,
          "copyConcurrency": 2
        }
        """.data(using: .utf8)!

        let options = try JSONDecoder().decode(OrganizationOptions.self, from: json)

        XCTAssertTrue(options.recursive)
        XCTAssertFalse(options.includeCameraFolder)
        XCTAssertFalse(options.includeLensFolder)
        XCTAssertFalse(options.renameByDate)
        XCTAssertEqual(options.extensionCase, .lower)
        XCTAssertEqual(options.operationMode, .move)
        XCTAssertEqual(options.timeZone.secondsFromGMT(), 9 * 3_600)
        XCTAssertEqual(options.metadataConcurrency, 3)
        XCTAssertEqual(options.copyConcurrency, 2)
    }

    func testEncodingAndDecodingTimezoneIdentifier() throws {
        let options = OrganizationOptions(timezoneIdentifier: "America/Los_Angeles")
        let data = try JSONEncoder().encode(options)
        let decoded = try JSONDecoder().decode(OrganizationOptions.self, from: data)

        XCTAssertEqual(decoded.timezoneIdentifier, "America/Los_Angeles")
        XCTAssertEqual(decoded.timeZone.identifier, "America/Los_Angeles")
    }
}
