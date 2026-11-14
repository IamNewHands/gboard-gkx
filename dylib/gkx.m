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

    // 先快速检查 textDocumentProxy 是否包含 markedText
    if ([vc isKindOfClass:[UIInputViewController class]]) {
        UIInputViewController *ivc = (UIInputViewController *)vc;
        NSObject *proxy = (NSObject *)ivc.textDocumentProxy;
        if ([proxy respondsToSelector:NSSelectorFromString(@"markedText")]) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            NSString *mt = [proxy performSelector:NSSelectorFromString(@"markedText")];
            #pragma clang diagnostic pop
            if (mt && [mt isKindOfClass:[NSString class]] && mt.length > 0) return YES;
        }
    }

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
        if (@available(iOS 13.0, *)) {
            if ([ivc.textDocumentProxy respondsToSelector:@selector(unmarkText)]) {
                [ivc.textDocumentProxy unmarkText];
            }
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

static void GXKRestoreKeySubviews(UIView *key) {
    if (!key) return;
    for (UIView *sub in key.subviews) {
        if (sub != gActionKeyButton) {
            sub.hidden = NO;
        }
    }
}

static UIView *GXKFindNineKeyEmojiKey(UIView *root) {
    if (!root) return nil;

    // 1. 递归查找当前在屏幕可视区内活跃可见的九键键盘容器 (GKB9KeysSoftKeyboardView)
    UIView *active9KeyView = nil;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    int guard = 0;
    while (stack.count > 0 && guard++ < 1500) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];

        if (v.isHidden || v.alpha < 0.05 || !v.window) continue;

        NSString *cls = NSStringFromClass([v class]);
        // 关键红线：仅匹配九键软键盘 GKB9KeysSoftKeyboardView，严禁匹配 26 键 (GKBZhQwertySoftKeyboardView)
        if ([cls containsString:@"9Key"] && [cls containsString:@"SoftKeyboard"]) {
            CGRect r = [v convertRect:v.bounds toView:root];
            // 必须在可视窗口区域内且尺寸有效
            if (r.size.width > 80.0 && r.size.height > 80.0 && CGRectIntersectsRect(root.bounds, r)) {
                active9KeyView = v;
                break;
            }
        }
        [stack addObjectsFromArray:v.subviews];
    }

    // 若当前无活跃的九键键盘（例如处于 26 键 Qwerty 或英文全键盘），绝对返回 nil（彻底保持原样）
    if (!active9KeyView) {
        return nil;
    }

    // 2. 从九键容器中获取按键映射字典 allSoftKeys
    NSDictionary *allKeys = nil;
    SEL selAllKeys = NSSelectorFromString(@"allSoftKeys");
    if ([active9KeyView respondsToSelector:selAllKeys]) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        allKeys = [active9KeyView performSelector:selAllKeys];
        #pragma clang diagnostic pop
    }
    if (!allKeys || ![allKeys isKindOfClass:[NSDictionary class]]) {
        Ivar iv = class_getInstanceVariable([active9KeyView class], "_allSoftKeys");
        if (iv) {
            allKeys = object_getIvar(active9KeyView, iv);
        }
    }

    UIView *returnKey = nil;
    UIView *emojiKey = nil;

    if (allKeys && [allKeys isKindOfClass:[NSDictionary class]]) {
        returnKey = allKeys[@"key_pos_9keys_return"];
        emojiKey = allKeys[@"key_pos_9keys_emoji"];
    }

    // 3. 校验 key_pos_9keys_emoji（绝对不可为回车键 returnKey，彻底根除变到回车按钮的缺陷）
    if (emojiKey && emojiKey != returnKey && [emojiKey isKindOfClass:[UIView class]]) {
        if (!emojiKey.isHidden && emojiKey.window) {
            CGRect r = [emojiKey convertRect:emojiKey.bounds toView:root];
            if (r.size.width > 15.0 && r.size.height > 15.0 && CGRectIntersectsRect(root.bounds, r)) {
                return emojiKey;
            }
        }
    }

    // 4. 稳健兜底：若字典未直接命中，在 active9KeyView 右侧列严格查找位于回车键上方的按键
    CGFloat rightColX = active9KeyView.bounds.size.width * 0.70;
    CGFloat returnKeyY = (returnKey ? [returnKey convertPoint:CGPointZero toView:active9KeyView].y : 99999.0);

    UIView *bestCandidate = nil;
    CGFloat maxCandidateY = -1.0;

    NSMutableArray<UIView *> *subStack = [NSMutableArray arrayWithObject:active9KeyView];
    int subGuard = 0;
    while (subStack.count > 0 && subGuard++ < 300) {
        UIView *sub = subStack.lastObject;
        [subStack removeLastObject];

        if (sub != active9KeyView && [NSStringFromClass([sub class]) isEqualToString:@"GKBSoftKeyView"]) {
            if (sub != returnKey && !sub.isHidden && sub.alpha > 0.05) {
                CGPoint p = [sub convertPoint:CGPointZero toView:active9KeyView];
                if (p.x > rightColX && p.y < returnKeyY - 10.0 && p.y > 40.0) {
                    if (p.y > maxCandidateY) {
                        maxCandidateY = p.y;
                        bestCandidate = sub;
                    }
                }
            }
        }
        [subStack addObjectsFromArray:sub.subviews];
    }

    return bestCandidate;
}

static void GXKUpdateActionKey(UIViewController *vc) {
    if (!vc || !vc.view) return;
    UIView *root = vc.view;

    UIView *currentKey = GXKFindNineKeyEmojiKey(root);

    // 模式 1：当前不在九键界面（处于 26 键全键盘、英文键盘或全屏候选面板）
    if (!currentKey) {
        if (gActionKeyButton) {
            gActionKeyButton.hidden = YES;
        }
        // 如果此前有被隐藏子视图的表情按键，彻底恢复其原生子视图显示
        if (gEmojiSoftKeyView) {
            GXKRestoreKeySubviews(gEmojiSoftKeyView);
            gEmojiSoftKeyView = nil;
        }
        return; // 26 键完全保持官方原生原样，绝不修改！
    }

    // 模式 2：处于九键体系（拼音九键、123 数字九键、符号九键）
    if (gEmojiSoftKeyView && gEmojiSoftKeyView != currentKey) {
        // 如果切换到了不同的九键子界面，恢复前一个按键的原生子视图
        GXKRestoreKeySubviews(gEmojiSoftKeyView);
    }
    gEmojiSoftKeyView = currentKey;

    if (!gActionTarget) {
        gActionTarget = [[GXKActionKeyTarget alloc] init];
    }

    UIButton *btn = gActionKeyButton;
    if (!btn || btn.superview != currentKey) {
        if (btn && btn.superview) {
            [btn removeFromSuperview];
        }
        if (!btn) {
            btn = [UIButton buttonWithType:UIButtonTypeCustom];
            btn.tag = GXK_ACTION_TAG;
            btn.titleLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightMedium];
            btn.layer.cornerRadius = 5.0;
            btn.layer.masksToBounds = YES;
            [btn addTarget:gActionTarget action:@selector(onActionKeyTapped:) forControlEvents:UIControlEventTouchUpInside];
            gActionKeyButton = btn;
        }
        btn.frame = currentKey.bounds;
        btn.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [currentKey addSubview:btn];
    }

    currentKey.userInteractionEnabled = YES;
    btn.hidden = NO;

    // 隐藏当前按键原有的表情图标，避免与自定义文字重叠
    for (UIView *sub in currentKey.subviews) {
        if (sub != btn) {
            sub.hidden = YES;
        }
    }

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
        // 未输入拼音状态：显示「换行」
        [btn setTitle:@"换行" forState:UIControlStateNormal];
        if (isDark) {
            [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            btn.backgroundColor = [UIColor colorWithWhite:0.35 alpha:1.0];
        } else {
            [btn setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
            btn.backgroundColor = [UIColor colorWithRed:0.82 green:0.84 blue:0.86 alpha:1.0];
        }
    }

    [currentKey bringSubviewToFront:btn];
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
    if (gEmojiSoftKeyView) {
        GXKRestoreKeySubviews(gEmojiSoftKeyView);
        gEmojiSoftKeyView = nil;
    }
    if (gActionKeyButton) {
        gActionKeyButton.hidden = YES;
        [gActionKeyButton removeFromSuperview];
        gActionKeyButton = nil;
    }
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
