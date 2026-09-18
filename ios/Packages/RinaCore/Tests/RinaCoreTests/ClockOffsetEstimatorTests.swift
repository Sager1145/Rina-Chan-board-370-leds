import XCTest
@testable import RinaCore

final class ClockOffsetEstimatorTests: XCTestCase {
    func testSymmetricDelayOffsetIsZeroWhenClocksMatch() {
        // m1=1000, board rx=1000+5(delay)=1005, board tx=1005, m4=1000+5+5=1010 (rtt=10, offset=0).
        let sample = ClockSample(m1: 1000, b2: 1005, b3: 1005, m4: 1010)
        XCTAssertEqual(sample.rttUs, 10)
        XCTAssertEqual(sample.offsetUs, 0)
    }

    func testAsymmetricDelayIsHandledByOffsetFormula() {
        // Board clock is 500us ahead of phone; 3us up, 7us down (asymmetric).
        // m1=1000, b2 = 1000+3+500=1503, b3=1503, m4=1000+3+7=1010.
        let sample = ClockSample(m1: 1000, b2: 1503, b3: 1503, m4: 1010)
        XCTAssertEqual(sample.rttUs, (1010 - 1000) - (1503 - 1503))
        XCTAssertEqual(sample.offsetUs, ((1503 - 1000) + (1503 - 1010)) / 2)
    }

    func testEstimatePicksMinimumRttSample() {
        var estimator = ClockOffsetEstimator()
        // rtt=(100-0)-(150-150)=100, offset=(150+50)/2=100.
        estimator.addSample(ClockSample(m1: 0, b2: 150, b3: 150, m4: 100), bootId: "boot-1")
        // Lower RTT (0), offset 500 — must win over the higher-RTT sample above.
        // rtt=(1000-1000)-(1500-1500)=0, offset=((1500-1000)+(1500-1000))/2=500.
        estimator.addSample(ClockSample(m1: 1000, b2: 1500, b3: 1500, m4: 1000), bootId: "boot-1")
        XCTAssertEqual(estimator.bestRttUs, 0)
        XCTAssertEqual(estimator.offsetUs, 500)
    }

    func testBoardTimeAndPhoneTimeRoundTrip() {
        var estimator = ClockOffsetEstimator()
        estimator.addSample(ClockSample(m1: 1000, b2: 1500, b3: 1500, m4: 1000), bootId: "boot-1")
        let boardTime = estimator.boardTime(forPhone: 5_000_000)
        XCTAssertEqual(boardTime, 5_000_000 + 500)
        XCTAssertEqual(estimator.phoneTime(forBoard: boardTime!), 5_000_000)
    }

    func testNoSamplesYieldsNilEstimate() {
        let estimator = ClockOffsetEstimator()
        XCTAssertNil(estimator.bestRttUs)
        XCTAssertNil(estimator.offsetUs)
        XCTAssertNil(estimator.boardTime(forPhone: 1000))
        XCTAssertNil(estimator.phoneTime(forBoard: 1000))
    }

    func testKeepsOnlyLastMaxSamples() {
        var estimator = ClockOffsetEstimator(maxSamples: 2)
        // First sample: huge RTT but would win on offset if not evicted.
        estimator.addSample(ClockSample(m1: 0, b2: 100_000, b3: 100_000, m4: 200_000), bootId: "boot-1")
        estimator.addSample(ClockSample(m1: 1000, b2: 1200, b3: 1200, m4: 1400), bootId: "boot-1")
        estimator.addSample(ClockSample(m1: 2000, b2: 2200, b3: 2200, m4: 2400), bootId: "boot-1")
        XCTAssertEqual(estimator.samples.count, 2)
        // The very first (huge-RTT, low-index) sample must have been evicted.
        XCTAssertFalse(estimator.samples.contains(where: { $0.rttUs == 200_000 }))
    }

    func testBootIdChangeDiscardsAllSamples() {
        var estimator = ClockOffsetEstimator()
        estimator.addSample(ClockSample(m1: 0, b2: 100, b3: 100, m4: 10), bootId: "boot-1")
        estimator.addSample(ClockSample(m1: 1000, b2: 1100, b3: 1100, m4: 1010), bootId: "boot-1")
        XCTAssertEqual(estimator.samples.count, 2)

        estimator.addSample(ClockSample(m1: 5000, b2: 5100, b3: 5100, m4: 5010), bootId: "boot-2")
        XCTAssertEqual(estimator.samples.count, 1)
        XCTAssertEqual(estimator.bootId, "boot-2")
    }

    func testRemoveAllSamplesClearsSamplesButKeepsBootId() {
        // A fresh re-anchor sampling burst must not let a stale low-RTT
        // sample from an earlier burst keep winning the estimate.
        var estimator = ClockOffsetEstimator()
        estimator.addSample(ClockSample(m1: 0, b2: 50, b3: 50, m4: 10), bootId: "boot-1") // rtt=10
        XCTAssertEqual(estimator.bestRttUs, 10)

        estimator.removeAllSamples()
        XCTAssertTrue(estimator.samples.isEmpty)
        XCTAssertNil(estimator.bestRttUs)
        XCTAssertNil(estimator.offsetUs)
        // bootId is remembered, so a same-boot sample after clearing does not
        // get treated as a boot change (no implicit extra discard).
        XCTAssertEqual(estimator.bootId, "boot-1")

        estimator.addSample(ClockSample(m1: 1000, b2: 1500, b3: 1500, m4: 1000), bootId: "boot-1") // rtt=0
        XCTAssertEqual(estimator.samples.count, 1)
        XCTAssertEqual(estimator.bestRttUs, 0)
    }
}
