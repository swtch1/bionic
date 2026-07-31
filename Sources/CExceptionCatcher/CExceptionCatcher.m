#import "include/CExceptionCatcher.h"

NSString *_Nullable ms_tryCatch(void (^_Nonnull block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        // `reason` is the human-readable half ("Input HW format and tap format not matching");
        // `name` alone is almost always NSInvalidArgumentException and says nothing useful.
        return exception.reason ?: exception.name ?: @"unknown NSException";
    }
}
