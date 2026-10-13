import Network
import XCTest
@testable import RinaBoard

final class TCPHotspotInterfaceTests: XCTestCase {
    func testBoardHotspotTCPRequiresWiFi() {
        let parameters = TCPTransport.parameters(for: .hotspot)

        XCTAssertEqual(parameters.requiredInterfaceType, .wifi)
    }

    func testHomeWiFiAndOtherTCPKeepTheSystemInterfaceChoice() {
        let unrestricted = NWParameters.tcp.requiredInterfaceType
        let homeWiFi = TCPTransport.parameters(for: .wifi(host: "rina.local", port: 80))
        let other = TCPTransport.parameters(for: .bluetooth)

        XCTAssertNotEqual(unrestricted, .wifi)
        XCTAssertEqual(homeWiFi.requiredInterfaceType, unrestricted)
        XCTAssertEqual(other.requiredInterfaceType, unrestricted)
    }
}
