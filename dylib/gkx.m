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
static NSString *const GXKEmojiKeyID = @"key_pos_9keys_emoji";

// 原包 Gboard 2.3.19 已确认的内容接口；只读模型，不改 actions/布局。
@protocol GXKNativeSoftKeyContent <NSObject>
@property(nonatomic, readonly) NSDictionary *idToViewDict;
@property(nonatomic, readonly) id softKeyDef;
- (void)updateView;
@end

@protocol GXKNativeIconContent <NSObject>
@property(nonatomic, strong) UIImage *image;
@property(nonatomic, strong) UIImage *highlightedImage;
@property(nonatomic, readonly) UIColor *foregroundColor;
@end

@protocol GXKNativeActionModel <NSObject>
@property(nonatomic, readonly) NSArray *actionsArray;
@end

#pragma mark - 全局状态

static __weak UIViewController *gCurrentVC;
static __weak UIView *gEmojiSoftKeyView;
static __weak UIView<GXKNativeIconContent> *gActionNativeIcon;
static UIImage *gActionNormalImage;
static UIImage *gActionHighlightedImage;
static id gActionSoftKeyDef;
static UIButton *gActionKeyButton;
static NSTimer *gStatePollTimer;
static BOOL gUpdatingActionKey;

// 原实现函数指针
static void (*gOrigViewDidAppear)(id, SEL, BOOL);
static void (*gOrigViewWillAppear)(id, SEL, BOOL);
static void (*gOrigViewWillDisappear)(id, SEL, BOOL);
static void (*gOrigViewDidLayoutSubviews)(id, SEL);
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

// 九键本身继承自26键类：必须先识别九键，再排除最近的26键祖先。
static UIView *GXKNineKeyBodyForKey(UIView *key, UIView *root) {
    Class nineClass = NSClassFromString(@"GKB9KeysSoftKeyboardView");
    Class qwertyClass = NSClassFromString(@"GKBZhQwertySoftKeyboardView");
    for (UIView *v = key.superview; v; v = v.superview) {
        if (nineClass && [v isKindOfClass:nineClass]) return v;
        if (qwertyClass && [v isKindOfClass:qwertyClass]) return nil;
        if (v == root) break;
    }
    return nil;
}

static BOOL GXKKeyIsVisible(UIView *key, UIView *root) {
    if (!root.window || key.window != root.window || CGRectIsEmpty(key.bounds)) return NO;
    CGRect visibleRect = CGRectIntersection(root.bounds, [key convertRect:key.bounds toView:root]);
    for (UIView *v = key; v; v = v.superview) {
        if (v.isHidden || v.alpha < 0.05) return NO;
        if (v.clipsToBounds) {
            visibleRect = CGRectIntersection(visibleRect, [v convertRect:v.bounds toView:root]);
        }
        if (CGRectIsEmpty(visibleRect)) return NO;
        if (v == root) return YES;
    }
    return NO;
}

static UIView *GXKFindNineKeyEmojiKey(UIView *root) {
    Class keyClass = NSClassFromString(@"GKBSoftKeyView");
    Class nineClass = NSClassFromString(@"GKB9KeysSoftKeyboardView");
    Class qwertyClass = NSClassFromString(@"GKBZhQwertySoftKeyboardView");
    Class fixedClass = NSClassFromString(@"GKBSoftKeyboardViewWithFixedLayout");
    if (!root || !root.window || !keyClass || !nineClass || !qwertyClass || !fixedClass) return nil;

    UIView *candidate = nil;
    UIView *visibleBody = nil;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    NSUInteger visited = 0;
    while (stack.count && visited++ < 1500) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        if (v.isHidden || v.alpha < 0.05 || v.window != root.window) continue;
        // 九键继承26键；generic/fixed内层不是独立peer，只有最外层已证布局体参与。
        BOOL isNineBody = [v isKindOfClass:nineClass];
        BOOL isPeerBody = isNineBody || [v isKindOfClass:qwertyClass] || [v isKindOfClass:fixedClass];
        if (isPeerBody && GXKKeyIsVisible(v, root)) {
            if (!visibleBody) visibleBody = v;
            else if (![v isDescendantOfView:visibleBody]) return nil;
        }
        if ([v isKindOfClass:keyClass] && [v.restorationIdentifier isEqualToString:GXKEmojiKeyID] &&
            GXKNineKeyBodyForKey(v, root) && GXKKeyIsVisible(v, root)) {
            if (candidate && candidate != v) return nil;
            candidate = v;
        }
        [stack addObjectsFromArray:v.subviews];
    }
    if (stack.count || ![visibleBody isKindOfClass:nineClass] ||
        GXKNineKeyBodyForKey(candidate, root) != visibleBody) return nil;
    return candidate; // 完整遍历且仅一个可见九键owner；9↔26/独立数字切换不猜。
}

static UIView<GXKNativeIconContent> *GXKNativeIconForKey(UIView *key) {
    if (![key respondsToSelector:@selector(idToViewDict)] ||
        ![key respondsToSelector:@selector(softKeyDef)] ||
        ![key respondsToSelector:@selector(updateView)]) return nil;
    NSDictionary *contents = ((id<GXKNativeSoftKeyContent>)key).idToViewDict;
    if (![contents isKindOfClass:[NSDictionary class]]) return nil;
    UIView *icon = contents[@"image"];
    Class iconClass = NSClassFromString(@"GKBImageViewWithBackground");
    if (!iconClass || ![icon isKindOfClass:iconClass] || ![icon isDescendantOfView:key] ||
        ![icon respondsToSelector:@selector(image)] || ![icon respondsToSelector:@selector(setImage:)] ||
        ![icon respondsToSelector:@selector(highlightedImage)] ||
        ![icon respondsToSelector:@selector(setHighlightedImage:)] ||
        ![icon respondsToSelector:@selector(foregroundColor)]) return nil;
    return (UIView<GXKNativeIconContent> *)icon;
}

static BOOL GXKModelHasNativeActions(id model) {
    if (![model respondsToSelector:@selector(actionsArray)]) return NO;
    NSArray *actions = ((id<GXKNativeActionModel>)model).actionsArray;
    return [actions isKindOfClass:[NSArray class]] && actions.count > 0;
}

static UIFont *GXKNativeActionFont(UIView *key, UIView *root) {
    UIView *body = GXKNineKeyBodyForKey(key, root);
    if (!body) return [UIFont systemFontOfSize:16.0];
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:body];
    NSUInteger visited = 0;
    while (stack.count && visited++ < 300) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        // 只读同布局原生回车文字的字体，不改其标题、外观或行为。
        if ([v.restorationIdentifier isEqualToString:@"key_pos_9keys_return"] &&
            [v respondsToSelector:@selector(idToViewDict)]) {
            NSDictionary *contents = ((id<GXKNativeSoftKeyContent>)v).idToViewDict;
            UILabel *label = [contents isKindOfClass:[NSDictionary class]] ? contents[@"label"] : nil;
            if ([label isKindOfClass:[UILabel class]] && label.font) return label.font;
        }
        [stack addObjectsFromArray:v.subviews];
    }
    // 原包 softkey_9keys_label_blue.nib：Roboto-Regular 16pt；无该字体时用UIKit常规字体。
    return [UIFont fontWithName:@"Roboto-Regular" size:16.0] ?: [UIFont systemFontOfSize:16.0];
}

static void GXKDetachActionKey(void) {
    BOOL wasUpdating = gUpdatingActionKey;
    gUpdatingActionKey = YES; // 原生refresh引起布局回调时不能重新绑定正在释放的按钮。
    UIView *oldKey = gEmojiSoftKeyView;
    UIView<GXKNativeIconContent> *oldIcon = gActionNativeIcon;
    UIImage *normalImage = gActionNormalImage;
    UIImage *highlightedImage = gActionHighlightedImage;
    id oldModel = gActionSoftKeyDef;
    UIButton *oldButton = gActionKeyButton;
    gEmojiSoftKeyView = nil;
    gActionNativeIcon = nil;
    gActionNormalImage = nil;
    gActionHighlightedImage = nil;
    gActionSoftKeyDef = nil;
    gActionKeyButton = nil;
    [oldButton removeFromSuperview];
    if (oldKey && [oldKey respondsToSelector:@selector(updateView)]) {
        // 原生updateView还会应用viewAttributes并setHidden:NO，保留宿主现有隐藏状态。
        BOOL wasHidden = oldKey.isHidden;
        [(id<GXKNativeSoftKeyContent>)oldKey updateView];
        oldKey.hidden = wasHidden;
        // 只有同一emoji/model/icon可用保留的前景；不能回写到复用成回车的新模型。
        // updateView已证恢复normal image，但highlightedImage未获相同证明。
        if ([oldKey.restorationIdentifier isEqualToString:GXKEmojiKeyID] &&
            GXKNativeIconForKey(oldKey) == oldIcon &&
            ((id<GXKNativeSoftKeyContent>)oldKey).softKeyDef == oldModel) {
            if (!oldIcon.image && normalImage) oldIcon.image = normalImage;
            if (!oldIcon.highlightedImage && highlightedImage) oldIcon.highlightedImage = highlightedImage;
        }
    }
    gUpdatingActionKey = wasUpdating;
}

@interface GXKActionKeyTarget : NSObject
- (void)onActionKeyTapped:(UIButton *)sender;
@end

static void GXKUpdateActionKey(UIViewController *vc);

@implementation GXKActionKeyTarget
- (void)onActionKeyTapped:(UIButton *)sender {
    UIViewController *vc = gCurrentVC;
    if (!vc || ![vc isKindOfClass:[UIInputViewController class]] || sender != gActionKeyButton) return;
    UIView *key = GXKFindNineKeyEmojiKey(vc.view);
    if (!key || key != gEmojiSoftKeyView || sender.superview != key ||
        GXKNativeIconForKey(key) != gActionNativeIcon ||
        ((id<GXKNativeSoftKeyContent>)key).softKeyDef != gActionSoftKeyDef ||
        !GXKModelHasNativeActions(gActionSoftKeyDef)) {
        GXKUpdateActionKey(vc); // 布局/模型已变：旧点击不执行任何输入操作。
        return;
    }
    UIInputViewController *ivc = (UIInputViewController *)vc;
    id<UITextDocumentProxy> proxy = ivc.textDocumentProxy;
    BOOL composing = GXKIsComposingActive(vc);
    if (composing) {
        GXKPerformClearComposing(vc); // 保留原有「重输」能力。
        if (@available(iOS 10.0, *)) {
            UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
            [fb impactOccurred];
        }
    } else {
        if (proxy) [proxy insertText:@"\n"];
        if (@available(iOS 10.0, *)) {
            UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
            [fb impactOccurred];
        }
    }
    __weak UIViewController *weakVC = vc;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        UIViewController *currentVC = weakVC;
        if (currentVC && currentVC == gCurrentVC) GXKUpdateActionKey(currentVC);
    });
}
@end

static GXKActionKeyTarget *gActionTarget;

static void GXKUpdateActionKey(UIViewController *vc) {
    if (gUpdatingActionKey || !vc || vc != gCurrentVC || !vc.isViewLoaded) return;
    gUpdatingActionKey = YES;
    UIView *root = vc.view;
    UIView *currentKey = GXKFindNineKeyEmojiKey(root);
    UIView<GXKNativeIconContent> *icon = GXKNativeIconForKey(currentKey);
    id model = icon ? ((id<GXKNativeSoftKeyContent>)currentKey).softKeyDef : nil;
    UIColor *color = icon.foregroundColor;
    if (!currentKey || !icon || !GXKModelHasNativeActions(model) || ![color isKindOfClass:[UIColor class]]) {
        GXKDetachActionKey(); // 26键、未知/不完整布局完全保持原生，不猜测替代键。
        gUpdatingActionKey = NO;
        return;
    }

    if (gEmojiSoftKeyView != currentKey || gActionNativeIcon != icon || gActionSoftKeyDef != model ||
        !gActionKeyButton || gActionKeyButton.superview != currentKey) {
        GXKDetachActionKey();
        // 原生updateView会应用布局/可见性属性：重新验证控制器、root及完整当前目标。
        if (vc != gCurrentVC || !vc.isViewLoaded || vc.view != root) {
            gUpdatingActionKey = NO;
            return;
        }
        currentKey = GXKFindNineKeyEmojiKey(root);
        icon = GXKNativeIconForKey(currentKey);
        model = icon ? ((id<GXKNativeSoftKeyContent>)currentKey).softKeyDef : nil;
        color = icon.foregroundColor;
        // 新绑定必须存在当前原生前景与action，不用上次保存的图授权空内容模型。
        BOOL hasForeground = [icon.image isKindOfClass:[UIImage class]] ||
                             [icon.highlightedImage isKindOfClass:[UIImage class]];
        if (!currentKey || !icon || !GXKModelHasNativeActions(model) || !hasForeground ||
            ![color isKindOfClass:[UIColor class]]) {
            gUpdatingActionKey = NO;
            return;
        }
        if (!gActionTarget) gActionTarget = [[GXKActionKeyTarget alloc] init];
        // 每次新绑定使用新按钮，旧TouchUp不能跟随复用的UIButton落到另一个键。
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
        btn.tag = GXK_ACTION_TAG;
        btn.backgroundColor = [UIColor clearColor];
        btn.adjustsImageWhenHighlighted = NO;
        btn.showsTouchWhenHighlighted = NO;
        btn.titleLabel.adjustsFontSizeToFitWidth = YES;
        btn.titleLabel.minimumScaleFactor = 0.85;
        btn.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [btn addTarget:gActionTarget action:@selector(onActionKeyTapped:) forControlEvents:UIControlEventTouchUpInside];
        gEmojiSoftKeyView = currentKey;
        gActionNativeIcon = icon;
        gActionSoftKeyDef = model;
        gActionKeyButton = btn;
        [currentKey addSubview:btn];
    }

    // 仅保留两张前景UIImage；原生重绘产生新图时更新引用，不存通用视图快照。
    // 同一个UIView的backgroundLayer、边框、主题完全不动。
    if (icon.image) {
        gActionNormalImage = icon.image;
        icon.image = nil;
    }
    if (icon.highlightedImage) {
        gActionHighlightedImage = icon.highlightedImage;
        icon.highlightedImage = nil;
    }
    UIButton *btn = gActionKeyButton;
    if (!CGRectEqualToRect(btn.frame, currentKey.bounds)) btn.frame = currentKey.bounds;
    UIFont *font = GXKNativeActionFont(currentKey, root);
    if (![btn.titleLabel.font isEqual:font]) btn.titleLabel.font = font;
    if (![[btn titleColorForState:UIControlStateNormal] isEqual:color]) {
        [btn setTitleColor:color forState:UIControlStateNormal];
        [btn setTitleColor:color forState:UIControlStateHighlighted];
    }
    NSString *title = GXKIsComposingActive(vc) ? @"重输" : @"换行";
    if (![[btn titleForState:UIControlStateNormal] isEqualToString:title]) {
        [btn setTitle:title forState:UIControlStateNormal];
        [btn setTitle:title forState:UIControlStateHighlighted];
        btn.accessibilityLabel = title;
    }
    if (btn.hidden) btn.hidden = NO;
    if (currentKey.subviews.lastObject != btn) [currentKey bringSubviewToFront:btn];
    gUpdatingActionKey = NO;
}

#pragma mark - 视图控制器生命周期 Hook

static void gkx_textDidChange(id self, SEL _cmd, id textInput) {
    if (gOrigTextDidChange) gOrigTextDidChange(self, _cmd, textInput);
    __weak UIViewController *weakVC = (UIViewController *)self;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *vc = weakVC;
        if (vc && vc == gCurrentVC) GXKUpdateActionKey(vc);
    });
}

static void gkx_viewDidLayoutSubviews(id self, SEL _cmd) {
    if (gOrigViewDidLayoutSubviews) gOrigViewDidLayoutSubviews(self, _cmd);
    if ((UIViewController *)self == gCurrentVC) GXKUpdateActionKey((UIViewController *)self);
}

static void gkx_viewWillAppear(id self, SEL _cmd, BOOL animated) {
    if (gOrigViewWillAppear) gOrigViewWillAppear(self, _cmd, animated);
    if ((UIViewController *)self != gCurrentVC) GXKDetachActionKey();
    gCurrentVC = (UIViewController *)self;

    // 部署外部万象词库
    GXKEnsureUserDictionaryDeployed();

    // 轮询只补足组字/原生主题内容刷新；布局切换由layout回调立即重新定位。
    if (!gStatePollTimer) {
        gStatePollTimer = [NSTimer scheduledTimerWithTimeInterval:0.20 repeats:YES block:^(NSTimer *timer) {
            UIViewController *vc = gCurrentVC;
            if (vc) GXKUpdateActionKey(vc);
        }];
        [[NSRunLoop mainRunLoop] addTimer:gStatePollTimer forMode:NSRunLoopCommonModes];
    }
}

static void gkx_viewWillDisappear(id self, SEL _cmd, BOOL animated) {
    // 先撤销当前绑定，原生生命周期引起的布局/异步事件不得重建旧按钮。
    if ((UIViewController *)self == gCurrentVC) {
        gCurrentVC = nil;
        [gStatePollTimer invalidate];
        gStatePollTimer = nil;
        GXKDetachActionKey();
    }
    if (gOrigViewWillDisappear) gOrigViewWillDisappear(self, _cmd, animated);
}

static void gkx_viewDidAppear(id self, SEL _cmd, BOOL animated) {
    if (gOrigViewDidAppear) gOrigViewDidAppear(self, _cmd, animated);
    if ((UIViewController *)self == gCurrentVC) GXKUpdateActionKey((UIViewController *)self);
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
        Method mLayout = class_getInstanceMethod(vcClass, @selector(viewDidLayoutSubviews));
        if (mLayout) {
            gOrigViewDidLayoutSubviews = (void (*)(id, SEL))method_getImplementation(mLayout);
            // 若生命周期来自父类，只在本控制器挂载hook，不污染UIViewController或其他键盘。
            if (!class_addMethod(vcClass, @selector(viewDidLayoutSubviews), (IMP)gkx_viewDidLayoutSubviews,
                                 method_getTypeEncoding(mLayout))) {
                method_setImplementation(mLayout, (IMP)gkx_viewDidLayoutSubviews);
            }
        }
        Method mText = class_getInstanceMethod(vcClass, @selector(textDidChange:));
        if (mText) {
            gOrigTextDidChange = (void (*)(id, SEL, id))method_getImplementation(mText);
            method_setImplementation(mText, (IMP)gkx_textDidChange);
        }
    }
}
