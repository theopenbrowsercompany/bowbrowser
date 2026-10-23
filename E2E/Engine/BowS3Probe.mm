#import "BowS3Probe.h"

#include "BowE2EHooks.h"

#include <libproc.h>
#include <mach/mach_time.h>
#include <sys/resource.h>

#include "include/cef_command_line.h"
#include "include/cef_task_manager.h"

namespace {

// rusage times are Mach absolute time units (not nanoseconds on Apple silicon); this converts them.
uint64_t MachToNanoseconds(uint64_t machTime) {
  static mach_timebase_info_data_t timebase = [] {
    mach_timebase_info_data_t info;
    mach_timebase_info(&info);
    return info;
  }();
  return machTime * timebase.numer / timebase.denom;
}

// Held between startTaskManager and stopTaskManager: Chromium's task manager refreshes its figures only while CEF's
// task manager object lives, so a reading from one made on the spot is all zeros.
CefRefPtr<CefTaskManager>& HeldTaskManager() {
  static CefRefPtr<CefTaskManager> manager;
  return manager;
}

CefRefPtr<CefBrowserHost> HostOf(uint64_t tabID) {
  CefRefPtr<CefBrowser> browser = BowEngineBrowserForTabID(tabID);
  return browser ? browser->GetHost() : nullptr;
}

}  // namespace

@implementation BowS3TaskSample

- (instancetype)initWithCPU:(double)cpu memory:(int64_t)memory gpuMemory:(int64_t)gpuMemory {
  if ((self = [super init])) {
    _cpuUsage = cpu;
    _memory = memory;
    _gpuMemory = gpuMemory;
  }
  return self;
}

@end

@implementation BowS3ProcessUsage

- (instancetype)initWithPid:(pid_t)pid usage:(const rusage_info_v4&)usage {
  if ((self = [super init])) {
    _pid = pid;
    _cpuNanoseconds = MachToNanoseconds(usage.ri_user_time + usage.ri_system_time);
    _packageIdleWakeups = usage.ri_pkg_idle_wkups;
    _interruptWakeups = usage.ri_interrupt_wkups;
    _billedEnergyNanojoules = usage.ri_billed_energy;
    _physicalFootprint = usage.ri_phys_footprint;
    _qosNanoseconds = @[
      @(MachToNanoseconds(usage.ri_cpu_time_qos_default)), @(MachToNanoseconds(usage.ri_cpu_time_qos_maintenance)),
      @(MachToNanoseconds(usage.ri_cpu_time_qos_background)), @(MachToNanoseconds(usage.ri_cpu_time_qos_utility)),
      @(MachToNanoseconds(usage.ri_cpu_time_qos_legacy)), @(MachToNanoseconds(usage.ri_cpu_time_qos_user_initiated)),
      @(MachToNanoseconds(usage.ri_cpu_time_qos_user_interactive))
    ];
  }
  return self;
}

@end

@implementation BowS3Probe

+ (BOOL)setWasHidden:(BOOL)hidden forTab:(uint64_t)tabID {
  CefRefPtr<CefBrowserHost> host = HostOf(tabID);
  if (!host) return NO;
  host->WasHidden(hidden);
  return YES;
}

+ (BOOL)setAudioMuted:(BOOL)muted forTab:(uint64_t)tabID {
  CefRefPtr<CefBrowserHost> host = HostOf(tabID);
  if (!host) return NO;
  host->SetAudioMuted(muted);
  return YES;
}

+ (BOOL)isAudioMutedForTab:(uint64_t)tabID {
  CefRefPtr<CefBrowserHost> host = HostOf(tabID);
  return host && host->IsAudioMuted();
}

+ (BOOL)setWindowlessFrameRate:(int)rate forTab:(uint64_t)tabID {
  CefRefPtr<CefBrowserHost> host = HostOf(tabID);
  if (!host) return NO;
  host->SetWindowlessFrameRate(rate);
  return YES;
}

+ (void)startTaskManager {
  if (!HeldTaskManager()) HeldTaskManager() = CefTaskManager::GetTaskManager();
}

+ (void)stopTaskManager {
  HeldTaskManager() = nullptr;
}

+ (BowS3TaskSample*)taskSampleForTab:(uint64_t)tabID {
  CefRefPtr<CefBrowser> browser = BowEngineBrowserForTabID(tabID);
  CefRefPtr<CefTaskManager> manager = HeldTaskManager();
  if (!browser || !manager) return nil;
  const int64_t task = manager->GetTaskIdForBrowserId(browser->GetIdentifier());
  if (task < 0) return nil;
  CefTaskInfo info;
  if (!manager->GetTaskInfo(task, info)) return nil;
  return [[BowS3TaskSample alloc] initWithCPU:info.cpu_usage memory:info.memory gpuMemory:info.gpu_memory];
}

+ (NSString*)switchValue:(NSString*)name {
  CefRefPtr<CefCommandLine> line = CefCommandLine::GetGlobalCommandLine();
  if (!line || !line->HasSwitch(name.UTF8String)) return nil;
  return [NSString stringWithUTF8String:line->GetSwitchValue(name.UTF8String).ToString().c_str()] ?: @"";
}

+ (BowS3ProcessUsage*)usageOfProcess:(pid_t)pid {
  rusage_info_v4 usage = {};
  if (proc_pid_rusage(pid, RUSAGE_INFO_V4, reinterpret_cast<rusage_info_t*>(&usage)) != 0) return nil;
  return [[BowS3ProcessUsage alloc] initWithPid:pid usage:usage];
}

@end
