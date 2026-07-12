#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^HWSystemAudioTapSamplesHandler)(
  NSData *samples,
  double sampleRate,
  double hostTime
);

/// Captures outgoing process audio before it reaches the selected output device.
///
/// An empty process list creates a global tap that excludes HermesWhisper. A non-empty
/// list captures only those process identifiers.
@interface HWSystemAudioTapCapture : NSObject

@property(nonatomic, copy, nullable) HWSystemAudioTapSamplesHandler samplesHandler;

- (BOOL)startWithProcessIDs:(NSArray<NSNumber *> *)processIDs
                      error:(NSError **)error;
- (void)stop;

@end

NS_ASSUME_NONNULL_END
