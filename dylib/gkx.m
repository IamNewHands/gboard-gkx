// gkx.m — Gboard iOS 增强 dylib
// v0.4.0: 修复皮肤四角 + 收窄 G 图标行
//
// 取证（v0.3.0 截图逐像素测量，684x1479）:
//   1. 绿色诊断条位于 y=886..923、x=3..右边，正好覆盖键盘面板顶部约 24pt 的圆角区
//      -> 四角变直角是全宽覆盖层造成的，不是 Gboard 皮肤问题
//      底部圆角完好（半径约 40px），说明面板本身圆角正常
//   2. header 行 y=927..1004 高 77px(约45pt)，G 图标仅 y=926..961 高 36px(约21pt)
//      -> 图标贴顶、下方空 42px，这是"G 那行太宽"的来源
//
// 修复:
//   - 诊断条改成居中圆角胶囊并自动隐藏，不再贴边 -> 四角恢复
//   - 去掉背景色兜底（浅色 override 已足够，兜底反而会盖掉圆角）
//   - hook keyboardHeaderHeightForOrientation: 收窄 header 行
//   - 缩放 GKBHeaderLogoView，让 G 图标与新行高协调
//
// 构建: clang -dynamiclib -arch arm64 -miphoneos-version-min=12.0
// 注入: tools/inject.py 给 Gboard.appex/Gboard 加 LC_LOAD_DYLIB @rpath/libgkx.dylib

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>
#import <string.h>
#import <stdlib.h>
#import <math.h>

#define GXK_TAG 0x47584B34  // 'GXK4'

// 本构建里 framework 的 app group 字符串已被改写为该名字
static NSString *const GXKGroup = @"group.zunbengege.top";
// 外观偏好键: "light"(默认) / "dark" / "system"
static NSString *const GXKAppearanceKey = @"GXKAppearance";

// header 行收窄比例（原约45pt -> 约33pt）
static const CGFloat kHeaderScale = 0.74;
// G 图标缩放比例
static const CGFloat kLogoScale = 0.88;

static void (*gOrigViewDidAppear)(id, SEL, BOOL);
static CGFloat (*gOrigHeaderHeight)(id, SEL, long);

static UILabel *gOverlay;
static __weak UIViewController *gVC;
static int gTick;
static BOOL gHeaderHooked;

#pragma mark - 外观

static UIUserInterfaceStyle DesiredStyle(void) {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:GXKGroup];
    NSString *v = d ? [d stringForKey:GXKAppearanceKey] : nil;
    if ([v isEqualToString:@"dark"]) return UIUserInterfaceStyleDark;
    if ([v isEqualToString:@"system"]) return UIUserInterfaceStyleUnspecified;
    return UIUserInterfaceStyleLight;
}

// 只对根视图、window、键盘背景层设 override，不动 Gboard 自己的键帽配色
static void ApplyAppearance(UIView *root, UIUserInterfaceStyle style) {
    if (!root) return;
    if (@available(iOS 13.0, *)) {
        if (root.overrideUserInterfaceStyle != style) root.overrideUserInterfaceStyle = style;
        UIWindow *win = root.window;
        if (win && win.overrideUserInterfaceStyle != style) win.overrideUserInterfaceStyle = style;
    }
    NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
    int guard = 0;
    while (stack.count > 0 && guard++ < 4000) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        NSString *cls = NSStringFromClass([v class]);
        if ([cls containsString:@"InputViewContent"] || [cls isEqualToString:@"UIInputView"]) {
            if (@available(iOS 13.0, *)) {
                if (v.overrideUserInterfaceStyle != style) v.overrideUserInterfaceStyle = style;
            }
        }
        [stack addObjectsFromArray:v.subviews];
    }
}

#pragma mark - G 图标行

// 找到"自己声明了该 selector"的类（避免拿到 UIKit 基类的实现）
static Class FindClassOwning(SEL sel, const char *hint) {
    int n = objc_getClassList(NULL, 0);
    if (n <= 0) return Nil;
    Class *list = (Class *)malloc(sizeof(Class) * (size_t)n);
    if (!list) return Nil;
    objc_getClassList(list, n);
    Class result = Nil;
    for (int i = 0; i < n && !result; i++) {
        Class c = list[i];
        const char *name = class_getName(c);
        if (!name) continue;
        if (hint && !strstr(name, hint)) continue;
        unsigned int mc = 0;
        Method *ms = class_copyMethodList(c, &mc);
        for (unsigned int j = 0; j < mc; j++) {
            if (method_getName(ms[j]) == sel) { result = c; break; }
        }
        if (ms) free(ms);
    }
    free(list);
    return result;
}

static CGFloat gkx_headerHeight(id self, SEL _cmd, long orientation) {
    CGFloat h = gOrigHeaderHeight ? gOrigHeaderHeight(self, _cmd, orientation) : 0;
    if (h <= 0) return h;
    return floor(h * kHeaderScale);
}

static void HookHeaderHeight(void) {
    if (gHeaderHooked) return;
    SEL sel = NSSelectorFromString(@"keyboardHeaderHeightForOrientation");
    if (!sel) return;
    Class owner = FindClassOwning(sel, "InputViewController");
    if (!owner) owner = FindClassOwning(sel, "GKB");
    if (!owner) return;
    Method m = class_getInstanceMethod(owner, sel);
    if (!m) return;
    gOrigHeaderHeight = (CGFloat (*)(id, SEL, long))method_getImplementation(m);
    method_setImplementation(m, (IMP)gkx_headerHeight);
    gHeaderHooked = YES;
}

// 缩小 G 图标并让它在新行高里协调
static void ShrinkLogo(UIView *root) {
    if (!root) return;
    NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
    int guard = 0;
    while (stack.count > 0 && guard++ < 4000) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        NSString *cls = NSStringFromClass([v class]);
        if ([cls isEqualToString:@"GKBHeaderLogoView"] || [cls containsString:@"HeaderLogo"]) {
            if (CGAffineTransformIsIdentity(v.transform)) {
                v.transform = CGAffineTransformMakeScale(kLogoScale, kLogoScale);
            }
        }
        [stack addObjectsFromArray:v.subviews];
    }
}

#pragma mark - 诊断胶囊

static void ShowOverlay(NSString *text, UIView *host) {
    if (!host) return;
    if (!gOverlay || gOverlay.superview != host) {
        [gOverlay removeFromSuperview];
        gOverlay = [[UILabel alloc] initWithFrame:CGRectZero];
        gOverlay.tag = GXK_TAG;
        gOverlay.numberOfLines = 1;
        gOverlay.font = [UIFont boldSystemFontOfSize:8.0];
        gOverlay.textColor = [UIColor whiteColor];
        gOverlay.backgroundColor = [UIColor colorWithRed:0.0 green:0.42 blue:0.0 alpha:0.85];
        gOverlay.textAlignment = NSTextAlignmentCenter;
        gOverlay.userInteractionEnabled = NO;
        gOverlay.clipsToBounds = YES;
        gOverlay.layer.zPosition = 10000;
        [host addSubview:gOverlay];
    }
    CGFloat w = 170, h = 15;
    gOverlay.layer.cornerRadius = h / 2.0;
    gOverlay.frame = CGRectMake((host.bounds.size.width - w) / 2.0, 4, w, h);
    gOverlay.text = text;
    [host bringSubviewToFront:gOverlay];
}

static void Refresh(void) {
    UIViewController *vc = gVC;
    if (!vc) return;
    UIView *root = vc.view;
    UIView *host = root.window ?: root;
    if (!root || !host) return;

    ApplyAppearance(root, DesiredStyle());
    ShrinkLogo(root);
    HookHeaderHeight();

    CGFloat headerH = 0;
    if ([vc respondsToSelector:NSSelectorFromString(@"keyboardHeader")]) {
        @try {
            UIView *h = [vc valueForKey:@"keyboardHeader"];
            headerH = h.bounds.size.height;
        } @catch (id e) {}
    }
    NSString *line = [NSString stringWithFormat:@"GXK v4 hdr=%.0f hooked=%d",
                      headerH, gHeaderHooked ? 1 : 0];
    ShowOverlay(line, host);
}

static void ScheduleRefresh(void) {
    static const int64_t delays[] = {0, 150, 500, 1200};
    if (gTick >= (int)(sizeof(delays) / sizeof(delays[0]))) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)),
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
    if (gOrigViewDidAppear) gOrigViewDidAppear(self, _cmd, animated);
    gVC = (UIViewController *)self;
    gTick = 0;
    ScheduleRefresh();
}

#pragma mark - 入口

__attribute__((constructor))
static void gkx_init(void) {
    Class base = NSClassFromString(@"GKBInputViewControllerBase");
    Class principal = NSClassFromString(@"GKBUIInputViewController");
    if (!base && !principal) return;

    Class target = base ?: principal;
    Method m = class_getInstanceMethod(target, @selector(viewDidAppear:));
    if (!m) return;
    gOrigViewDidAppear = (void (*)(id, SEL, BOOL))method_getImplementation(m);
    method_setImplementation(m, (IMP)gkx_viewDidAppear);
}
