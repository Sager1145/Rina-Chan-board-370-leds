import Foundation
import XCTest
@testable import RinaBoard

@MainActor
final class AcceptanceRecoveryTests: XCTestCase {
    func testLogExportRedactsJSONPasswordAndKeepsDiagnosticContext() {
        let model = DebugViewModel()
        model.log(.info, #"{"password":"ACCEPTANCE_FAKE_PASSWORD","operation":"connect"}"#)

        let exported = model.logShareText
        XCTAssertFalse(exported.contains("ACCEPTANCE_FAKE_PASSWORD"))
        XCTAssertTrue(exported.contains("connect"), "Redaction must retain useful diagnostic context")
    }

    func testLogExportRedactsEntireBearerAuthorizationValue() {
        let model = DebugViewModel()
        model.log(.warn, "Authorization: Bearer ACCEPTANCE_FAKE_BEARER_TOKEN")

        XCTAssertFalse(model.logShareText.contains("ACCEPTANCE_FAKE_BEARER_TOKEN"),
                       "Redacting only the Bearer scheme leaves the credential in the export")
    }

    func testLogExportDoesNotLeakPasswordSuffixAfterEscapedJSONQuote() throws {
        let model = DebugViewModel()
        let message = #"{"password":"ACCEPTANCE_PREFIX\"ACCEPTANCE_SECRET_SUFFIX","operation":"connect"}"#
        // Verify this is valid JSON containing one password before testing export.
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: String])
        XCTAssertEqual(object["password"], "ACCEPTANCE_PREFIX\"ACCEPTANCE_SECRET_SUFFIX")
        model.log(.info, message)

        let exported = model.logShareText
        XCTAssertFalse(exported.contains("ACCEPTANCE_PREFIX"))
        XCTAssertFalse(exported.contains("ACCEPTANCE_SECRET_SUFFIX"),
                       "An escaped quote must not terminate password redaction")
        XCTAssertTrue(exported.contains("connect"))
    }

    func testRawDiagnosticsKeepUnknownNestedFieldsAndNullValues() throws {
        let data = Data(#"{"futureFirmware":{"backend":"acceptance-backend","samples":[{"label":"first"},{"label":"second"}],"missing":null}}"#.utf8)
        let rows = Dictionary(uniqueKeysWithValues: DebugJSON.flatten(data).map { ($0.key, $0.value) })

        XCTAssertEqual(rows["futureFirmware.backend"], "acceptance-backend")
        XCTAssertEqual(rows["futureFirmware.samples[0].label"], "first")
        XCTAssertEqual(rows["futureFirmware.samples[1].label"], "second")
        XCTAssertNotNil(rows["futureFirmware.missing"], "Unknown null-valued fields must remain visible")
        let prettyData = try XCTUnwrap(DebugJSON.prettyString(from: data).data(using: .utf8))
        let prettyObject = try XCTUnwrap(JSONSerialization.jsonObject(with: prettyData) as? [String: Any])
        XCTAssertNotNil(prettyObject["futureFirmware"])
    }
}
