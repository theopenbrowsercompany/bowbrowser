// What the loopback fixtures share with other loopback listeners in E2E/Engine (the certs test's stand-in update
// server). Objective-C only; never import it from Swift.
#pragma once

#import <Foundation/Foundation.h>
#import <Network/Network.h>

/// The self-signed fixture identity the certificate listener serves (for badcert.bow.test, trusted by nothing),
/// imported into process memory only, never into a keychain. Nil with `error` set before macOS 15, which that needs.
sec_identity_t _Nullable BowLoopbackFixtureIdentity(NSError* _Nullable* _Nullable error);

/// Binds `parameters` to 127.0.0.1 on a port the system picks, loopback only.
void BowLoopbackBind(nw_parameters_t _Nonnull parameters);

/// The value of the request head's header `name` (compared ignoring case), or nil.
NSString* _Nullable BowLoopbackHeaderValue(NSString* _Nonnull head, NSString* _Nonnull name);

/// Why a listener or connection failed, in words.
NSString* _Nonnull BowLoopbackDescribe(nw_error_t _Nullable error);
