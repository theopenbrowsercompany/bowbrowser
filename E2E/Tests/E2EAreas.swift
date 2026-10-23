/// Every e2e area's tests, in the order `--e2e=all` runs them. To add an area, add its file in E2E/Tests and one
/// line here. One entry per line, each with a trailing comma: git merges this file by union (`.gitattributes`),
/// and `make guards` checks the format, duplicate lines and duplicate test names.
@MainActor
enum E2EAreas {
    static let all: [[any E2ETest]] = [
        AppTests.all,
        SandboxTests.all,
        InputTests.all,
        TabsTests.all,
        ProfilesTests.all,
        NavigationTests.all,
        FindTests.all,
        PermissionsTests.all,
        SidebarViewTests.all,
        ImportTests.all,
        DownloadsTests.all,
        StoreTests.all,
    ]
}
