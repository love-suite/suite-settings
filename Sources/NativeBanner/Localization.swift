import Foundation

/// The banner's strings in the Mac's language (`Bundle.module`, this library's catalog).
public func BL(_ key: String) -> String {
    let language = Locale.preferredLanguages.first.map { String($0.prefix(2)) } ?? "en"
    if let path = Bundle.module.path(forResource: language, ofType: "lproj"), let bundle = Bundle(path: path) {
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }
    return NSLocalizedString(key, bundle: .module, comment: "")
}
