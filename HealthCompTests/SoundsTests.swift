import AVFoundation
import XCTest
@testable import HealthComp

@MainActor
final class SoundsTests: XCTestCase {
    func testEverySoundIsBundledAndItsHitIsInsideTheFile() throws {
        XCTAssertEqual(SoundEffect.allCases.count, 11)
        for effect in SoundEffect.allCases {
            let url = try XCTUnwrap(Sounds.url(effect), effect.rawValue)
            let file = try AVAudioFile(forReading: url)
            let duration = Double(file.length) / file.fileFormat.sampleRate
            XCTAssertLessThan(effect.accent, duration, effect.rawValue)
            XCTAssertGreaterThan(effect.gain, 0, effect.rawValue)
            XCTAssertLessThanOrEqual(effect.gain, 1, effect.rawValue)
        }
    }

    #if DEBUG
    func testATestRunIsMuted() {
        XCTAssertTrue(Sounds.isMuted)
    }
    #endif

    func testTheSwitchAndTheSliderSetTheLevel() throws {
        let name = "SoundsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        // On and at full volume until Settings says otherwise.
        XCTAssertEqual(try XCTUnwrap(Sounds.level(.versus, defaults: defaults)), 0.8, accuracy: 0.0001)
        defaults.set(0.5, forKey: Sounds.volumeKey)
        XCTAssertEqual(try XCTUnwrap(Sounds.level(.versus, defaults: defaults)), 0.2, accuracy: 0.0001)
        XCTAssertEqual(
            try XCTUnwrap(Sounds.level(.stamp, defaults: defaults)),
            0.2 * SoundEffect.stamp.gain,
            accuracy: 0.0001
        )
        defaults.set(0.0, forKey: Sounds.volumeKey)
        XCTAssertEqual(Sounds.level(.versus, defaults: defaults), 0)
        defaults.set(1.0, forKey: Sounds.volumeKey)
        defaults.set(false, forKey: Sounds.enabledKey)
        XCTAssertNil(Sounds.level(.versus, defaults: defaults))
    }
}
