/// The app's one name for the engine's page view. Everything outside `App/UI/Engine/` uses this name, so the switch
/// to the BowWebKit engine points it at `WebKitSurfaceView` and touches no other file.
typealias EngineSurfaceView = BowWebView
