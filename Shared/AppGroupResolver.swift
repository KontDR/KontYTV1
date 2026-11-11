import Foundation

enum AppGroupResolver {
    static func candidates(configured: String, altGroups: [String], profileGroups: [String]) -> [String] {
        var seen = Set<String>()
        return ([configured] + altGroups.sorted() + profileGroups.sorted()).filter { value in
            let matches = value == configured || (value.hasPrefix(configured + ".") && value.count > configured.count + 1)
            return matches && seen.insert(value).inserted
        }
    }
    static func profileGroups(bundle: Bundle = .main) -> [String] {
        guard let path = bundle.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: path),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any] else { return [] }
        return entitlements["com.apple.security.application-groups"] as? [String] ?? []
    }
    static func resolved(bundle: Bundle = .main) -> (group: String, url: URL)? {
        guard let configured = bundle.object(forInfoDictionaryKey: "KontYTAppGroup") as? String else { return nil }
        let alt = bundle.object(forInfoDictionaryKey: "ALTAppGroups")
        let groups = (alt as? [String]) ?? Array((alt as? [String: String] ?? [:]).values)
        for group in candidates(configured: configured, altGroups: groups, profileGroups: profileGroups(bundle: bundle)) {
            if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) { return (group, url) }
        }
        return nil
    }
}
