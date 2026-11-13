// gkx.m — Gboard iOS 键盘定制 dylib (极简重制版)
//
// 核心范围：
//   1. 外部万象词库 (user_dictionary.db) 自动部署到 App Group 共享容器
//   2. 九键界面回车键上方表情键替换为「重输」/「换行」动态切换按键
// 其余一切界面与输入逻辑均完全保持 Gboard 官方原生！

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

#define GXK_LOG(fmt, ...) NSLog(@"[GXK] " fmt, ##__VA_ARGS__)
#define GXK_ACTION_TAG 0x47584B41  // 'GXKA'

static NSString *const GXKGroup = @"group.zunbengege.top";

#pragma mark - 全局状态

static __weak UIViewController *gCurrentVC;
static __weak UIView *gEmojiSoftKeyView;
static UIButton *gActionKeyButton;
static NSTimer *gStatePollTimer;

// 原实现函数指针
static void (*gOrigViewDidAppear)(id, SEL, BOOL);
static void (*gOrigViewWillAppear)(id, SEL, BOOL);
static void (*gOrigViewWillDisappear)(id, SEL, BOOL);
static void (*gOrigTextDidChange)(id, SEL, id);

#pragma mark - 外部词库自动部署 (防 Jetsam 轻量版)

static void GXKEnsureUserDictionaryDeployed(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *containerURL = [fm containerURLForSecurityApplicationGroupIdentifier:GXKGroup];
    if (!containerURL) {
        GXK_LOG(@"[!] App Group 容器不可用: %@", GXKGroup);
        return;
    }

    NSURL *targetDBURL = [containerURL URLByAppendingPathComponent:@"user_dictionary.db"];

    NSBundle *mainBundle = [NSBundle mainBundle];
    NSString *bundlePath = [mainBundle pathForResource:@"user_dictionary" ofType:@"db"];
    if (!bundlePath) {
        bundlePath = [[mainBundle bundlePath] stringByAppendingPathComponent:@"Frameworks/user_dictionary.db"];
    }
    if (!bundlePath) {
        bundlePath = [[mainBundle.bundleURL URLByAppendingPathComponent:@"../../Frameworks/user_dictionary.db"] URLByStandardizingPath].path;
    }
    if (!bundlePath || ![fm fileExistsAtPath:bundlePath]) {
        GXK_LOG(@"[*] 安装包内未找到预置 user_dictionary.db");
        return;
    }

    BOOL needCopy = YES;
    if ([fm fileExistsAtPath:targetDBURL.path]) {
        NSDictionary *srcAttrs = [fm attributesOfItemAtPath:bundlePath error:nil];
        NSDictionary *dstAttrs = [fm attributesOfItemAtPath:targetDBURL.path error:nil];
        if (srcAttrs && dstAttrs) {
            unsigned long long srcSize = [srcAttrs fileSize];
            unsigned long long dstSize = [dstAttrs fileSize];
            NSDate *srcDate = srcAttrs[NSFileModificationDate];
            NSDate *dstDate = dstAttrs[NSFileModificationDate];
            if (srcSize == dstSize && [dstDate compare:srcDate] != NSOrderedAscending) {
                needCopy = NO; // 大小一致且目标文件较新，无需重复拷贝
            }
        }
    }

    if (needCopy) {
        GXK_LOG(@"[*] 正在将预置词库部署到 App Group 共享容器...");
        [fm removeItemAtURL:targetDBURL error:nil];
        NSError *err = nil;
        if ([fm copyItemAtPath:bundlePath toPath:targetDBURL.path error:&err]) {
            GXK_LOG(@"[+] 词库部署成功: %@", targetDBURL.path);
        } else {
            GXK_LOG(@"[!] 词库部署失败: %@", err.localizedDescription);
        }
    }
}

#pragma mark - 拼音输入状态判定 (Composing)

static BOOL GXKIsComposingActive(UIViewController *vc) {
    if (!vc || !vc.view) return NO;
    UIView *root = vc.view;

    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    int guard = 0;
    while (stack.count > 0 && guard++ < 1500) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];

        if (v.isHidden || v.alpha < 0.05) continue;

        NSString *cls = NSStringFromClass([v class]);

        // 判定 1: 扫描 Composing 与 Preedit 视图中是否有拼音文字
        if ([cls containsString:@"Composing"] || [cls containsString:@"Preedit"]) {
            if ([v respondsToSelector:@selector(text)]) {
                NSString *t = [v valueForKey:@"text"];
                if (t.length > 0) return YES;
            }
            if ([v respondsToSelector:@selector(attributedText)]) {
                NSAttributedString *at = [v valueForKey:@"attributedText"];
                if (at.string.length > 0) return YES;
            }
            for (UIView *sub in v.subviews) {
                if ([sub respondsToSelector:@selector(text)]) {
                    NSString *t = [sub valueForKey:@"text"];
                    if (t.length > 0) return YES;
                }
            }
        }

        // 判定 2: 九键右下角回车键在拼音输入中会变为「确认」
        if ([cls isEqualToString:@"GKBSoftKeyView"]) {
            CGPoint p = [v convertPoint:CGPointZero toView:root];
            if (p.x > root.bounds.size.width * 0.70 && p.y > 150.0) {
                for (UIView *sub in v.subviews) {
                    if ([sub isKindOfClass:[UILabel class]]) {
                        NSString *txt = ((UILabel *)sub).text;
                        if ([txt isEqualToString:@"确认"] || [txt containsString:@"确"]) {
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

#pragma mark - 清空拼音 (重输)

static void GXKPerformClearComposing(UIViewController *vc) {
    if (!vc) return;

    // 1. 调用 Gboard 原生 resetKeyboard
    SEL selReset = NSSelectorFromString(@"resetKeyboard");
    if ([vc respondsToSelector:selReset]) {
        ((void (*)(id, SEL))objc_msgSend)(vc, selReset);
    }

    // 2. 调用 abortComposing
    SEL selAbort = NSSelectorFromString(@"abortComposing");
    if ([vc respondsToSelector:selAbort]) {
        ((void (*)(id, SEL))objc_msgSend)(vc, selAbort);
    }

    // 3. 在 ivar 对象上兜底调用 reset/abort
    unsigned int count = 0;
    Ivar *ivars = class_copyIvarList([vc class], &count);
    for (unsigned int i = 0; i < count; i++) {
        id val = object_getIvar(vc, ivars[i]);
        if (val && [val isKindOfClass:[NSObject class]]) {
            if ([val respondsToSelector:selAbort]) {
                #pragma clang diagnostic push
                #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                [val performSelector:selAbort];
                #pragma clang diagnostic pop
            }
            if ([val respondsToSelector:selReset]) {
                #pragma clang diagnostic push
                #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                [val performSelector:selReset];
                #pragma clang diagnostic pop
            }
        }
    }
    if (ivars) free(ivars);

    // 4. 清除宿主 markedText
    if ([vc isKindOfClass:[UIInputViewController class]]) {
        UIInputViewController *ivc = (UIInputViewController *)vc;
        if ([ivc.textDocumentProxy respondsToSelector:@selector(unmarkText)]) {
            [ivc.textDocumentProxy unmarkText];
        }
    }
}

#pragma mark - 动作键目标与更新

@interface GXKActionKeyTarget : NSObject
- (void)onActionKeyTapped:(UIButton *)sender;
@end

static void GXKUpdateActionKey(UIViewController *vc);

@implementation GXKActionKeyTarget
- (void)onActionKeyTapped:(UIButton *)sender {
    if (!gCurrentVC) return;
    UIInputViewController *ivc = (UIInputViewController *)gCurrentVC;
    id<UITextDocumentProxy> proxy = ivc.textDocumentProxy;

    BOOL composing = GXKIsComposingActive(gCurrentVC);
    if (composing) {
        // 重输模式：清空未提交的拼音
        GXKPerformClearComposing(gCurrentVC);
        if (@available(iOS 10.0, *)) {
            UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
            [fb impactOccurred];
        }
    } else {
        // 换行模式：插入换行符
        if (proxy) {
            [proxy insertText:@"\n"];
        }
        if (@available(iOS 10.0, *)) {
            UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
            [fb impactOccurred];
        }
    }

    // 点击后立即刷新状态
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        if (gCurrentVC) {
            GXKUpdateActionKey(gCurrentVC);
        }
    });
}
@end

static GXKActionKeyTarget *gActionTarget;

static UIView *GXKFindNineKeyEmojiKey(UIView *root) {
    if (!root) return nil;
    CGFloat w = root.bounds.size.width;
    CGFloat rightColX = w * 0.70;

    // 先定位九键键盘容器
    UIView *nineContainer = nil;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    int guard = 0;
    while (stack.count > 0 && guard++ < 1000) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        NSString *cls = NSStringFromClass([v class]);
        if ([cls containsString:@"9Key"] && !v.isHidden) {
            nineContainer = v;
            break;
        }
        [stack addObjectsFromArray:v.subviews];
    }

    UIView *searchRoot = nineContainer ?: root;
    stack = [NSMutableArray arrayWithObject:searchRoot];
    guard = 0;
    while (stack.count > 0 && guard++ < 1200) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];

        if (v.isHidden || v.alpha < 0.05) continue;

        NSString *cls = NSStringFromClass([v class]);
        if ([cls isEqualToString:@"GKBSoftKeyView"]) {
            CGPoint p = [v convertPoint:CGPointZero toView:root];
            // 九键右侧纵列 (x > 70%)，回车键上方 (y 在 80 ~ 165pt)
            if (p.x > rightColX && p.y > 80.0 && p.y < 165.0) {
                return v;
            }
            // 语义辅助判定
            NSString *label = [(v.accessibilityLabel ?: @"") lowercaseString];
            NSString *ident = [(v.accessibilityIdentifier ?: @"") lowercaseString];
            if (([label containsString:@"emoji"] || [label containsString:@"表情"] || [ident containsString:@"emoji"]) &&
                p.x > rightColX) {
                return v;
            }
        }
        [stack addObjectsFromArray:v.subviews];
    }
    return nil;
}

static void GXKUpdateActionKey(UIViewController *vc) {
    if (!vc || !vc.view) return;
    UIView *root = vc.view;

    if (!gEmojiSoftKeyView || !gEmojiSoftKeyView.window) {
        gEmojiSoftKeyView = GXKFindNineKeyEmojiKey(root);
    }

    if (!gEmojiSoftKeyView) {
        if (gActionKeyButton) gActionKeyButton.hidden = YES;
        return;
    }

    UIView *key = gEmojiSoftKeyView;
    if (!gActionTarget) {
        gActionTarget = [[GXKActionKeyTarget alloc] init];
    }

    UIButton *btn = [key viewWithTag:GXK_ACTION_TAG];
    if (!btn) {
        btn = [UIButton buttonWithType:UIButtonTypeCustom];
        btn.tag = GXK_ACTION_TAG;
        btn.frame = key.bounds;
        btn.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        btn.titleLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightMedium];
        btn.layer.cornerRadius = 5.0;
        btn.layer.masksToBounds = YES;
        [btn addTarget:gActionTarget action:@selector(onActionKeyTapped:) forControlEvents:UIControlEventTouchUpInside];
        [key addSubview:btn];
        key.userInteractionEnabled = YES;

        // 隐藏该按键原有表情图标，避免与文字重叠
        for (UIView *sub in key.subviews) {
            if (sub != btn) sub.hidden = YES;
        }
    }
    btn.hidden = NO;
    gActionKeyButton = btn;

    BOOL isDark = NO;
    if (@available(iOS 13.0, *)) {
        if (root.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) {
            isDark = YES;
        }
    }

    BOOL composing = GXKIsComposingActive(vc);
    if (composing) {
        // 拼音输入状态：显示「重输」
        [btn setTitle:@"重输" forState:UIControlStateNormal];
        [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        btn.backgroundColor = [UIColor colorWithRed:0.86 green:0.32 blue:0.28 alpha:0.95]; // 醒目微红
    } else {
        // 未输入状态：显示「换行」
        [btn setTitle:@"换行" forState:UIControlStateNormal];
        if (isDark) {
            [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            btn.backgroundColor = [UIColor colorWithWhite:0.35 alpha:1.0];
        } else {
            [btn setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
            btn.backgroundColor = [UIColor colorWithRed:0.82 green:0.84 blue:0.86 alpha:1.0];
        }
    }

    [key bringSubviewToFront:btn];
}

#pragma mark - 视图控制器生命周期 Hook

static void gkx_textDidChange(id self, SEL _cmd, id textInput) {
    if (gOrigTextDidChange) gOrigTextDidChange(self, _cmd, textInput);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gCurrentVC) GXKUpdateActionKey(gCurrentVC);
    });
}

static void gkx_viewWillAppear(id self, SEL _cmd, BOOL animated) {
    if (gOrigViewWillAppear) gOrigViewWillAppear(self, _cmd, animated);
    gCurrentVC = (UIViewController *)self;
    
    // 部署外部万象词库
    GXKEnsureUserDictionaryDeployed();

    // 启动状态轮询定时器 (0.2s 极轻量轮询，实时同步「重输」/「换行」)
    if (!gStatePollTimer) {
        gStatePollTimer = [NSTimer scheduledTimerWithTimeInterval:0.20
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
    gEmojiSoftKeyView = nil;
}

static void gkx_viewDidAppear(id self, SEL _cmd, BOOL animated) {
    if (gOrigViewDidAppear) gOrigViewDidAppear(self, _cmd, animated);
    gCurrentVC = (UIViewController *)self;
    
    GXKUpdateActionKey(gCurrentVC);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        if (gCurrentVC) GXKUpdateActionKey(gCurrentVC);
    });
}

#pragma mark - dylib 构造入口

__attribute__((constructor))
static void gkx_init(void) {
    GXK_LOG(@"libgkx 初始化注入 (极简万象词库 + 九键重输换行版)...");

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
        Method mText = class_getInstanceMethod(vcClass, @selector(textDidChange:));
        if (mText) {
            gOrigTextDidChange = (void (*)(id, SEL, id))method_getImplementation(mText);
            method_setImplementation(mText, (IMP)gkx_textDidChange);
        }
    }
}
