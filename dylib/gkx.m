// gkx.m — Gboard iOS 增强 dylib
// v0.8.0: 按 v0.7.0 运行时日志修正
//
// v0.7.0 日志结论:
//   logoW=1        -> G 视图 402x26 已收窄到 56x26，这一项对了
//   mic=0          -> 判据错了：我只查 ComposingView 的直接子视图，而它已被
//                     Gboard 自己置为 hidden，所以计数为 0
//   cand=0         -> 判空逻辑失效：按 visibleCells 判断，空候选行仍报"有内容"
//
// 结构实测（root=402x276）:
//   header  22pt  (UIView 402x22@0,0)  -> GKBSoftKeyboardView -> GKBHeaderLogoView 56x26
//                                        + GKBPinyinComposingView(含麦克风 26x26@366,0)
//   body   254pt  (UIView 402x254@0,22)
//     候选行 GKBNibView 402x44@0,4      -> GKBHeaderLogoView 56x44 + 候选集合视图
//     键盘行 GKBNibView 402x206@0,48
// 所以"两层" = 22pt 头行 + 44pt 空候选行 = 66pt。
//
// 底部小地球那一行在 vc.view 树里不存在，本版把父视图链和完整树都打出来定位。
//
// 本版改动:
//   a. 候选行判空改为"查真实可见内容"，空则折叠，键盘行上移 44pt，整体高度减 44pt
//   b. 麦克风判据改为"顶部 70pt 内所有小尺寸软键"，不再依赖 ComposingView 层级
//   c. 头行 G 图标子视图夹进 22pt 行内并居中
//   d. 增加父视图链 + 完整树 + 小地球搜索，用于定位底部条
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

static const CGFloat kHeaderLogoW = 56.0;
static const CGFloat kCandRowH    = 44.0;
static const CGFloat kKeysOffsetY = 48.0;
static const CGFloat kCandOffsetY = 4.0;

static void (*gOrigViewDidAppear)(id, SEL, BOOL);

static UITextView *gPanel;
static NSMutableString *gReport;
static __weak UIViewController *gVC;
static int gPass;

static BOOL gCollapsed;
static CGFloat gOrigBodyH, gOrigOuterH, gOrigRootH;

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
    while (stack.count > 0 && guard++ < 6000) {
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

// 按 y 找候选行 / 键盘行 nib
static void FindNibs(UIView *root, UIView **candNib, UIView **keysNib) {
    if (candNib) *candNib = nil;
    if (keysNib) *keysNib = nil;
    UIView *host = FindFirst(root, @"GKB9KeysSoftKeyboardView") ?: root;
    for (UIView *v in AllViews(host)) {
        if (![NSStringFromClass([v class]) isEqualToString:@"GKBNibView"]) continue;
        CGFloat h = v.frame.size.height;
        CGFloat y = v.frame.origin.y;
        if (candNib && h > 30 && h < 60 && y < 12 && !*candNib) *candNib = v;
        else if (keysNib && h > 150 && y > 30 && !*keysNib) *keysNib = v;
    }
}

#pragma mark - 判空（改为查真实可见内容）

static BOOL RowHasVisibleContent(UIView *row) {
    for (UIView *v in AllViews(row)) {
        if (v == row) continue;
        if (v.hidden || v.alpha < 0.05) continue;
        NSString *cls = NSStringFromClass([v class]);
        // G 图标本身不算"候选内容"
        if ([cls containsString:@"HeaderLogo"] || [cls containsString:@"CircleView"]) continue;
        if ([cls containsString:@"BackgroundImage"]) continue;
        if ([v isKindOfClass:[UILabel class]]) {
            if (((UILabel *)v).text.length > 0) return YES;
            continue;
        }
        if ([v isKindOfClass:[UITextField class]]) {
            if (((UITextField *)v).text.length > 0) return YES;
            continue;
        }
        if ([v isKindOfClass:[UITextView class]]) {
            if (((UITextView *)v).text.length > 0) return YES;
            continue;
        }
        if ([v isKindOfClass:[UIImageView class]]) {
            if (((UIImageView *)v).image != nil) return YES;
            continue;
        }
    }
    return NO;
}

#pragma mark - 布局修复

static NSInteger FixLogo(UIView *root) {
    NSInteger n = 0;
    for (UIView *v in AllViews(root)) {
        if (![NSStringFromClass([v class]) isEqualToString:@"GKBHeaderLogoView"]) continue;
        CGRect f = v.frame;
        if (f.size.width > 120) {
            v.frame = CGRectMake(f.origin.x, f.origin.y, kHeaderLogoW, f.size.height);
            f = v.frame;
            n++;
        }
        // 子图标夹进父视图可见范围并居中
        CGFloat ph = f.size.height, pw = f.size.width;
        for (UIView *kid in v.subviews) {
            CGRect kf = kid.frame;
            if (kf.size.width <= pw && kf.size.height <= ph &&
                kf.origin.x >= 0 && kf.origin.y >= 0) continue;
            CGFloat sc = 1.0;
            if (kf.size.width > pw || kf.size.height > ph) {
                sc = fmin(pw / kf.size.width, ph / kf.size.height);
            }
            if (sc < 0.999) {
                kid.transform = CGAffineTransformMakeScale(sc, sc);
            }
            kid.center = CGPointMake(pw / 2.0, ph / 2.0);
        }
    }
    return n;
}

// 顶部 70pt 内所有小尺寸软键 = 麦克风/辅助键
static NSInteger KillTopSoftKeys(UIView *root) {
    NSInteger n = 0;
    for (UIView *v in AllViews(root)) {
        if (![NSStringFromClass([v class]) isEqualToString:@"GKBSoftKeyView"]) continue;
        CGRect f = v.frame;
        if (f.size.width > 60 || f.size.height > 60) continue;
        // 转换到 root 坐标判断是否在顶部
        CGPoint p = [v convertPoint:CGPointZero toView:root];
        if (p.y > 70) continue;
        if (v.hidden) continue;
        v.hidden = YES;
        n++;
    }
    return n;
}

static void SetCollapsed(UIViewController *vc, UIView *root, BOOL collapse) {
    UIView *candNib = nil, *keysNib = nil;
    FindNibs(root, &candNib, &keysNib);
    if (!candNib || !keysNib) return;

    UIView *body = nil, *outer = nil;
    @try { body = [vc valueForKey:@"keyboardBody"]; } @catch (id e) {}
    outer = body.superview;

    if (!gCollapsed && collapse) {
        gOrigBodyH  = body  ? body.frame.size.height  : 0;
        gOrigOuterH = outer ? outer.frame.size.height : 0;
        gOrigRootH  = vc.view.frame.size.height;
    }

    CGFloat d = collapse ? kCandRowH : -kCandRowH;

    if (collapse) {
        candNib.hidden = YES;
        keysNib.frame = CGRectMake(keysNib.frame.origin.x, kCandOffsetY,
                                   keysNib.frame.size.width, keysNib.frame.size.height);
    } else {
        candNib.hidden = NO;
        keysNib.frame = CGRectMake(keysNib.frame.origin.x, kKeysOffsetY,
                                   keysNib.frame.size.width, keysNib.frame.size.height);
    }

    if (body && gOrigBodyH > 0) {
        body.frame = CGRectMake(body.frame.origin.x, body.frame.origin.y,
                                body.frame.size.width, gOrigBodyH - d);
    }
    if (outer && gOrigOuterH > 0) {
        outer.frame = CGRectMake(outer.frame.origin.x, outer.frame.origin.y,
                                 outer.frame.size.width, gOrigOuterH - d);
    }
    if (gOrigRootH > 0) {
        CGRect rf = vc.view.frame;
        vc.view.frame = CGRectMake(rf.origin.x, rf.origin.y, rf.size.width, gOrigRootH - d);
    }
    [vc.view layoutIfNeeded];
    gCollapsed = collapse;
}

static void ApplyLayoutFixes(UIViewController *vc, UIView *root) {
    NSInteger logo = FixLogo(root);
    NSInteger mic = KillTopSoftKeys(root);

    UIView *candNib = nil;
    FindNibs(root, &candNib, NULL);
    BOOL empty = candNib ? !RowHasVisibleContent(candNib) : NO;
    SetCollapsed(vc, root, empty);

    [gReport appendFormat:@"\n== pass%d ==\nlogoW=%ld mic=%ld cand=%d collapsed=%d\n",
     gPass, (long)logo, (long)mic, empty ? 1 : 0, gCollapsed ? 1 : 0];

    // 候选行内容明细：判空依据必须可见，否则下一轮还会误判
    if (candNib) {
        [gReport appendString:@"-- 候选行内容 --\n"];
        int shown = 0;
        for (UIView *v in AllViews(candNib)) {
            if (v == candNib || shown >= 14) continue;
            NSString *cls = NSStringFromClass([v class]);
            NSString *extra = @"";
            if ([v isKindOfClass:[UILabel class]]) {
                NSString *t = ((UILabel *)v).text;
                extra = [NSString stringWithFormat:@" text=%@", t.length ? t : @"(empty)"];
            } else if ([v isKindOfClass:[UICollectionView class]]) {
                UICollectionView *cv = (UICollectionView *)v;
                NSInteger total = 0;
                NSInteger secs = cv.numberOfSections;
                for (NSInteger si = 0; si < secs; si++) {
                    total += [cv numberOfItemsInSection:si];
                }
                extra = [NSString stringWithFormat:@" items=%ld vis=%lu hid=%d",
                         (long)total, (unsigned long)cv.visibleCells.count, cv.hidden ? 1 : 0];
            } else if ([v isKindOfClass:[UIImageView class]]) {
                UIImage *img = ((UIImageView *)v).image;
                extra = [NSString stringWithFormat:@" img=%@", img ? @"Y" : @"N"];
            }
            [gReport appendFormat:@"   %@ %.0fx%.0f%s%s\n", cls,
             v.frame.size.width, v.frame.size.height,
             v.hidden ? " H" : "", extra];
            shown++;
        }
    }
}

#pragma mark - 诊断

static void DumpChain(UIViewController *vc) {
    UIView *v = vc.view;
    int lvl = 0;
    while (v && lvl < 7) {
        [gReport appendFormat:@"CHAIN%d %@ %.0fx%.0f@%.0f,%.0f kids=%lu\n",
         lvl, NSStringFromClass([v class]),
         v.frame.size.width, v.frame.size.height,
         v.frame.origin.x, v.frame.origin.y,
         (unsigned long)v.subviews.count];
        v = v.superview;
        lvl++;
    }
}

static void FindGlobe(UIView *root) {
    for (UIView *v in AllViews(root)) {
        NSString *cls = NSStringFromClass([v class]);
        if ([cls.lowercaseString containsString:@"globe"]) {
            [gReport appendFormat:@"GLOBE %@ %.0fx%.0f@%.0f,%.0f%s\n",
             cls, v.frame.size.width, v.frame.size.height,
             v.frame.origin.x, v.frame.origin.y, v.hidden ? " H" : ""];
        }
        if ([v isKindOfClass:[UIImageView class]]) {
            UIImage *img = ((UIImageView *)v).image;
            if (img && img.size.height > 12 && img.size.height < 40 &&
                v.frame.size.width < 60 && v.frame.size.height < 60) {
                CGPoint p = [v convertPoint:CGPointZero toView:root];
                if (p.y > root.bounds.size.height - 70) {
                    [gReport appendFormat:@"BOTTOM-IMG %.0fx%.0f@%.0f,%.0f img=%.0fx%.0f\n",
                     v.frame.size.width, v.frame.size.height, p.x, p.y,
                     img.size.width, img.size.height];
                }
            }
        }
    }
}

static void DumpTree(UIView *root, BOOL full) {
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
        BOOL show = full || v.frame.size.height > 8.0 ||
                    [cls containsString:@"Header"] || [cls containsString:@"Logo"] ||
                    [cls containsString:@"Body"] || [cls containsString:@"Input"] ||
                    [cls containsString:@"Composing"] || [cls containsString:@"Nib"];
        if (show) {
            NSMutableString *pad = [NSMutableString string];
            for (int i = 0; i < d && i < 10; i++) [pad appendString:@" "];
            [gReport appendFormat:@"%@%@ %.0fx%.0f@%.0f,%.0f%s\n",
             pad, cls, v.frame.size.width, v.frame.size.height,
             v.frame.origin.x, v.frame.origin.y, v.hidden ? " H" : ""];
        }
        if (!full && d > 5) continue;
        NSArray *kids = v.subviews;
        for (NSInteger i = (NSInteger)kids.count - 1; i >= 0; i--) {
            [stack addObject:kids[i]];
            [depths addObject:@(d + 1)];
        }
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
    gPanel.frame = CGRectMake(0, 0, host.bounds.size.width, host.bounds.size.height * 0.55);
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
    if (gPass == 1) {
        DumpChain(vc);
        FindGlobe(root);
        DumpTree(root, YES);
    } else {
        DumpTree(root, NO);
    }
    RenderPanel(root.window ?: root);
}

static void gkx_viewDidAppear(id self, SEL _cmd, BOOL animated) {
    if (gOrigViewDidAppear) gOrigViewDidAppear(self, _cmd, animated);
    gVC = (UIViewController *)self;
    gReport = [NSMutableString stringWithFormat:@"GXK v8  %@\n", NSStringFromClass([self class])];
    gPass = 0;
    gCollapsed = NO;
    gOrigBodyH = gOrigOuterH = gOrigRootH = 0;

    static const int64_t delays[] = {700, 1700, 3200};
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
