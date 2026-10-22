// gkx.m — Gboard iOS 增强 dylib
// v1.0.0: 停止改尺寸，只折叠候选行，并打印完整视图树
//
// v0.9.0 日志暴露的真相（实测，非推断）:
//   pass1: UIInputView 402x56@0,220
//   -> vc.view 原始是 402x276@0,0，被我按 44 连缩了 5 次:
//      276->232->188->144->100->56, y: 0->44->88->132->176->220
//   而 window 里底部那条 GKBSoftKeyView 80x50@322,226 (y=226..276)
//   就在 vc.view 里面 -> 把 vc.view 缩到 56 高，底部条以外全被裁掉。
//   截图只剩底排、上面全黑，与此完全一致。
//
// v0.7/0.8/0.9 三次失败有同一个共性:
//   都在改 frame，而 Gboard 自己的布局会重算并覆盖我的改动。
//   证据: v0.9.0 里 bodyC=402x254 在我赋值之后仍然是 254,
//         因为 Relayout 末尾调用了 [root layoutIfNeeded]。
//
// 本版策略（零风险 + 拿真数据）:
//   1. 不改任何高度、不动任何祖先视图
//   2. 只把候选行 hidden = YES，让 Gboard 自己的布局引擎去回流
//   3. 打印完整视图树（不筛选，绝对坐标 + 层级缩进 + hidden 标记）
//   4. 折叠后 900ms 再打一次，看 Gboard 是否自己收起了那 44pt
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

static const CGFloat kMaxDumpLines = 400;

static void (*gOrigViewDidAppear)(id, SEL, BOOL);

static UITextView *gPanel;
static NSMutableString *gReport;
static __weak UIViewController *gVC;
static int gPass;
static BOOL gDumpedBefore;

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

#pragma mark - 只做外观类修正（不动几何）

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

// 只折叠候选行，绝不改任何高度
static NSInteger CollapseCandidates(UIView *root) {
    NSInteger n = 0;
    UIView *keysHost = FindFirst(root, @"GKB9KeysSoftKeyboardView") ?: root;
    for (UIView *v in AllViews(keysHost)) {
        if (![NSStringFromClass([v class]) isEqualToString:@"GKBNibView"]) continue;
        CGFloat h = v.frame.size.height, y = v.frame.origin.y;
        if (h > 30 && h < 60 && y < 12) {
            if (!v.hidden) { v.hidden = YES; n++; }
        }
    }
    return n;
}

#pragma mark - 诊断

static NSInteger DepthTo(UIView *v, UIView *base) {
    NSInteger d = 0;
    UIView *q = v;
    while (q && q != base) { q = q.superview; d++; }
    return q ? d : -1;
}

static void DumpChain(UIViewController *vc) {
    UIView *v = vc.view;
    int lvl = 0;
    while (v && lvl < 8) {
        [gReport appendFormat:@"CHAIN%d %@ %.0fx%.0f@%.0f,%.0f%s\n", lvl,
         NSStringFromClass([v class]), v.frame.size.width, v.frame.size.height,
         v.frame.origin.x, v.frame.origin.y, v.hidden ? " H" : ""];
        v = v.superview; lvl++;
    }
}

static void DumpFull(UIView *root, const char *tag) {
    UIWindow *win = root.window;
    UIView *base = win ? (UIView *)win : root;
    [gReport appendFormat:@"\n---- %s base=%@ %.0fx%.0f ----\n", tag,
     NSStringFromClass([base class]), base.bounds.size.width, base.bounds.size.height];
    int shown = 0, total = 0;
    for (UIView *v in AllViews(base)) {
        total++;
        if (shown >= (int)kMaxDumpLines) continue;
        CGRect f = [v convertRect:v.bounds toView:base];
        NSInteger d = DepthTo(v, base);
        if (d < 0) d = 0;
        NSMutableString *pad = [NSMutableString string];
        for (NSInteger i = 0; i < d && i < 10; i++) [pad appendString:@"."];
        [gReport appendFormat:@"%@%@ %.0fx%.0f@%.0f,%.0f%s\n",
         pad, NSStringFromClass([v class]),
         f.size.width, f.size.height, f.origin.x, f.origin.y,
         v.hidden ? " H" : ""];
        shown++;
    }
    [gReport appendFormat:@"total=%d shown=%d\n", total, shown];
}

// keyboardHeader / keyboardBody 及其容器链（真实容器关系）
static void DumpContainers(UIViewController *vc, UIView *root) {
    UIView *hdr = nil, *body = nil;
    @try {
        hdr  = [vc valueForKey:@"keyboardHeader"];
        body = [vc valueForKey:@"keyboardBody"];
    } @catch (id e) {}
    [gReport appendString:@"\n-- containers --\n"];
    if (hdr) {
        CGRect f = [hdr convertRect:hdr.bounds toView:root];
        [gReport appendFormat:@"hdr   %@ %.0fx%.0f@%.0f,%.0f\n",
         NSStringFromClass([hdr class]), f.size.width, f.size.height, f.origin.x, f.origin.y];
        UIView *p = hdr.superview; int i = 0;
        while (p && i < 3) {
            CGRect pf = [p convertRect:p.bounds toView:root];
            [gReport appendFormat:@"  hdrP%d %@ %.0fx%.0f@%.0f,%.0f\n", i,
             NSStringFromClass([p class]), pf.size.width, pf.size.height, pf.origin.x, pf.origin.y];
            p = p.superview; i++;
        }
    } else [gReport appendString:@"hdr   (nil)\n"];
    if (body) {
        CGRect f = [body convertRect:body.bounds toView:root];
        [gReport appendFormat:@"body  %@ %.0fx%.0f@%.0f,%.0f\n",
         NSStringFromClass([body class]), f.size.width, f.size.height, f.origin.x, f.origin.y];
        UIView *p = body.superview; int i = 0;
        while (p && i < 3) {
            CGRect pf = [p convertRect:p.bounds toView:root];
            [gReport appendFormat:@"  bodyP%d %@ %.0fx%.0f@%.0f,%.0f\n", i,
             NSStringFromClass([p class]), pf.size.width, pf.size.height, pf.origin.x, pf.origin.y];
            p = p.superview; i++;
        }
    } else [gReport appendString:@"body  (nil)\n"];
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
        gPanel.font = [UIFont monospacedSystemFontOfSize:7.0 weight:UIFontWeightRegular];
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

    gPass++;

    // 首次进入: 在任何改动之前抓一份原始树（真·ground truth）
    if (!gDumpedBefore) {
        DumpFull(root, "BEFORE-ANY-CHANGE");
        DumpContainers(vc, root);
        gDumpedBefore = YES;
    }

    ApplyAppearance(root, DesiredStyle());
    NSInteger logo = FixLogo(root);
    NSInteger mic  = KillTopSoftKeys(root);
    NSInteger col  = CollapseCandidates(root);

    [gReport appendFormat:@"\n== pass%d ==\nlogoW=%ld mic=%ld collapsed=%ld view=%.0fx%.0f@%.0f,%.0f\n",
     gPass, (long)logo, (long)mic, (long)col,
     root.frame.size.width, root.frame.size.height,
     root.frame.origin.x, root.frame.origin.y];
    DumpChain(vc);
    DumpContainers(vc, root);

    if (gPass == 1) {
        // 折叠后 900ms 再看: Gboard 是否自己把 44pt 收掉了
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 900 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            UIViewController *c = gVC;
            if (!c || !c.view) return;
            [gReport appendString:@"\n#### AFTER-COLLAPSE-900ms ####\n"];
            DumpChain(c);
            DumpContainers(c, c.view);
            RenderPanel(c.view.window ?: c.view);
        });
    }

    RenderPanel(root.window ?: root);
}

static void gkx_viewDidAppear(id self, SEL _cmd, BOOL animated) {
    if (gOrigViewDidAppear) gOrigViewDidAppear(self, _cmd, animated);
    gVC = (UIViewController *)self;
    gReport = [NSMutableString stringWithFormat:@"GXK v10  %@\n", NSStringFromClass([self class])];
    gPass = 0;
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
