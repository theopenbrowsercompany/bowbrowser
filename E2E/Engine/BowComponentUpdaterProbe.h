// What the certs tests (E2E/Tests/Certs.swift) read from Chromium's component updater, the service that keeps the
// certificate revocation list (CRLSet), the Chrome Root Store and the Certificate Transparency log list current
// between engine updates. Read only, apart from asking for one update check. Main thread only (CEF's UI thread),
// except the stand-in update server, which any thread may use.
#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// One registered component as the updater reported it when it was read.
@interface BowE2EComponent : NSObject
@property(nonatomic, readonly, copy) NSString *componentID;
/// Empty until the component is installed.
@property(nonatomic, readonly, copy) NSString *name;
/// Empty until the component is installed.
@property(nonatomic, readonly, copy) NSString *version;
/// The updater's state, in lower case words (new, checking, up to date, update error, ...).
@property(nonatomic, readonly, copy) NSString *state;
@end

@interface BowComponentUpdaterProbe : NSObject

/// True when CEF hands out its component updater on this thread.
+ (BOOL)isAvailable;

/// Every component registered with the updater, in the updater's order. Empty when the updater is unavailable or
/// was turned off (`--disable-component-update`).
+ (NSArray<BowE2EComponent *> *)registeredComponents;

/// Asks the updater for an on demand, foreground update check of one component. `completion` runs once on the main
/// thread with the result in lower case words (none, update check error, service error, ...).
+ (void)checkForUpdateOf:(NSString *)componentID completion:(void (^)(NSString *result))completion;

@end

/// One request the stand-in update server received, as it arrived.
@interface BowE2EUpdateRequest : NSObject
@property(nonatomic, readonly, copy) NSString *method;
/// The request target: the path and query string.
@property(nonatomic, readonly, copy) NSString *target;
/// The Host header: the host the updater addressed before the host resolver rules sent it here.
@property(nonatomic, readonly, copy) NSString *host;
/// The request body as UTF-8 (the updater's JSON, which names each component by its app ID), as it arrived: a
/// chunked body keeps its chunk sizes.
@property(nonatomic, readonly, copy) NSString *body;
@end

/// A stand-in for the update server: a TLS listener on 127.0.0.1 that records every request and answers each with
/// 500, so an update check reaches it and fails there, and nothing leaves the machine. The certs test maps the
/// update host to it with Chromium's host resolver rules. It serves the loopback fixtures' self-signed identity, so
/// the engine must run with `ignore-certificate-errors` for a request to get past the handshake.
/// Each connection serves one request and closes; only loopback connections are accepted.
@interface BowE2EUpdateServer : NSObject

/// Starts the listener and waits until it listens (or failed), at most a few seconds. Returns nil and sets `error`
/// when it could not start (its identity needs macOS 15). Call from any thread.
+ (nullable instancetype)startWithError:(NSError **)error;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

/// The listener's port on 127.0.0.1.
@property(nonatomic, readonly) uint16_t port;

/// Every request received so far, oldest first. A request is recorded before its answer is sent.
@property(nonatomic, readonly, copy) NSArray<BowE2EUpdateRequest *> *requests;

/// Stops the listener and closes every open connection. Safe to call more than once; it also stops when released.
- (void)stop;

@end

NS_ASSUME_NONNULL_END
