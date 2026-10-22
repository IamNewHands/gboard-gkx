// gkx.m — Gboard iOS 增强 dylib
// v0.9.0: 修 v0.8.0 的过度上移（G 图标被顶出屏幕）+ 关闭底部空隙
//
// v0.8.0 日志暴露的问题（实测）:
//   collapsed=1  候选行折叠成功（这一项对了）
//   但 pass1 树里:
//     UIView 402x22@0,-44    <- header 容器被顶到 -44，G 图标完全出屏
//     UIView 402x254@0,-22   <- body 容器仍 254，且在 -22
//     GKBNibView 402x206@0,4 <- 键盘行在 body 内 y=4
//   CHAIN0 UIInputView 402x232 与 CHAIN1..5 全是 402x276
//
// 根因: 内容总高 22+254=276 大于 vc.view 的 232，而内容在 vc.view 内是
// 底部对齐（bottom-anchored）的 -> 溢出量 44 全部堆到顶部，
// header 被推到 -44、body 被推到 -22，底部反而留出 44pt 空隙。
// 我只缩了 vc.view，没有缩父链，所以溢出与空隙同时出现。
//
// 本版做法: 让"内容高度 == 容器高度 == 父链高度"，三者一起减 44
//   1. 候选行保持折叠（已验证有效）
//   2. body 容器高度 254 -> 210，键盘行 y=4
//   3. header 容器显式钉在 y=0，body 容器钉在 y=22
//   4. vc.view 与父链（UIView/_UIDropShadowClippingView/UIDropShadowView）
//      一起底部锚定地减 44：y += 44, h -= 44 -> 底部空隙随之消失
//   5. 打印 window 完整子树，定位底部小地球/麦克风行到底归谁
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

static NSString *const GXKGroup = @"group.zunbengege.top";
static NSString *const GXKAppearanceKey = @"GXKAppearance";

static const CGFloat kDelta      = 44.0;  // 候选行高度
static const CGFloat kHeaderH    = 22.0;
static const CGFloat kKeysOffsetY = 4.0;

static void (*gOrigViewDidAppear)(id, SEL, BOOL);

static UITextView *gPanel;
static NSMutableString *gReport;
static __weak UIViewController *gVC;
static int gPass;
static BOOL gApplied;

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
    while (stack.count > 0 && guard++ < 5000) {
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

#pragma mark - 遍历

static NSArray<UIView *> *AllViews(UIView *root) {
    NSMutableArray *out = [NSMutableArray array];
    NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
    int guard = 0;
    while (stack.count > 0 && guard++ < 8000) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        [out addObject:v];
        [stack addObjectsFromArray:v.subviews];
    }
    return out;
}

static UIView *FindFirst(UIView *root, NSString *needle) {
    for (UIView *v in AllViews(root)) {
        if ([NSStringFromClass([v class]) containsString:needle]) return v;
    }
    return nil;
}

#pragma mark - 布局

// 底部锚定收缩：y += d, h -= d（保持底边不动）
static void ShrinkBottomAnchored(UIView *v, CGFloat d) {
    if (!v) return;
    CGRect f = v.frame;
    if (f.size.height <= d + 1) return;
    v.frame = CGRectMake(f.origin.x, f.origin.y + d, f.size.width, f.size.height - d);
}

static NSInteger FixLogo(UIView *root) {
    NSInteger n = 0;
    for (UIView *v in AllViews(root)) {
        if (![NSStringFromClass([v class]) isEqualToString:@"GKBHeaderLogoView"]) continue;
        CGRect f = v.frame;
        if (f.size.width > 120) {
            v.frame = CGRectMake(f.origin.x, f.origin.y, 56.0, f.size.height);
            f = v.frame;
            n++;
        }
        CGFloat ph = f.size.height, pw = f.size.width;
        for (UIView *kid in v.subviews) {
            CGRect kf = kid.frame;
            BOOL inside = kf.origin.x >= 0 && kf.origin.y >= 0 &&
                          kf.size.width <= pw && kf.size.height <= ph;
            if (inside) continue;
            CGFloat sc = 1.0;
            if (kf.size.width > pw || kf.size.height > ph) {
                sc = fmin(pw / kf.size.width, ph / kf.size.height);
            }
            if (sc < 0.999) kid.transform = CGAffineTransformMakeScale(sc, sc);
            kid.center = CGPointMake(pw / 2.0, ph / 2.0);
        }
    }
    return n;
}

static NSInteger KillTopSoftKeys(UIView *root) {
    NSInteger n = 0;
    for (UIView *v in AllViews(root)) {
        if (![NSStringFromClass([v class]) isEqualToString:@"GKBSoftKeyView"]) continue;
        CGRect f = v.frame;
        if (f.size.width > 60 || f.size.height > 60) continue;
        CGPoint p = [v convertPoint:CGPointZero toView:root];
        if (p.y > 70 || p.y < -60) continue;
        if (v.hidden) continue;
        v.hidden = YES;
        n++;
    }
    return n;
}

// 核心: 内容、容器、父链三者一起减 44，并显式钉住 header/body 位置
static void Relayout(UIViewController *vc, UIView *root) {
    UIView *hdr = nil, *body = nil;
    @try {
        hdr  = [vc valueForKey:@"keyboardHeader"];
        body = [vc valueForKey:@"keyboardBody"];
    } @catch (id e) {}

    UIView *hdrC  = hdr.superview;          // 22pt 容器
    UIView *bodyC = body.superview;         // 254pt 容器
    UIView *bodyP = bodyC.superview;        // 232pt 容器

    // 候选行折叠
    UIView *candNib = nil;
    UIView *keysHost = FindFirst(root, @"GKB9KeysSoftKeyboardView") ?: root;
    UIView *keysNib = nil;
    for (UIView *v in AllViews(keysHost)) {
        if (![NSStringFromClass([v class]) isEqualToString:@"GKBNibView"]) continue;
        CGFloat h = v.frame.size.height, y = v.frame.origin.y;
        if (h > 30 && h < 60 && y < 12) candNib = v;
        else if (h > 150 && y > 30) keysNib = v;
    }
    if (candNib) candNib.hidden = YES;

    CGFloat W = root.frame.size.width;
    CGFloat newH = root.frame.size.height - kDelta;

    // 1) vc.view 减 44（底部锚定）
    if (!gApplied) {
        ShrinkBottomAnchored(root, kDelta);
        gApplied = YES;
    }

    // 2) 父链一起减 44，保持底边不动 -> 底部空隙消失
    UIView *p = root.superview;
    int lvl = 0;
    while (p && lvl < 5) {
        NSString *cls = NSStringFromClass([p class]);
        if ([cls containsString:@"Window"]) break;   // 不动窗口
        ShrinkBottomAnchored(p, kDelta);
        p = p.superview;
        lvl++;
    }

    // 3) 显式钉住 header 与 body，杜绝底部对齐溢出
    if (hdrC) hdrC.frame = CGRectMake(0, 0, W, kHeaderH);
    if (bodyP) bodyP.frame = CGRectMake(0, 0, W, newH);
    if (bodyC) bodyC.frame = CGRectMake(0, kHeaderH, W, newH - kHeaderH);
    if (body)  body.frame  = CGRectMake(0, 0, W, newH - kHeaderH);
    if (hdr)   hdr.frame   = CGRectMake(0, 0, W, kHeaderH);

    // 4) 键盘行贴到 body 顶部
    if (keysNib) {
        keysNib.frame = CGRectMake(0, kKeysOffsetY, W, keysNib.frame.size.height);
    }

    [root setNeedsLayout];
    [root layoutIfNeeded];

    [gReport appendFormat:
     @"hdrC=%.0fx%.0f@%.0f,%.0f bodyC=%.0fx%.0f@%.0f,%.0f keys=%.0fx%.0f@%.0f,%.0f\n",
     hdrC.frame.size.width, hdrC.frame.size.height, hdrC.frame.origin.x, hdrC.frame.origin.y,
     bodyC.frame.size.width, bodyC.frame.size.height, bodyC.frame.origin.x, bodyC.frame.origin.y,
     keysNib.frame.size.width, keysNib.frame.size.height,
     keysNib.frame.origin.x, keysNib.frame.origin.y];
}

#pragma mark - 诊断

static void DumpChain(UIViewController *vc) {
    UIView *v = vc.view;
    int lvl = 0;
    while (v && lvl < 7) {
        [gReport appendFormat:@"CHAIN%d %@ %.0fx%.0f@%.0f,%.0f\n", lvl,
         NSStringFromClass([v class]), v.frame.size.width, v.frame.size.height,
         v.frame.origin.x, v.frame.origin.y];
        v = v.superview; lvl++;
    }
}

// 在 window 全树里找底部小地球/麦克风行（v0.8 日志里它不在 vc.view 内）
static void FindBottomBar(UIViewController *vc) {
    UIWindow *win = vc.view.window;
    if (!win) { [gReport appendString:@"NO WINDOW\n"]; return; }
    CGFloat winH = win.bounds.size.height;
    [gReport appendFormat:@"window=%.0fx%.0f\n", win.bounds.size.width, winH];
    int shown = 0;
    for (UIView *v in AllViews(win)) {
        CGRect f = [v convertRect:v.bounds toView:win];
        NSString *cls = NSStringFromClass([v class]);
        BOOL interesting =
            (f.size.height > 20 && f.size.height < 90 && f.origin.y > winH - 140) ||
            [cls.lowercaseString containsString:@"globe"] ||
            [cls.lowercaseString containsString:@"dictat"] ||
            [cls.lowercaseString containsString:@"bottombar"];
        if (!interesting || shown >= 30) continue;
        [gReport appendFormat:@"  %@ %.0fx%.0f@%.0f,%.0f%s\n", cls,
         f.size.width, f.size.height, f.origin.x, f.origin.y, v.hidden ? " H" : ""];
        shown++;
    }
}

#pragma mark - 面板

@interface GXKPanelTap : NSObject
@end
@implementation GXKPanelTap
- (void)handle:(UITapGestureRecognizer *)g {
    if (gPanel.text.length > 0) [UIPasteboard generalPasteboard].string = gPanel.text;
    [gPanel removeFromSuperview];
}
@end

static void RenderPanel(UIView *host) {
    if (!host) return;
    if (!gPanel) {
        gPanel = [[UITextView alloc] initWithFrame:CGRectZero];
        gPanel.editable = NO;
        gPanel.scrollEnabled = YES;
        gPanel.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.95];
        gPanel.textColor = [UIColor colorWithRed:0.6 green:1.0 blue:0.6 alpha:1.0];
        gPanel.font = [UIFont monospacedSystemFontOfSize:7.5 weight:UIFontWeightRegular];
        gPanel.layer.zPosition = 20000;
        gPanel.textContainerInset = UIEdgeInsetsMake(3, 3, 3, 3);
        GXKPanelTap *t = [[GXKPanelTap alloc] init];
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:t action:@selector(handle:)];
        [gPanel addGestureRecognizer:tap];
        objc_setAssociatedObject(gPanel, "gxk_tap", t, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    gPanel.text = gReport;
    if (gPanel.superview != host) {
        [gPanel removeFromSuperview];
        [host addSubview:gPanel];
    }
    gPanel.frame = CGRectMake(0, 0, host.bounds.size.width, host.bounds.size.height * 0.5);
    [host bringSubviewToFront:gPanel];
}

static void Pass(void) {
    UIViewController *vc = gVC;
    if (!vc) return;
    UIView *root = vc.view;
    if (!root) return;
    ApplyAppearance(root, DesiredStyle());
    gPass++;
    NSInteger logo = FixLogo(root);
    NSInteger mic = KillTopSoftKeys(root);
    Relayout(vc, root);

    [gReport appendFormat:@"\n== pass%d ==\nlogoW=%ld mic=%ld view=%.0fx%.0f\n",
     gPass, (long)logo, (long)mic, root.frame.size.width, root.frame.size.height];
    DumpChain(vc);
    if (gPass == 1) FindBottomBar(vc);
    RenderPanel(root.window ?: root);
}

static void gkx_viewDidAppear(id self, SEL _cmd, BOOL animated) {
    if (gOrigViewDidAppear) gOrigViewDidAppear(self, _cmd, animated);
    gVC = (UIViewController *)self;
    gReport = [NSMutableString stringWithFormat:@"GXK v9  %@\n", NSStringFromClass([self class])];
    gPass = 0;
    gApplied = NO;
    static const int64_t delays[] = {700, 1500, 2600, 4000};
    for (int i = 0; i < 4; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delays[i] * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{ Pass(); });
    }
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
