// gkx.m — Gboard iOS 增强扩展 dylib
// 阶段一 + 阶段二 + 外部词库预置支持
//
// 核心能力:
//   1. 下滑收起键盘 (Swipe Down to Dismiss)
//   2. 界面视觉去杂 (去除失效语音入口、G 标缩至 56pt、强制深色/浅色/跟随系统)
//   3. 英文 QWERTY 上滑大写 (Up-flick Uppercase)
//   4. 快捷编辑工具条 (全选、复制、剪切、会话内撤销栈、深色切换)
//   5. 外部词库自动部署 (自动同步 user_dictionary.db 至 App Group 容器)
//
// 构建: xcrun --sdk iphoneos clang -dynamiclib -arch arm64 -miphoneos-version-min=12.0 -fobjc-arc -O2 ...

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
static BOOL gToolbarExpanded = NO;
static NSMutableArray<NSNumber *> *gUndoStack;

// 原实现指针
static void (*gOrigViewDidAppear)(id, SEL, BOOL);
static void (*gOrigViewWillAppear)(id, SEL, BOOL);
static void (*gOrigInsertText)(id, SEL, NSString *);
static void (*gOrigTouchesBegan)(id, SEL, NSSet *, UIEvent *);
static void (*gOrigTouchesEnded)(id, SEL, NSSet *, UIEvent *);

#pragma mark - 外观与深色模式控制

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

static void GXKCycleAppearance(void) {
    UIUserInterfaceStyle cur = GXKDesiredStyle();
    NSString *nextStr = @"system";
    if (cur == UIUserInterfaceStyleUnspecified) nextStr = @"dark";
    else if (cur == UIUserInterfaceStyleDark) nextStr = @"light";
    else nextStr = @"system";

    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:GXKGroup];
    if (d) {
        [d setObject:nextStr forKey:GXKAppearanceKey];
        [d synchronize];
    }
    if (gCurrentVC && gCurrentVC.view) {
        GXKApplyAppearance(gCurrentVC.view, GXKDesiredStyle());
    }
}

#pragma mark - 界面清理 (去除语音键、缩放 G 标)

static void GXKCleanUI(UIView *root) {
    if (!root) return;

    // 禁用设置中的语音配置
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

        // 1. 缩放 G 标 HeaderLogoView
        if ([cls isEqualToString:@"GKBHeaderLogoView"]) {
            CGRect f = v.frame;
            if (f.size.width > 90) {
                v.frame = CGRectMake(f.origin.x, f.origin.y, 56.0, f.size.height);
                for (UIView *sub in v.subviews) {
                    sub.center = CGPointMake(28.0, f.size.height / 2.0);
                }
            }
        }

        // 2. 隐藏右上角或空格栏旁的语音键 (按类名或标识查找)
        if ([cls isEqualToString:@"GKBSoftKeyView"]) {
            NSString *acc = v.accessibilityLabel ?: @"";
            NSString *ident = v.accessibilityIdentifier ?: @"";
            if ([acc containsString:@"Voice"] || [acc containsString:@"voice"] ||
                [acc containsString:@"Mic"] || [acc containsString:@"mic"] ||
                [ident containsString:@"voice"] || [ident containsString:@"mic"]) {
                v.hidden = YES;
            }
            // 空格键右侧小语音图标通常尺寸在 40x40 且处于顶部右侧区域
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

#pragma mark - 下滑收起键盘手势

@interface GXKSwipeDismissDelegate : NSObject <UIGestureRecognizerDelegate>
@end

@implementation GXKSwipeDismissDelegate
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    // 允许与候选行水平滚动或点击同时识别
    return YES;
}
@end

static GXKSwipeDismissDelegate *gDismissDelegate;

static void GXKHandlePan(UIPanGestureRecognizer *pan) {
    if (!gCurrentVC) return;
    if (pan.state == UIGestureRecognizerStateEnded) {
        CGPoint translation = [pan translationInView:gCurrentVC.view];
        CGPoint velocity = [pan velocityInView:gCurrentVC.view];

        // 判定垂直向下滑动超过 45pt，或垂直初速度 > 250 pt/s
        if (translation.y > 45.0 && fabs(translation.y) > fabs(translation.x) * 1.3) {
            UIInputViewController *ivc = (UIInputViewController *)gCurrentVC;
            if ([ivc respondsToSelector:@selector(dismissKeyboard)]) {
                [ivc dismissKeyboard];
            }
        } else if (velocity.y > 300.0 && fabs(velocity.y) > fabs(velocity.x) * 1.5) {
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
    objc_setAssociatedObject(pan, "gxk_swipe_dismiss", @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [vc.view addGestureRecognizer:pan];
}

@implementation GXKSwipeDismissDelegate (Handler)
- (void)handlePan:(UIPanGestureRecognizer *)pan {
    GXKHandlePan(pan);
}
@end

#pragma mark - 英文 QWERTY 上滑大写 (Up-flick Uppercase)

static const char *kTouchStartKey = "gxk_touch_start";

static UILabel *GXKFindKeyLabel(UIView *keyView) {
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:keyView];
    int guard = 0;
    while (stack.count > 0 && guard++ < 100) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        if ([v isKindOfClass:[UILabel class]]) {
            UILabel *lbl = (UILabel *)v;
            NSString *t = lbl.text;
            if (t.length == 1) {
                unichar c = [t characterAtIndex:0];
                if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')) {
                    return lbl;
                }
            }
        }
        [stack addObjectsFromArray:v.subviews];
    }
    return nil;
}

static void gkx_softKey_touchesBegan(id self, SEL _cmd, NSSet *touches, UIEvent *event) {
    UITouch *t = [touches anyObject];
    if (t) {
        CGPoint pt = [t locationInView:(UIView *)self];
        NSValue *val = [NSValue valueWithCGPoint:pt];
        objc_setAssociatedObject(self, kTouchStartKey, val, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (gOrigTouchesBegan) gOrigTouchesBegan(self, _cmd, touches, event);
}

static void gkx_softKey_touchesEnded(id self, SEL _cmd, NSSet *touches, UIEvent *event) {
    UITouch *t = [touches anyObject];
    NSValue *startVal = objc_getAssociatedObject(self, kTouchStartKey);
    objc_setAssociatedObject(self, kTouchStartKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    if (t && startVal && gCurrentVC) {
        CGPoint startPt = [startVal CGPointValue];
        CGPoint endPt = [t locationInView:(UIView *)self];
        CGFloat dy = endPt.y - startPt.y;
        CGFloat dx = endPt.x - startPt.x;

        // 判定向上微滑手势: 垂直向上 > 16pt，且垂直分量占主导
        if (dy < -16.0 && fabs(dy) > fabs(dx) * 1.2) {
            UILabel *lbl = GXKFindKeyLabel((UIView *)self);
            if (lbl && lbl.text.length == 1) {
                NSString *upper = [lbl.text uppercaseString];
                UIInputViewController *ivc = (UIInputViewController *)gCurrentVC;
                if (ivc && ivc.textDocumentProxy) {
                    [ivc.textDocumentProxy insertText:upper];
                    // 记录撤销栈
                    if (!gUndoStack) gUndoStack = [NSMutableArray array];
                    [gUndoStack addObject:@(upper.length)];
                    return; // 拦截消费，不再调用原始 touchesEnded 防止打出小写
                }
            }
        }
    }
    if (gOrigTouchesEnded) gOrigTouchesEnded(self, _cmd, touches, event);
}

#pragma mark - 快捷编辑工具条 (第二阶段)

@interface GXKToolbarTarget : NSObject
@end

@implementation GXKToolbarTarget

- (void)onSelectAll {
    if (!gCurrentVC) return;
    UIInputViewController *ivc = (UIInputViewController *)gCurrentVC;
    id<UITextDocumentProxy> proxy = ivc.textDocumentProxy;
    if ([proxy respondsToSelector:@selector(selectAll:)]) {
        [proxy performSelector:@selector(selectAll:) withObject:nil];
    } else {
        // 尝试移动光标至文档首尾以唤起系统动作
        [proxy adjustTextPositionByCharacterOffset:9999];
    }
}

- (void)onCopy {
    if (!gCurrentVC) return;
    UIInputViewController *ivc = (UIInputViewController *)gCurrentVC;
    NSString *sel = ivc.textDocumentProxy.selectedText;
    if (sel.length > 0) {
        [UIPasteboard generalPasteboard].string = sel;
    }
}

- (void)onCut {
    if (!gCurrentVC) return;
    UIInputViewController *ivc = (UIInputViewController *)gCurrentVC;
    NSString *sel = ivc.textDocumentProxy.selectedText;
    if (sel.length > 0) {
        [UIPasteboard generalPasteboard].string = sel;
        [ivc.textDocumentProxy deleteBackward];
    }
}

- (void)onUndo {
    if (!gCurrentVC || !gUndoStack || gUndoStack.count == 0) return;
    UIInputViewController *ivc = (UIInputViewController *)gCurrentVC;
    id<UITextDocumentProxy> proxy = ivc.textDocumentProxy;
    NSInteger count = [gUndoStack.lastObject integerValue];
    [gUndoStack removeLastObject];
    for (NSInteger i = 0; i < count; i++) {
        [proxy deleteBackward];
    }
}

- (void)onToggleAppearance {
    GXKCycleAppearance();
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
    [btn setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
    btn.backgroundColor = [UIColor colorWithWhite:0.5 alpha:0.15];
    btn.layer.cornerRadius = 6.0;
    btn.layer.masksToBounds = YES;
    btn.contentEdgeInsets = UIEdgeInsetsMake(4, 8, 4, 8);
    [btn addTarget:gToolbarTarget action:action forControlEvents:UIControlEventTouchUpInside];
    return btn;
}

static void GXKSetupToolbar(UIViewController *vc) {
    if (!vc || !vc.view) return;
    if (gToolbarView && gToolbarView.superview == vc.view) return;

    if (!gToolbarTarget) gToolbarTarget = [[GXKToolbarTarget alloc] init];

    CGFloat width = vc.view.bounds.size.width;
    gToolbarView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, 36.0)];
    gToolbarView.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.08];
    gToolbarView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleBottomMargin;

    UIStackView *stack = [[UIStackView alloc] initWithFrame:gToolbarView.bounds];
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.distribution = UIStackViewDistributionEqualSpacing;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    stack.layoutMargins = UIEdgeInsetsMake(0, 10, 0, 10);
    stack.layoutMarginsRelativeArrangement = YES;

    [stack addArrangedSubview:GXKCreateToolButton(@"全选", @selector(onSelectAll))];
    [stack addArrangedSubview:GXKCreateToolButton(@"复制", @selector(onCopy))];
    [stack addArrangedSubview:GXKCreateToolButton(@"剪切", @selector(onCut))];
    [stack addArrangedSubview:GXKCreateToolButton(@"撤销", @selector(onUndo))];
    [stack addArrangedSubview:GXKCreateToolButton(@"深色", @selector(onToggleAppearance))];
    [stack addArrangedSubview:GXKCreateToolButton(@"收起", @selector(onDismiss))];

    [gToolbarView addSubview:stack];
    [vc.view addSubview:gToolbarView];
}

#pragma mark - 撤销记录 Hook (insertText)

static void gkx_proxy_insertText(id self, SEL _cmd, NSString *text) {
    if (text.length > 0) {
        if (!gUndoStack) gUndoStack = [NSMutableArray array];
        [gUndoStack addObject:@(text.length)];
        // 限制栈深
        if (gUndoStack.count > 100) [gUndoStack removeObjectAtIndex:0];
    }
    if (gOrigInsertText) gOrigInsertText(self, _cmd, text);
}

#pragma mark - 外部词库自动预置与部署 (Mozc user_dictionary.db)

static void GXKEnsureUserDictionaryDeployed(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *containerURL = [fm containerURLForSecurityApplicationGroupIdentifier:GXKGroup];
    if (!containerURL) {
        GXK_LOG(@"无法定位 App Group 容器: %@", GXKGroup);
        return;
    }

    NSURL *targetDBURL = [containerURL URLByAppendingPathComponent:@"user_dictionary.db"];

    // 寻找包内预置的 user_dictionary.db
    NSBundle *mainBundle = [NSBundle mainBundle];
    NSString *bundlePath = [mainBundle pathForResource:@"user_dictionary" ofType:@"db"];
    if (!bundlePath) {
        // 检查 Frameworks 目录
        bundlePath = [[mainBundle bundlePath] stringByAppendingPathComponent:@"Frameworks/user_dictionary.db"];
    }
    if (!bundlePath || ![fm fileExistsAtPath:bundlePath]) {
        return;
    }

    // 若容器内不存在，或预置词库比容器内更新，则覆盖写入
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
        if ([fm copyItemAtPath:bundlePath toPath:targetDBURL.path error:&err]) {
            GXK_LOG(@"成功部署预置词库至: %@", targetDBURL.path);
        } else {
            GXK_LOG(@"部署词库失败: %@", err);
        }
    }
}

#pragma mark - 视图生命周期 Hook

static void gkx_viewWillAppear(id self, SEL _cmd, BOOL animated) {
    if (gOrigViewWillAppear) gOrigViewWillAppear(self, _cmd, animated);
    gCurrentVC = (UIViewController *)self;
    // 重置本次输入会话的撤销栈
    gUndoStack = [NSMutableArray array];

    // 自动部署词库
    GXKEnsureUserDictionaryDeployed();
}

static void gkx_viewDidAppear(id self, SEL _cmd, BOOL animated) {
    if (gOrigViewDidAppear) gOrigViewDidAppear(self, _cmd, animated);
    gCurrentVC = (UIViewController *)self;
    UIView *root = gCurrentVC.view;
    if (!root) return;

    // 1. 设置下滑收起键盘手势
    GXKSetupSwipeDismiss(gCurrentVC);

    // 2. 界面视觉清理与深色模式覆盖
    GXKApplyAppearance(root, GXKDesiredStyle());
    GXKCleanUI(root);

    // 3. 挂载快捷编辑条 (位于 header 区域)
    GXKSetupToolbar(gCurrentVC);

    // 延时再次清理防止 Gboard layoutSubviews 重算复原
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
    GXK_LOG(@"libgkx 初始化注入...");

    // 1. Hook GKBUIInputViewController 生命周期
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

    // 2. Hook GKBSoftKeyView 触摸事件 (用于英文 QWERTY 上滑大写)
    Class keyClass = NSClassFromString(@"GKBSoftKeyView");
    if (keyClass) {
        Method mBegan = class_getInstanceMethod(keyClass, @selector(touchesBegan:withEvent:));
        if (mBegan) {
            gOrigTouchesBegan = (void (*)(id, SEL, NSSet *, UIEvent *))method_getImplementation(mBegan);
            method_setImplementation(mBegan, (IMP)gkx_softKey_touchesBegan);
        }
        Method mEnded = class_getInstanceMethod(keyClass, @selector(touchesEnded:withEvent:));
        if (mEnded) {
            gOrigTouchesEnded = (void (*)(id, SEL, NSSet *, UIEvent *))method_getImplementation(mEnded);
            method_setImplementation(mEnded, (IMP)gkx_softKey_touchesEnded);
        }
    }

    // 3. Hook GKBTextDocumentProxyWrapper insertText: (撤销记录)
    Class proxyClass = NSClassFromString(@"GKBTextDocumentProxyWrapper") ?: NSClassFromString(@"UIInputViewController");
    if (proxyClass) {
        Method mInsert = class_getInstanceMethod(proxyClass, @selector(insertText:));
        if (mInsert) {
            gOrigInsertText = (void (*)(id, SEL, NSString *))method_getImplementation(mInsert);
            method_setImplementation(mInsert, (IMP)gkx_proxy_insertText);
        }
    }
}
