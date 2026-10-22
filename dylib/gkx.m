// gkx.m — Gboard iOS 增强 dylib
// Phase 0.5: 诊断版。键盘顶部显示运行时状态，用来定位「黑色键盘 + 看不到标记」的原因。
//
// 构建：clang -dynamiclib -arch arm64 -miphoneos-version-min=12.0
// 注入：tools/inject.py 给 Gboard.appex/Gboard 加 LC_LOAD_DYLIB @rpath/libgkx.dylib

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>

#define GXK_TAG 0x47584B32  // 'GXK2'

// 本构建里 framework 的 app group 字符串已被改写为该名字
static NSString *const GXKGroup = @"group.zunbengege.top";
// Gboard 主题键（来自 gboard_framework 的 kGKBKeyboardThemeId）
static NSString *const GXKThemeKey = @"KeyboardThemeId";
static NSString *const GXKDefaultTheme = @"theme_default";

static void (*gOrigViewDidAppear)(id, SEL, BOOL);

static UILabel *gOverlay;
static __weak UIViewController *gVC;
static int gRefreshTick;

static NSString *Short(NSString *s) {
    if (!s) return @"(nil)";
    if (s.length <= 34) return s;
    return [[s substringToIndex:31] stringByAppendingString:@"..."];
}

static NSString *TreeLine(UIView *root) {
    NSMutableArray *parts = [NSMutableArray array];
    NSArray *kids = root.subviews;
    for (NSUInteger i = 0; i < kids.count && i < 4; i++) {
        UIView *v = kids[i];
        [parts addObject:[NSString stringWithFormat:@"%@(%lu)",
                          NSStringFromClass([v class]),
                          (unsigned long)v.subviews.count]];
    }
    if (parts.count == 0) return @"<empty>";
    return [parts componentsJoinedByString:@" "];
}

static NSString *DefaultsTheme(NSString *suite) {
    NSUserDefaults *d = suite ? [[NSUserDefaults alloc] initWithSuiteName:suite]
                              : [NSUserDefaults standardUserDefaults];
    if (!d) return @"(nosuite)";
    id v = [d objectForKey:GXKThemeKey];
    if (!v) return @"(nil)";
    if ([v isKindOfClass:[NSString class]]) return Short((NSString *)v);
    return Short([v description]);
}

static void RefreshOverlay(void) {
    UIViewController *vc = gVC;
    if (!vc) return;
    UIView *host = vc.view.window;
    if (!host) host = vc.view;
    if (!host) return;

    NSMutableString *t = [NSMutableString string];
    [t appendFormat:@"GXK v2 OK  %@\n", Short(NSStringFromClass([vc class]))];
    [t appendFormat:@"theme grp=%@ std=%@\n", DefaultsTheme(GXKGroup), DefaultsTheme(nil)];

    UIView *body = nil, *head = nil;
    @try {
        if ([vc respondsToSelector:NSSelectorFromString(@"keyboardBody")]) {
            body = [vc valueForKey:@"keyboardBody"];
        }
        if ([vc respondsToSelector:NSSelectorFromString(@"keyboardHeader")]) {
            head = [vc valueForKey:@"keyboardHeader"];
        }
    } @catch (id e) {}

    [t appendFormat:@"body=%@ n=%lu  head=%@ n=%lu\n",
     body ? NSStringFromClass([body class]) : @"-",
     body ? (unsigned long)body.subviews.count : 0UL,
     head ? NSStringFromClass([head class]) : @"-",
     head ? (unsigned long)head.subviews.count : 0UL];
    [t appendFormat:@"tree: %@", TreeLine(vc.view)];

    if (!gOverlay || gOverlay.superview != host) {
        [gOverlay removeFromSuperview];
        gOverlay = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, host.bounds.size.width, 62)];
        gOverlay.tag = GXK_TAG;
        gOverlay.numberOfLines = 0;
        gOverlay.font = [UIFont boldSystemFontOfSize:8.0];
        gOverlay.textColor = [UIColor colorWithRed:0.55 green:1.0 blue:0.60 alpha:1.0];
        gOverlay.backgroundColor = [UIColor colorWithRed:0 green:0 blue:0 alpha:0.82];
        gOverlay.userInteractionEnabled = NO;
        gOverlay.layer.zPosition = 10000;
        [host addSubview:gOverlay];
    }
    gOverlay.frame = CGRectMake(0, 0, host.bounds.size.width, 62);
    gOverlay.text = t;
    [host bringSubviewToFront:gOverlay];
}

static void ScheduleRefresh(void) {
    static const int64_t delays[] = {0, 200, 700, 1600};
    if (gRefreshTick >= 4) return;
    int64_t ms = delays[gRefreshTick++];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, ms * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        RefreshOverlay();
        ScheduleRefresh();
    });
}

static void gkx_viewDidAppear(id self, SEL _cmd, BOOL animated) {
    if (gOrigViewDidAppear) {
        gOrigViewDidAppear(self, _cmd, animated);
    }
    gVC = (UIViewController *)self;
    gRefreshTick = 0;
    ScheduleRefresh();
}

static void SeedThemeIfMissing(void) {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:GXKGroup];
    if (!d) return;
    if ([d objectForKey:GXKThemeKey]) return;
    [d setObject:GXKDefaultTheme forKey:GXKThemeKey];
    [d synchronize];
}

__attribute__((constructor))
static void gkx_init(void) {
    // 只有键盘扩展进程里才有这个类；主 App 里不会挂任何 UI
    Class base = NSClassFromString(@"GKBInputViewControllerBase");
    Class principal = NSClassFromString(@"GKBUIInputViewController");
    if (!base && !principal) return;

    SeedThemeIfMissing();

    Class target = base ?: principal;
    Method m = class_getInstanceMethod(target, @selector(viewDidAppear:));
    if (!m) return;
    gOrigViewDidAppear = (void (*)(id, SEL, BOOL))method_getImplementation(m);
    method_setImplementation(m, (IMP)gkx_viewDidAppear);
}
