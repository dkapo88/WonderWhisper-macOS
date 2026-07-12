#import "CoreAudioSystemTapCapture.h"

#import <CoreAudio/CoreAudio.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#import <CoreAudio/HostTime.h>
#import <atomic>
#import <vector>

namespace {

NSString *const HWSystemAudioTapErrorDomain = @"com.wonderwhisper.system-audio-tap";

AudioObjectPropertyAddress PropertyAddress(AudioObjectPropertySelector selector) {
  return {
    selector,
    kAudioObjectPropertyScopeGlobal,
    kAudioObjectPropertyElementMain
  };
}

NSError *StatusError(OSStatus status, NSString *operation) {
  UInt32 bigEndianStatus = CFSwapInt32HostToBig(static_cast<UInt32>(status));
  char statusText[5] = {};
  memcpy(statusText, &bigEndianStatus, 4);
  NSString *readableStatus = [NSString stringWithUTF8String:statusText];
  NSString *message = nil;
  if (readableStatus != nil && [readableStatus rangeOfCharacterFromSet:
      NSCharacterSet.alphanumericCharacterSet.invertedSet].location == NSNotFound) {
    message = [NSString stringWithFormat:@"%@ failed (%@).", operation, readableStatus];
  } else {
    message = [NSString stringWithFormat:@"%@ failed (%d).", operation, status];
  }
  return [NSError errorWithDomain:HWSystemAudioTapErrorDomain
                             code:status
                         userInfo:@{NSLocalizedDescriptionKey: message}];
}

AudioObjectID ProcessObjectID(pid_t pid) {
  AudioObjectPropertyAddress address =
    PropertyAddress(kAudioHardwarePropertyTranslatePIDToProcessObject);
  AudioObjectID processObject = kAudioObjectUnknown;
  UInt32 outputSize = sizeof(processObject);
  AudioObjectGetPropertyData(
    kAudioObjectSystemObject,
    &address,
    sizeof(pid),
    &pid,
    &outputSize,
    &processObject
  );
  return processObject;
}

bool AggregateHasInputStream(AudioObjectID aggregateDeviceID) {
  AudioObjectPropertyAddress streamsAddress =
    PropertyAddress(kAudioDevicePropertyStreams);
  UInt32 streamsSize = 0;
  OSStatus status = AudioObjectGetPropertyDataSize(
    aggregateDeviceID,
    &streamsAddress,
    0,
    nullptr,
    &streamsSize
  );
  if (status != kAudioHardwareNoError || streamsSize < sizeof(AudioObjectID)) {
    return false;
  }

  std::vector<AudioObjectID> streams(streamsSize / sizeof(AudioObjectID));
  status = AudioObjectGetPropertyData(
    aggregateDeviceID,
    &streamsAddress,
    0,
    nullptr,
    &streamsSize,
    streams.data()
  );
  if (status != kAudioHardwareNoError) {
    return false;
  }

  for (AudioObjectID streamID : streams) {
    AudioObjectPropertyAddress directionAddress =
      PropertyAddress(kAudioStreamPropertyDirection);
    UInt32 direction = 0;
    UInt32 directionSize = sizeof(direction);
    status = AudioObjectGetPropertyData(
      streamID,
      &directionAddress,
      0,
      nullptr,
      &directionSize,
      &direction
    );
    if (status == kAudioHardwareNoError && direction != 0) {
      return true;
    }
  }
  return false;
}

bool WaitForAggregateInputStream(AudioObjectID aggregateDeviceID) {
  for (int attempt = 0; attempt < 100; ++attempt) {
    if (AggregateHasInputStream(aggregateDeviceID)) {
      return true;
    }
    usleep(10'000);
  }
  return false;
}

}  // namespace

@interface HWSystemAudioTapCapture () {
  AudioObjectID _tapID;
  AudioObjectID _aggregateDeviceID;
  AudioDeviceIOProcID _ioProcID;
  std::atomic<double> _tapSampleRate;
  AudioObjectPropertyListenerBlock _tapFormatListener;
  dispatch_queue_t _deliveryQueue;
  std::vector<Float32> _monoBuffer;
}

- (OSStatus)refreshTapFormat;
- (OSStatus)handleInputData:(const AudioBufferList *)inputData
                  inputTime:(const AudioTimeStamp *)inputTime;
- (BOOL)startWithProcessIDs:(NSArray<NSNumber *> *)processIDs
          remainingAttempts:(NSUInteger)remainingAttempts
                      error:(NSError **)error;

@end

static OSStatus SystemAudioIOProc(
  AudioObjectID,
  const AudioTimeStamp *,
  const AudioBufferList *inputData,
  const AudioTimeStamp *inputTime,
  AudioBufferList *,
  const AudioTimeStamp *,
  void *clientData
) noexcept {
  HWSystemAudioTapCapture *capture = (__bridge HWSystemAudioTapCapture *)clientData;
  return [capture handleInputData:inputData inputTime:inputTime];
}

@implementation HWSystemAudioTapCapture

- (instancetype)init {
  self = [super init];
  if (self != nil) {
    _tapID = kAudioObjectUnknown;
    _aggregateDeviceID = kAudioObjectUnknown;
    _ioProcID = nullptr;
    _tapSampleRate.store(0, std::memory_order_relaxed);
    _tapFormatListener = nil;
    _deliveryQueue = dispatch_queue_create(
      "com.wonderwhisper.meeting.system-tap-delivery",
      DISPATCH_QUEUE_SERIAL
    );
  }
  return self;
}

- (void)dealloc {
  [self stop];
}

- (BOOL)startWithProcessIDs:(NSArray<NSNumber *> *)processIDs
                      error:(NSError **)error {
  return [self startWithProcessIDs:processIDs remainingAttempts:3 error:error];
}

- (BOOL)startWithProcessIDs:(NSArray<NSNumber *> *)processIDs
          remainingAttempts:(NSUInteger)remainingAttempts
                      error:(NSError **)error {
  [self stop];

  NSMutableArray<NSNumber *> *processObjects = [NSMutableArray array];
  for (NSNumber *processID in processIDs) {
    AudioObjectID objectID = ProcessObjectID(processID.intValue);
    if (objectID != kAudioObjectUnknown) {
      [processObjects addObject:@(objectID)];
    }
  }

  CATapDescription *description = [[CATapDescription alloc] init];
  description.name = @"WonderWhisper meeting system audio";
  description.privateTap = YES;
  description.muteBehavior = CATapUnmuted;
  description.mixdown = YES;
  description.mono = YES;
  if (processIDs.count == 0) {
    AudioObjectID ownProcessObject = ProcessObjectID(getpid());
    if (ownProcessObject != kAudioObjectUnknown) {
      [processObjects addObject:@(ownProcessObject)];
    }
    description.exclusive = YES;
  } else {
    if (processObjects.count == 0) {
      if (error != nullptr) {
        *error = [NSError errorWithDomain:HWSystemAudioTapErrorDomain
                                     code:-1
                                 userInfo:@{
          NSLocalizedDescriptionKey:
            @"The meeting application is not producing a Core Audio process yet."
        }];
      }
      return NO;
    }
    description.exclusive = NO;
  }
  description.processes = processObjects;

  OSStatus status = AudioHardwareCreateProcessTap(description, &_tapID);
  if (status != kAudioHardwareNoError) {
    if (error != nullptr) {
      *error = StatusError(status, @"Creating the system audio tap");
    }
    [self stop];
    return NO;
  }

  status = [self refreshTapFormat];
  if (status != kAudioHardwareNoError) {
    if (error != nullptr) {
      *error = StatusError(status, @"Reading the system audio tap format");
    }
    [self stop];
    return NO;
  }

  AudioObjectPropertyAddress formatAddress = PropertyAddress(kAudioTapPropertyFormat);
  __weak HWSystemAudioTapCapture *weakSelf = self;
  _tapFormatListener = ^(
    UInt32,
    const AudioObjectPropertyAddress *
  ) {
    HWSystemAudioTapCapture *strongSelf = weakSelf;
    if (strongSelf != nil) {
      [strongSelf refreshTapFormat];
    }
  };
  status = AudioObjectAddPropertyListenerBlock(
    _tapID,
    &formatAddress,
    _deliveryQueue,
    _tapFormatListener
  );
  if (status != kAudioHardwareNoError) {
    if (error != nullptr) {
      *error = StatusError(status, @"Monitoring the system audio tap format");
    }
    [self stop];
    return NO;
  }

  AudioObjectPropertyAddress uidAddress = PropertyAddress(kAudioTapPropertyUID);
  UInt32 uidSize = sizeof(CFStringRef);
  CFStringRef tapUID = nullptr;
  status = AudioObjectGetPropertyData(
    _tapID,
    &uidAddress,
    0,
    nullptr,
    &uidSize,
    &tapUID
  );
  if (status != kAudioHardwareNoError || tapUID == nullptr) {
    if (error != nullptr) {
      *error = StatusError(status, @"Reading the system audio tap identifier");
    }
    [self stop];
    return NO;
  }

  NSString *aggregateUID = NSUUID.UUID.UUIDString;
  NSDictionary *aggregateDescription = @{
    @kAudioAggregateDeviceNameKey: @"WonderWhisper meeting audio",
    @kAudioAggregateDeviceUIDKey: aggregateUID,
    @kAudioAggregateDeviceIsPrivateKey: @YES
  };
  status = AudioHardwareCreateAggregateDevice(
    (__bridge CFDictionaryRef)aggregateDescription,
    &_aggregateDeviceID
  );
  if (status != kAudioHardwareNoError) {
    CFRelease(tapUID);
    if (error != nullptr) {
      *error = StatusError(status, @"Creating the system audio input device");
    }
    [self stop];
    return NO;
  }

  AudioObjectPropertyAddress tapListAddress =
    PropertyAddress(kAudioAggregateDevicePropertyTapList);
  CFArrayRef tapList = (__bridge CFArrayRef)@[(__bridge NSString *)tapUID];
  UInt32 tapListSize = sizeof(tapList);
  status = AudioObjectSetPropertyData(
    _aggregateDeviceID,
    &tapListAddress,
    0,
    nullptr,
    tapListSize,
    &tapList
  );
  CFRelease(tapUID);
  if (status != kAudioHardwareNoError) {
    if (error != nullptr) {
      *error = StatusError(status, @"Connecting the system audio tap");
    }
    [self stop];
    return NO;
  }

  if (!WaitForAggregateInputStream(_aggregateDeviceID)) {
    NSError *readinessError = [NSError errorWithDomain:HWSystemAudioTapErrorDomain
                                                   code:-2
                                               userInfo:@{
      NSLocalizedDescriptionKey:
        @"The system audio input device did not become ready."
    }];
    [self stop];
    if (remainingAttempts > 1) {
      usleep(100'000);
      return [self startWithProcessIDs:processIDs
                     remainingAttempts:remainingAttempts - 1
                                 error:error];
    }
    if (error != nullptr) {
      *error = readinessError;
    }
    return NO;
  }

  status = AudioDeviceCreateIOProcID(
    _aggregateDeviceID,
    SystemAudioIOProc,
    (__bridge void *)self,
    &_ioProcID
  );
  if (status == kAudioHardwareNoError) {
    status = AudioDeviceStart(_aggregateDeviceID, _ioProcID);
  }
  if (status != kAudioHardwareNoError) {
    NSError *startError = StatusError(status, @"Starting system audio capture");
    [self stop];
    if (remainingAttempts > 1) {
      NSUInteger completedAttempts = 4 - remainingAttempts;
      useconds_t delay = static_cast<useconds_t>(completedAttempts * 150'000);
      usleep(delay);
      return [self startWithProcessIDs:processIDs
                     remainingAttempts:remainingAttempts - 1
                                 error:error];
    }
    if (error != nullptr) {
      *error = startError;
    }
    return NO;
  }
  return YES;
}

- (void)stop {
  if (_aggregateDeviceID != kAudioObjectUnknown && _ioProcID != nullptr) {
    AudioDeviceStop(_aggregateDeviceID, _ioProcID);
    AudioDeviceDestroyIOProcID(_aggregateDeviceID, _ioProcID);
    _ioProcID = nullptr;
  }
  if (_tapID != kAudioObjectUnknown && _tapFormatListener != nil) {
    AudioObjectPropertyAddress formatAddress =
      PropertyAddress(kAudioTapPropertyFormat);
    AudioObjectRemovePropertyListenerBlock(
      _tapID,
      &formatAddress,
      _deliveryQueue,
      _tapFormatListener
    );
    _tapFormatListener = nil;
  }
  if (_deliveryQueue != nil) {
    dispatch_sync(_deliveryQueue, ^{});
  }
  if (_aggregateDeviceID != kAudioObjectUnknown) {
    AudioHardwareDestroyAggregateDevice(_aggregateDeviceID);
    _aggregateDeviceID = kAudioObjectUnknown;
  }
  if (_tapID != kAudioObjectUnknown) {
    AudioHardwareDestroyProcessTap(_tapID);
    _tapID = kAudioObjectUnknown;
  }
  _tapSampleRate.store(0, std::memory_order_relaxed);
}

- (OSStatus)refreshTapFormat {
  AudioStreamBasicDescription format = {};
  AudioObjectPropertyAddress formatAddress = PropertyAddress(kAudioTapPropertyFormat);
  UInt32 formatSize = sizeof(format);
  OSStatus status = AudioObjectGetPropertyData(
    _tapID,
    &formatAddress,
    0,
    nullptr,
    &formatSize,
    &format
  );
  bool isFloatPCM = format.mFormatID == kAudioFormatLinearPCM
    && (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
    && format.mBitsPerChannel == 32;
  if (status != kAudioHardwareNoError
      || !isFloatPCM
      || format.mSampleRate <= 0
      || format.mChannelsPerFrame == 0) {
    _tapSampleRate.store(0, std::memory_order_relaxed);
    return status == kAudioHardwareNoError ? kAudio_ParamError : status;
  }
  _tapSampleRate.store(format.mSampleRate, std::memory_order_relaxed);
  return kAudioHardwareNoError;
}

- (OSStatus)handleInputData:(const AudioBufferList *)inputData
                  inputTime:(const AudioTimeStamp *)inputTime {
  HWSystemAudioTapSamplesHandler handler = self.samplesHandler;
  if (handler == nil || inputData == nullptr || inputData->mNumberBuffers == 0) {
    return kAudioHardwareNoError;
  }
  double sampleRate = _tapSampleRate.load(std::memory_order_relaxed);
  if (sampleRate <= 0) {
    return kAudioHardwareNoError;
  }

  const AudioBuffer &buffer = inputData->mBuffers[0];
  if (buffer.mData == nullptr || buffer.mDataByteSize == 0) {
    return kAudioHardwareNoError;
  }
  UInt32 channelCount = MAX(1, buffer.mNumberChannels);
  size_t sampleCount = buffer.mDataByteSize / sizeof(Float32);
  size_t frameCount = sampleCount / channelCount;
  if (frameCount == 0) {
    return kAudioHardwareNoError;
  }

  const Float32 *input = static_cast<const Float32 *>(buffer.mData);
  _monoBuffer.resize(frameCount);
  if (channelCount == 1) {
    memcpy(_monoBuffer.data(), input, frameCount * sizeof(Float32));
  } else {
    for (size_t frame = 0; frame < frameCount; ++frame) {
      Float32 sum = 0;
      for (UInt32 channel = 0; channel < channelCount; ++channel) {
        sum += input[frame * channelCount + channel];
      }
      _monoBuffer[frame] = sum / static_cast<Float32>(channelCount);
    }
  }

  UInt64 hostTime = inputTime != nullptr && inputTime->mHostTime != 0
    ? inputTime->mHostTime
    : AudioGetCurrentHostTime();
  double hostSeconds = static_cast<double>(AudioConvertHostTimeToNanos(hostTime)) / 1e9;
  NSData *data = [[NSData alloc] initWithBytes:_monoBuffer.data()
                                       length:_monoBuffer.size() * sizeof(Float32)];
  dispatch_async(_deliveryQueue, ^{
    handler(data, sampleRate, hostSeconds);
  });
  return kAudioHardwareNoError;
}

@end
