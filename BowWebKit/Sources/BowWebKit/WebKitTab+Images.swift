import AppKit
import ImageIO
import WebKit

/// Loads an image for the tab (a site icon for the sidebar, an image for Copy Image), as CEF's `DownloadImage` with
/// `is_favicon` does on Chromium.
///
/// The image is fetched by the tab's own web view as a download, so it goes through the profile's own
/// `WKWebsiteDataStore` (its network session, proxy and cache) and never a shared `URLSession`. Like `DownloadImage`
/// with `is_favicon`, which CEF documents as sending no cookies and accepting none, the request sends none of the
/// profile's cookies and stores none the answer sets: an icon fetch is not a visit, so it neither identifies the
/// person to the site nor lets the site mark the profile.
extension WebKitTab {
    /// Loads the image at `url` (http, https or data) and returns it at most `maxPixelSize` pixels on a side, or nil
    /// when the tab is closed or closes meanwhile, the fetch fails or answers with an error status, the body is not
    /// an image ImageIO decodes, or the address has another scheme. Of a file with several images (an ICO), it takes
    /// the largest that fits, else the smallest scaled down, as Chromium does. Fetching and decoding never block the
    /// main actor; cancelling the calling task, or the tab releasing its page, cancels the fetch.
    func loadImage(at url: URL, maxPixelSize: Int) async -> NSImage? {
        guard !isClosed, let webView, maxPixelSize > 0 else { return nil }
        let body: ImageBody
        switch url.scheme?.lowercased() {
        case "http", "https":
            let fetch = ImageFetch(url: url)
            imageFetches.insert(fetch)
            defer { imageFetches.remove(fetch) }
            guard let file = await fetch.run(on: webView) else { return nil }
            body = .file(file)
        case "data":
            body = .dataURL(url)
        default:
            return nil
        }
        let decoded = await Task.detached(priority: .utility) { body.decode(maxPixelSize: maxPixelSize) }.value
        guard !isClosed, let image = decoded?.image else { return nil }
        // One bitmap of the decoded pixels, a point per pixel, as the CEF bridge hands its icons over.
        let bitmap = NSBitmapImageRep(cgImage: image)
        let result = NSImage(size: NSSize(width: image.width, height: image.height))
        result.addRepresentation(bitmap)
        return result
    }

    /// Cancels every image fetch in flight, each of which then returns nil. Called as the tab releases its page.
    func cancelImageFetches() {
        for fetch in imageFetches { fetch.cancel() }
    }
}

/// Where an image's bytes are: a fetched file (deleted once read) or a data address.
private enum ImageBody: Sendable {
    case file(URL)
    case dataURL(URL)

    /// Reads and decodes the image, off the main actor.
    func decode(maxPixelSize: Int) -> DecodedImage? {
        switch self {
        case .file(let file):
            defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
            guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }
            return ImageDecoding.image(from: data, maxPixelSize: maxPixelSize).map(DecodedImage.init)
        case .dataURL(let url):
            guard let data = try? Data(contentsOf: url) else { return nil }
            return ImageDecoding.image(from: data, maxPixelSize: maxPixelSize).map(DecodedImage.init)
        }
    }
}

/// A decoded image handed back from the decoding task; a `CGImage` is immutable.
private struct DecodedImage: @unchecked Sendable {
    let image: CGImage
}

/// Decodes image bytes with ImageIO.
enum ImageDecoding {
    /// The most pixels a frame may have to be decoded (16384 on a side, the most Copy Image asks for), so a small
    /// file that claims a huge image cannot take the memory to decode it.
    static let maxFramePixels = 16384 * 16384

    /// The image in `data`, at most `maxPixelSize` pixels on a side, its aspect kept; nil when `data` holds no
    /// image ImageIO decodes. Of several frames it takes the largest whose longer side fits, else the smallest,
    /// scaled down (Chromium's choice for `DownloadImage`); it never scales up.
    static func image(from data: Data, maxPixelSize: Int) -> CGImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard maxPixelSize > 0, let source = CGImageSourceCreateWithData(data as CFData, options) else { return nil }
        var fitting: (index: Int, side: Int)?
        var smallest: (index: Int, side: Int)?
        for index in 0..<CGImageSourceGetCount(source) {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, options) as? [CFString: Any],
                let width = properties[kCGImagePropertyPixelWidth] as? Int,
                let height = properties[kCGImagePropertyPixelHeight] as? Int,
                width > 0, height > 0, width * height <= maxFramePixels
            else { continue }
            let side = max(width, height)
            if side <= maxPixelSize, side > fitting?.side ?? 0 { fitting = (index, side) }
            if side < smallest?.side ?? .max { smallest = (index, side) }
        }
        guard let chosen = fitting ?? smallest else { return nil }
        let thumbnail =
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: min(maxPixelSize, chosen.side),
            ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, chosen.index, thumbnail)
    }
}

/// One image fetch: a download the tab's web view starts on the profile's store, into a folder of its own in the
/// temporary directory. It ends once, with the file or nil; cancelling it cancels the download and deletes the
/// folder.
@MainActor
final class ImageFetch: NSObject, WKDownloadDelegate {
    /// The largest body accepted; a longer one is cancelled as it arrives.
    nonisolated static let maxBytes: Int64 = 64 * 1024 * 1024

    private let url: URL
    private var download: WKDownload?
    private var continuation: CheckedContinuation<URL?, Never>?
    private var progress: NSKeyValueObservation?
    private var folder: URL?
    private var isFinished = false

    init(url: URL) {
        self.url = url
    }

    /// Fetches the image through `webView`'s store and returns the file it wrote, or nil. The calling task being
    /// cancelled cancels the fetch.
    func run(on webView: WKWebView) async -> URL? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !isFinished else { return continuation.resume(returning: nil) }
                self.continuation = continuation
                var request = URLRequest(url: url)
                // No cookies sent and none stored, as CEF's DownloadImage with is_favicon (see the extension).
                request.httpShouldHandleCookies = false
                webView.startDownload(using: request) { [weak self] download in
                    guard let self, !self.isFinished else { return download.cancel(nil) }
                    self.adopt(download)
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancel() }
        }
    }

    /// Cancels the download and ends the fetch with nil; does nothing once it ended.
    func cancel() {
        download?.cancel(nil)
        finish(nil)
    }

    private func adopt(_ download: WKDownload) {
        self.download = download
        download.delegate = self
        progress = download.progress.observe(\.completedUnitCount) { [weak self] progress, _ in
            let count = progress.completedUnitCount
            guard count > Self.maxBytes else { return }
            Task { @MainActor in self?.cancel() }
        }
    }

    /// Ends the fetch once: hands back `file` (nil for none), and on nil deletes the folder.
    private func finish(_ file: URL?) {
        guard !isFinished else { return }
        isFinished = true
        progress?.invalidate()
        progress = nil
        download = nil
        if file == nil, let folder { try? FileManager.default.removeItem(at: folder) }
        continuation?.resume(returning: file)
        continuation = nil
    }

    // MARK: WKDownloadDelegate

    /// Only a successful answer of a size within `maxBytes` is written, into a new folder of its own.
    func download(
        _ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String
    ) async -> URL? {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard !isFinished, (200..<300).contains(status), response.expectedContentLength <= Self.maxBytes else {
            finish(nil)
            return nil
        }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("BowImageFetches", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else {
            finish(nil)
            return nil
        }
        self.folder = folder
        return folder.appendingPathComponent("image")
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard !isFinished, let folder else { return removeFolder() }
        finish(folder.appendingPathComponent("image"))
    }

    /// A failed or cancelled download: ends the fetch with nil, and deletes whatever WebKit wrote after a cancel.
    func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
        finish(nil)
        removeFolder()
    }

    private func removeFolder() {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }
}
