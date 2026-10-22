// Lists the app's child processes (Chromium's helpers) for the sandbox e2e test.
#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// One live child process of the app, read from the kernel.
@interface BowChildProcess : NSObject

@property(nonatomic, readonly) pid_t pid;
/// The process's command line arguments, including the executable path first.
@property(nonatomic, readonly, copy) NSArray<NSString *> *arguments;
/// Whether the kernel reports the process as confined by a sandbox (sandbox_check).
@property(nonatomic, readonly, getter=isSandboxed) BOOL sandboxed;

/// Every live child process of this process. A child that exits while it is being read is left out.
+ (NSArray<BowChildProcess *> *)childrenOfCurrentProcess;

@end

NS_ASSUME_NONNULL_END
