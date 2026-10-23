import AppKit
import BowCore

/// The tint of the Space on screen: the window's one Frame colored surface (behind the sidebar and around the page
/// card) takes a light wash of the active Space's theme color (`SpaceTint`), in light and dark appearance alike, and
/// the default theme leaves the plain Frame color. When the tint changes (another Space comes on screen, or the
/// Space on screen gets another theme) it fades to the new one in a fifth of a second, or changes at once with
/// Reduce Motion on.
@MainActor
final class SpaceThemeFeature: NSResponder, BrowserWindowFeature {
    /// How long the tint takes to change.
    static let duration: TimeInterval = 0.2

    init(window: BrowserWindowController) {
        self.window = window
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    isolated deinit {
        animation?.stop()
    }

    private weak var window: BrowserWindowController?
    /// The theme the tint shows, or is fading to; nil until the window first shows a Space.
    private(set) var theme: SpaceTheme?
    /// The surface colors drawn now, in light and dark appearance.
    private var shown: Pair?
    private var animation: TintAnimation?

    /// Whether the tint is fading to `theme` right now.
    var isAnimating: Bool { animation?.isAnimating ?? false }

    /// A surface color for each appearance.
    private struct Pair {
        var light: SpaceTintColor
        var dark: SpaceTintColor

        func mixed(with other: Pair, fraction: Double) -> Pair {
            Pair(
                light: light.mixed(with: other.light, fraction: fraction),
                dark: dark.mixed(with: other.dark, fraction: fraction))
        }
    }

    func activeSpaceChanged(_ space: SidebarSpace) {
        show(space.resolvedTheme)
    }

    func storeChanged(_ graph: SidebarGraph) {
        show(graph.activeTheme)
    }

    /// Tints the window for `theme`: at once the first time, then fading unless Reduce Motion is on. The same theme
    /// again changes nothing; a new one mid fade fades on from the color drawn now, so nothing stays half tinted.
    private func show(_ next: SpaceTheme) {
        guard next != theme else { return }
        theme = next
        let target = Pair(
            light: SpaceTint.color(for: next, over: Self.frame(.aqua)),
            dark: SpaceTint.color(for: next, over: Self.frame(.darkAqua)))
        animation?.stop()
        animation = nil
        guard let from = shown, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            draw(target)
            return
        }
        let fade = TintAnimation(duration: Self.duration) { [weak self] progress in
            self?.draw(from.mixed(with: target, fraction: progress))
        }
        animation = fade
        fade.start()
    }

    private func draw(_ pair: Pair) {
        shown = pair
        let light = Self.nsColor(pair.light)
        let dark = Self.nsColor(pair.dark)
        window?.window?.backgroundColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    /// The brand's Frame color in appearance `name`.
    private static func frame(_ name: NSAppearance.Name) -> SpaceTintColor {
        var color = SpaceTintColor(red: 0, green: 0, blue: 0)
        NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
            if let srgb = BowBrand.frame.usingColorSpace(.sRGB) {
                color = SpaceTintColor(
                    red: Double(srgb.redComponent), green: Double(srgb.greenComponent),
                    blue: Double(srgb.blueComponent))
            }
        }
        return color
    }

    private static func nsColor(_ color: SpaceTintColor) -> NSColor {
        NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1)
    }
}

/// A standard AppKit animation that runs on the main run loop without blocking it, handing each frame's progress
/// (eased in and out, from 0 to 1) to `step`; the last frame is always 1.
@MainActor
private final class TintAnimation: NSAnimation {
    private nonisolated let step: @MainActor @Sendable (Double) -> Void

    init(duration: TimeInterval, step: @escaping @MainActor @Sendable (Double) -> Void) {
        self.step = step
        super.init(duration: duration, animationCurve: .easeInOut)
        animationBlockingMode = .nonblocking
        frameRate = 60
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var currentProgress: NSAnimation.Progress {
        // A nonblocking animation sets its progress from the main run loop.
        didSet {
            let value = Double(currentValue)
            let step = self.step
            MainActor.assumeIsolated { step(value) }
        }
    }
}
