import AVFoundation

/// The app's eleven sounds, by the moment each one plays on.
enum SoundEffect: String, CaseIterable {
    case versus = "matchup_display"
    case ahead = "menu_spirits_target_pointup"
    case sent = "system_fixed"
    case final = "menu_tournament_battle_finish"
    case total = "result_all_battle_icon"
    case stamp = "common_punch_hit_m"
    case clear = "result_scene_change01"
    case cheer = "audience_cheer_m"
    case slash = "item_killsword_flash"
    case slam = "common_criticalhit"
    case crowd = "audience_cheer_l"

    /// Seconds into the file where its hit is heard: a sound starts this
    /// early, so the hit lands on the picture's.
    var accent: TimeInterval {
        switch self {
        case .versus: 0.085
        case .final: 0.055
        case .cheer: 0.26
        case .crowd: 0.15
        case .slash: 0.015
        case .ahead, .sent: 0.005
        case .total, .stamp, .clear, .slam: 0
        }
    }

    /// How loud the moment is, times what levels its file against the others.
    var gain: Float {
        switch self {
        case .versus: 1
        case .ahead: 0.45 * 0.7
        case .sent: 0.35 * 0.62
        case .final: 0.8 * 0.78
        case .total: 0.4 * 0.82
        case .stamp: 0.9 * 0.47
        case .clear: 0.5
        case .cheer: 0.55
        case .slash: 0.7
        case .slam: 0.72
        case .crowd: 0.6
        }
    }
}

/// Plays them. Ambient audio: silent mode mutes it, and the person's music
/// keeps playing underneath.
@MainActor
enum Sounds {
    static let enabledKey = "healthcomp.sounds.enabled"
    static let volumeKey = "healthcomp.sounds.volume"

    private static var players: [SoundEffect: AVAudioPlayer] = [:]

    /// Test runs play at zero volume: the same path, and no noise from the
    /// Mac behind the simulator.
    static let isMuted: Bool = {
        #if DEBUG
        let process = ProcessInfo.processInfo
        return process.environment["XCTestConfigurationFilePath"] != nil
            || process.arguments.contains { $0.hasSuffix("-competition-test-lab") }
        #else
        return false
        #endif
    }()

    /// Nil when Settings has sounds off. The slider is squared, so halfway
    /// sounds about half as loud.
    static func level(_ effect: SoundEffect, defaults: UserDefaults = .standard) -> Float? {
        guard defaults.object(forKey: enabledKey) as? Bool != false else { return nil }
        let volume = min(max(defaults.object(forKey: volumeKey) as? Double ?? 1, 0), 1)
        return 0.8 * effect.gain * Float(volume * volume)
    }

    /// Plays so the sound's hit lands `delay` seconds from now.
    static func play(_ effect: SoundEffect, in delay: TimeInterval = 0) {
        guard let level = level(effect), level > 0, let player = player(effect) else { return }
        player.stop()
        player.currentTime = 0
        player.volume = isMuted ? 0 : level
        player.play(atTime: player.deviceCurrentTime + max(0, delay - effect.accent))
    }

    /// A skipped animation takes its sounds with it, waiting ones too.
    static func stop() {
        players.values.forEach { $0.stop() }
    }

    static func url(_ effect: SoundEffect) -> URL? {
        Bundle.main.url(forResource: effect.rawValue, withExtension: "wav")
    }

    private static func player(_ effect: SoundEffect) -> AVAudioPlayer? {
        if let player = players[effect] { return player }
        try? AVAudioSession.sharedInstance().setCategory(.ambient)
        guard let url = url(effect), let player = try? AVAudioPlayer(contentsOf: url) else { return nil }
        player.prepareToPlay()
        players[effect] = player
        return player
    }
}
