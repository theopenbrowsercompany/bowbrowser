// What the opt-in hidden tab measurement (E2E/Tests/S3.swift) reads and changes in the engine, beyond what the app
// does: CEF calls on one tab's browser host, Chromium's task manager, the engine's switches and a process's resource
// usage from the kernel. Main thread only.
#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// One reading of Chromium's task manager for a tab's main task.
@interface BowS3TaskSample : NSObject
/// CPU use of the task's process, 0 to processors × 100.
@property(nonatomic, readonly) double cpuUsage;
/// Memory footprint in bytes, -1 when the task manager has no value yet.
@property(nonatomic, readonly) int64_t memory;
/// GPU memory in bytes, -1 when the task manager has no value yet.
@property(nonatomic, readonly) int64_t gpuMemory;
@end

/// A process's cumulative resource usage, read with proc_pid_rusage (RUSAGE_INFO_V4). Times are in nanoseconds.
@interface BowS3ProcessUsage : NSObject
@property(nonatomic, readonly) pid_t pid;
/// User plus system CPU time.
@property(nonatomic, readonly) uint64_t cpuNanoseconds;
@property(nonatomic, readonly) uint64_t packageIdleWakeups;
@property(nonatomic, readonly) uint64_t interruptWakeups;
/// Energy the kernel billed to the process, in nanojoules.
@property(nonatomic, readonly) uint64_t billedEnergyNanojoules;
@property(nonatomic, readonly) uint64_t physicalFootprint;
/// CPU time per quality of service class, in the order default, maintenance, background, utility, legacy,
/// user initiated, user interactive.
@property(nonatomic, readonly, copy) NSArray<NSNumber *> *qosNanoseconds;
@end

@interface BowS3Probe : NSObject

/// Calls WasHidden on the tab's browser host. Returns false when the tab has no browser.
+ (BOOL)setWasHidden:(BOOL)hidden forTab:(uint64_t)tabID;
/// Calls SetAudioMuted on the tab's browser host. Returns false when the tab has no browser.
+ (BOOL)setAudioMuted:(BOOL)muted forTab:(uint64_t)tabID;
/// Whether the tab's browser host reports its audio muted (false when the tab has no browser).
+ (BOOL)isAudioMutedForTab:(uint64_t)tabID;
/// Calls SetWindowlessFrameRate on the tab's browser host. Returns false when the tab has no browser.
+ (BOOL)setWindowlessFrameRate:(int)rate forTab:(uint64_t)tabID;
/// Keeps Chromium's task manager refreshing (about once a second) until `stopTaskManager`, which must come before the
/// engine shuts down.
+ (void)startTaskManager;
+ (void)stopTaskManager;
/// The task manager's reading for the tab's main task, nil before `startTaskManager`, when the tab has no browser or
/// the task manager no task for it.
+ (nullable BowS3TaskSample *)taskSampleForTab:(uint64_t)tabID;
/// The value of the engine switch `name` (without dashes) in the browser process's command line, "" for a switch
/// with no value, nil when it is absent.
+ (nullable NSString *)switchValue:(NSString *)name;
/// The process's usage now, nil when it is gone or cannot be read.
+ (nullable BowS3ProcessUsage *)usageOfProcess:(pid_t)pid;

@end

NS_ASSUME_NONNULL_END
