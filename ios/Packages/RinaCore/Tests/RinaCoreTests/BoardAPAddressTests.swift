import XCTest
@testable import RinaCore

final class BoardAPAddressTests: XCTestCase {
    func testFactoryVectorsAndReservedHostRemapping() {
        let vectors = [
            "80B54EF48E09": "10.244.142.9", "80B54EF74801": "10.247.72.1",
            "000000000001": "10.0.0.1", "000000FFFFFE": "10.255.255.254",
            "000000000000": "172.16.0.1", "0000000000FF": "172.16.0.2",
            "000000007EFF": "172.16.0.254", "000000007F00": "172.16.1.1",
            "000000FFFF00": "172.18.4.7", "000000FFFFFF": "172.18.4.8"
        ]
        for (identity, expected) in vectors {
            XCTAssertEqual(BoardAPAddress.defaultAddress(boardID: identity), expected, identity)
            XCTAssertEqual(BoardAPAddress.defaultAddress(boardID: identity.lowercased()), expected)
            XCTAssertEqual(BoardAPAddress.canonicalPrivateAddress(expected), expected)
        }
        for identity in ["", "F48E09", "80B54EF48E0G", " 80B54EF48E09", "80B54EF48E099"] {
            XCTAssertNil(BoardAPAddress.defaultAddress(boardID: identity))
        }
    }

    func testPrivateGatewayValidationIsStrictAndMatchesFirmware() {
        for address in ["10.0.0.1", "10.255.255.254", "172.16.0.1", "172.31.255.254", "192.168.0.1"] {
            XCTAssertEqual(BoardAPAddress.canonicalPrivateAddress(address), address)
        }
        for address in ["10.0.0.0", "10.0.0.255", "172.15.0.1", "172.32.0.1", "192.169.0.1",
                        "8.8.8.8", "127.0.0.1", "169.254.1.1", "0.0.0.1", "255.255.255.1",
                        "10.0.0.256", "10.0.0", "10..0.1", "10.0.0.1.2", "10.0.0.-1",
                        "10.0.0.+1", "10.0.0.01", "010.0.0.1", "10.0.0.1 ", " 10.0.0.1", "１０.0.0.1"] {
            XCTAssertNil(BoardAPAddress.canonicalPrivateAddress(address), address)
        }
    }

    func testWifiSetApPreservesOldPayloadAndIncludesOptionalIPOnlyWhenRequested() {
        let legacy = RinaCommand.wifiSetAp(ssid: "Board", password: "password").jsonObject
        XCTAssertNil(legacy["ip"])
        XCTAssertEqual(legacy["ssid"] as? String, "Board")
        let ipOnly = RinaCommand.wifiSetAp(ssid: "", password: "", ip: "10.20.30.40").jsonObject
        XCTAssertEqual(ipOnly["ip"] as? String, "10.20.30.40")
        XCTAssertEqual(ipOnly["ssid"] as? String, "")
        XCTAssertEqual(ipOnly["password"] as? String, "")
    }
}
