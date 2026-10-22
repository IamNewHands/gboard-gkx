// gkx.m — Gboard iOS 增强 dylib
// v0.3.0: 修复黑色键盘。
//
// 结论依据（v0.2.0-diag 截图 + 二进制取证）:
//   1. vc.view 的直接子视图是 UIImageView + 两个 UIInputViewContent + UIView
//   2. UIInputViewContent 是 UIKit 私有键盘背景层，按 traitCollection 绘制，
//      不读 Gboard 的 KeyboardThemeId
//   3. GKBGboardAppResources.bundle/theme.plist 只定义 theme_default / theme_dark，
//      没有"浅色主题"这个可选值 -> Gboard 设置里切不出白键盘
// 因此修复点不在主题键，而在强制浅色外观 + 背景层兜底。
//
// 构建: clang -dynamiclib -arch arm64 -miphoneos-version-min=12.0
// 注入: tools/inject.py 给 Gboard.appex/Gboard 加 LC_LOAD_DYLIB @rpath/libgkx.dylib

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>

#define GXK_TAG 0x47584B33  // 'GXK3'

// 本构建里 framework 的 app group 字符串已被改写为该名字
static NSString *const GXKGroup = @"group.zunbengege.top";
// 外观偏好键: "light"(默认) / "dark" / "system"
static NSString *const GXKAppearanceKey = @"GXKAppearance";

static void (*gOrigViewDidAppear)(id, SEL, BOOL);

static UILabel *gOverlay;
static __weak UIViewController *gVC;
static int gTick;
static NSUInteger gInputBgCount;

#pragma mark - 外观

static NSString *StyleName(UIUserInterfaceStyle s) {
    switch (s) {
        case UIUserInterfaceStyleLight: return @"light";
        case UIUserInterfaceStyleDark:  return @"dark";
        default: return @"unspec";
    }
}

static UIUserInterfaceStyle DesiredStyle(void) {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:GXKGroup];
    NSString *v = d ? [d stringForKey:GXKAppearanceKey] : nil;
    if ([v isEqualToString:@"dark"]) return UIUserInterfaceStyleDark;
    if ([v isEqualToString:@"system"]) return UIUserInterfaceStyleUnspecified;
    return UIUserInterfaceStyleLight;
}

// 只对根视图、window 和键盘背景层设置 override，避免改动 Gboard 自己的键帽配色逻辑
static void ApplyAppearance(UIView *root, UIUserInterfaceStyle style) {
    if (!root) return;
    if (@available(iOS 13.0, *)) {
        if (root.overrideUserInterfaceStyle != style) {
            root.overrideUserInterfaceStyle = style;
        }
        UIWindow *win = root.window;
        if (win && win.overrideUserInterfaceStyle != style) {
            win.overrideUserInterfaceStyle = style;
        }
    }

    NSUInteger hits = 0;
    NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
    int guard = 0;
    while (stack.count > 0 && guard++ < 4000) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        NSString *cls = NSStringFromClass([v class]);
        BOOL isBg = [cls containsString:@"InputViewContent"] || [cls isEqualToString:@"UIInputView"];
        if (isBg) {
            hits++;
            if (@available(iOS 13.0, *)) {
                if (v.overrideUserInterfaceStyle != style) {
                    v.overrideUserInterfaceStyle = style;
                }
            }
            // 兜底: 若该层没有自己的背景图，直接给浅色底
            if ([v isKindOfClass:[UIImageView class]]) {
                UIImageView *iv = (UIImageView *)v;
                if (!iv.image) {
                    iv.backgroundColor = [UIColor colorWithWhite:0.94 alpha:1.0];
                }
            } else if (!v.backgroundColor) {
                v.backgroundColor = [UIColor colorWithWhite:0.94 alpha:1.0];
            }
        }
        [stack addObjectsFromArray:v.subviews];
    }
    gInputBgCount = hits;
}

// 诊断用: 键盘背景图是否存在及尺寸（资源缺失会返回 nil）
static NSString *BgInfo(UIView *root) {
    if (!root) return @"-";
    NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
    int guard = 0;
    while (stack.count > 0 && guard++ < 4000) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        if ([v isKindOfClass:[UIImageView class]]) {
            UIImage *img = ((UIImageView *)v).image;
            if (!img) return @"nil";
            return [NSString stringWithFormat:@"%.0fx%.0f", img.size.width, img.size.height];
        }
        [stack addObjectsFromArray:v.subviews];
    }
    return @"-";
}

#pragma mark - 诊断条

static void ShowOverlay(NSString *text, UIView *host) {
    if (!host) return;
    if (!gOverlay || gOverlay.superview != host) {
        [gOverlay removeFromSuperview];
        gOverlay = [[UILabel alloc] initWithFrame:CGRectZero];
        gOverlay.tag = GXK_TAG;
        gOverlay.numberOfLines = 1;
        gOverlay.font = [UIFont boldSystemFontOfSize:9.0];
        gOverlay.textColor = [UIColor whiteColor];
        gOverlay.backgroundColor = [UIColor colorWithRed:0.0 green:0.45 blue:0.0 alpha:0.92];
        gOverlay.textAlignment = NSTextAlignmentCenter;
        gOverlay.userInteractionEnabled = NO;
        gOverlay.layer.zPosition = 10000;
        [host addSubview:gOverlay];
    }
    gOverlay.frame = CGRectMake(0, 0, host.bounds.size.width, 24);
    gOverlay.text = text;
    [host bringSubviewToFront:gOverlay];
}

static void Refresh(void) {
    UIViewController *vc = gVC;
    if (!vc) return;
    UIView *root = vc.view;
    UIView *host = root.window ?: root;
    if (!root || !host) return;

    UIUserInterfaceStyle want = DesiredStyle();
    ApplyAppearance(root, want);

    UIUserInterfaceStyle sysStyle = UIUserInterfaceStyleUnspecified;
    if (@available(iOS 13.0, *)) {
        sysStyle = host.traitCollection.userInterfaceStyle;
    }

    NSString *line = [NSString stringWithFormat:@"GXK v3 %@->%@ bg=%@ n=%lu",
                      StyleName(sysStyle), StyleName(want), BgInfo(root),
                      (unsigned long)gInputBgCount];
    ShowOverlay(line, host);
}

static void ScheduleRefresh(void) {
    static const int64_t delays[] = {0, 120, 400, 900, 1500};
    if (gTick >= (int)(sizeof(delays) / sizeof(delays[0]))) {
        // 诊断条 6 秒后自动撤掉，不长期遮挡键盘
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [gOverlay removeFromSuperview];
        });
        return;
    }
    int64_t ms = delays[gTick++];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, ms * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        Refresh();
        ScheduleRefresh();
    });
}

static void gkx_viewDidAppear(id self, SEL _cmd, BOOL animated) {
    if (gOrigViewDidAppear) {
        gOrigViewDidAppear(self, _cmd, animated);
    }
    gVC = (UIViewController *)self;
    gTick = 0;
    ScheduleRefresh();
}

#pragma mark - 入口

__attribute__((constructor))
static void gkx_init(void) {
    // 只有键盘扩展进程里才有这些类；主 App 里不挂任何 UI
    Class base = NSClassFromString(@"GKBInputViewControllerBase");
    Class principal = NSClassFromString(@"GKBUIInputViewController");
    if (!base && !principal) return;

    Class target = base ?: principal;
    Method m = class_getInstanceMethod(target, @selector(viewDidAppear:));
    if (!m) return;
    gOrigViewDidAppear = (void (*)(id, SEL, BOOL))method_getImplementation(m);
    method_setImplementation(m, (IMP)gkx_viewDidAppear);
}
