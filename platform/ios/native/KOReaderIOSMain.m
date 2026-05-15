#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <math.h>

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

#include "SDL3/SDL_main.h"

typedef NS_ENUM(NSInteger, KOIOSPickerStatus) {
    KOIOSPickerStatusIdle = 0,
    KOIOSPickerStatusPending = 1,
    KOIOSPickerStatusFinished = 2,
    KOIOSPickerStatusCancelled = 3,
    KOIOSPickerStatusFailed = 4,
};

static KOIOSPickerStatus KOPluginZipStatus = KOIOSPickerStatusIdle;
static NSString *KOPluginZipPath;
static NSString *KOPluginZipError;
static KOIOSPickerStatus KOFileImportStatus = KOIOSPickerStatusIdle;
static NSInteger KOFileImportCount = 0;
static NSString *KOFileImportDestination;
static NSString *KOFileImportError;
static KOIOSPickerStatus KOExternalFolderStatus = KOIOSPickerStatusIdle;
static NSString *KOExternalFolderPath;
static NSString *KOExternalFolderBookmark;
static NSString *KOExternalFolderError;

static UIWindow *KOKeyWindow(void);
static UIViewController *KORootViewController(void);
static NSString *KOApplicationSupportPath(void);

static void KOSetPluginZipResult(KOIOSPickerStatus status, NSString *path, NSString *error) {
    @synchronized (NSProcessInfo.processInfo) {
        KOPluginZipStatus = status;
        KOPluginZipPath = [path copy];
        KOPluginZipError = [error copy];
    }
}

static BOOL KOPluginZipImportIsPending(void) {
    @synchronized (NSProcessInfo.processInfo) {
        return KOPluginZipStatus == KOIOSPickerStatusPending;
    }
}

static void KOSetFileImportResult(KOIOSPickerStatus status, NSInteger count, NSString *destination, NSString *error) {
    @synchronized (NSProcessInfo.processInfo) {
        KOFileImportStatus = status;
        KOFileImportCount = count;
        KOFileImportDestination = [destination copy];
        KOFileImportError = [error copy];
    }
}

static BOOL KOFileImportIsPending(void) {
    @synchronized (NSProcessInfo.processInfo) {
        return KOFileImportStatus == KOIOSPickerStatusPending;
    }
}

static void KOSetExternalFolderResult(KOIOSPickerStatus status, NSString *path, NSString *bookmark, NSString *error) {
    @synchronized (NSProcessInfo.processInfo) {
        KOExternalFolderStatus = status;
        KOExternalFolderPath = [path copy];
        KOExternalFolderBookmark = [bookmark copy];
        KOExternalFolderError = [error copy];
    }
}

static BOOL KOExternalFolderPickerIsPending(void) {
    @synchronized (NSProcessInfo.processInfo) {
        return KOExternalFolderStatus == KOIOSPickerStatusPending;
    }
}

static NSMutableDictionary<NSString *, NSURL *> *KOExternalFolderActiveURLs(void) {
    static NSMutableDictionary<NSString *, NSURL *> *activeURLs;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        activeURLs = [NSMutableDictionary dictionary];
    });
    return activeURLs;
}

static void KOSetActiveExternalFolderURL(NSString *bookmark, NSURL *url) {
    if (bookmark.length == 0 || url == nil) return;
    NSMutableDictionary<NSString *, NSURL *> *activeURLs = KOExternalFolderActiveURLs();
    @synchronized (activeURLs) {
        NSURL *oldURL = activeURLs[bookmark];
        if (oldURL != nil) {
            [oldURL stopAccessingSecurityScopedResource];
        }
        activeURLs[bookmark] = url;
    }
}

static void KORemoveActiveExternalFolderURL(NSString *bookmark) {
    if (bookmark.length == 0) return;
    NSMutableDictionary<NSString *, NSURL *> *activeURLs = KOExternalFolderActiveURLs();
    @synchronized (activeURLs) {
        NSURL *url = activeURLs[bookmark];
        if (url != nil) {
            [url stopAccessingSecurityScopedResource];
            [activeURLs removeObjectForKey:bookmark];
        }
    }
}

static NSString *KOPathForDirectory(NSSearchPathDirectory directory) {
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(directory, NSUserDomainMask, YES);
    return paths.count > 0 ? paths.firstObject : NSHomeDirectory();
}

static NSString *KOApplicationSupportPath(void) {
    NSString *path = [KOPathForDirectory(NSApplicationSupportDirectory) stringByAppendingPathComponent:@"KOReader"];
    [NSFileManager.defaultManager createDirectoryAtPath:path
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:nil];
    return path;
}

static NSString *KOStringFromUTF8(const char *value) {
    if (value == NULL) return @"";
    NSString *string = [NSString stringWithUTF8String:value];
    return string ?: @"";
}

static const char *KORetainUTF8(NSString *string) {
    if (string == nil) string = @"";
    static NSMutableArray<NSString *> *retained;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        retained = [NSMutableArray array];
    });
    NSString *copy = [string copy];
    @synchronized (retained) {
        [retained addObject:copy];
        if (retained.count > 64) {
            [retained removeObjectsInRange:NSMakeRange(0, retained.count - 64)];
        }
    }
    return copy.UTF8String;
}

static void KOCopyUTF8ToBuffer(NSString *string, char *buffer, size_t capacity) {
    if (buffer == NULL || capacity == 0) return;
    const char *value = string.UTF8String ?: "";
    strlcpy(buffer, value, capacity);
}

static NSString *KOCreateExternalFolderBookmark(NSURL *url, NSError **error) {
    NSData *bookmark = [url bookmarkDataWithOptions:0
                    includingResourceValuesForKeys:nil
                                     relativeToURL:nil
                                             error:error];
    if (bookmark == nil) return nil;
    return [bookmark base64EncodedStringWithOptions:0];
}

static NSString *KOUniqueDestinationPath(NSString *directory, NSString *filename) {
    if (filename.length == 0) filename = @"imported-file";
    NSString *candidate = [directory stringByAppendingPathComponent:filename];
    NSFileManager *fileManager = NSFileManager.defaultManager;
    if (![fileManager fileExistsAtPath:candidate]) {
        return candidate;
    }

    NSString *basename = filename.stringByDeletingPathExtension;
    NSString *extension = filename.pathExtension;
    for (NSInteger i = 2; i < NSIntegerMax; i++) {
        NSString *nextName = extension.length > 0
            ? [NSString stringWithFormat:@"%@-%ld.%@", basename, (long)i, extension]
            : [NSString stringWithFormat:@"%@-%ld", basename, (long)i];
        candidate = [directory stringByAppendingPathComponent:nextName];
        if (![fileManager fileExistsAtPath:candidate]) {
            return candidate;
        }
    }
    return nil;
}

static BOOL KOImportFileURL(NSURL *url, NSString *destination, NSError **error) {
    NSFileManager *fileManager = NSFileManager.defaultManager;
    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSString *filename = url.lastPathComponent.length > 0 ? url.lastPathComponent : @"imported-file";
    NSString *targetPath = KOUniqueDestinationPath(destination, filename);
    if (targetPath.length == 0) {
        if (scoped) [url stopAccessingSecurityScopedResource];
        if (error != NULL) {
            *error = [NSError errorWithDomain:@"KOReaderIOSImport"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: @"Could not create a unique destination filename."}];
        }
        return NO;
    }

    NSString *temporaryName = [NSString stringWithFormat:@".koreader-import-%@-%@", NSUUID.UUID.UUIDString, filename];
    NSURL *temporaryURL = [NSURL fileURLWithPath:[destination stringByAppendingPathComponent:temporaryName]];
    [fileManager removeItemAtURL:temporaryURL error:nil];
    BOOL copied = [fileManager copyItemAtURL:url toURL:temporaryURL error:error];
    if (scoped) [url stopAccessingSecurityScopedResource];
    if (!copied) {
        [fileManager removeItemAtURL:temporaryURL error:nil];
        return NO;
    }

    NSURL *targetURL = [NSURL fileURLWithPath:targetPath];
    BOOL moved = [fileManager moveItemAtURL:temporaryURL toURL:targetURL error:error];
    if (!moved) {
        [fileManager removeItemAtURL:temporaryURL error:nil];
    }
    return moved;
}

const char *KOIOSGetBundlePath(void) {
    return KORetainUTF8(NSBundle.mainBundle.bundlePath);
}

const char *KOIOSGetResourcePath(void) {
    return KORetainUTF8(NSBundle.mainBundle.resourcePath);
}

const char *KOIOSGetDocumentsPath(void) {
    return KORetainUTF8(KOPathForDirectory(NSDocumentDirectory));
}

const char *KOIOSGetApplicationSupportPath(void) {
    return KORetainUTF8(KOApplicationSupportPath());
}

const char *KOIOSGetNativeLibraryDir(void) {
    return KORetainUTF8([[NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"reader"] stringByAppendingPathComponent:@"libs"]);
}

void KOIOSGetSafeAreaInsets(int *top, int *right, int *bottom, int *left) {
    __block UIEdgeInsets insets = UIEdgeInsetsZero;
    __block CGFloat scale = UIScreen.mainScreen.scale;
    void (^readInsets)(void) = ^{
        UIWindow *window = KOKeyWindow();
        if (window != nil) {
            UIView *view = window.rootViewController.view;
            [window layoutIfNeeded];
            scale = window.screen.scale ?: UIScreen.mainScreen.scale;
            CGRect bounds = window.bounds;
            CGRect safe = window.safeAreaLayoutGuide.layoutFrame;
            if (safe.size.width > 0 && safe.size.height > 0) {
                insets = UIEdgeInsetsMake(
                    safe.origin.y - bounds.origin.y,
                    safe.origin.x - bounds.origin.x,
                    bounds.origin.y + bounds.size.height - safe.origin.y - safe.size.height,
                    bounds.origin.x + bounds.size.width - safe.origin.x - safe.size.width
                );
            }
            if (UIEdgeInsetsEqualToEdgeInsets(insets, UIEdgeInsetsZero) && view != nil) {
                [view layoutIfNeeded];
                insets = view.safeAreaInsets;
            }
        }
    };
    if (NSThread.isMainThread) {
        readInsets();
    } else {
        dispatch_sync(dispatch_get_main_queue(), readInsets);
    }
    if (top != NULL) *top = (int)ceil(insets.top * scale);
    if (right != NULL) *right = (int)ceil(insets.right * scale);
    if (bottom != NULL) *bottom = (int)ceil(insets.bottom * scale);
    if (left != NULL) *left = (int)ceil(insets.left * scale);
    NSLog(@"KOReader safe area insets points={%.1f, %.1f, %.1f, %.1f} scale=%.1f pixels={%d, %d, %d, %d}",
          insets.top, insets.right, insets.bottom, insets.left, scale,
          top != NULL ? *top : 0,
          right != NULL ? *right : 0,
          bottom != NULL ? *bottom : 0,
          left != NULL ? *left : 0);
}

int KOIOSOpenLink(const char *url) {
    if (url == NULL) return 0;
    NSString *string = KOStringFromUTF8(url);
    if (string.length == 0) return 0;
    NSURL *nsurl = [NSURL URLWithString:string];
    if (nsurl == nil) return 0;
    dispatch_async(dispatch_get_main_queue(), ^{
        [UIApplication.sharedApplication openURL:nsurl options:@{} completionHandler:nil];
    });
    return 1;
}

int KOIOSHasClipboardText(void) {
    __block BOOL hasText = NO;
    void (^readClipboard)(void) = ^{
        hasText = UIPasteboard.generalPasteboard.string.length > 0;
    };
    if (NSThread.isMainThread) {
        readClipboard();
    } else {
        dispatch_sync(dispatch_get_main_queue(), readClipboard);
    }
    return hasText ? 1 : 0;
}

const char *KOIOSGetClipboardText(void) {
    __block NSString *text = @"";
    void (^readClipboard)(void) = ^{
        text = [UIPasteboard.generalPasteboard.string ?: @"" copy];
    };
    if (NSThread.isMainThread) {
        readClipboard();
    } else {
        dispatch_sync(dispatch_get_main_queue(), readClipboard);
    }
    return KORetainUTF8(text);
}

int KOIOSSetClipboardText(const char *text) {
    NSString *string = KOStringFromUTF8(text);
    void (^writeClipboard)(void) = ^{
        UIPasteboard.generalPasteboard.string = string;
    };
    if (NSThread.isMainThread) {
        writeClipboard();
    } else {
        dispatch_sync(dispatch_get_main_queue(), writeClipboard);
    }
    return 1;
}

int KOIOSCanShareText(void) {
    return 1;
}

static UIWindow *KOKeyWindow(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (scene.activationState != UISceneActivationStateForegroundActive) continue;
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        for (UIWindow *window in windowScene.windows) {
            if (window.isKeyWindow) return window;
        }
    }
    return nil;
}

static UIViewController *KORootViewController(void) {
    return KOKeyWindow().rootViewController;
}

@interface KOPluginZipPickerDelegate : NSObject <UIDocumentPickerDelegate>
@end

static KOPluginZipPickerDelegate *KOPluginZipPicker;

@implementation KOPluginZipPickerDelegate

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    (void)controller;
    KOSetPluginZipResult(KOIOSPickerStatusCancelled, nil, nil);
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    (void)controller;
    NSURL *url = urls.firstObject;
    if (url == nil) {
        KOSetPluginZipResult(KOIOSPickerStatusCancelled, nil, nil);
        return;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL scoped = [url startAccessingSecurityScopedResource];
        NSError *error = nil;
        NSFileManager *fileManager = NSFileManager.defaultManager;
        NSString *importDir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"koreader-plugin-imports"];
        if (![fileManager createDirectoryAtPath:importDir withIntermediateDirectories:YES attributes:nil error:&error]) {
            if (scoped) [url stopAccessingSecurityScopedResource];
            KOSetPluginZipResult(KOIOSPickerStatusFailed, nil, error.localizedDescription);
            return;
        }

        NSString *filename = url.lastPathComponent.length > 0 ? url.lastPathComponent : @"plugin.zip";
        NSString *destName = [NSString stringWithFormat:@"%@-%@", NSUUID.UUID.UUIDString, filename];
        NSURL *destURL = [NSURL fileURLWithPath:[importDir stringByAppendingPathComponent:destName]];
        [fileManager removeItemAtURL:destURL error:nil];
        BOOL copied = [fileManager copyItemAtURL:url toURL:destURL error:&error];
        if (scoped) [url stopAccessingSecurityScopedResource];

        if (!copied) {
            KOSetPluginZipResult(KOIOSPickerStatusFailed, nil, error.localizedDescription);
            return;
        }
        KOSetPluginZipResult(KOIOSPickerStatusFinished, destURL.path, nil);
    });
}

@end

@interface KOFileImportPickerDelegate : NSObject <UIDocumentPickerDelegate>
@end

static KOFileImportPickerDelegate *KOFileImportPicker;

@implementation KOFileImportPickerDelegate

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    (void)controller;
    KOSetFileImportResult(KOIOSPickerStatusCancelled, 0, nil, nil);
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    (void)controller;
    NSString *destination;
    @synchronized (NSProcessInfo.processInfo) {
        destination = [KOFileImportDestination copy];
    }
    if (urls.count == 0 || destination.length == 0) {
        KOSetFileImportResult(KOIOSPickerStatusCancelled, 0, destination, nil);
        return;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSInteger imported = 0;
        NSMutableArray<NSString *> *errors = [NSMutableArray array];
        for (NSURL *url in urls) {
            NSError *error = nil;
            if (KOImportFileURL(url, destination, &error)) {
                imported++;
            } else {
                NSString *filename = url.lastPathComponent.length > 0 ? url.lastPathComponent : @"unknown";
                NSString *message = error.localizedDescription ?: @"copy failed";
                [errors addObject:[NSString stringWithFormat:@"%@: %@", filename, message]];
            }
        }

        NSString *errorText = errors.count > 0 ? [errors componentsJoinedByString:@"\n"] : nil;
        KOSetFileImportResult(imported > 0 ? KOIOSPickerStatusFinished : KOIOSPickerStatusFailed,
                              imported,
                              destination,
                              errorText);
    });
}

@end

@interface KOExternalFolderPickerDelegate : NSObject <UIDocumentPickerDelegate>
@end

static KOExternalFolderPickerDelegate *KOExternalFolderPicker;

@implementation KOExternalFolderPickerDelegate

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    (void)controller;
    KOSetExternalFolderResult(KOIOSPickerStatusCancelled, nil, nil, nil);
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    (void)controller;
    NSURL *url = urls.firstObject;
    if (url == nil) {
        KOSetExternalFolderResult(KOIOSPickerStatusCancelled, nil, nil, nil);
        return;
    }

    BOOL scoped = [url startAccessingSecurityScopedResource];
    if (!scoped) {
        KOSetExternalFolderResult(KOIOSPickerStatusFailed, nil, nil, @"Could not access the selected folder.");
        return;
    }

    NSError *error = nil;
    NSString *bookmark = KOCreateExternalFolderBookmark(url, &error);
    if (bookmark.length == 0) {
        [url stopAccessingSecurityScopedResource];
        NSString *message = error.localizedDescription ?: @"Could not create a persistent folder bookmark.";
        KOSetExternalFolderResult(KOIOSPickerStatusFailed, nil, nil, message);
        return;
    }

    KOSetActiveExternalFolderURL(bookmark, url);
    KOSetExternalFolderResult(KOIOSPickerStatusFinished, url.path, bookmark, nil);
}

@end

int KOIOSShareText(const char *text, const char *reason, const char *title, const char *mimetype) {
    (void)reason;
    (void)title;
    (void)mimetype;
    if (text == NULL) return 0;
    NSString *string = KOStringFromUTF8(text);
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *root = KORootViewController();
        if (root == nil) return;
        UIActivityViewController *controller = [[UIActivityViewController alloc] initWithActivityItems:@[string] applicationActivities:nil];
        UIPopoverPresentationController *popover = controller.popoverPresentationController;
        if (popover != nil) {
            popover.sourceView = root.view;
            popover.sourceRect = root.view.bounds;
            popover.permittedArrowDirections = 0;
        }
        [root presentViewController:controller animated:YES completion:nil];
    });
    return 1;
}

int KOIOSRequestPluginZipImport(void) {
    if (KOPluginZipImportIsPending()) {
        return 0;
    }
    KOSetPluginZipResult(KOIOSPickerStatusPending, nil, nil);
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *root = KORootViewController();
        if (root == nil) {
            KOSetPluginZipResult(KOIOSPickerStatusFailed, nil, @"No active iOS window.");
            return;
        }
        if (root.presentedViewController != nil) {
            KOSetPluginZipResult(KOIOSPickerStatusFailed, nil, @"Another iOS dialog is already open.");
            return;
        }
        if (KOPluginZipPicker == nil) {
            KOPluginZipPicker = [KOPluginZipPickerDelegate new];
        }
        UIDocumentPickerViewController *controller = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeZIP] asCopy:YES];
        controller.delegate = KOPluginZipPicker;
        controller.allowsMultipleSelection = NO;
        [root presentViewController:controller animated:YES completion:nil];
    });
    return 1;
}

int KOIOSGetPluginZipImportStatus(void) {
    @synchronized (NSProcessInfo.processInfo) {
        return (int)KOPluginZipStatus;
    }
}

const char *KOIOSGetPluginZipImportPath(void) {
    @synchronized (NSProcessInfo.processInfo) {
        return KORetainUTF8(KOPluginZipPath ?: @"");
    }
}

const char *KOIOSGetPluginZipImportError(void) {
    @synchronized (NSProcessInfo.processInfo) {
        return KORetainUTF8(KOPluginZipError ?: @"");
    }
}

void KOIOSConsumePluginZipImportResult(void) {
    KOSetPluginZipResult(KOIOSPickerStatusIdle, nil, nil);
}

int KOIOSRequestFileImport(const char *destination_path) {
    if (KOFileImportIsPending()) {
        return 0;
    }
    NSString *destination = KOStringFromUTF8(destination_path);
    BOOL isDirectory = NO;
    if (destination.length == 0
        || ![NSFileManager.defaultManager fileExistsAtPath:destination isDirectory:&isDirectory]
        || !isDirectory) {
        KOSetFileImportResult(KOIOSPickerStatusFailed, 0, destination, @"The destination folder does not exist.");
        return 0;
    }

    KOSetFileImportResult(KOIOSPickerStatusPending, 0, destination, nil);
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *root = KORootViewController();
        if (root == nil) {
            KOSetFileImportResult(KOIOSPickerStatusFailed, 0, destination, @"No active iOS window.");
            return;
        }
        if (root.presentedViewController != nil) {
            KOSetFileImportResult(KOIOSPickerStatusFailed, 0, destination, @"Another iOS dialog is already open.");
            return;
        }
        if (KOFileImportPicker == nil) {
            KOFileImportPicker = [KOFileImportPickerDelegate new];
        }
        UIDocumentPickerViewController *controller = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeData] asCopy:YES];
        controller.delegate = KOFileImportPicker;
        controller.allowsMultipleSelection = YES;
        [root presentViewController:controller animated:YES completion:nil];
    });
    return 1;
}

int KOIOSGetFileImportStatus(void) {
    @synchronized (NSProcessInfo.processInfo) {
        return (int)KOFileImportStatus;
    }
}

int KOIOSGetFileImportCount(void) {
    @synchronized (NSProcessInfo.processInfo) {
        return (int)KOFileImportCount;
    }
}

const char *KOIOSGetFileImportError(void) {
    @synchronized (NSProcessInfo.processInfo) {
        return KORetainUTF8(KOFileImportError ?: @"");
    }
}

void KOIOSConsumeFileImportResult(void) {
    KOSetFileImportResult(KOIOSPickerStatusIdle, 0, nil, nil);
}

int KOIOSRequestExternalFolderPicker(void) {
    if (KOExternalFolderPickerIsPending()) {
        return 0;
    }
    KOSetExternalFolderResult(KOIOSPickerStatusPending, nil, nil, nil);
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *root = KORootViewController();
        if (root == nil) {
            KOSetExternalFolderResult(KOIOSPickerStatusFailed, nil, nil, @"No active iOS window.");
            return;
        }
        if (root.presentedViewController != nil) {
            KOSetExternalFolderResult(KOIOSPickerStatusFailed, nil, nil, @"Another iOS dialog is already open.");
            return;
        }
        if (KOExternalFolderPicker == nil) {
            KOExternalFolderPicker = [KOExternalFolderPickerDelegate new];
        }
        UIDocumentPickerViewController *controller = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeFolder] asCopy:NO];
        controller.delegate = KOExternalFolderPicker;
        controller.allowsMultipleSelection = NO;
        [root presentViewController:controller animated:YES completion:nil];
    });
    return 1;
}

int KOIOSGetExternalFolderPickerStatus(void) {
    @synchronized (NSProcessInfo.processInfo) {
        return (int)KOExternalFolderStatus;
    }
}

const char *KOIOSGetExternalFolderPickerPath(void) {
    @synchronized (NSProcessInfo.processInfo) {
        return KORetainUTF8(KOExternalFolderPath ?: @"");
    }
}

const char *KOIOSGetExternalFolderPickerBookmark(void) {
    @synchronized (NSProcessInfo.processInfo) {
        return KORetainUTF8(KOExternalFolderBookmark ?: @"");
    }
}

const char *KOIOSGetExternalFolderPickerError(void) {
    @synchronized (NSProcessInfo.processInfo) {
        return KORetainUTF8(KOExternalFolderError ?: @"");
    }
}

void KOIOSConsumeExternalFolderPickerResult(void) {
    KOSetExternalFolderResult(KOIOSPickerStatusIdle, nil, nil, nil);
}

int KOIOSResolveExternalFolderBookmark(const char *bookmark_b64,
                                       char *out_path, size_t path_capacity,
                                       char *out_bookmark_b64, size_t bookmark_capacity,
                                       char *out_error, size_t error_capacity) {
    KOCopyUTF8ToBuffer(@"", out_path, path_capacity);
    KOCopyUTF8ToBuffer(@"", out_bookmark_b64, bookmark_capacity);
    KOCopyUTF8ToBuffer(@"", out_error, error_capacity);
    if (bookmark_b64 == NULL || bookmark_b64[0] == '\0') {
        KOCopyUTF8ToBuffer(@"Missing folder bookmark.", out_error, error_capacity);
        return 0;
    }

    NSString *bookmarkString = KOStringFromUTF8(bookmark_b64);
    NSData *bookmarkData = [[NSData alloc] initWithBase64EncodedString:bookmarkString options:0];
    if (bookmarkData == nil) {
        KOCopyUTF8ToBuffer(@"Invalid folder bookmark.", out_error, error_capacity);
        return 0;
    }

    BOOL stale = NO;
    NSError *error = nil;
    NSURL *url = [NSURL URLByResolvingBookmarkData:bookmarkData
                                           options:0
                                     relativeToURL:nil
                               bookmarkDataIsStale:&stale
                                             error:&error];
    if (url == nil) {
        KOCopyUTF8ToBuffer(error.localizedDescription ?: @"Could not resolve folder bookmark.", out_error, error_capacity);
        return 0;
    }

    if (![url startAccessingSecurityScopedResource]) {
        KOCopyUTF8ToBuffer(@"Could not access the saved folder.", out_error, error_capacity);
        return 0;
    }

    NSString *activeBookmark = bookmarkString;
    if (stale) {
        NSError *bookmarkError = nil;
        NSString *refreshedBookmark = KOCreateExternalFolderBookmark(url, &bookmarkError);
        if (refreshedBookmark.length > 0) {
            activeBookmark = refreshedBookmark;
            KOCopyUTF8ToBuffer(refreshedBookmark, out_bookmark_b64, bookmark_capacity);
        } else {
            NSLog(@"KOReader could not refresh stale external folder bookmark: %@", bookmarkError.localizedDescription);
        }
    }

    KOSetActiveExternalFolderURL(activeBookmark, url);
    if (![activeBookmark isEqualToString:bookmarkString]) {
        KORemoveActiveExternalFolderURL(bookmarkString);
    }
    KOCopyUTF8ToBuffer(url.path, out_path, path_capacity);
    return 1;
}

int KOIOSReleaseExternalFolderBookmark(const char *bookmark_b64) {
    if (bookmark_b64 == NULL || bookmark_b64[0] == '\0') {
        return 0;
    }
    KORemoveActiveExternalFolderURL(KOStringFromUTF8(bookmark_b64));
    return 1;
}

static void KOSetEnv(NSString *name, NSString *value) {
    setenv(name.UTF8String, value.UTF8String, 1);
}

static int KORunLua(void) {
    NSString *resourcePath = NSBundle.mainBundle.resourcePath;
    NSString *koreaderPath = [resourcePath stringByAppendingPathComponent:@"reader"];
    NSString *readerPath = [koreaderPath stringByAppendingPathComponent:@"reader.lua"];

    KOSetEnv(@"KO_IOS_BUNDLE_PATH", NSBundle.mainBundle.bundlePath);
    KOSetEnv(@"KO_IOS_RESOURCE_PATH", resourcePath);
    KOSetEnv(@"KO_IOS_DOCUMENTS_PATH", KOPathForDirectory(NSDocumentDirectory));
    KOSetEnv(@"KO_IOS_APPLICATION_SUPPORT_PATH", KOApplicationSupportPath());
    KOSetEnv(@"KO_IOS_NATIVE_LIBRARY_DIR", [koreaderPath stringByAppendingPathComponent:@"libs"]);

    if (chdir(koreaderPath.fileSystemRepresentation) != 0) {
        return 1;
    }

    lua_State *L = luaL_newstate();
    if (L == NULL) return 1;
    luaL_openlibs(L);

    lua_newtable(L);
    lua_pushstring(L, readerPath.fileSystemRepresentation);
    lua_rawseti(L, -2, 0);
    lua_setglobal(L, "arg");

    int status = luaL_dofile(L, readerPath.fileSystemRepresentation);
    if (status != LUA_OK) {
        NSLog(@"KOReader Lua error: %s", lua_tostring(L, -1));
    }
    lua_close(L);
    return status == LUA_OK ? 0 : 1;
}

int main(int argc, char *argv[]) {
    (void)argc;
    (void)argv;
    @autoreleasepool {
        return KORunLua();
    }
}
