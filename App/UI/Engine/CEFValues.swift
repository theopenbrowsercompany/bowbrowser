import AppKit
import BowCore

// The BowCore values of the bridge's values. The bridge mirrors them one to one.

extension EngineTabState {
    init(_ state: BowTabState) {
        self.init(
            tabID: TabID(rawValue: state.tabID),
            url: state.url,
            title: state.title,
            faviconURL: state.faviconURL,
            isLoading: state.isLoading,
            canGoBack: state.canGoBack,
            canGoForward: state.canGoForward,
            isAudible: state.isAudible,
            isCapturingVideo: state.isCapturingVideo,
            isCapturingAudio: state.isCapturingAudio,
            hasEditedForm: state.hasEditedForm
        )
    }
}

extension EngineNavigation {
    init(_ navigation: BowNavigation) {
        let transition: NavigationTransition =
            switch navigation.transition {
            case .link: .link
            case .typed: .typed
            case .formSubmit: .formSubmit
            case .reload: .reload
            case .backForward: .backForward
            case .other: .other
            }
        self.init(
            url: navigation.url, transition: transition, isUserGesture: navigation.isUserGesture,
            isRedirect: navigation.isRedirect)
    }
}

extension PopupRequest {
    init(_ request: BowPopupRequest) {
        let disposition: PopupDisposition =
            switch request.disposition {
            case .foregroundTab: .foregroundTab
            case .backgroundTab: .backgroundTab
            case .popup: .popup
            case .window: .window
            }
        self.init(
            targetURL: request.targetURL,
            disposition: disposition,
            isUserGesture: request.isUserGesture,
            requestedSize: request.requestedSize.map { PopupSize(width: $0.width, height: $0.height) },
            windowFeatures: PopupWindowFeatures(
                x: request.windowFeatures.x?.intValue,
                y: request.windowFeatures.y?.intValue,
                width: request.windowFeatures.width?.intValue,
                height: request.windowFeatures.height?.intValue,
                isPopup: request.windowFeatures.isPopup
            ),
            clickModifiers: PopupClickModifiers(
                command: request.clickModifiers.contains(.command),
                shift: request.clickModifiers.contains(.shift)
            )
        )
    }
}

extension BowPopupRequest.Decision {
    init(_ decision: PopupDecision) {
        self =
            switch decision {
            case .foregroundTab: .foregroundTab
            case .backgroundTab: .backgroundTab
            // The engine creates a panel's page as it does a tab's, and the app shows it in the panel.
            case .popupPanel: .foregroundTab
            // A Peek's page too: the app shows it in the Peek card.
            case .peek: .foregroundTab
            case .window: .window
            case .block: .block
            }
    }
}

extension EngineKeyEvent {
    init(_ event: BowKeyEvent) {
        let kind: Kind =
            switch event.kind {
            case .keyDown: .keyDown
            case .keyUp: .keyUp
            case .character: .character
            }
        var modifiers: KeyModifiers = []
        if event.modifiers.contains(.shift) { modifiers.insert(.shift) }
        if event.modifiers.contains(.control) { modifiers.insert(.control) }
        if event.modifiers.contains(.option) { modifiers.insert(.option) }
        if event.modifiers.contains(.command) { modifiers.insert(.command) }
        self.init(
            kind: kind,
            keyCode: event.keyCode,
            characters: event.characters,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifiers: modifiers,
            isInEditableField: event.isInEditableField
        )
    }
}

extension AuthChallenge {
    init(_ challenge: BowAuthChallenge) {
        self.init(
            url: challenge.url,
            host: challenge.host,
            port: challenge.port,
            realm: challenge.realm,
            scheme: challenge.scheme,
            isProxy: challenge.fromProxy
        )
    }
}

extension CertificateError {
    init(_ error: BowCertificateError) {
        self.init(url: error.url, reason: Reason(chromiumCode: error.code))
    }
}

extension CertificateError.Reason {
    /// The reason for one of Chromium's certificate error codes (`net/base/net_error_list.h`).
    init(chromiumCode code: Int) {
        self =
            switch code {
            case -200: .nameMismatch  // ERR_CERT_COMMON_NAME_INVALID
            case -201: .dateInvalid  // ERR_CERT_DATE_INVALID
            case -202: .untrustedAuthority  // ERR_CERT_AUTHORITY_INVALID
            case -203: .containsErrors  // ERR_CERT_CONTAINS_ERRORS
            case -204: .noRevocationMechanism  // ERR_CERT_NO_REVOCATION_MECHANISM
            case -205: .unableToCheckRevocation  // ERR_CERT_UNABLE_TO_CHECK_REVOCATION
            case -206: .revoked  // ERR_CERT_REVOKED
            case -207: .invalid  // ERR_CERT_INVALID
            case -208: .weakSignature  // ERR_CERT_WEAK_SIGNATURE_ALGORITHM
            case -210: .nonUniqueName  // ERR_CERT_NON_UNIQUE_NAME
            case -211: .weakKey  // ERR_CERT_WEAK_KEY
            case -212: .nameConstraintViolation  // ERR_CERT_NAME_CONSTRAINT_VIOLATION
            case -213: .validityTooLong  // ERR_CERT_VALIDITY_TOO_LONG
            case -214: .notPubliclyLogged  // ERR_CERTIFICATE_TRANSPARENCY_REQUIRED
            case -217: .distrustedAuthority  // ERR_CERT_SYMANTEC_LEGACY
            case -219: .selfSignedLocalNetwork  // ERR_CERT_SELF_SIGNED_LOCAL_NETWORK
            default: .other
            }
    }
}

extension NavigationError {
    init(_ error: BowNavigationError) {
        self.init(reason: Reason(chromiumCode: error.code), description: error.errorText)
    }
}

extension NavigationError.Reason {
    /// The reason for one of Chromium's network error codes (`net/base/net_error_list.h`).
    init(chromiumCode code: Int) {
        self =
            switch code {
            case -3: .aborted  // ERR_ABORTED
            case -105, -137: .nameNotResolved  // ERR_NAME_NOT_RESOLVED, ERR_NAME_RESOLUTION_FAILED
            // ERR_CONNECTION_REFUSED, ERR_CONNECTION_FAILED, ERR_ADDRESS_INVALID, ERR_ADDRESS_UNREACHABLE
            case -102, -104, -108, -109: .cannotConnect
            // ERR_CONNECTION_CLOSED, ERR_CONNECTION_RESET, ERR_CONNECTION_ABORTED, ERR_EMPTY_RESPONSE
            case -100, -101, -103, -324: .connectionLost
            case -7, -118: .timedOut  // ERR_TIMED_OUT, ERR_CONNECTION_TIMED_OUT
            case -106: .offline  // ERR_INTERNET_DISCONNECTED
            case -299 ... -200: .certificate  // the ERR_CERT_* range
            case -300, -301, -302: .badAddress  // ERR_INVALID_URL, ERR_DISALLOWED_URL_SCHEME, ERR_UNKNOWN_URL_SCHEME
            // ERR_BLOCKED_BY_CLIENT, ERR_BLOCKED_BY_ADMINISTRATOR, ERR_BLOCKED_BY_RESPONSE
            case -20, -22, -27: .blocked
            default: .other
            }
    }
}

// The bridge's permission kinds are an option set; BowCore's are a set of cases with the same names.
private let permissionKinds: [(BowPermissionRequest.Kind, PermissionKind)] = [
    (.camera, .camera),
    (.microphone, .microphone),
    (.screenCapture, .screenCapture),
    (.geolocation, .geolocation),
    (.notifications, .notifications),
    (.clipboard, .clipboard),
    (.midiSysex, .midiSysex),
    (.storageAccess, .storageAccess),
    (.windowManagement, .windowManagement),
    (.localFonts, .localFonts),
    (.other, .other),
]

extension Set where Element == PermissionKind {
    init(_ kinds: BowPermissionRequest.Kind) {
        self.init(permissionKinds.filter { kinds.contains($0.0) }.map(\.1))
    }
}

extension BowPermissionRequest.Kind {
    init(_ kinds: Set<PermissionKind>) {
        self = []
        for (bridgeKind, kind) in permissionKinds where kinds.contains(kind) { insert(bridgeKind) }
    }
}

extension ProcessGoneReason {
    init(_ reason: BowProcessGoneReason) {
        self =
            switch reason {
            case .crashed: .crashed
            case .killed: .killed
            case .outOfMemory: .outOfMemory
            case .launchFailed: .launchFailed
            case .other: .other
            }
    }
}
