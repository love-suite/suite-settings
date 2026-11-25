import Foundation
import SuiteCore

/// The profile last loaded or saved (Settings › Profile), for what can be restored from it.
struct CurrentProfile {
    var name: String
    /// Explorer's settings as the profile holds them.
    var settings: [String: Any]

    static func load(store: ProfileStore = ProfileStore()) -> CurrentProfile? {
        guard let path = SuiteDefaults.explorer.string(forKey: SettingsProfile.currentKey) else { return nil }
        let wanted = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard let file = store.list().first(where: { $0.url.resolvingSymlinksInPath().path == wanted }),
              let profile = try? store.read(file) else { return nil }
        return CurrentProfile(name: profile.name, settings: profile.settings[SuiteDefaults.explorerDomain] ?? [:])
    }
}
