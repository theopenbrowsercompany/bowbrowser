import AppKit
import BowCore
import Testing
import WebKit

@testable import BowWebKit

/// Loading a site icon or a page image for a tab (`WebKitTab.loadImage`): a PNG and an ICO come back at most the size
/// asked for; an error status, a body that is no image, another scheme and a closed tab give nil; and the fetch sends
/// none of the profile's cookies and stores none, as CEF's `DownloadImage` for an icon.
@Suite(.serialized) @MainActor struct ImageLoadTests {
    init() {
        TestHost.start()
    }

    private func fixture(_ name: String) throws -> Data {
        let root = try #require(Bundle.module.resourceURL).appendingPathComponent("Fixtures/images")
        return try Data(contentsOf: root.appendingPathComponent(name))
    }

    /// The pixel size of `image`'s bitmap, or nil for none.
    private func pixels(_ image: NSImage?) -> String {
        guard let image, let rep = image.representations.first else { return "nil" }
        return "\(rep.pixelsWide)x\(rep.pixelsHigh)"
    }

    private func report(_ ok: Bool, _ check: String, _ detail: String) {
        #expect(ok, "\(check): \(detail)")
        print("\(ok ? "PASS" : "FAIL") imageLoad.\(check): \(detail)")
    }

    /// Runs `body` on a rig with one tab showing a plain page, finishing the rig either way.
    private func withTab(_ body: (TabRig, WebKitTab) async throws -> Void) async throws {
        let rig = try TabRig()
        do {
            let page = rig.url("/navigation/a.html")
            let tab = rig.tab("/navigation/a.html")
            try await rig.waitFor("finish \(page)")
            try await body(rig, tab)
        } catch {
            try? await rig.finish()
            throw error
        }
        try await rig.finish()
    }

    @Test func pngAndIcoComeBackWithinTheSizeAsked() async throws {
        try await withTab { rig, tab in
            // A 256 x 128 PNG asked for at 32 keeps its aspect.
            let png = await tab.loadImage(at: rig.url("/images/wide.png"), maxPixelSize: 32)
            report(pixels(png) == "32x16", "png", pixels(png))

            // An ICO with a 16 and a 64 pixel frame: the largest frame that fits, else the smallest scaled down.
            let ico = rig.url("/images/favicon.ico")
            let fits = await tab.loadImage(at: ico, maxPixelSize: 32)
            let large = await tab.loadImage(at: ico, maxPixelSize: 64)
            let small = await tab.loadImage(at: ico, maxPixelSize: 8)
            let sizes = [fits, large, small].map(pixels)
            report(sizes == ["16x16", "64x64", "8x8"], "ico", sizes.joined(separator: ", "))

            // A data address decodes without a fetch.
            let data = try fixture("wide.png").base64EncodedString()
            let inline = await tab.loadImage(
                at: try #require(URL(string: "data:image/png;base64,\(data)")), maxPixelSize: 64)
            report(pixels(inline) == "64x32", "dataURL", pixels(inline))
        }
    }

    @Test func errorStatusNonImageBodyAndOtherSchemesGiveNil() async throws {
        try await withTab { rig, tab in
            // A 404 whose body is a valid PNG: the status alone refuses it.
            let body = try fixture("wide.png")
            rig.server.route("/images/missing.png") { _ in
                FixtureServer.Response(status: 404, headers: ["Content-Type: image/png"], body: body)
            }
            let missing = await tab.loadImage(at: rig.url("/images/missing.png"), maxPixelSize: 32)
            report(missing == nil && rig.server.count(path: "/images/missing.png") == 1, "404", pixels(missing))

            let html = await tab.loadImage(at: rig.url("/navigation/b.html"), maxPixelSize: 32)
            report(html == nil && rig.server.count(path: "/navigation/b.html") == 1, "html", pixels(html))

            let file = try #require(Bundle.module.resourceURL).appendingPathComponent("Fixtures/images/wide.png")
            let local = await tab.loadImage(at: file, maxPixelSize: 32)
            report(local == nil, "fileScheme", pixels(local))
        }
    }

    @Test func closedTabGivesNilAndClosingCancelsTheFetch() async throws {
        try await withTab { rig, tab in
            // A fetch in flight when the tab closes ends with nil at once; the server never answers it.
            rig.server.route("/images/slow.png") { _ in FixtureServer.Response(status: 200, delay: .infinity) }
            var result: NSImage??
            let pending = Task {
                result = .some(await tab.loadImage(at: rig.url("/images/slow.png"), maxPixelSize: 32))
            }
            try await waitUntil("the server saw /images/slow.png") { rig.server.count(path: "/images/slow.png") == 1 }
            _ = await tab.close()
            // Waits on the fetch's own end, checked next; a fetch closing did not end is reported by the check.
            try? await waitUntil("the fetch ended") { result != nil }
            pending.cancel()
            let ended = result != nil
            let cancelled = result ?? nil
            report(
                ended && cancelled == nil && tab.imageFetches.isEmpty, "closing",
                ended ? pixels(cancelled) : "still fetching after the tab closed")

            // A closed tab fetches nothing.
            let closed = await tab.loadImage(at: rig.url("/images/wide.png"), maxPixelSize: 32)
            report(closed == nil && rig.server.count(path: "/images/wide.png") == 0, "closed", pixels(closed))
        }
    }

    @Test func sendsNoCookieAndStoresNone() async throws {
        try await withTab { rig, tab in
            let store = rig.profile.store
            let cookie = try #require(
                HTTPCookie(properties: [.domain: "127.0.0.1", .path: "/", .name: "probe", .value: "1"]))
            await store.httpCookieStore.setCookie(cookie)
            let body = try fixture("wide.png")
            rig.server.route("/images/cookie.png") { _ in
                FixtureServer.Response(
                    status: 200, headers: ["Content-Type: image/png", "Set-Cookie: fromImage=1; Path=/"], body: body)
            }

            // The profile's cookie reaches a page the tab loads, so the store holds it for this origin.
            let page = rig.url("/navigation/b.html")
            tab.load(page)
            try await rig.waitFor("finish \(page)")
            let pageCookie = rig.server.log().last { $0.path == "/navigation/b.html" }?.cookie ?? ""
            report(pageCookie.contains("probe=1"), "cookie.page", "page sent '\(pageCookie)'")

            // The image fetch sends none of it, and the cookie its answer sets is not stored.
            let image = await tab.loadImage(at: rig.url("/images/cookie.png"), maxPixelSize: 32)
            let request = rig.server.log().last { $0.path == "/images/cookie.png" }
            let names = await store.httpCookieStore.allCookies().map(\.name).sorted()
            let ok = image != nil && request != nil && request?.headers["cookie"] == nil && names == ["probe"]
            report(
                ok, "cookie.image", "image \(pixels(image)), sent '\(request?.cookie ?? "no request")', stored \(names)"
            )
        }
    }
}
