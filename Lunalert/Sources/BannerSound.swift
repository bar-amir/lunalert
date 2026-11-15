import AppKit
import UserNotifications

/// The sound a banner plays: one of Lunalert's own cosmic sounds (bundled in
/// `Contents/Resources`, made by `scripts/make-sounds.py`), a macOS alert sound, or none.
/// Stored in UserDefaults as its raw value: "Starlight", "system:Glass" or "none".
struct BannerSound: RawRepresentable, Hashable, Identifiable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    var id: String { rawValue }

    static let defaultsKey = "bannerSound"
    static let none = BannerSound(rawValue: "none")
    static let `default` = BannerSound(rawValue: "Starlight")

    /// Lunalert's own sounds, in menu order.
    static let lunalert: [BannerSound] = ["Starlight", "Pulsar", "Comet", "Orbit", "Nebula", "Moonrise"]
        .map(BannerSound.init(rawValue:))

    /// The alert sounds macOS ships, by name ("Glass", "Ping", …).
    static let system: [BannerSound] = {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/System/Library/Sounds")) ?? []
        return names.filter { $0.hasSuffix(".aiff") }
            .map { ($0 as NSString).deletingPathExtension }
            .sorted()
            .map { BannerSound(rawValue: "system:\($0)") }
    }()

    var isSystem: Bool { rawValue.hasPrefix("system:") }
    var name: String { isSystem ? String(rawValue.dropFirst("system:".count)) : rawValue }
    var label: String { self == .none ? "None" : name }

    private var bundledURL: URL? {
        guard !isSystem, self != .none else { return nil }
        return Bundle.main.url(forResource: name, withExtension: "caf")
    }

    /// What to attach to a banner. Bundled sounds sit directly in `Contents/Resources`, where
    /// UserNotifications looks for an app's own sounds; system ones resolve by plain name.
    var notificationSound: UNNotificationSound? {
        if self == .none { return nil }
        if isSystem { return UNNotificationSound(named: UNNotificationSoundName(name)) }
        guard bundledURL != nil else { return .default }
        return UNNotificationSound(named: UNNotificationSoundName("\(name).caf"))
    }

    private static var previewing: NSSound?

    /// Plays the sound right away, for the Settings preview.
    func preview() {
        Self.previewing?.stop()
        let sound: NSSound?
        if self == .none { sound = nil }
        else if isSystem { sound = NSSound(named: NSSound.Name(name)) }
        else { sound = bundledURL.flatMap { NSSound(contentsOf: $0, byReference: true) } }
        Self.previewing = sound
        sound?.play()
    }

    /// The old on/off "Play a sound" switch becomes a choice: off maps to None, on to the default.
    static func migrateLegacyToggle() {
        let defaults = UserDefaults.standard
        guard let enabled = defaults.object(forKey: "soundEnabled") as? Bool else { return }
        if defaults.string(forKey: defaultsKey) == nil, !enabled {
            defaults.set(none.rawValue, forKey: defaultsKey)
        }
        defaults.removeObject(forKey: "soundEnabled")
    }
}
