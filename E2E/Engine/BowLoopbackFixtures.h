// Real sockets on 127.0.0.1 for the e2e fixtures the in-process bow.test server cannot give: Chromium asks the app
// for a user name and password only for answers that came over the network, and certificate errors need TLS.
// Swift sees this header.
#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Two listeners on free loopback ports, started for one e2e run and stopped at its end. The runner maps host names
/// to them with Chromium's host resolver rules, so tests load `http://auth.bow.test/` and `https://badcert.bow.test/`.
///
/// - The sign in listener speaks plain HTTP. Every path but `/favicon.ico` (404) answers 401 with `WWW-Authenticate: Basic realm="bow"`
///   until a request carries the Basic credentials `authUser` and `authPassword`, which get a 200 page titled
///   "Signed in". A path under `/realm/<name>/` (letters and digits) names the realm `<name>` instead, so each test
///   can sign in to a realm the engine has no remembered credentials for. (Plain HTTP, since over TLS the self-signed certificate would fail first.)
/// - The certificate listener speaks TLS with a self-signed certificate for `badcert.bow.test`, which no keychain
///   trusts, so loading it is a certificate error (ERR_CERT_AUTHORITY_INVALID). A load that goes on anyway gets a
///   200 page titled "Bad certificate". The identity lives in process memory only: it is never added to a keychain.
///
/// Each connection serves one request and closes. Both listeners accept loopback connections only.
@interface BowLoopbackFixtures : NSObject

/// The user name and password the sign in listener accepts.
@property(class, nonatomic, readonly, copy) NSString *authUser;
@property(class, nonatomic, readonly, copy) NSString *authPassword;

/// Starts both listeners and waits until they listen (or failed), at most a few seconds each. Returns nil and sets
/// `error` when the sign in listener could not start; nothing is left listening then. The certificate listener is
/// optional: when it cannot start (its identity needs macOS 15 to stay out of keychains), `certificateFailure` says
/// why and the sign in listener still serves. Call from any thread: the listeners' work runs on a queue of their
/// own, so waiting on the main thread is safe.
+ (nullable instancetype)startWithError:(NSError **)error;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

/// The sign in listener's port on 127.0.0.1.
@property(nonatomic, readonly) uint16_t authPort;
/// The certificate listener's port on 127.0.0.1, or 0 when it did not start.
@property(nonatomic, readonly) uint16_t certificatePort;
/// Why the certificate listener did not start, or nil when it runs.
@property(nonatomic, readonly, copy, nullable) NSString *certificateFailure;

/// Requests the sign in listener answered with 401, and with 200 (they carried the right credentials).
@property(nonatomic, readonly) NSInteger unauthorizedRequests;
@property(nonatomic, readonly) NSInteger authorizedRequests;
/// Requests the certificate listener answered, which only a load that went on past the certificate error makes.
@property(nonatomic, readonly) NSInteger certificateRequests;

/// Stops both listeners, closes every open connection and waits until they are gone, at most a few seconds.
/// Safe to call more than once; the listeners also stop when the object is released.
- (void)stop;

@end

NS_ASSUME_NONNULL_END
