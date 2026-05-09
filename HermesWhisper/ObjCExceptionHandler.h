#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ObjCExceptionHandler : NSObject

+ (nullable id)catchException:(id _Nullable (^)(void))tryBlock error:(__autoreleasing NSError **)error;

@end

NS_ASSUME_NONNULL_END
