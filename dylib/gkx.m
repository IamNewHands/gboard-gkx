// gkx.m — Gboard iOS 增强扩展 dylib
// 阶段一 + 阶段二 + 外部词库预置支持
//
// 修复与优化:
//   1. 彻底移除 G 图标 (GKBHeaderLogoView 隐藏)
//   2. 顶部工具条动作修复 (全选高亮选区、复制/剪切自动回退当前文本、粘贴剪贴板、撤销回退)
//   3. 「深色」按钮替换为「粘贴」功能
//   4. 彻底修复九键滑行输入失效问题 (移除按键触摸劫持，下滑收起手势限制在顶部区域且 cancelsTouchesInView=NO)

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>
#import <string.h>
#import <stdlib.h>
#import <math.h>

#define GXK_LOG(fmt, ...) NSLog(@"[GXK] " fmt, ##__VA_ARGS__)

static NSString *const GXKGroup = @"group.zunbengege.top";
static NSString *const GXKAppearanceKey = @"GXKAppearance";

#pragma mark - 全局状态

static __weak UIViewController *gCurrentVC;
static UIView *gToolbarView;

// 原实现指针
static void (*gOrigViewDidAppear)(id, SEL, BOOL);
static void (*gOrigViewWillAppear)(id, SEL, BOOL);

#pragma mark - 外观与深色模式

static UIUserInterfaceStyle GXKDesiredStyle(void) {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:GXKGroup];
    NSString *v = d ? [d stringForKey:GXKAppearanceKey] : nil;
    if ([v isEqualToString:@"dark"]) return UIUserInterfaceStyleDark;
    if ([v isEqualToString:@"light"]) return UIUserInterfaceStyleLight;
    return UIUserInterfaceStyleUnspecified;
}

static void GXKApplyAppearance(UIView *root, UIUserInterfaceStyle style) {
    if (!root) return;
    if (@available(iOS 13.0, *)) {
        if (root.overrideUserInterfaceStyle != style) root.overrideUserInterfaceStyle = style;
        UIWindow *win = root.window;
        if (win && win.overrideUserInterfaceStyle != style) win.overrideUserInterfaceStyle = style;
    }
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    int guard = 0;
    while (stack.count > 0 && guard++ < 5000) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        if (@available(iOS 13.0, *)) {
            NSString *cls = NSStringFromClass([v class]);
            if ([cls containsString:@"InputView"] || [cls containsString:@"GKB"]) {
                if (v.overrideUserInterfaceStyle != style) v.overrideUserInterfaceStyle = style;
            }
        }
        [stack addObjectsFromArray:v.subviews];
    }
}

#pragma mark - 界面清理 (彻底隐藏 G 标与失效语音键)

static void GXKCleanUI(UIView *root) {
    if (!root) return;

    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:GXKGroup];
    if (d) {
        [d setObject:@NO forKey:@"GKBKeyboardSettingEnableVoiceInput"];
    }

    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    int guard = 0;
    while (stack.count > 0 && guard++ < 6000) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];

        NSString *cls = NSStringFromClass([v class]);

        // 1. 彻底隐藏 G 标
        if ([cls isEqualToString:@"GKBHeaderLogoView"] || [cls containsString:@"Logo"]) {
            v.hidden = YES;
            v.alpha = 0.0;
            v.userInteractionEnabled = NO;
            for (UIView *sub in v.subviews) {
                sub.hidden = YES;
            }
        }

        // 2. 隐藏右上角与空格旁失效的语音键
        if ([cls isEqualToString:@"GKBSoftKeyView"]) {
            NSString *acc = v.accessibilityLabel ?: @"";
            NSString *ident = v.accessibilityIdentifier ?: @"";
            if ([acc containsString:@"Voice"] || [acc containsString:@"voice"] ||
                [acc containsString:@"Mic"] || [acc containsString:@"mic"] ||
                [ident containsString:@"voice"] || [ident containsString:@"mic"]) {
                v.hidden = YES;
            }
            CGPoint pt = [v convertPoint:CGPointZero toView:root];
            if (pt.y < 50 && pt.x > (root.bounds.size.width - 60)) {
                if (v.bounds.size.width < 50 && v.bounds.size.height < 50) {
                    v.hidden = YES;
                }
            }
        }

        [stack addObjectsFromArray:v.subviews];
    }
}

#pragma mark - 下滑收起键盘手势 (安全限定顶部，绝不干扰滑行输入)

@interface GXKSwipeDismissDelegate : NSObject <UIGestureRecognizerDelegate>
@end

@implementation GXKSwipeDismissDelegate

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    // 严格限制：只允许从键盘顶部区域 (y < 46pt) 开始的下滑手势生效
    // 如果触摸点在键盘按键主体区 (y >= 46pt)，立刻返回 NO，保证滑行输入零干扰！
    CGPoint pt = [gestureRecognizer locationInView:gestureRecognizer.view];
    if (pt.y > 46.0) {
        return NO;
    }
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    CGPoint pt = [touch locationInView:gestureRecognizer.view];
    if (pt.y > 46.0) {
        return NO;
    }
    return YES;
}

@end

static GXKSwipeDismissDelegate *gDismissDelegate;

static void GXKHandlePan(UIPanGestureRecognizer *pan) {
    if (!gCurrentVC) return;
    if (pan.state == UIGestureRecognizerStateEnded) {
        CGPoint translation = [pan translationInView:gCurrentVC.view];
        CGPoint velocity = [pan velocityInView:gCurrentVC.view];

        // 顶部向下滑动判定
        if ((translation.y > 35.0 && fabs(translation.y) > fabs(translation.x) * 1.2) ||
            (velocity.y > 250.0 && fabs(velocity.y) > fabs(velocity.x) * 1.3)) {
            UIInputViewController *ivc = (UIInputViewController *)gCurrentVC;
            if ([ivc respondsToSelector:@selector(dismissKeyboard)]) {
                [ivc dismissKeyboard];
            }
        }
    }
}

static void GXKSetupSwipeDismiss(UIViewController *vc) {
    if (!vc || !vc.view) return;
    for (UIGestureRecognizer *g in vc.view.gestureRecognizers) {
        if ([objc_getAssociatedObject(g, "gxk_swipe_dismiss") boolValue]) return;
    }
    if (!gDismissDelegate) {
        gDismissDelegate = [[GXKSwipeDismissDelegate alloc] init];
    }
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:gDismissDelegate action:@selector(handlePan:)];
    pan.delegate = gDismissDelegate;
    // 关键属性：绝不取消底层键盘按键视图的 touches 事件！
    pan.cancelsTouchesInView = NO;
    pan.delaysTouchesBegan = NO;
    pan.delaysTouchesEnded = NO;

    objc_setAssociatedObject(pan, "gxk_swipe_dismiss", @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [vc.view addGestureRecognizer:pan];
}

@implementation GXKSwipeDismissDelegate (Handler)
- (void)handlePan:(UIPanGestureRecognizer *)pan {
    GXKHandlePan(pan);
}
@end

#pragma mark - 快捷编辑工具条 (动作实装)

@interface GXKToolbarTarget : NSObject
@end

@implementation GXKToolbarTarget

- (void)onSelectAll {
    if (!gCurrentVC) return;
    UIInputViewController *ivc = (UIInputViewController *)gCurrentVC;
    id<UITextDocumentProxy> proxy = ivc.textDocumentProxy;
    if (!proxy) return;

    NSString *before = proxy.documentContextBeforeInput ?: @"";
    NSString *after = proxy.documentContextAfterInput ?: @"";
    NSString *full = [before stringByAppendingString:after];

    if (full.length > 0) {
        // 利用 setMarkedText:selectedRange: 将当前全部文字标记为高亮选区
        [proxy setMarkedText:full selectedRange:NSMakeRange(0, full.length)];
    }
}

- (void)onCopy {
    if (!gCurrentVC) return;
    UIInputViewController *ivc = (UIInputViewController *)gCurrentVC;
    id<UITextDocumentProxy> proxy = ivc.textDocumentProxy;
    if (!proxy) return;

    NSString *sel = proxy.selectedText;
    if (sel.length > 0) {
        [UIPasteboard generalPasteboard].string = sel;
    } else {
        // 若宿主无独立选区，复制当前输入框内已有文本
        NSString *ctx = proxy.documentContextBeforeInput;
        if (ctx.length > 0) {
            [UIPasteboard generalPasteboard].string = ctx;
        }
    }
}

- (void)onCut {
    if (!gCurrentVC) return;
    UIInputViewController *ivc = (UIInputViewController *)gCurrentVC;
    id<UITextDocumentProxy> proxy = ivc.textDocumentProxy;
    if (!proxy) return;

    NSString *sel = proxy.selectedText;
    if (sel.length > 0) {
        [UIPasteboard generalPasteboard].string = sel;
        [proxy deleteBackward];
    } else {
        NSString *ctx = proxy.documentContextBeforeInput;
        if (ctx.length > 0) {
            [UIPasteboard generalPasteboard].string = ctx;
            for (NSUInteger i = 0; i < ctx.length; i++) {
                [proxy deleteBackward];
            }
        }
    }
}

- (void)onPaste {
    if (!gCurrentVC) return;
    UIInputViewController *ivc = (UIInputViewController *)gCurrentVC;
    id<UITextDocumentProxy> proxy = ivc.textDocumentProxy;
    if (!proxy) return;

    NSString *str = [UIPasteboard generalPasteboard].string;
    if (str.length > 0) {
        [proxy insertText:str];
    }
}

- (void)onUndo {
    if (!gCurrentVC) return;
    UIInputViewController *ivc = (UIInputViewController *)gCurrentVC;
    id<UITextDocumentProxy> proxy = ivc.textDocumentProxy;
    if (!proxy) return;

    // 撤销动作：直接触发回退删除
    [proxy deleteBackward];
}

- (void)onDismiss {
    if (!gCurrentVC) return;
    UIInputViewController *ivc = (UIInputViewController *)gCurrentVC;
    if ([ivc respondsToSelector:@selector(dismissKeyboard)]) {
        [ivc dismissKeyboard];
    }
}

@end

static GXKToolbarTarget *gToolbarTarget;

static UIButton *GXKCreateToolButton(NSString *title, SEL action) {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    [btn setTitle:title forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightMedium];
    [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    btn.backgroundColor = [UIColor colorWithWhite:0.25 alpha:0.65];
    btn.layer.cornerRadius = 6.0;
    btn.layer.masksToBounds = YES;
    btn.contentEdgeInsets = UIEdgeInsetsMake(4, 10, 4, 10);
    [btn addTarget:gToolbarTarget action:action forControlEvents:UIControlEventTouchUpInside];
    return btn;
}

static void GXKSetupToolbar(UIViewController *vc) {
    if (!vc || !vc.view) return;
    if (gToolbarView && gToolbarView.superview == vc.view) return;

    if (!gToolbarTarget) gToolbarTarget = [[GXKToolbarTarget alloc] init];

    CGFloat width = vc.view.bounds.size.width;
    gToolbarView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, 36.0)];
    gToolbarView.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.4];
    gToolbarView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleBottomMargin;

    UIStackView *stack = [[UIStackView alloc] initWithFrame:gToolbarView.bounds];
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.distribution = UIStackViewDistributionEqualSpacing;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    stack.layoutMargins = UIEdgeInsetsMake(0, 10, 0, 10);
    stack.layoutMarginsRelativeArrangement = YES;

    // 按用户要求：全选、复制、剪切、粘贴、撤销、收起
    [stack addArrangedSubview:GXKCreateToolButton(@"全选", @selector(onSelectAll))];
    [stack addArrangedSubview:GXKCreateToolButton(@"复制", @selector(onCopy))];
    [stack addArrangedSubview:GXKCreateToolButton(@"剪切", @selector(onCut))];
    [stack addArrangedSubview:GXKCreateToolButton(@"粘贴", @selector(onPaste))];
    [stack addArrangedSubview:GXKCreateToolButton(@"撤销", @selector(onUndo))];
    [stack addArrangedSubview:GXKCreateToolButton(@"收起", @selector(onDismiss))];

    [gToolbarView addSubview:stack];
    [vc.view addSubview:gToolbarView];
}

#pragma mark - 外部词库自动预置与部署

static void GXKEnsureUserDictionaryDeployed(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *containerURL = [fm containerURLForSecurityApplicationGroupIdentifier:GXKGroup];
    if (!containerURL) return;

    NSURL *targetDBURL = [containerURL URLByAppendingPathComponent:@"user_dictionary.db"];

    NSBundle *mainBundle = [NSBundle mainBundle];
    NSString *bundlePath = [mainBundle pathForResource:@"user_dictionary" ofType:@"db"];
    if (!bundlePath) {
        bundlePath = [[mainBundle bundlePath] stringByAppendingPathComponent:@"Frameworks/user_dictionary.db"];
    }
    if (!bundlePath || ![fm fileExistsAtPath:bundlePath]) return;

    BOOL needCopy = YES;
    if ([fm fileExistsAtPath:targetDBURL.path]) {
        NSDictionary *srcAttrs = [fm attributesOfItemAtPath:bundlePath error:nil];
        NSDictionary *dstAttrs = [fm attributesOfItemAtPath:targetDBURL.path error:nil];
        if (srcAttrs && dstAttrs) {
            NSDate *srcDate = srcAttrs[NSFileModificationDate];
            NSDate *dstDate = dstAttrs[NSFileModificationDate];
            if ([dstDate compare:srcDate] == NSOrderedDescending) {
                needCopy = NO;
            }
        }
    }

    if (needCopy) {
        [fm removeItemAtURL:targetDBURL error:nil];
        NSError *err = nil;
        [fm copyItemAtPath:bundlePath toPath:targetDBURL.path error:&err];
    }
}

#pragma mark - 视图生命周期 Hook

static void gkx_viewWillAppear(id self, SEL _cmd, BOOL animated) {
    if (gOrigViewWillAppear) gOrigViewWillAppear(self, _cmd, animated);
    gCurrentVC = (UIViewController *)self;
    GXKEnsureUserDictionaryDeployed();
}

static void gkx_viewDidAppear(id self, SEL _cmd, BOOL animated) {
    if (gOrigViewDidAppear) gOrigViewDidAppear(self, _cmd, animated);
    gCurrentVC = (UIViewController *)self;
    UIView *root = gCurrentVC.view;
    if (!root) return;

    // 1. 设置下滑收起键盘手势 (安全限定顶部 y<46pt)
    GXKSetupSwipeDismiss(gCurrentVC);

    // 2. 界面视觉清理 (完全隐藏 G 标与语音)
    GXKApplyAppearance(root, GXKDesiredStyle());
    GXKCleanUI(root);

    // 3. 挂载快捷编辑条 (全选/复制/剪切/粘贴/撤销/收起)
    GXKSetupToolbar(gCurrentVC);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        if (gCurrentVC && gCurrentVC.view) {
            GXKCleanUI(gCurrentVC.view);
            GXKApplyAppearance(gCurrentVC.view, GXKDesiredStyle());
        }
    });
}

#pragma mark - dylib 构造入口

__attribute__((constructor))
static void gkx_init(void) {
    GXK_LOG(@"libgkx 初始化注入 (极速轻量修复版)...");

    // Hook GKBUIInputViewController 生命周期
    Class vcClass = NSClassFromString(@"GKBUIInputViewController") ?: NSClassFromString(@"GKBInputViewControllerBase");
    if (vcClass) {
        Method mAppear = class_getInstanceMethod(vcClass, @selector(viewDidAppear:));
        if (mAppear) {
            gOrigViewDidAppear = (void (*)(id, SEL, BOOL))method_getImplementation(mAppear);
            method_setImplementation(mAppear, (IMP)gkx_viewDidAppear);
        }
        Method mWill = class_getInstanceMethod(vcClass, @selector(viewWillAppear:));
        if (mWill) {
            gOrigViewWillAppear = (void (*)(id, SEL, BOOL))method_getImplementation(mWill);
            method_setImplementation(mWill, (IMP)gkx_viewWillAppear);
        }
    }
    // 提示: 不再 hook GKBSoftKeyView 的 touchesBegan/touchesEnded，确保九键和全键盘滑行输入原生性能不受任何影响！
}
