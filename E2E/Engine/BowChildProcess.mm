#import "BowChildProcess.h"

#include <libproc.h>
#include <sys/sysctl.h>
#include <unistd.h>

#include <vector>

// In libSystem without a public header. With no operation and filter type 0 (none) it reads no further
// arguments; it returns 0 for an unconfined process, -1 when it cannot tell (the process is gone), and
// nonzero otherwise.
extern "C" int sandbox_check(pid_t pid, const char* operation, int type, ...);

namespace {

// Reads a process's arguments from KERN_PROCARGS2: argc, the executable path, padding, then argc strings.
// Returns nil when the process is gone or its arguments cannot be read.
NSArray<NSString*>* ArgumentsOf(pid_t pid) {
  int mib[3] = {CTL_KERN, KERN_PROCARGS2, pid};
  size_t size = 0;
  if (sysctl(mib, 3, nullptr, &size, nullptr, 0) != 0 || size < sizeof(int)) return nil;
  std::vector<char> buffer(size);
  if (sysctl(mib, 3, buffer.data(), &size, nullptr, 0) != 0 || size < sizeof(int)) return nil;

  int argc = 0;
  memcpy(&argc, buffer.data(), sizeof(argc));
  const char* cursor = buffer.data() + sizeof(argc);
  const char* end = buffer.data() + size;
  // Skip the executable path and the NUL padding after it. An empty argv[0] would be skipped too; Chromium
  // starts every helper with its executable path there.
  while (cursor < end && *cursor != '\0') cursor++;
  while (cursor < end && *cursor == '\0') cursor++;

  NSMutableArray<NSString*>* arguments = [NSMutableArray arrayWithCapacity:argc];
  for (int i = 0; i < argc && cursor < end; i++) {
    size_t length = strnlen(cursor, end - cursor);
    NSString* argument = [[NSString alloc] initWithBytes:cursor length:length encoding:NSUTF8StringEncoding];
    [arguments addObject:argument ?: @""];
    cursor += length + 1;
  }
  return arguments;
}

}  // namespace

@implementation BowChildProcess

- (instancetype)initWithPid:(pid_t)pid arguments:(NSArray<NSString*>*)arguments sandboxed:(BOOL)sandboxed {
  if ((self = [super init])) {
    _pid = pid;
    _arguments = [arguments copy];
    _sandboxed = sandboxed;
  }
  return self;
}

+ (NSArray<BowChildProcess*>*)childrenOfCurrentProcess {
  // Room for many more helpers than Chromium starts; the count is re-read if they ever fill it.
  std::vector<pid_t> pids(256);
  int count = 0;
  for (;;) {
    count = proc_listchildpids(getpid(), pids.data(), (int)(pids.size() * sizeof(pid_t)));
    if (count < 0) return @[];
    if ((size_t)count < pids.size()) break;
    pids.resize(pids.size() * 2);
  }

  NSMutableArray<BowChildProcess*>* children = [NSMutableArray array];
  for (int i = 0; i < count; i++) {
    pid_t pid = pids[i];
    NSArray<NSString*>* arguments = ArgumentsOf(pid);
    if (!arguments) continue;
    int sandbox = sandbox_check(pid, nullptr, 0);
    if (sandbox == -1) continue;
    [children addObject:[[BowChildProcess alloc] initWithPid:pid arguments:arguments sandboxed:sandbox != 0]];
  }
  return children;
}

@end
