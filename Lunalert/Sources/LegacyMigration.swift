import Foundation

/// The app used to be called Belfry. On first launch as Lunalert, carry over its settings, its
/// already-announced history (so old notifications aren't announced again) and a saved token.
enum LegacyMigration {
    private static let oldName = "Bel" + "fry"
    private static let oldIdentifier = "io.github.baramir." + "bel" + "fry"
    private static let doneKey = "migratedFromPreviousName"

    static func run() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        if let old = defaults.persistentDomain(forName: oldIdentifier) {
            for (key, value) in old where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let oldDir = support.appendingPathComponent(oldName, isDirectory: true)
        let newDir = support.appendingPathComponent("Lunalert", isDirectory: true)
        if fm.fileExists(atPath: oldDir.path), !fm.fileExists(atPath: newDir.path) {
            try? fm.moveItem(at: oldDir, to: newDir)
        }
        if Keychain.readToken() == nil, let token = Keychain.readToken(service: oldIdentifier) {
            Keychain.saveToken(token)
        }
        defaults.set(true, forKey: doneKey)
    }
}
