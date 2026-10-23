// The loopback fixtures' TLS identity, for other loopback listeners in E2E/Engine. Objective-C only; never import
// it from Swift.
#pragma once

#import <Foundation/Foundation.h>
#import <Network/Network.h>

/// The self-signed fixture identity the certificate listener serves (for badcert.bow.test, trusted by nothing),
/// imported into process memory only, never into a keychain. Nil with `error` set before macOS 15, which that needs.
sec_identity_t _Nullable BowLoopbackFixtureIdentity(NSError* _Nullable* _Nullable error);
