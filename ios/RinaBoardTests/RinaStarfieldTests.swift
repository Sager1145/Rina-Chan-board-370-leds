import XCTest
@testable import RinaBoard

final class RinaStarfieldTests: XCTestCase {
    func testParticleGenerationIsDeterministic() {
        let first = RinaStarfieldModel.makeParticles(configuration: .appBackground)
        let second = RinaStarfieldModel.makeParticles(configuration: .appBackground)
        XCTAssertEqual(first, second)
    }

    func testParticleCountMatchesConfiguration() {
        var configuration = RinaStarfieldConfiguration.appBackground
        configuration.particleCount = 41
        XCTAssertEqual(RinaStarfieldModel.makeParticles(configuration: configuration).count, 41)
        configuration.particleCount = 0
        XCTAssertTrue(RinaStarfieldModel.makeParticles(configuration: configuration).isEmpty)
    }

    func testParticlesStayWithinConfiguredRanges() {
        let configuration = RinaStarfieldConfiguration.appBackground
        let particles = RinaStarfieldModel.makeParticles(configuration: configuration)
        XCTAssertFalse(particles.isEmpty)
        for particle in particles {
            XCTAssert((0.035...0.965).contains(particle.x))
            XCTAssert((configuration.minimumSize...configuration.maximumSize).contains(particle.size))
            XCTAssert((configuration.minimumDuration...configuration.maximumDuration).contains(particle.duration))
            XCTAssert((0..<1).contains(particle.initialPhase))
            XCTAssertLessThanOrEqual(abs(particle.horizontalSway), configuration.maximumHorizontalSway)
            XCTAssertLessThanOrEqual(abs(particle.linearDrift), configuration.maximumLinearDrift)
        }
    }

    func testParticlesStartSpreadOverThePass() {
        let particles = RinaStarfieldModel.makeParticles(configuration: .appBackground)
        let buckets = Set(particles.map { Int($0.initialPhase * 4) })
        XCTAssertEqual(buckets.count, 4, "Stars should already be spread over the screen at launch.")
        XCTAssertEqual(Set(particles.map(\.tone)).count, 3)
    }

    func testStarRisesFromBelowTheScreenToAboveIt() throws {
        let particle = try XCTUnwrap(RinaStarfieldModel.makeParticles(configuration: .appBackground).first)
        let size = CGSize(width: 400, height: 800)
        let margin = RinaStarfieldConfiguration.appBackground.verticalMargin
        // Time at which this particle is 30% and then 60% through its pass.
        func time(atProgress progress: Double) -> TimeInterval {
            var phase = progress - particle.initialPhase
            if phase < 0 { phase += 1 }
            return phase * particle.duration
        }
        let lower = try XCTUnwrap(RinaStarfield.placement(of: particle, in: size, time: time(atProgress: 0.3), margin: margin))
        let higher = try XCTUnwrap(RinaStarfield.placement(of: particle, in: size, time: time(atProgress: 0.6), margin: margin))
        XCTAssertLessThan(higher.center.y, lower.center.y)
        XCTAssertEqual(lower.center.y, 800 + margin - 0.3 * (800 + margin * 2), accuracy: 0.001)
    }

    @MainActor
    func testStarClockHoldsTimeWhilePausedInsteadOfJumping() {
        let clock = RinaStarClock()
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        XCTAssertEqual(clock.time(at: start), 0)

        clock.setRunning(true, at: start)
        clock.setRunning(true, at: start.addingTimeInterval(1)) // repeated report from a second backdrop
        XCTAssertEqual(clock.time(at: start.addingTimeInterval(2)), 2, accuracy: 1e-9)

        clock.setRunning(false, at: start.addingTimeInterval(2))
        clock.setRunning(false, at: start.addingTimeInterval(3))
        // A 60 s pause (boot loader, Notification Center) adds nothing.
        XCTAssertEqual(clock.time(at: start.addingTimeInterval(62)), 2, accuracy: 1e-9)

        clock.setRunning(true, at: start.addingTimeInterval(62))
        XCTAssertEqual(clock.time(at: start.addingTimeInterval(62)), 2, accuracy: 1e-9)
        XCTAssertEqual(clock.time(at: start.addingTimeInterval(63.5)), 3.5, accuracy: 1e-9)
    }

    func testStarIsInvisibleAtTheWrapPoint() throws {
        let particle = try XCTUnwrap(RinaStarfieldModel.makeParticles(configuration: .appBackground).first)
        let wrapTime = (1 - particle.initialPhase) * particle.duration
        XCTAssertNil(RinaStarfield.placement(of: particle, in: CGSize(width: 400, height: 800),
                                             time: wrapTime, margin: 36))
    }
}
