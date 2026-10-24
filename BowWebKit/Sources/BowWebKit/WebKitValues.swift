import BowCore
import Foundation
import WebKit

// WebKit's values in Bow's terms. Nothing here switches over a BowCore enum, so a new BowCore case breaks no
// engine code.

/// WebKit's own error domain (`WKErrorDomain` is a different one, for script and process errors).
let webKitErrorDomain = "WebKitErrorDomain"

/// `WebKitErrorDomain` codes (WebKit's `WebKitErrors.h`).
enum WebKitErrorCode {
    static let cannotShowMIMEType = 100
    static let cannotShowURL = 101
    static let frameLoadInterruptedByPolicyChange = 102
    static let cannotUseRestrictedPort = 103
    static let frameLoadBlockedByContentBlocker = 104
    static let frameLoadBlockedByContentFilter = 105
    static let frameLoadBlockedByRestrictions = 106
    static let pluginWillHandleLoad = 204
}

extension NavigationError {
    /// A failed navigation from the error WebKit handed its navigation delegate.
    init(_ error: any Error) {
        let error = error as NSError
        self.init(reason: Self.reason(domain: error.domain, code: error.code), description: error.localizedDescription)
    }

    /// Bow's reason for a WebKit or URL loading error.
    static func reason(domain: String, code: Int) -> Reason {
        switch domain {
        case NSURLErrorDomain:
            switch code {
            case NSURLErrorCancelled: .aborted
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: .nameNotResolved
            case NSURLErrorCannotConnectToHost: .cannotConnect
            case NSURLErrorNetworkConnectionLost: .connectionLost
            case NSURLErrorTimedOut: .timedOut
            case NSURLErrorNotConnectedToInternet, NSURLErrorInternationalRoamingOff, NSURLErrorDataNotAllowed:
                .offline
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasBadDate,
                NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot,
                NSURLErrorServerCertificateNotYetValid, NSURLErrorClientCertificateRejected,
                NSURLErrorClientCertificateRequired:
                .certificate
            case NSURLErrorBadURL, NSURLErrorUnsupportedURL: .badAddress
            case NSURLErrorAppTransportSecurityRequiresSecureConnection: .blocked
            default: .other
            }
        case webKitErrorDomain:
            switch code {
            // A redirect the policy cancelled, a response turned into a download or no page at all: the
            // navigation ended without failing to load.
            case WebKitErrorCode.frameLoadInterruptedByPolicyChange, WebKitErrorCode.pluginWillHandleLoad,
                WebKitErrorCode.cannotShowMIMEType:
                .aborted
            case WebKitErrorCode.cannotShowURL: .badAddress
            case WebKitErrorCode.cannotUseRestrictedPort, WebKitErrorCode.frameLoadBlockedByContentBlocker,
                WebKitErrorCode.frameLoadBlockedByContentFilter, WebKitErrorCode.frameLoadBlockedByRestrictions:
                .blocked
            default: .other
            }
        default:
            .other
        }
    }

    /// The navigation ended without loading a page because Bow ended it: stopped, replaced or closed.
    static let abortedByBow = NavigationError(reason: .aborted, description: "The navigation was aborted.")
}

extension NavigationTransition {
    /// Why a navigation started, from WebKit's navigation type. A navigation WebKit calls `other` that the app
    /// started with `EngineTab.load` is `typed`; any other `other` (a script navigation, a client redirect) stays
    /// `other`, since WebKit does not tell a script navigation from the rest (inference).
    init(_ type: WKNavigationType, isAppLoad: Bool) {
        switch type {
        case .linkActivated: self = .link
        case .formSubmitted, .formResubmitted: self = .formSubmit
        case .backForward: self = .backForward
        case .reload: self = .reload
        case .other: self = isAppLoad ? .typed : .other
        @unknown default: self = .other
        }
    }
}
