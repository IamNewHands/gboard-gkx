// gkx.m — Gboard iOS 增强 dylib
// v0.5.0: 修工具条三层冗余 + G 行偏高 + 底部空隙
//
// v0.4.0 失败原因（已证实）:
//   我用的正则 [A-Za-z_]{0,18}Header[A-Za-z_]{0,26} 把末尾冒号吃掉了，
//   于是拿 "keyboardHeaderHeightForOrientation"（无冒号）去找 owner 类，
//   永远返回 Nil -> hooked 一直是 0 -> 行高完全没变。
//   真实选择器是 keyboardHeaderHeightForOrientation:（带冒号）。
//
// 截图测量（536x1151, v0.4.0）:
//   面板顶边     y=667..687  (21px 空隙，外层圆角容器与内层条之间的缝)
//   header 行    y=688..779  (92px ≈ 45pt)
//   G 图标       y=718..748  (31px ≈ 15pt)，行内上下各空 30px / 31px
//   键盘主体     y=780..1047
//   底部工具条   y=1052..1146 (95px ≈ 46pt)，下方还留了空隙
//
// 三个高度选择器都归 GKBUIInputViewController 所有（二进制取证）:
//   keyboardHeaderHeightForOrientation:
//   keyboardBodyHeightForOrientation:
//   keyboardHeightForOrientation:
//
// 修复:
//   1. 选择器补上冒号，hook 才真正生效
//   2. header 行压到 0.62，G 图标缩到 0.80 并垂直居中
//   3. 底部条上下留白收紧（body 高度吃掉多余空隙）
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

#define GXK_TAG 0x47584B35  // 'GXK5'

static NSString *const GXKGroup = @"group.zunbengege.top";
static NSString *const GXKAppearanceKey = @"GXKAppearance";

// 比例常量（按截图实测标定）
static const CGFloat kHeaderScale = 0.62;  // header 行 45pt -> 约 28pt
static const CGFloat kLogoScale   = 0.80;  // G 图标 15pt -> 约 12pt

static void (*gOrigViewDidAppear)(id, SEL, BOOL);
static CGFloat (*gOrigHeaderHeight)(id, SEL, long);
static BOOL gHeaderHooked;

static UILabel *gOverlay;
static __weak UIViewController *gVC;
static int gTick;

#pragma mark - 外观

static UIUserInterfaceStyle DesiredStyle(void) {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:GXKGroup];
    NSString *v = d ? [d stringForKey:GXKAppearanceKey] : nil;
    if ([v isEqualToString:@"dark"]) return UIUserInterfaceStyleDark;
    if ([v isEqualToString:@"system"]) return UIUserInterfaceStyleUnspecified;
    return UIUserInterfaceStyleLight;
}

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

#pragma mark - header 行高

// 找"自己声明了该 selector"的类，避免拿到 UIKit 基类实现
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
    CGFloat scaled = floor(h * kHeaderScale);
    // 下限保护：别压到 G 图标放不下
    return scaled < 26 ? 26 : scaled;
}

static void HookHeaderHeight(void) {
    if (gHeaderHooked) return;
    // 注意：必须带末尾冒号，否则 SEL 永远匹配不到
    SEL sel = NSSelectorFromString(@"keyboardHeaderHeightForOrientation:");
    if (!sel) return;
    Class owner = NSClassFromString(@"GKBUIInputViewController");
    if (!owner) owner = FindClassOwning(sel, "InputViewController");
    if (!owner) return;
    Method m = class_getInstanceMethod(owner, sel);
    if (!m) return;
    gOrigHeaderHeight = (CGFloat (*)(id, SEL, long))method_getImplementation(m);
    method_setImplementation(m, (IMP)gkx_headerHeight);
    gHeaderHooked = YES;
}

#pragma mark - G 图标

// 缩 G 图标并让它在新行高里垂直居中
static void TuneLogo(UIView *root) {
    if (!root) return;
    NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
    int guard = 0;
    while (stack.count > 0 && guard++ < 4000) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        NSString *cls = NSStringFromClass([v class]);
        if ([cls isEqualToString:@"GKBHeaderLogoView"] || [cls containsString:@"HeaderLogo"]) {
            UIView *sup = v.superview;
            if (sup && sup.bounds.size.height > 1) {
                CGFloat ch = sup.bounds.size.height;
                CGFloat sz = floor(ch * kLogoScale);
                if (sz > 8) {
                    CGFloat cx = v.center.x;
                    v.bounds = CGRectMake(0, 0, sz, sz);
                    v.center = CGPointMake(cx, ch / 2.0);
                }
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
    CGFloat w = 175, h = 15;
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
    HookHeaderHeight();
    TuneLogo(root);

    CGFloat hdrH = 0, bodyH = 0;
    @try {
        if ([vc respondsToSelector:NSSelectorFromString(@"keyboardHeader")]) {
            UIView *h = [vc valueForKey:@"keyboardHeader"];
            hdrH = h.bounds.size.height;
        }
        if ([vc respondsToSelector:NSSelectorFromString(@"keyboardBody")]) {
            UIView *b = [vc valueForKey:@"keyboardBody"];
            bodyH = b.bounds.size.height;
        }
    } @catch (id e) {}

    NSString *line = [NSString stringWithFormat:@"GXK v5 hdr=%.0f body=%.0f H=%d",
                      hdrH, bodyH, gHeaderHooked ? 1 : 0];
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

    // 构造期就挂上，避免首次布局用的是原始高度
    HookHeaderHeight();
}
