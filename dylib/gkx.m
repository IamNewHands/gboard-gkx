// gkx.m — Gboard iOS 增强扩展 dylib
// 阶段一 + 阶段二 + 万象词库 + 外观自适应与7项深度优化版
//
// 核心修复与功能闭环:
//   1. 修复全屏黑幕遮挡：确保 window 与全屏容器 UIInputSetContainerView 始终透明，绝不遮挡宿主 App 输入框与聊天内容
//   2. 外观模式自由切换：设置面板支持 [跟随系统 / 浅色 / 深色]，白天自动自适应浅色、夜晚自适应深色，工具栏/按键/面板全层级自适应配色
//   3. 全选修复：彻底移除 setMarkedText，改为「全选复制」与「清空」，绝不再生成并排重复文字
//   4. 预编辑防遮挡：键盘高度通过约束扩充 (+34pt)，Gboard 视图整体下移，工具条置顶且完全不遮挡拼音与候选
//   5. 九键重输/换行：动态将回车上方表情键改造成「重输」（拼音编辑时微红清空）与「换行」（未输入时插入换行，浅深色自适应按键）
//   6. 极速轻量内存：万象词库精选 6 万核心高频词 (2.18MB)，彻底消除 iOS Jetsam 杀扩展闪退
//   7. 原生悬浮设置：支持键盘高度调节、外观模式切换、万象词库开关与剪贴板词库导入
//
// 保障：不劫持全局按键触摸，九键与全键盘滑行输入原生性能不受任何影响。

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>
#import <string.h>
#import <stdlib.h>
#import <math.h>

#define GXK_LOG(fmt, ...) NSLog(@"[GXK] " fmt, ##__VA_ARGS__)
#define GXK_ACTION_TAG 0x47584B41  // 'GXKA'

static NSString *const GXKGroup = @"group.zunbengege.top";
static NSString *const GXKAppearanceKey = @"GXKAppearance";
static NSString *const GXKHeightOffsetKey = @"GXKKeyboardHeightOffset";
static NSString *const GXKDictEnabledKey = @"GXKDictEnabled";

#pragma mark - 全局状态

static __weak UIViewController *gCurrentVC;
static UIView *gToolbarView;
static UIView *gSettingsModalView;
static NSLayoutConstraint *gHeightConstraint;
static CGFloat gBaseKeyboardHeight = 0.0;

static __weak UIView *gEmojiSoftKeyView;
static UIButton *gActionKeyButton;
static NSTimer *gStatePollTimer;

// 原实现指针
static void (*gOrigViewDidAppear)(id, SEL, BOOL);
static void (*gOrigViewWillAppear)(id, SEL, BOOL);
static void (*gOrigViewWillDisappear)(id, SEL, BOOL);
static void (*gOrigUpdateViewConstraints)(id, SEL);
static void (*gOrigTextDidChange)(id, SEL, id);

#pragma mark - 选项读取与写入

static CGFloat GXKGetHeightOffset(void) {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:GXKGroup];
    if (!d) return 34.0;
    if ([d objectForKey:GXKHeightOffsetKey] == nil) return 34.0; // 默认 +34pt 给顶部工具条
    return [d doubleForKey:GXKHeightOffsetKey];
}

static BOOL GXKIsDictEnabled(void) {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:GXKGroup];
    if (!d) return YES;
    if ([d objectForKey:GXKDictEnabledKey] == nil) return YES;
    return [d boolForKey:GXKDictEnabledKey];
}

#pragma mark - 外观与自适应模式 (跟随系统 / 强制浅色 / 强制深色)

static NSString *GXKGetAppearance(void) {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:GXKGroup];
    NSString *val = d ? [d stringForKey:GXKAppearanceKey] : nil;
    if ([val isEqualToString:@"light"] || [val isEqualToString:@"dark"]) {
        return val;
    }
    return @"system";
}

static UIUserInterfaceStyle GXKDesiredStyle(void) {
    NSString *app = GXKGetAppearance();
    if ([app isEqualToString:@"light"]) return UIUserInterfaceStyleLight;
    if ([app isEqualToString:@"dark"]) return UIUserInterfaceStyleDark;
    return UIUserInterfaceStyleUnspecified; // 跟随系统
}

static BOOL GXKIsCurrentDark(UIView *view) {
    UIUserInterfaceStyle desired = GXKDesiredStyle();
    if (desired == UIUserInterfaceStyleDark) return YES;
    if (desired == UIUserInterfaceStyleLight) return NO;
    if (@available(iOS 13.0, *)) {
        if (view && view.traitCollection) {
            return view.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
        }
        if (view && view.window && view.window.traitCollection) {
            return view.window.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
        }
        if ([UIScreen mainScreen].traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) {
            return YES;
        }
    }
    return NO;
}

static void GXKUpdateToolbarTheme(BOOL isDark);
extern void GXKUpdateActionKey(UIViewController *vc);

static void GXKApplyAppearance(UIViewController *vc) {
    if (!vc || !vc.view) return;
    UIView *root = vc.view;
    UIUserInterfaceStyle style = GXKDesiredStyle();

    if (@available(iOS 13.0, *)) {
        if (root.overrideUserInterfaceStyle != style) {
            root.overrideUserInterfaceStyle = style;
        }
        UIWindow *win = root.window;
        if (win) {
            if (win.overrideUserInterfaceStyle != style) {
                win.overrideUserInterfaceStyle = style;
            }
            // 确保全屏容器 UIInputSetContainerView 绝对透明，绝不遮挡上层宿主 App 与输入框
            win.backgroundColor = [UIColor clearColor];
            for (UIView *wv in win.subviews) {
                NSString *wcls = NSStringFromClass([wv class]);
                if ([wcls containsString:@"Container"] || [wcls containsString:@"Window"]) {
                    wv.backgroundColor = [UIColor clearColor];
                }
                if ([wcls containsString:@"Backdrop"] || [wcls containsString:@"Content"] || [wcls containsString:@"Host"]) {
                    if (wv.overrideUserInterfaceStyle != style) {
                        wv.overrideUserInterfaceStyle = style;
                    }
                }
            }
        }
    }

    // 键盘根视图保持透明，让 UIKit 原生毛玻璃背景与 Gboard 皮肤层按 traitCollection 正常呈现
    root.backgroundColor = [UIColor clearColor];

    BOOL isDark = GXKIsCurrentDark(root);
    GXKUpdateToolbarTheme(isDark);
    GXKUpdateActionKey(vc);
}

#pragma mark - 界面清理与布局下移避让 (完全腾出工具栏空间)

static void GXKCleanAndShiftUI(UIView *root) {
    if (!root) return;
    CGFloat offset = GXKGetHeightOffset();

    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    int guard = 0;
    while (stack.count > 0 && guard++ < 4000) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];

        NSString *cls = NSStringFromClass([v class]);

        // 1. 彻底移除 G 标志 (隐藏并禁用)
        if ([cls isEqualToString:@"GKBHeaderLogoView"] || [cls containsString:@"Logo"]) {
            v.hidden = YES;
            v.alpha = 0.0;
            v.userInteractionEnabled = NO;
        }

        // 2. 隐藏右上角与空格旁的失效语音键
        if ([cls isEqualToString:@"GKBSoftKeyView"]) {
            NSString *acc = v.accessibilityLabel ?: @"";
            NSString *ident = v.accessibilityIdentifier ?: @"";
            if ([acc containsString:@"Voice"] || [acc containsString:@"voice"] ||
                [acc containsString:@"Mic"] || [acc containsString:@"mic"] ||
                [ident containsString:@"voice"] || [ident containsString:@"mic"]) {
                v.hidden = YES;
            }
            CGPoint pt = [v convertPoint:CGPointZero toView:root];
            if (pt.y < 50.0 && pt.x > (root.bounds.size.width - 60.0)) {
                if (v.bounds.size.width < 50.0 && v.bounds.size.height < 50.0) {
                    v.hidden = YES;
                }
            }
        }

        // 3. 将 Gboard 的顶层容器 (Header, Body, Candidate) 整体下移 offset，完全避让顶部工具栏
        if (offset > 0.0) {
            if ([cls containsString:@"KeyboardHeader"] || [cls containsString:@"keyboardHeader"] ||
                [cls containsString:@"KeyboardBody"] || [cls containsString:@"keyboardBody"] ||
                [cls isEqualToString:@"GKBNibView"] || [cls containsString:@"Candidate"]) {
                CGRect f = v.frame;
                if (f.origin.y < (offset - 4.0)) {
                    v.frame = CGRectMake(f.origin.x, offset, f.size.width, f.size.height);
                }
            }
        }

        [stack addObjectsFromArray:v.subviews];
    }
}

#pragma mark - 预编辑拼音状态检测与九键重输/换行按键

static BOOL GXKIsComposingActive(UIViewController *vc) {
    if (!vc || !vc.view) return NO;
    UIView *root = vc.view;

    // 状态检测 1: 扫描 Composing 与 Candidate 视图中是否有拼音文字
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    int guard = 0;
    while (stack.count > 0 && guard++ < 1500) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];

        NSString *cls = NSStringFromClass([v class]);
        if ([cls containsString:@"Composing"] || [cls containsString:@"Candidate"]) {
            if ([v respondsToSelector:@selector(text)]) {
                NSString *t = [v valueForKey:@"text"];
                if (t.length > 0) return YES;
            }
            if ([v respondsToSelector:@selector(attributedText)]) {
                NSAttributedString *at = [v valueForKey:@"attributedText"];
                if (at.string.length > 0) return YES;
            }
        }

        // 状态检测 2: 九键右下角回车键在拼音输入中会变为「确认」或拼音文字
        if ([cls isEqualToString:@"GKBSoftKeyView"]) {
            CGPoint p = [v convertPoint:CGPointZero toView:root];
            if (p.x > root.bounds.size.width * 0.70 && p.y > 150.0) {
                for (UIView *sub in v.subviews) {
                    if ([sub isKindOfClass:[UILabel class]]) {
                        NSString *txt = ((UILabel *)sub).text;
                        if ([txt isEqualToString:@"确认"] || [txt containsString:@"确"] || [txt isEqualToString:@"Enter"]) {
                            return YES;
                        }
                    }
                }
            }
        }

        [stack addObjectsFromArray:v.subviews];
    }
    return NO;
}

static void GXKClearComposing(UIViewController *vc) {
    if (!vc) return;

    // 1. 调用 Gboard 内部的 abortComposing
    SEL selAbort = NSSelectorFromString(@"abortComposing");
    NSMutableArray *targets = [NSMutableArray arrayWithObject:vc];
    unsigned int count = 0;
    Ivar *ivars = class_copyIvarList([vc class], &count);
    for (unsigned int i = 0; i < count; i++) {
        id val = object_getIvar(vc, ivars[i]);
        if (val && [val isKindOfClass:[NSObject class]]) {
            [targets addObject:val];
        }
    }
    if (ivars) free(ivars);

    for (id t in targets) {
        if ([t respondsToSelector:selAbort]) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [t performSelector:selAbort];
            #pragma clang diagnostic pop
        }
    }

    // 2. 备用兜底方案：模拟触发 Delete 退格键清除拼音
    UIView *delKey = nil;
    CGFloat w = vc.view.bounds.size.width;
    for (UIView *v in vc.view.subviews) {
        NSMutableArray *st = [NSMutableArray arrayWithObject:v];
        int g = 0;
        while (st.count > 0 && g++ < 1000) {
            UIView *cur = st.lastObject;
            [st removeLastObject];
            if ([NSStringFromClass([cur class]) isEqualToString:@"GKBSoftKeyView"]) {
                NSString *acc = cur.accessibilityLabel ?: @"";
                CGPoint p = [cur convertPoint:CGPointZero toView:vc.view];
                if ([acc containsString:@"Delete"] || [acc containsString:@"Backspace"] ||
                    (p.x > w * 0.72 && p.y > 40.0 && p.y < 95.0)) {
                    delKey = cur;
                    break;
                }
            }
            [st addObjectsFromArray:cur.subviews];
        }
        if (delKey) break;
    }

    if (delKey) {
        for (int i = 0; i < 10; i++) {
            if ([delKey respondsToSelector:@selector(touchesBegan:withEvent:)]) {
                [delKey touchesBegan:[NSSet set] withEvent:nil];
            }
            if ([delKey respondsToSelector:@selector(touchesEnded:withEvent:)]) {
                [delKey touchesEnded:[NSSet set] withEvent:nil];
            }
        }
    }

    // 3. 解除可能存在的 markedText
    UIInputViewController *ivc = (UIInputViewController *)vc;
    if ([ivc.textDocumentProxy respondsToSelector:@selector(unmarkText)]) {
        [ivc.textDocumentProxy unmarkText];
    }
}

#pragma mark - 动作键目标与更新

@interface GXKActionKeyTarget : NSObject
- (void)onActionKeyTapped:(UIButton *)sender;
@end

@implementation GXKActionKeyTarget
- (void)onActionKeyTapped:(UIButton *)sender {
    if (!gCurrentVC) return;
    UIInputViewController *ivc = (UIInputViewController *)gCurrentVC;
    id<UITextDocumentProxy> proxy = ivc.textDocumentProxy;

    BOOL composing = GXKIsComposingActive(gCurrentVC);
    if (composing) {
        // 重输模式：清空未提交的拼音
        GXKClearComposing(gCurrentVC);
        UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
        [fb impactOccurred];
    } else {
        // 换行模式：插入换行符
        if (proxy) {
            [proxy insertText:@"\n"];
        }
        UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [fb impactOccurred];
    }

    // 点击后立即刷新状态
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        if (gCurrentVC) {
            extern void GXKUpdateActionKey(UIViewController *vc);
            GXKUpdateActionKey(gCurrentVC);
        }
    });
}
@end

static GXKActionKeyTarget *gActionTarget;

void GXKUpdateActionKey(UIViewController *vc) {
    if (!vc || !vc.view) return;
    UIView *root = vc.view;

    // 定位九键回车上方表情键（第 5 列，y 在 80~160pt）
    if (!gEmojiSoftKeyView || !gEmojiSoftKeyView.window) {
        CGFloat w = root.bounds.size.width;
        CGFloat rightColX = w * 0.70;
        for (UIView *v in root.subviews) {
            NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:v];
            int g = 0;
            while (stack.count > 0 && g++ < 1200) {
                UIView *sub = stack.lastObject;
                [stack removeLastObject];
                if ([NSStringFromClass([sub class]) isEqualToString:@"GKBSoftKeyView"]) {
                    CGPoint p = [sub convertPoint:CGPointZero toView:root];
                    if (p.x > rightColX && p.y > 80.0 && p.y < 165.0) {
                        gEmojiSoftKeyView = sub;
                        break;
                    }
                }
                [stack addObjectsFromArray:sub.subviews];
            }
            if (gEmojiSoftKeyView) break;
        }
    }

    if (gEmojiSoftKeyView) {
        UIView *key = gEmojiSoftKeyView;
        if (!gActionTarget) gActionTarget = [[GXKActionKeyTarget alloc] init];

        UIButton *btn = [key viewWithTag:GXK_ACTION_TAG];
        if (!btn) {
            btn = [UIButton buttonWithType:UIButtonTypeCustom];
            btn.tag = GXK_ACTION_TAG;
            btn.frame = key.bounds;
            btn.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            btn.titleLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightMedium];
            [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            btn.layer.cornerRadius = 5.0;
            btn.layer.masksToBounds = YES;
            [btn addTarget:gActionTarget action:@selector(onActionKeyTapped:) forControlEvents:UIControlEventTouchUpInside];
            [key addSubview:btn];
            key.userInteractionEnabled = YES;

            // 隐藏该按键原有的笑脸表情图标
            for (UIView *kid in key.subviews) {
                if (kid != btn) kid.hidden = YES;
            }
        }
        gActionKeyButton = btn;

        BOOL isDark = GXKIsCurrentDark(vc ? vc.view : nil);
        BOOL composing = GXKIsComposingActive(vc);
        if (composing) {
            [btn setTitle:@"重输" forState:UIControlStateNormal];
            btn.backgroundColor = [UIColor colorWithRed:0.85 green:0.30 blue:0.25 alpha:0.95]; // 醒目微红
            [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            btn.layer.borderWidth = 0.0;
        } else {
            [btn setTitle:@"换行" forState:UIControlStateNormal];
            if (isDark) {
                btn.backgroundColor = [UIColor colorWithWhite:0.25 alpha:0.85]; // 沉稳深灰
                [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
                btn.layer.borderWidth = 0.0;
            } else {
                btn.backgroundColor = [UIColor colorWithWhite:0.88 alpha:0.95]; // 优雅浅灰
                [btn setTitleColor:[UIColor colorWithWhite:0.15 alpha:1.0] forState:UIControlStateNormal];
                btn.layer.borderColor = [UIColor colorWithWhite:0.75 alpha:0.7].CGColor;
                btn.layer.borderWidth = 0.5;
            }
        }
        [key bringSubviewToFront:btn];
    }
}

#pragma mark - 下滑收起键盘手势 (安全限定顶部 y<46pt，cancelsTouchesInView=NO)

@interface GXKSwipeDismissDelegate : NSObject <UIGestureRecognizerDelegate>
@end

@implementation GXKSwipeDismissDelegate

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    CGPoint pt = [gestureRecognizer locationInView:gestureRecognizer.view];
    if (pt.y > 46.0) return NO;
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    CGPoint pt = [touch locationInView:gestureRecognizer.view];
    if (pt.y > 46.0) return NO;
    return YES;
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    if (!gCurrentVC) return;
    if (pan.state == UIGestureRecognizerStateEnded) {
        CGPoint translation = [pan translationInView:gCurrentVC.view];
        CGPoint velocity = [pan velocityInView:gCurrentVC.view];
        if ((translation.y > 35.0 && fabs(translation.y) > fabs(translation.x) * 1.2) ||
            (velocity.y > 250.0 && fabs(velocity.y) > fabs(velocity.x) * 1.3)) {
            UIInputViewController *ivc = (UIInputViewController *)gCurrentVC;
            if ([ivc respondsToSelector:@selector(dismissKeyboard)]) {
                [ivc dismissKeyboard];
            }
        }
    }
}

@end

static GXKSwipeDismissDelegate *gDismissDelegate;

static void GXKSetupSwipeDismiss(UIViewController *vc) {
    if (!vc || !vc.view) return;
    for (UIGestureRecognizer *g in vc.view.gestureRecognizers) {
        if ([objc_getAssociatedObject(g, "gxk_swipe_dismiss") boolValue]) return;
    }
    if (!gDismissDelegate) gDismissDelegate = [[GXKSwipeDismissDelegate alloc] init];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:gDismissDelegate action:@selector(handlePan:)];
    pan.delegate = gDismissDelegate;
    pan.cancelsTouchesInView = NO;
    pan.delaysTouchesBegan = NO;
    pan.delaysTouchesEnded = NO;
    objc_setAssociatedObject(pan, "gxk_swipe_dismiss", @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [vc.view addGestureRecognizer:pan];
}

#pragma mark - 顶部轻量工具栏与设置面板

static void GXKShowSettingsModal(UIViewController *vc);

@interface GXKToolbarTarget : NSObject
@end

@implementation GXKToolbarTarget

- (void)onSelectAllCopy {
    if (!gCurrentVC) return;
    UIInputViewController *ivc = (UIInputViewController *)gCurrentVC;
    id<UITextDocumentProxy> proxy = ivc.textDocumentProxy;
    if (!proxy) return;

    // 真正实用的全选操作：全选并直接复制到系统剪贴板，彻底废除 setMarkedText，绝不产生并排重复文字
    NSString *before = proxy.documentContextBeforeInput ?: @"";
    NSString *after = proxy.documentContextAfterInput ?: @"";
    NSString *full = [before stringByAppendingString:after];
    if (full.length > 0) {
        [UIPasteboard generalPasteboard].string = full;
        UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [fb impactOccurred];
    }
}

- (void)onClearAll {
    if (!gCurrentVC) return;
    UIInputViewController *ivc = (UIInputViewController *)gCurrentVC;
    id<UITextDocumentProxy> proxy = ivc.textDocumentProxy;
    if (!proxy) return;
    NSString *ctx = proxy.documentContextBeforeInput;
    for (NSUInteger i = 0; i < ctx.length; i++) {
        [proxy deleteBackward];
    }
    UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [fb impactOccurred];
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
    UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [fb impactOccurred];
}

- (void)onPaste {
    if (!gCurrentVC) return;
    UIInputViewController *ivc = (UIInputViewController *)gCurrentVC;
    id<UITextDocumentProxy> proxy = ivc.textDocumentProxy;
    if (!proxy) return;
    NSString *str = [UIPasteboard generalPasteboard].string;
    if (str.length > 0) {
        [proxy insertText:str];
        UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [fb impactOccurred];
    }
}

- (void)onUndo {
    if (!gCurrentVC) return;
    UIInputViewController *ivc = (UIInputViewController *)gCurrentVC;
    id<UITextDocumentProxy> proxy = ivc.textDocumentProxy;
    if (!proxy) return;
    [proxy deleteBackward];
}

- (void)onOpenSettings {
    if (gCurrentVC) GXKShowSettingsModal(gCurrentVC);
}

@end

static GXKToolbarTarget *gToolbarTarget;

static UIButton *GXKCreateToolButton(NSString *title, SEL action) {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    [btn setTitle:title forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightMedium];
    btn.layer.cornerRadius = 6.0;
    btn.layer.masksToBounds = YES;
    btn.contentEdgeInsets = UIEdgeInsetsMake(4, 8, 4, 8);
    [btn addTarget:gToolbarTarget action:action forControlEvents:UIControlEventTouchUpInside];
    return btn;
}

static void GXKUpdateToolbarTheme(BOOL isDark) {
    if (!gToolbarView) return;
    gToolbarView.backgroundColor = isDark ? [UIColor colorWithWhite:0.10 alpha:0.75]
                                          : [UIColor colorWithWhite:0.95 alpha:0.85];
    for (UIView *sub in gToolbarView.subviews) {
        if ([sub isKindOfClass:[UIStackView class]]) {
            for (UIView *btn in sub.subviews) {
                if ([btn isKindOfClass:[UIButton class]]) {
                    UIButton *b = (UIButton *)btn;
                    if (isDark) {
                        b.backgroundColor = [UIColor colorWithWhite:0.25 alpha:0.70];
                        [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
                        b.layer.borderColor = [UIColor clearColor].CGColor;
                        b.layer.borderWidth = 0.0;
                    } else {
                        b.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.90];
                        [b setTitleColor:[UIColor colorWithWhite:0.15 alpha:1.0] forState:UIControlStateNormal];
                        b.layer.borderColor = [UIColor colorWithWhite:0.80 alpha:0.8].CGColor;
                        b.layer.borderWidth = 0.5;
                    }
                }
            }
        }
    }
}

static void GXKSetupToolbar(UIViewController *vc) {
    if (!vc || !vc.view) return;
    if (gToolbarView && gToolbarView.superview == vc.view) {
        GXKUpdateToolbarTheme(GXKIsCurrentDark(vc.view));
        return;
    }

    if (!gToolbarTarget) gToolbarTarget = [[GXKToolbarTarget alloc] init];

    CGFloat width = vc.view.bounds.size.width;
    CGFloat toolbarHeight = 32.0;

    gToolbarView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, toolbarHeight)];
    gToolbarView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleBottomMargin;

    UIStackView *stack = [[UIStackView alloc] initWithFrame:gToolbarView.bounds];
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.distribution = UIStackViewDistributionEqualSpacing;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    stack.layoutMargins = UIEdgeInsetsMake(0, 8, 0, 8);
    stack.layoutMarginsRelativeArrangement = YES;

    [stack addArrangedSubview:GXKCreateToolButton(@"全选复制", @selector(onSelectAllCopy))];
    [stack addArrangedSubview:GXKCreateToolButton(@"剪切", @selector(onCut))];
    [stack addArrangedSubview:GXKCreateToolButton(@"粘贴", @selector(onPaste))];
    [stack addArrangedSubview:GXKCreateToolButton(@"撤销", @selector(onUndo))];
    [stack addArrangedSubview:GXKCreateToolButton(@"清空", @selector(onClearAll))];
    [stack addArrangedSubview:GXKCreateToolButton(@"⚙️设置", @selector(onOpenSettings))];

    [gToolbarView addSubview:stack];
    [vc.view addSubview:gToolbarView];
    [vc.view bringSubviewToFront:gToolbarView];

    GXKUpdateToolbarTheme(GXKIsCurrentDark(vc.view));
}

#pragma mark - 悬浮设置面板 (高度调节 + 词库管理)

@interface GXKSettingsHandler : NSObject
@end

@implementation GXKSettingsHandler

- (void)onHeightChanged:(UISegmentedControl *)seg {
    CGFloat offsets[] = {0.0, 20.0, 34.0, 50.0};
    NSInteger idx = seg.selectedSegmentIndex;
    if (idx >= 0 && idx < 4) {
        CGFloat off = offsets[idx];
        NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:GXKGroup];
        [d setDouble:off forKey:GXKHeightOffsetKey];
        [d synchronize];

        if (gCurrentVC && gCurrentVC.view) {
            CGFloat base = (gBaseKeyboardHeight > 150.0) ? gBaseKeyboardHeight : 276.0;
            if (gHeightConstraint) {
                gHeightConstraint.constant = base + off;
            }
            [gCurrentVC.view setNeedsUpdateConstraints];
            [gCurrentVC.view updateConstraintsIfNeeded];
            [gCurrentVC.view setNeedsLayout];
            [gCurrentVC.view layoutIfNeeded];
            GXKCleanAndShiftUI(gCurrentVC.view);
        }
    }
}

- (void)onDictToggle:(UISwitch *)sw {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:GXKGroup];
    [d setBool:sw.isOn forKey:GXKDictEnabledKey];
    [d synchronize];

    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *containerURL = [fm containerURLForSecurityApplicationGroupIdentifier:GXKGroup];
    NSURL *activeURL = [containerURL URLByAppendingPathComponent:@"user_dictionary.db"];
    NSURL *disabledURL = [containerURL URLByAppendingPathComponent:@"user_dictionary.db.disabled"];

    if (!sw.isOn && [fm fileExistsAtPath:activeURL.path]) {
        [fm moveItemAtURL:activeURL toURL:disabledURL error:nil];
    } else if (sw.isOn && [fm fileExistsAtPath:disabledURL.path]) {
        [fm moveItemAtURL:disabledURL toURL:activeURL error:nil];
    }
}

- (void)onImportClipboard {
    NSString *txt = [UIPasteboard generalPasteboard].string;
    if (txt.length == 0) return;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *containerURL = [fm containerURLForSecurityApplicationGroupIdentifier:GXKGroup];
    NSURL *userTxtURL = [containerURL URLByAppendingPathComponent:@"user_import.txt"];
    NSData *data = [txt dataUsingEncoding:NSUTF8StringEncoding];

    if ([fm fileExistsAtPath:userTxtURL.path]) {
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:userTxtURL.path];
        [handle seekToEndOfFile];
        [handle writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
        [handle writeData:data];
        [handle closeFile];
    } else {
        [data writeToURL:userTxtURL atomically:YES];
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"导入完成"
                                                                   message:@"已成功将剪贴板内容暂存至本地词表库！"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
    if (gCurrentVC) [gCurrentVC presentViewController:alert animated:YES completion:nil];
}

- (void)onAppearanceChanged:(UISegmentedControl *)seg {
    NSString *val = @"system";
    if (seg.selectedSegmentIndex == 1) val = @"light";
    else if (seg.selectedSegmentIndex == 2) val = @"dark";

    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:GXKGroup];
    [d setObject:val forKey:GXKAppearanceKey];
    [d synchronize];

    UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [fb impactOccurred];

    if (gCurrentVC) {
        GXKApplyAppearance(gCurrentVC);
        // 重新刷新设置面板自身样式
        if (gSettingsModalView) {
            [gSettingsModalView removeFromSuperview];
            gSettingsModalView = nil;
            GXKShowSettingsModal(gCurrentVC);
        }
    }
}

- (void)onClose {
    [gSettingsModalView removeFromSuperview];
    gSettingsModalView = nil;
}

@end

static GXKSettingsHandler *gSettingsHandler;

static void GXKShowSettingsModal(UIViewController *vc) {
    if (!vc || !vc.view) return;
    if (gSettingsModalView) {
        [gSettingsModalView removeFromSuperview];
        gSettingsModalView = nil;
        return;
    }
    if (!gSettingsHandler) gSettingsHandler = [[GXKSettingsHandler alloc] init];

    BOOL isDark = GXKIsCurrentDark(vc.view);
    CGFloat w = vc.view.bounds.size.width;
    CGFloat h = 255.0;
    gSettingsModalView = [[UIView alloc] initWithFrame:CGRectMake(12, 36, w - 24, h)];
    gSettingsModalView.backgroundColor = isDark ? [UIColor colorWithRed:0.16 green:0.16 blue:0.18 alpha:0.98]
                                                : [UIColor colorWithRed:0.95 green:0.95 blue:0.97 alpha:0.98];
    gSettingsModalView.layer.cornerRadius = 14.0;
    gSettingsModalView.layer.masksToBounds = YES;
    gSettingsModalView.layer.borderColor = isDark ? [UIColor colorWithWhite:0.35 alpha:0.5].CGColor
                                                  : [UIColor colorWithWhite:0.80 alpha:0.9].CGColor;
    gSettingsModalView.layer.borderWidth = 1.0;

    UIColor *titleColor = isDark ? [UIColor whiteColor] : [UIColor colorWithWhite:0.10 alpha:1.0];
    UIColor *labelColor = isDark ? [UIColor lightGrayColor] : [UIColor colorWithWhite:0.35 alpha:1.0];

    // 标题
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, 12, w - 56, 22)];
    title.text = @"Gboard GKX 增强设置";
    title.textColor = titleColor;
    title.font = [UIFont systemFontOfSize:16 weight:UIFontWeightBold];
    [gSettingsModalView addSubview:title];

    // 1. 键盘高度调节
    UILabel *lblHeight = [[UILabel alloc] initWithFrame:CGRectMake(16, 44, 75, 26)];
    lblHeight.text = @"键盘高度";
    lblHeight.textColor = labelColor;
    lblHeight.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
    [gSettingsModalView addSubview:lblHeight];

    UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:@[@"紧凑", @"标准", @"偏高", @"较高"]];
    seg.frame = CGRectMake(90, 43, w - 130, 28);
    CGFloat curOff = GXKGetHeightOffset();
    if (curOff <= 5.0) seg.selectedSegmentIndex = 0;
    else if (curOff <= 25.0) seg.selectedSegmentIndex = 1;
    else if (curOff <= 40.0) seg.selectedSegmentIndex = 2;
    else seg.selectedSegmentIndex = 3;
    [seg addTarget:gSettingsHandler action:@selector(onHeightChanged:) forControlEvents:UIControlEventValueChanged];
    [gSettingsModalView addSubview:seg];

    // 2. 外观模式调节 (跟随系统 / 浅色 / 深色)
    UILabel *lblTheme = [[UILabel alloc] initWithFrame:CGRectMake(16, 82, 75, 26)];
    lblTheme.text = @"外观模式";
    lblTheme.textColor = labelColor;
    lblTheme.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
    [gSettingsModalView addSubview:lblTheme];

    UISegmentedControl *segTheme = [[UISegmentedControl alloc] initWithItems:@[@"跟随系统", @"浅色", @"深色"]];
    segTheme.frame = CGRectMake(90, 81, w - 130, 28);
    NSString *curApp = GXKGetAppearance();
    if ([curApp isEqualToString:@"light"]) segTheme.selectedSegmentIndex = 1;
    else if ([curApp isEqualToString:@"dark"]) segTheme.selectedSegmentIndex = 2;
    else segTheme.selectedSegmentIndex = 0;
    [segTheme addTarget:gSettingsHandler action:@selector(onAppearanceChanged:) forControlEvents:UIControlEventValueChanged];
    [gSettingsModalView addSubview:segTheme];

    // 3. 词库开关
    UILabel *lblDict = [[UILabel alloc] initWithFrame:CGRectMake(16, 122, 120, 26)];
    lblDict.text = @"启用万象词库";
    lblDict.textColor = labelColor;
    lblDict.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
    [gSettingsModalView addSubview:lblDict];

    UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(w - 75, 119, 51, 31)];
    sw.on = GXKIsDictEnabled();
    [sw addTarget:gSettingsHandler action:@selector(onDictToggle:) forControlEvents:UIControlEventValueChanged];
    [gSettingsModalView addSubview:sw];

    // 4. 从剪贴板导入
    UIButton *btnImport = [UIButton buttonWithType:UIButtonTypeSystem];
    btnImport.frame = CGRectMake(16, 160, w - 56, 32);
    [btnImport setTitle:@"📥 从系统剪贴板导入词条" forState:UIControlStateNormal];
    btnImport.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    [btnImport setTitleColor:[UIColor colorWithRed:0.20 green:0.60 blue:1.0 alpha:1.0] forState:UIControlStateNormal];
    btnImport.backgroundColor = isDark ? [UIColor colorWithWhite:0.25 alpha:0.5]
                                       : [UIColor colorWithWhite:0.90 alpha:0.7];
    btnImport.layer.cornerRadius = 6.0;
    [btnImport addTarget:gSettingsHandler action:@selector(onImportClipboard) forControlEvents:UIControlEventTouchUpInside];
    [gSettingsModalView addSubview:btnImport];

    // 5. 完成关闭按钮
    UIButton *btnClose = [UIButton buttonWithType:UIButtonTypeSystem];
    btnClose.frame = CGRectMake(16, 204, w - 56, 34);
    [btnClose setTitle:@"完成" forState:UIControlStateNormal];
    btnClose.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightBold];
    [btnClose setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    btnClose.backgroundColor = [UIColor colorWithRed:0.22 green:0.55 blue:0.95 alpha:1.0];
    btnClose.layer.cornerRadius = 7.0;
    [btnClose addTarget:gSettingsHandler action:@selector(onClose) forControlEvents:UIControlEventTouchUpInside];
    [gSettingsModalView addSubview:btnClose];

    [vc.view addSubview:gSettingsModalView];
    [vc.view bringSubviewToFront:gSettingsModalView];
}

#pragma mark - 外部词库预置与安全加载 (6万轻量版)

static void GXKEnsureUserDictionaryDeployed(void) {
    if (!GXKIsDictEnabled()) return;

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
        [fm copyItemAtPath:bundlePath toPath:targetDBURL.path error:nil];
    }
}

#pragma mark - 视图生命周期 Hook

static void gkx_updateViewConstraints(id self, SEL _cmd) {
    if (gOrigUpdateViewConstraints) gOrigUpdateViewConstraints(self, _cmd);
    UIViewController *vc = (UIViewController *)self;
    if (!vc || !vc.view) return;

    if (gBaseKeyboardHeight <= 0.0 && vc.view.bounds.size.height > 150.0) {
        gBaseKeyboardHeight = vc.view.bounds.size.height;
    }
    CGFloat base = (gBaseKeyboardHeight > 150.0) ? gBaseKeyboardHeight : 276.0;
    CGFloat offset = GXKGetHeightOffset();

    if (!gHeightConstraint || gHeightConstraint.firstItem != vc.view) {
        gHeightConstraint = [NSLayoutConstraint constraintWithItem:vc.view
                                                         attribute:NSLayoutAttributeHeight
                                                         relatedBy:NSLayoutRelationEqual
                                                            toItem:nil
                                                         attribute:NSLayoutAttributeNotAnAttribute
                                                        multiplier:1.0
                                                          constant:base + offset];
        gHeightConstraint.priority = 999;
        [vc.view addConstraint:gHeightConstraint];
    } else {
        gHeightConstraint.constant = base + offset;
    }
}

static void gkx_textDidChange(id self, SEL _cmd, id textInput) {
    if (gOrigTextDidChange) gOrigTextDidChange(self, _cmd, textInput);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gCurrentVC) GXKUpdateActionKey(gCurrentVC);
    });
}

static void (*gOrigTraitCollectionDidChange)(id, SEL, UITraitCollection *);

static void gkx_traitCollectionDidChange(id self, SEL _cmd, UITraitCollection *prev) {
    if (gOrigTraitCollectionDidChange) gOrigTraitCollectionDidChange(self, _cmd, prev);
    UIViewController *vc = (UIViewController *)self;
    if (vc && [vc isViewLoaded]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            GXKApplyAppearance(vc);
        });
    }
}

static void gkx_viewWillAppear(id self, SEL _cmd, BOOL animated) {
    if (gOrigViewWillAppear) gOrigViewWillAppear(self, _cmd, animated);
    gCurrentVC = (UIViewController *)self;
    GXKEnsureUserDictionaryDeployed();
    GXKApplyAppearance(gCurrentVC);

    // 启动状态轮询定时器 (0.25s 极轻量轮询，实时同步「重输」/「换行」)
    if (!gStatePollTimer) {
        gStatePollTimer = [NSTimer scheduledTimerWithTimeInterval:0.25
                                                           target:[NSBlockOperation blockOperationWithBlock:^{
            if (gCurrentVC) GXKUpdateActionKey(gCurrentVC);
        }]
                                                         selector:@selector(main)
                                                         userInfo:nil
                                                          repeats:YES];
    }
}

static void gkx_viewWillDisappear(id self, SEL _cmd, BOOL animated) {
    if (gOrigViewWillDisappear) gOrigViewWillDisappear(self, _cmd, animated);
    if (gStatePollTimer) {
        [gStatePollTimer invalidate];
        gStatePollTimer = nil;
    }
}

static void gkx_viewDidAppear(id self, SEL _cmd, BOOL animated) {
    if (gOrigViewDidAppear) gOrigViewDidAppear(self, _cmd, animated);
    gCurrentVC = (UIViewController *)self;
    UIView *root = gCurrentVC.view;
    if (!root) return;

    if (gBaseKeyboardHeight <= 0.0 && root.bounds.size.height > 150.0) {
        gBaseKeyboardHeight = root.bounds.size.height;
    }

    // 1. 设置下滑收起键盘手势 (安全限定顶部 y<46pt)
    GXKSetupSwipeDismiss(gCurrentVC);

    // 2. 自适应外观模式 (透明顶层容器，宿主 App 视野完全清透，键盘依设置/系统切换浅深色)
    GXKApplyAppearance(gCurrentVC);

    // 3. 界面清理与布局下移避让
    GXKCleanAndShiftUI(root);

    // 4. 挂载顶部快捷编辑工具栏
    GXKSetupToolbar(gCurrentVC);

    // 5. 挂载九键重输/换行按键
    GXKUpdateActionKey(gCurrentVC);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 350 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        if (gCurrentVC && gCurrentVC.view) {
            GXKApplyAppearance(gCurrentVC);
            GXKCleanAndShiftUI(gCurrentVC.view);
            GXKUpdateActionKey(gCurrentVC);
        }
    });
}

#pragma mark - dylib 构造入口

__attribute__((constructor))
static void gkx_init(void) {
    GXK_LOG(@"libgkx 初始化注入 (自适应浅色/深色外观版)...");

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
        Method mDis = class_getInstanceMethod(vcClass, @selector(viewWillDisappear:));
        if (mDis) {
            gOrigViewWillDisappear = (void (*)(id, SEL, BOOL))method_getImplementation(mDis);
            method_setImplementation(mDis, (IMP)gkx_viewWillDisappear);
        }
        Method mConst = class_getInstanceMethod(vcClass, @selector(updateViewConstraints));
        if (mConst) {
            gOrigUpdateViewConstraints = (void (*)(id, SEL))method_getImplementation(mConst);
            method_setImplementation(mConst, (IMP)gkx_updateViewConstraints);
        }
        Method mText = class_getInstanceMethod(vcClass, @selector(textDidChange:));
        if (mText) {
            gOrigTextDidChange = (void (*)(id, SEL, id))method_getImplementation(mText);
            method_setImplementation(mText, (IMP)gkx_textDidChange);
        }
        Method mTrait = class_getInstanceMethod(vcClass, @selector(traitCollectionDidChange:));
        if (mTrait) {
            IMP newImp = (IMP)gkx_traitCollectionDidChange;
            const char *types = method_getTypeEncoding(mTrait);
            if (class_addMethod(vcClass, @selector(traitCollectionDidChange:), newImp, types)) {
                gOrigTraitCollectionDidChange = (void (*)(id, SEL, UITraitCollection *))method_getImplementation(mTrait);
            } else {
                gOrigTraitCollectionDidChange = (void (*)(id, SEL, UITraitCollection *))method_getImplementation(mTrait);
                method_setImplementation(mTrait, newImp);
            }
        }
    }
}
