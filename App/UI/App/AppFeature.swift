import Foundation

/// An app-level service shared by every window, such as a store kept per profile, in its own file under
/// `App/UI/App/` and listed in `AppFeatures.all`. The app delegate creates one of each once the engine has
/// started; window features look them up through `BrowserWindowController.appFeatures`.
@MainActor
protocol AppFeature: AnyObject {
    /// `dataDirectory` is where the engine keeps its profiles for this launch; services keep their files beside them.
    init(dataDirectory: URL)
}

/// The app's services, one of each type in `AppFeatures.all`.
@MainActor
final class AppFeatureSet {
    private let features: [any AppFeature]

    init(dataDirectory: URL) {
        features = AppFeatures.all.map { $0.init(dataDirectory: dataDirectory) }
    }

    /// The service of type `type`, which `AppFeatures.all` lists, so a missing one is a programming error.
    func require<Feature: AppFeature>(_ type: Feature.Type) -> Feature {
        guard let feature = features.lazy.compactMap({ $0 as? Feature }).first else {
            fatalError("\(type) is not listed in AppFeatures.all")
        }
        return feature
    }
}
