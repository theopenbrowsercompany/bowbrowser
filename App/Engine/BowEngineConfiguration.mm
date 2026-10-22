#import "BowEngineConfiguration.h"

@implementation BowEngineConfiguration

- (instancetype)initWithRootDataDirectory:(NSString*)rootDataDirectory {
  self = [super init];
  if (self) {
    _rootDataDirectory = [rootDataDirectory copy];
    _extraSwitches = @{};
  }
  return self;
}

@end
