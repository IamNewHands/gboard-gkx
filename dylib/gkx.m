// gkx.m — Gboard iOS 增强 dylib
// v0.7.0: 按运行时日志实测数据修布局
//
// 日志（v0.6.0-diag）给出的事实，推翻了前几版全部假设:
//   1. SEL keyboardHeaderHeightForOrientation: -> (none)
//      没有任何类实现这个选择器，字符串只是二进制残留。
//      所以 v0.4/v0.5 去 hook 它永远失败（H=0 就是这么来的）。
//   2. 顶部真实结构（402x276 总计）:
//        _keyboardHeader <GKBKeyboardViewContainerView> 402x22   y=0
//        _keyboardBody   <GKBKeyboardViewContainerView> 402x254  y=22
//        候选行 GKBNibView 402x44@0,4  （空的时候只有 G 图标 -> "两层"）
//        键盘行 GKBNibView 402x206@0,48
//   3. GKBHeaderLogoView 402x26@0,0  占满全宽 -> "G 那行太宽"
//      其子视图 UIView 36x36@10,17 溢出父视图，画到候选行里
//   4. 麦克风 = GKBPinyinComposingView 内的 GKBSoftKeyView 26x26@366,0
//
// 本版做的:
//   a. 不再 hook 不存在的选择器
//   b. 全宽 GKBHeaderLogoView 收窄成 56pt，并把内部图标夹进 22pt 行内
//   c. 隐藏麦克风按钮
//   d. 候选行为空时折叠它，键盘行上移，整体高度同步收缩（去掉"两层"和底部空隙）
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

// 布局常量（按日志实测值标定）
static const CGFloat kHeaderLogoW   = 56.0;  // 全宽 402 -> 56
static const CGFloat kCandRowH      = 44.0;  // 空候选行原始高度
static const CGFloat kKeysOffsetY   = 48.0;  // 键盘行在 body 内的原始 y
static const CGFloat kCandOffsetY   = 4.0;   // 候选行在 body 内的原始 y

static void (*gOrigViewDidAppear)(id, SEL, BOOL);

static UITextView *gPanel;
static NSMutableString *gReport;
static __weak UIViewController *gVC;
static int gPass;

// 折叠状态（只在状态变化时动，避免和 Gboard 自己的布局打架）
static BOOL gCollapsed;
static CGFloat gOrigBodyH, gOrigViewH;

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

#pragma mark - 遍历工具

static NSArray<UIView *> *AllViews(UIView *root) {
    NSMutableArray *out = [NSMutableArray array];
    NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
    int guard = 0;
    while (stack.count > 0 && guard++ < 5000) {
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

#pragma mark - 布局修复

// b. 全宽 G 视图收窄，内部图标夹进行高
static NSInteger FixLogo(UIView *root) {
    NSInteger n = 0;
    for (UIView *v in AllViews(root)) {
        if (![NSStringFromClass([v class]) isEqualToString:@"GKBHeaderLogoView"]) continue;
        CGRect f = v.frame;
        if (f.size.width <= 120) continue;      // 已经是窄的那个（候选行里的 56x44）
        // 收窄到 56pt，保持左对齐
        v.frame = CGRectMake(f.origin.x, f.origin.y, kHeaderLogoW, f.size.height);
        // 内部图标夹进父视图可见范围并居中
        CGFloat ph = f.size.height;
        for (UIView *kid in v.subviews) {
            CGRect kf = kid.frame;
            if (kf.size.height <= ph) continue;
            CGFloat scale = ph / kf.size.height;
            kid.transform = CGAffineTransformMakeScale(scale, scale);
            kid.center = CGPointMake(CGRectGetMidX(kid.superview.bounds),
                                     CGRectGetMidY(kid.superview.bounds));
        }
        n++;
    }
    return n;
}

// c. 隐藏麦克风
static NSInteger KillMic(UIView *root) {
    NSInteger n = 0;
    for (UIView *v in AllViews(root)) {
        if (![NSStringFromClass([v class]) containsString:@"ComposingView"]) continue;
        for (UIView *kid in v.subviews) {
            if (![NSStringFromClass([kid class]) isEqualToString:@"GKBSoftKeyView"]) continue;
            if (kid.hidden) continue;
            kid.hidden = YES;
            n++;
        }
    }
    return n;
}

// d. 空候选行折叠
static BOOL CandidatesEmpty(UIView *candNib) {
    for (UIView *v in AllViews(candNib)) {
        if (![NSStringFromClass([v class]) containsString:@"CandidatesCollectionView"]) continue;
        if (![v isKindOfClass:[UICollectionView class]]) continue;
        UICollectionView *cv = (UICollectionView *)v;
        if (cv.visibleCells.count > 0) return NO;
        if (cv.hidden) continue;
    }
    return YES;
}

static void SetCandidatesCollapsed(UIViewController *vc, UIView *root, BOOL collapse) {
    if (collapse == gCollapsed) return;

    UIView *body = nil;
    @try { body = [vc valueForKey:@"keyboardBody"]; } @catch (id e) {}

    UIView *candNib = nil, *keysNib = nil;
    UIView *keysHost = FindFirst(root, @"GKB9KeysSoftKeyboardView");
    UIView *scanRoot = keysHost ?: root;
    for (UIView *v in AllViews(scanRoot)) {
        if (![NSStringFromClass([v class]) isEqualToString:@"GKBNibView"]) continue;
        CGFloat h = v.frame.size.height;
        CGFloat y = v.frame.origin.y;
        if (h > 38 && h < 50 && y < 12) candNib = v;
        else if (h > 180 && y > 40) keysNib = v;
    }
    if (!candNib || !keysNib) return;

    if (!gCollapsed && collapse) {
        // 首次折叠前记录原始尺寸
        gOrigBodyH = body ? body.frame.size.height : 0;
        gOrigViewH = vc.view.frame.size.height;
    }

    if (collapse) {
        candNib.hidden = YES;
        keysNib.frame = CGRectMake(keysNib.frame.origin.x, kCandOffsetY,
                                   keysNib.frame.size.width, keysNib.frame.size.height);
        if (body && gOrigBodyH > 0) {
            body.frame = CGRectMake(body.frame.origin.x, body.frame.origin.y,
                                    body.frame.size.width, gOrigBodyH - kCandRowH);
        }
        if (gOrigViewH > 0) {
            vc.view.frame = CGRectMake(vc.view.frame.origin.x, vc.view.frame.origin.y,
                                       vc.view.frame.size.width, gOrigViewH - kCandRowH);
        }
    } else {
        candNib.hidden = NO;
        keysNib.frame = CGRectMake(keysNib.frame.origin.x, kKeysOffsetY,
                                   keysNib.frame.size.width, keysNib.frame.size.height);
        if (body && gOrigBodyH > 0) {
            body.frame = CGRectMake(body.frame.origin.x, body.frame.origin.y,
                                    body.frame.size.width, gOrigBodyH);
        }
        if (gOrigViewH > 0) {
            vc.view.frame = CGRectMake(vc.view.frame.origin.x, vc.view.frame.origin.y,
                                       vc.view.frame.size.width, gOrigViewH);
        }
    }
    gCollapsed = collapse;
}

static void ApplyLayoutFixes(UIViewController *vc, UIView *root) {
    NSInteger logo = FixLogo(root);
    NSInteger mic = KillMic(root);

    // 空候选行折叠：找到候选行后判断
    UIView *candNib = nil;
    UIView *keysHost = FindFirst(root, @"GKB9KeysSoftKeyboardView");
    for (UIView *v in AllViews(keysHost ?: root)) {
        if (![NSStringFromClass([v class]) isEqualToString:@"GKBNibView"]) continue;
        CGFloat h = v.frame.size.height;
        if (h > 38 && h < 50 && v.frame.origin.y < 12) { candNib = v; break; }
    }
    BOOL empty = candNib ? CandidatesEmpty(candNib) : NO;
    SetCandidatesCollapsed(vc, root, empty);

    [gReport appendFormat:@"\n== pass%d ==\nlogoW=%ld mic=%ld cand=%d collapsed=%d\n",
     gPass, (long)logo, (long)mic, empty ? 1 : 0, gCollapsed ? 1 : 0];
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

static void DumpTree(void) {
    UIViewController *vc = gVC;
    if (!vc) return;
    UIView *root = vc.view;
    [gReport appendFormat:@"root=%.0fx%.0f\n", root.frame.size.width, root.frame.size.height];
    NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
    NSMutableArray *depths = [NSMutableArray arrayWithObject:@0];
    int guard = 0;
    while (stack.count > 0 && guard++ < 3000) {
        UIView *v = stack.lastObject;
        int d = [depths.lastObject intValue];
        [stack removeLastObject];
        [depths removeLastObject];
        NSString *cls = NSStringFromClass([v class]);
        BOOL show = v.frame.size.height > 8.0 ||
                    [cls containsString:@"Header"] || [cls containsString:@"Logo"] ||
                    [cls containsString:@"Body"] || [cls containsString:@"Input"] ||
                    [cls containsString:@"Composing"] || [cls containsString:@"Globe"] ||
                    [cls containsString:@"Space"] || [cls containsString:@"Bottom"];
        if (show) {
            NSMutableString *pad = [NSMutableString string];
            for (int i = 0; i < d && i < 9; i++) [pad appendString:@" "];
            [gReport appendFormat:@"%@%@ %.0fx%.0f@%.0f,%.0f%s\n",
             pad, cls, v.frame.size.width, v.frame.size.height,
             v.frame.origin.x, v.frame.origin.y, v.hidden ? " H" : ""];
        }
        NSArray *kids = v.subviews;
        for (NSInteger i = (NSInteger)kids.count - 1; i >= 0; i--) {
            [stack addObject:kids[i]];
            [depths addObject:@(d + 1)];
        }
    }
}

static void RenderPanel(UIView *host) {
    if (!host) return;
    if (!gPanel) {
        gPanel = [[UITextView alloc] initWithFrame:CGRectZero];
        gPanel.editable = NO;
        gPanel.scrollEnabled = YES;
        gPanel.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.95];
        gPanel.textColor = [UIColor colorWithRed:0.6 green:1.0 blue:0.6 alpha:1.0];
        gPanel.font = [UIFont monospacedSystemFontOfSize:8.0 weight:UIFontWeightRegular];
        gPanel.layer.zPosition = 20000;
        gPanel.textContainerInset = UIEdgeInsetsMake(4, 4, 4, 4);
        GXKPanelTap *t = [[GXKPanelTap alloc] init];
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:t action:@selector(handle:)];
        [gPanel addGestureRecognizer:tap];
        objc_setAssociatedObject(gPanel, "gxk_tap", t, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    gPanel.text = gReport;
    gPanel.contentOffset = CGPointZero;
    if (gPanel.superview != host) {
        [gPanel removeFromSuperview];
        [host addSubview:gPanel];
    }
    // 只占上方 45%，键盘仍可见
    gPanel.frame = CGRectMake(0, 0, host.bounds.size.width, host.bounds.size.height * 0.45);
    [host bringSubviewToFront:gPanel];
}

static void Pass(void) {
    UIViewController *vc = gVC;
    if (!vc) return;
    UIView *root = vc.view;
    if (!root) return;
    ApplyAppearance(root, DesiredStyle());
    gPass++;
    ApplyLayoutFixes(vc, root);
    DumpTree();
    RenderPanel(root.window ?: root);
}

static void gkx_viewDidAppear(id self, SEL _cmd, BOOL animated) {
    if (gOrigViewDidAppear) gOrigViewDidAppear(self, _cmd, animated);
    gVC = (UIViewController *)self;
    gReport = [NSMutableString stringWithFormat:@"GXK v7  %@\n", NSStringFromClass([self class])];
    gPass = 0;
    gCollapsed = NO;
    gOrigBodyH = 0;
    gOrigViewH = 0;

    static const int64_t delays[] = {600, 1600, 3000};
    for (int i = 0; i < 3; i++) {
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
