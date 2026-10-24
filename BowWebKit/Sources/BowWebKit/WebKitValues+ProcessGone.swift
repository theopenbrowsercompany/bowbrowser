import BowCore

extension ProcessGoneReason {
    /// The contract's reason for WebKit's termination reason; nil (a raw value Bow does not know, or WebKit gave
    /// no reason because only its public callback is there) is `.other`.
    init(_ reason: SPIProcessTerminationReason?) {
        switch reason {
        case .exceededMemoryLimit: self = .outOfMemory
        case .exceededCPULimit: self = .exceededCPULimit
        case .requestedByClient: self = .requestedByApp
        case .crash: self = .crashed
        case nil: self = .other
        }
    }
}
