#import "MUIScreenCandidate.h"

@implementation MUIScreenCandidate

- (instancetype)init {
    self = [super init];
    if (self) {
        _identifier = @"";
        _displayName = @"Icon";
        _frameInRoot = CGRectZero;
    }
    return self;
}

@end
