// swift-format-ignore-file
// (swift-format would put a one-entry list on one line without its trailing comma, which union merges need.)

/// Every app-level service, in the order the app creates them. To add one, add its file under `App/UI/App/` and
/// one line here. One entry per line, each with a trailing comma: git merges this file by union (`.gitattributes`),
/// and `make guards` checks the format and duplicates.
@MainActor
enum AppFeatures {
    static let all: [any AppFeature.Type] = [
        SitePermissionStores.self,
        DownloadsCenter.self,
    ]
}
