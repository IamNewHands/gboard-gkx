// gkx.m — Gboard iOS 增强 dylib
// v0.6.0-diag: 运行时日志面板
//
// 为什么改用日志: v0.5.0 的胶囊显示 H=0、hdr=22，直接推翻了前两版的假设:
//   - H=0   -> hook 根本没装上（不是比例不对）
//   - hdr=22 -> keyboardHeader 只有 22pt，不是截图里那条 45pt 高的行
// 也就是说我一直在改一个不是问题源头的视图。继续看图只会更偏。
//
// 本版做的事: 把运行时事实全部打印出来，一次性定位:
//   1. 四个 Height 选择器到底有没有类响应（含全类扫描）
//   2. 控制器上所有 view/header/body/bar/strip 相关属性及其 frame
//   3. 完整视图树（类名 + frame + hidden）
//   4. 点击面板 -> 全文复制到剪贴板，可直接粘贴成文本发出来
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

static void (*gOrigViewDidAppear)(id, SEL, BOOL);

static UITextView *gPanel;
static __weak UIViewController *gVC;
static BOOL gDumped;

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

#pragma mark - 选择器普查

static NSString *SelectorReport(void) {
    NSMutableString *s = [NSMutableString string];
    NSArray *sels = @[@"keyboardHeaderHeightForOrientation:",
                      @"keyboardBodyHeightForOrientation:",
                      @"keyboardHeightForOrientation:",
                      @"suggestionsViewHeightForOrientation:",
                      @"setHeaderHeight:",
                      @"keyboardHeader",
                      @"keyboardBody"];

    Class uivc = NSClassFromString(@"GKBUIInputViewController");
    Class base = NSClassFromString(@"GKBInputViewControllerBase");
    [s appendFormat:@"CLS uivc=%@ base=%@\n",
     uivc ? @"Y" : @"N", base ? @"Y" : @"N"];
    if (uivc) [s appendFormat:@"  uivc super=%@\n", NSStringFromClass(class_getSuperclass(uivc))];
    if (base) [s appendFormat:@"  base super=%@\n", NSStringFromClass(class_getSuperclass(base))];

    // 全类扫描: 谁真的声明了这些选择器
    int n = objc_getClassList(NULL, 0);
    Class *list = (Class *)malloc(sizeof(Class) * (size_t)(n > 0 ? n : 1));
    if (list && n > 0) {
        objc_getClassList(list, n);
        for (NSString *selName in sels) {
            SEL sel = NSSelectorFromString(selName);
            if (!sel) continue;
            NSMutableArray *owners = [NSMutableArray array];
            for (int i = 0; i < n; i++) {
                unsigned int mc = 0;
                Method *ms = class_copyMethodList(list[i], &mc);
                for (unsigned int j = 0; j < mc; j++) {
                    if (method_getName(ms[j]) == sel) {
                        [owners addObject:NSStringFromClass(list[i])];
                        break;
                    }
                }
                if (ms) free(ms);
                if (owners.count >= 4) break;
            }
            [s appendFormat:@"SEL %@ -> %@\n", selName,
             owners.count ? [owners componentsJoinedByString:@","] : @"(none)"];

            // 实例响应性: 这是 hook 成败的直接依据
            if (uivc) {
                BOOL inst = [uivc instancesRespondToSelector:sel];
                BOOL cls  = [uivc respondsToSelector:sel];
                [s appendFormat:@"   uivc inst=%d cls=%d\n", inst ? 1 : 0, cls ? 1 : 0];
            }
        }
        free(list);
    }
    return s;
}

#pragma mark - 属性与视图树

static void AppendIvarValues(NSMutableString *s, id obj) {
    if (!obj) return;
    [s appendString:@"-- 属性/实例变量 --\n"];
    Class c = object_getClass(obj);
    int depth = 0;
    while (c && depth < 8) {
        unsigned int ic = 0;
        Ivar *ivs = class_copyIvarList(c, &ic);
        for (unsigned int i = 0; i < ic; i++) {
            const char *nm = ivar_getName(ivs[i]);
            if (!nm) continue;
            NSString *name = [NSString stringWithUTF8String:nm];
            NSString *low = name.lowercaseString;
            BOOL interesting = [low containsString:@"view"] || [low containsString:@"header"] ||
                               [low containsString:@"body"] || [low containsString:@"bar"] ||
                               [low containsString:@"strip"] || [low containsString:@"suggest"] ||
                               [low containsString:@"height"];
            if (!interesting) continue;
            const char *type = ivar_getTypeEncoding(ivs[i]);
            if (!type || type[0] != '@') continue;
            @try {
                id val = object_getIvar(obj, ivs[i]);
                if (!val) { [s appendFormat:@"  %@ = nil\n", name]; continue; }
                if ([val isKindOfClass:[UIView class]]) {
                    UIView *v = (UIView *)val;
                    [s appendFormat:@"  %@ <%@> %.0f,%.0f %.0fx%.0f hid=%d\n",
                     name, NSStringFromClass([v class]),
                     v.frame.origin.x, v.frame.origin.y,
                     v.frame.size.width, v.frame.size.height,
                     v.hidden ? 1 : 0];
                } else if ([val isKindOfClass:[NSNumber class]]) {
                    [s appendFormat:@"  %@ = %@\n", name, val];
                } else if ([val isKindOfClass:[NSString class]]) {
                    NSString *t = (NSString *)val;
                    if (t.length < 40) [s appendFormat:@"  %@ = %@\n", name, t];
                }
            } @catch (id e) {}
        }
        if (ivs) free(ivs);
        c = class_getSuperclass(c);
        depth++;
    }
}

static void AppendTree(NSMutableString *s, UIView *root) {
    [s appendString:@"-- 视图树 (类 frame 高 隐) --\n"];
    NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
    NSMutableArray *depths = [NSMutableArray arrayWithObject:@0];
    int guard = 0;
    while (stack.count > 0 && guard++ < 3000) {
        UIView *v = stack.lastObject;
        NSNumber *dn = depths.lastObject;
        int d = dn.intValue;
        [stack removeLastObject];
        [depths removeLastObject];

        NSString *cls = NSStringFromClass([v class]);
        // 只打印有意义的层：高度 > 8 或名字含关键字的
        BOOL show = v.frame.size.height > 8.0 ||
                    [cls containsString:@"Header"] || [cls containsString:@"Logo"] ||
                    [cls containsString:@"Body"] || [cls containsString:@"Input"] ||
                    [cls containsString:@"Suggestion"] || [cls containsString:@"Strip"];
        if (show) {
            NSMutableString *pad = [NSMutableString string];
            for (int i = 0; i < d && i < 8; i++) [pad appendString:@"  "];
            [s appendFormat:@"%@%@ %.0fx%.0f@%.0f,%.0f%s\n",
             pad, cls,
             v.frame.size.width, v.frame.size.height,
             v.frame.origin.x, v.frame.origin.y,
             v.hidden ? " H" : ""];
        }
        NSArray *kids = v.subviews;
        for (NSInteger i = (NSInteger)kids.count - 1; i >= 0; i--) {
            [stack addObject:kids[i]];
            [depths addObject:@(d + 1)];
        }
    }
}

#pragma mark - 面板

// 手势目标: 单击面板 = 全文复制到剪贴板并关闭
@interface GXKPanelTap : NSObject
@end

@implementation GXKPanelTap
- (void)handle:(UITapGestureRecognizer *)g {
    if (gPanel.text.length > 0) {
        [UIPasteboard generalPasteboard].string = gPanel.text;
    }
    [gPanel removeFromSuperview];
}
@end

static void BuildReport(void) {
    UIViewController *vc = gVC;
    if (!vc) return;
    UIView *root = vc.view;
    if (!root) return;

    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"GXK v6 diag  %@\n", NSStringFromClass([vc class])];
    [s appendString:SelectorReport()];
    AppendIvarValues(s, vc);
    AppendTree(s, root);

    if (!gPanel) {
        gPanel = [[UITextView alloc] initWithFrame:CGRectZero];
        gPanel.editable = NO;
        gPanel.scrollEnabled = YES;
        gPanel.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.94];
        gPanel.textColor = [UIColor colorWithRed:0.6 green:1.0 blue:0.6 alpha:1.0];
        gPanel.font = [UIFont fontWithName:@"Menlo" size:8.5] ?: [UIFont monospacedSystemFontOfSize:8.5 weight:UIFontWeightRegular];
        gPanel.layer.zPosition = 20000;
        gPanel.textContainerInset = UIEdgeInsetsMake(4, 4, 4, 4);
        // 单击 = 复制全文到剪贴板并关闭（可直接粘贴成文字发回来，不用截图）
        GXKPanelTap *target = [[GXKPanelTap alloc] init];
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:target
                                                                            action:@selector(handle:)];
        [gPanel addGestureRecognizer:tap];
        objc_setAssociatedObject(gPanel, "gxk_tap_target", target, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    gPanel.text = s;
    gPanel.contentOffset = CGPointZero;

    UIView *host = root.window ?: root;
    if (gPanel.superview != host) {
        [gPanel removeFromSuperview];
        [host addSubview:gPanel];
    }
    gPanel.frame = host.bounds;
    [host bringSubviewToFront:gPanel];
}

static void Refresh(void) {
    UIViewController *vc = gVC;
    if (!vc) return;
    UIView *root = vc.view;
    if (!root) return;
    ApplyAppearance(root, DesiredStyle());
    if (!gDumped) {
        gDumped = YES;
        BuildReport();
    }
}

static void gkx_viewDidAppear(id self, SEL _cmd, BOOL animated) {
    if (gOrigViewDidAppear) gOrigViewDidAppear(self, _cmd, animated);
    gVC = (UIViewController *)self;
    gDumped = NO;
    // 等布局稳定后再抓，否则全是零尺寸
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(700 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        Refresh();
    });
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
