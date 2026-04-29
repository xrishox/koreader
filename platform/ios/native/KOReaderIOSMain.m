#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

#include "SDL3/SDL_main.h"

typedef NS_ENUM(NSInteger, KOPluginZipImportStatus) {
    KOPluginZipImportStatusIdle = 0,
    KOPluginZipImportStatusPending = 1,
    KOPluginZipImportStatusFinished = 2,
    KOPluginZipImportStatusCancelled = 3,
    KOPluginZipImportStatusFailed = 4,
};

static KOPluginZipImportStatus KOPluginZipStatus = KOPluginZipImportStatusIdle;
static NSString *KOPluginZipPath;
static NSString *KOPluginZipError;

static UIWindow *KOKeyWindow(void);
static UIViewController *KORootViewController(void);

static void KOSetPluginZipResult(KOPluginZipImportStatus status, NSString *path, NSString *error) {
    @synchronized (NSProcessInfo.processInfo) {
        KOPluginZipStatus = status;
        KOPluginZipPath = [path copy];
        KOPluginZipError = [error copy];
    }
}

static NSString *KOPathForDirectory(NSSearchPathDirectory directory) {
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(directory, NSUserDomainMask, YES);
    return paths.count > 0 ? paths.firstObject : NSHomeDirectory();
}

static const char *KORetainUTF8(NSString *string) {
    static NSMutableArray<NSString *> *retained;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        retained = [NSMutableArray array];
    });
    NSString *copy = [string copy];
    @synchronized (retained) {
        [retained addObject:copy];
    }
    return copy.UTF8String;
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
    NSString *path = [KOPathForDirectory(NSApplicationSupportDirectory) stringByAppendingPathComponent:@"KOReader"];
    [NSFileManager.defaultManager createDirectoryAtPath:path
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:nil];
    return KORetainUTF8(path);
}

const char *KOIOSGetNativeLibraryDir(void) {
    return KORetainUTF8([[NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"reader"] stringByAppendingPathComponent:@"libs"]);
}

void KOIOSGetSafeAreaInsets(int *top, int *right, int *bottom, int *left) {
    __block UIEdgeInsets insets = UIEdgeInsetsZero;
    __block CGFloat scale = UIScreen.mainScreen.scale;
    void (^readInsets)(void) = ^{
        UIWindow *window = KOKeyWindow();
        UIView *view = window.rootViewController.view;
        if (window != nil) {
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
    NSURL *nsurl = [NSURL URLWithString:[NSString stringWithUTF8String:url]];
    if (nsurl == nil) return 0;
    dispatch_async(dispatch_get_main_queue(), ^{
        [UIApplication.sharedApplication openURL:nsurl options:@{} completionHandler:nil];
    });
    return 1;
}

int KOIOSHasClipboardText(void) {
    return UIPasteboard.generalPasteboard.string.length > 0;
}

const char *KOIOSGetClipboardText(void) {
    return KORetainUTF8(UIPasteboard.generalPasteboard.string ?: @"");
}

int KOIOSSetClipboardText(const char *text) {
    UIPasteboard.generalPasteboard.string = text ? [NSString stringWithUTF8String:text] : @"";
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
    KOSetPluginZipResult(KOPluginZipImportStatusCancelled, nil, nil);
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    (void)controller;
    NSURL *url = urls.firstObject;
    if (url == nil) {
        KOSetPluginZipResult(KOPluginZipImportStatusCancelled, nil, nil);
        return;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL scoped = [url startAccessingSecurityScopedResource];
        NSError *error = nil;
        NSFileManager *fileManager = NSFileManager.defaultManager;
        NSString *importDir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"koreader-plugin-imports"];
        if (![fileManager createDirectoryAtPath:importDir withIntermediateDirectories:YES attributes:nil error:&error]) {
            if (scoped) [url stopAccessingSecurityScopedResource];
            KOSetPluginZipResult(KOPluginZipImportStatusFailed, nil, error.localizedDescription);
            return;
        }

        NSString *filename = url.lastPathComponent.length > 0 ? url.lastPathComponent : @"plugin.zip";
        NSString *destName = [NSString stringWithFormat:@"%@-%@", NSUUID.UUID.UUIDString, filename];
        NSURL *destURL = [NSURL fileURLWithPath:[importDir stringByAppendingPathComponent:destName]];
        [fileManager removeItemAtURL:destURL error:nil];
        BOOL copied = [fileManager copyItemAtURL:url toURL:destURL error:&error];
        if (scoped) [url stopAccessingSecurityScopedResource];

        if (!copied) {
            KOSetPluginZipResult(KOPluginZipImportStatusFailed, nil, error.localizedDescription);
            return;
        }
        KOSetPluginZipResult(KOPluginZipImportStatusFinished, destURL.path, nil);
    });
}

@end

int KOIOSShareText(const char *text, const char *reason, const char *title, const char *mimetype) {
    (void)reason;
    (void)title;
    (void)mimetype;
    if (text == NULL) return 0;
    NSString *string = [NSString stringWithUTF8String:text];
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *root = KORootViewController();
        if (root == nil) return;
        UIActivityViewController *controller = [[UIActivityViewController alloc] initWithActivityItems:@[string] applicationActivities:nil];
        [root presentViewController:controller animated:YES completion:nil];
    });
    return 1;
}

int KOIOSRequestPluginZipImport(void) {
    KOSetPluginZipResult(KOPluginZipImportStatusPending, nil, nil);
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *root = KORootViewController();
        if (root == nil) {
            KOSetPluginZipResult(KOPluginZipImportStatusFailed, nil, @"No active iOS window.");
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
    KOSetEnv(@"KO_IOS_APPLICATION_SUPPORT_PATH", KOPathForDirectory(NSApplicationSupportDirectory));
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
