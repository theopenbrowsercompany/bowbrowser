import AppKit
import BowCore

// Questions a load asks before it can go on: HTTP sign in and certificate errors.

extension CEFTab {
    func tab(
        _ tab: BowTab,
        answer challenge: BowAuthChallenge,
        completionHandler: @escaping (String?, String?) -> Void
    ) {
        let challenge = AuthChallenge(challenge)
        Task { @MainActor [weak self] in
            var credentials: AuthCredentials?
            if let self, let delegate = self.delegate {
                credentials = await delegate.tab(self, answer: challenge)
            }
            completionHandler(credentials?.user, credentials?.password)
        }
    }

    func tab(
        _ tab: BowTab,
        decideCertificateError error: BowCertificateError,
        decisionHandler: @escaping (Bool) -> Void
    ) {
        let error = CertificateError(error)
        Task { @MainActor [weak self] in
            var decision = CertificateErrorDecision.cancel
            if let self, let delegate = self.delegate {
                decision = await delegate.tab(self, decideCertificateError: error)
            }
            decisionHandler(decision == .proceed)
        }
    }
}
