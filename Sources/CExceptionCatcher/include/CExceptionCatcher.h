#ifndef CExceptionCatcher_h
#define CExceptionCatcher_h

#import <Foundation/Foundation.h>

/// Runs `block` inside an Objective-C @try/@catch.
///
/// Swift's `do/catch` only sees Swift `Error`s and `NSError` out-params - it cannot
/// intercept an Objective-C `NSException`. AVFoundation's `-installTapOnBus:...`
/// raises one (rather than returning an error) when the requested format doesn't
/// match the node's, which is reachable in production via an input-device change
/// race: the hardware format can change between the moment we read
/// `outputFormat(forBus:)` and the moment the tap is installed. An uncaught
/// NSException calls std::terminate, so that race takes the whole process down
/// mid-meeting and loses the recording.
///
/// Returns nil on success, or the raised exception's `reason` so the Swift caller
/// can turn a hard crash into a recoverable error.
NSString *_Nullable ms_tryCatch(void (^_Nonnull block)(void)) NS_SWIFT_NAME(msTryCatch(_:));

#endif /* CExceptionCatcher_h */
