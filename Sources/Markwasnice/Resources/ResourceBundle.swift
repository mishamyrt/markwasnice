import Foundation

/// Where the bundled fonts and images actually live at runtime.
///
/// `Bundle.module` cannot be used directly. SwiftPM generates it to look for
/// the resource bundle next to `Bundle.main.bundleURL` — which, for an app, is
/// `Markwasnice.app` itself rather than its `Contents/Resources` — and to fall
/// back to the absolute `.build` path of the machine that compiled the binary.
/// On the build machine that fallback always hits, so a distributed .app with
/// no resource bundle inside it looks perfectly healthy locally and traps in
/// `fatalError` on every other machine.
enum ResourceBundle {
    private static let bundleName = "Markwasnice_Markwasnice.bundle"

    static let current: Bundle = {
        let candidates = [
            // Packaged .app: Contents/Resources/Markwasnice_Markwasnice.bundle
            Bundle.main.resourceURL,
            // `swift run`: the bundle sits beside the executable
            Bundle.main.bundleURL,
        ]

        for base in candidates.compactMap(\.self) {
            let url = base.appendingPathComponent(bundleName)
            if let bundle = Bundle(path: url.path) {
                return bundle
            }
        }

        // Tests and any other layout SwiftPM knows about.
        return .module
    }()
}
