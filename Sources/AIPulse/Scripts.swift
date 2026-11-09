import Foundation

enum Scripts {
    /// Scripts ship inside the app bundle so the app and its data collector are one install.
    static func url(_ name: String) -> URL? {
        Bundle.main.resourceURL?.appendingPathComponent("scripts/\(name)")
    }
}
