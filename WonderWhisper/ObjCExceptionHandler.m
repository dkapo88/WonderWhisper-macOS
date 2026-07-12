#import "ObjCExceptionHandler.h"

@implementation ObjCExceptionHandler

+ (nullable id)catchException:(id _Nullable (^)(void))tryBlock error:(__autoreleasing NSError **)error {
    @try {
        return tryBlock();
    }
    @catch (NSException *exception) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:@"ObjCExceptionHandler"
                                         code:0
                                     userInfo:@{NSLocalizedDescriptionKey: exception.reason ?: @"Unknown exception"}];
        }
        return nil;
    }
}

@end
