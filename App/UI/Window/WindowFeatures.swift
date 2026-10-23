/// Every browser window feature, in the order the window creates them and the responder chain asks them.
/// To add one, add its file under `App/UI/Window/` and one line here. One entry per line, each with a trailing
/// comma: git merges this file by union (`.gitattributes`), and `make guards` checks the format and duplicates.
@MainActor
enum WindowFeatures {
    static let all: [any BrowserWindowFeature.Type] = [
        NavigationFeature.self,
        FindFeature.self,
        PermissionsFeature.self,
        SidebarFeature.self,
        DownloadsFeature.self,
        TabActivityFeature.self,
        EmptySpaceFeature.self,
        HistoryFeature.self,
        SpacesFeature.self,
        PopupsFeature.self,
        CommandBarFeature.self,
        ContextMenuFeature.self,
        TabUnloadFeature.self,
        WindowLookFeature.self,
    ]
}
