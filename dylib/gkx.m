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
static __weak UIView *gActionHost;
static NSTimer *gStatePollTimer;
static BOOL gUpdatingActionKey;

// 组字状态缓存：全树扫描只在布局/文本事件里跑，0.2s轮询只读缓存。
static BOOL gComposingActive;
// 词库部署一次性：本进程内成功比对/拷贝后不再重复访问磁盘。
static BOOL gDictDeploySettled;
// 触觉复用：避免每次点击分配generator并丢失prepare预热。
static UIImpactFeedbackGenerator *gFbMedium;
static UIImpactFeedbackGenerator *gFbLight;

// 原实现函数指针
static void (*gOrigViewDidAppear)(id, SEL, BOOL);
static void (*gOrigViewWillAppear)(id, SEL, BOOL);
static void (*gOrigViewWillDisappear)(id, SEL, BOOL);
static void (*gOrigViewDidLayoutSubviews)(id, SEL);
static void (*gOrigTextDidChange)(id, SEL, id);

#pragma mark - 外部词库自动部署 (防 Jetsam 轻量版)

static void GXKEnsureUserDictionaryDeployed(void) {
    if (gDictDeploySettled) return; // 本进程已确认部署一致，不再访问磁盘。
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
            gDictDeploySettled = YES;
            GXK_LOG(@"[+] 词库部署成功: %@", targetDBURL.path);
        } else {
            GXK_LOG(@"[!] 词库部署失败: %@", err.localizedDescription);
        }
    } else {
        gDictDeploySettled = YES; // 包内与目标已一致，后续弹键盘无需再比对。
    }
}

#pragma mark - 拼音输入状态判定 (Composing)

// 组字状态有两个来源：代理层markedText是O(1)权威值；视图树扫描代价高，
// 只在布局/文本事件里跑一次并写入gComposingActive，轮询只读缓存。
static BOOL GXKComposingFromProxy(UIViewController *vc) {
    if (!vc) return NO;
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
    return NO;
}

static BOOL GXKComposingFullScan(UIViewController *vc) {
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

// 事件驱动的状态刷新：代理有mark就是YES（O(1)）；否则跑一次全树。
static void GXKRefreshComposingState(UIViewController *vc) {
    if (!vc) { gComposingActive = NO; return; }
    if (GXKComposingFromProxy(vc)) { gComposingActive = YES; return; }
    gComposingActive = GXKComposingFullScan(vc);
}

// 轮询与刷新用：优先读缓存，代理层已明确有mark时立即纠正缓存。
static BOOL GXKComposingStateCached(UIViewController *vc) {
    if (!vc) return NO;
    if (GXKComposingFromProxy(vc)) { gComposingActive = YES; return YES; }
    return gComposingActive;
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

// 覆盖按钮的宿主：GKBSoftKeyView的hitTest只判自身bounds、从不返回子视图，
// 所以按钮必须是键的祖先视图的子视图，才能成为命中链上最深的一层。
static UIView *GXKActionHostForKey(UIView *key) {
    if (!key) return nil;
    Class keyClass = NSClassFromString(@"GKBSoftKeyView");
    for (UIView *v = key.superview; v; v = v.superview) {
        if (keyClass && [v isKindOfClass:keyClass]) continue; // 嵌套键：继续上浮到真正容器。
        return v;
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
    gActionHost = nil;
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

#pragma mark - 触觉反馈 (复用 + prepare 预热)

static void GXKImpact(UIImpactFeedbackStyle style) {
    if (@available(iOS 10.0, *)) {
        if (style == UIImpactFeedbackStyleMedium) {
            if (!gFbMedium) gFbMedium = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
            [gFbMedium impactOccurred];
            [gFbMedium prepare]; // 为下一次点击预热，缩短延迟。
        } else {
            if (!gFbLight) gFbLight = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
            [gFbLight impactOccurred];
            [gFbLight prepare];
        }
    }
}

static void GXKReleaseHaptics(void) {
    gFbMedium = nil;
    gFbLight = nil;
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
    // 覆盖按钮挂在键的宿主容器上：GKBSoftKeyView的hitTest只判自身bounds、从不返回子视图。
    UIView *host = GXKActionHostForKey(key);
    if (!key || !host || key != gEmojiSoftKeyView || sender.superview != host ||
        GXKNativeIconForKey(key) != gActionNativeIcon ||
        ((id<GXKNativeSoftKeyContent>)key).softKeyDef != gActionSoftKeyDef ||
        !GXKModelHasNativeActions(gActionSoftKeyDef)) {
        GXKUpdateActionKey(vc); // 布局/模型已变：旧点击不执行任何输入操作。
        return;
    }
    UIInputViewController *ivc = (UIInputViewController *)vc;
    id<UITextDocumentProxy> proxy = ivc.textDocumentProxy;
    // 点击是低频事件：这里取一次真实状态，避免用轮询缓存的陈旧值决定重输/换行。
    GXKRefreshComposingState(vc);
    BOOL composing = gComposingActive;
    if (composing) {
        GXKPerformClearComposing(vc); // 保留原有「重输」能力。
        GXKImpact(UIImpactFeedbackStyleMedium);
    } else {
        if (proxy) [proxy insertText:@"\n"];
        GXKImpact(UIImpactFeedbackStyleLight);
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

    // 廉价路径：绑定仍然有效时只刷新标题/位置，不做全树定位。
    // 任一条不成立就落回完整路径，失败闭合语义不变。
    if (gEmojiSoftKeyView && gActionNativeIcon && gActionSoftKeyDef && gActionKeyButton && gActionHost &&
        gActionKeyButton.superview == gActionHost &&
        [gEmojiSoftKeyView.restorationIdentifier isEqualToString:GXKEmojiKeyID] &&
        GXKActionHostForKey(gEmojiSoftKeyView) == gActionHost &&
        [gEmojiSoftKeyView isDescendantOfView:root] &&
        GXKKeyIsVisible(gEmojiSoftKeyView, root) &&
        GXKNativeIconForKey(gEmojiSoftKeyView) == gActionNativeIcon &&
        ((id<GXKNativeSoftKeyContent>)gEmojiSoftKeyView).softKeyDef == gActionSoftKeyDef &&
        GXKModelHasNativeActions(gActionSoftKeyDef)) {
        UIButton *cheapBtn = gActionKeyButton;
        UIView<GXKNativeIconContent> *cheapIcon = gActionNativeIcon;
        // 原生updateView可能重画前景图：继续把图搬走，否则会盖在我们的文字下。
        if (cheapIcon.image) {
            gActionNormalImage = cheapIcon.image;
            cheapIcon.image = nil;
        }
        if (cheapIcon.highlightedImage) {
            gActionHighlightedImage = cheapIcon.highlightedImage;
            cheapIcon.highlightedImage = nil;
        }
        CGRect cheapRect = [gEmojiSoftKeyView convertRect:gEmojiSoftKeyView.bounds toView:gActionHost];
        if (!CGRectEqualToRect(cheapBtn.frame, cheapRect)) cheapBtn.frame = cheapRect;
        if (gActionHost.subviews.lastObject != cheapBtn) [gActionHost bringSubviewToFront:cheapBtn];
        UIColor *cheapColor = cheapIcon.foregroundColor;
        if ([cheapColor isKindOfClass:[UIColor class]] &&
            ![[cheapBtn titleColorForState:UIControlStateNormal] isEqual:cheapColor]) {
            [cheapBtn setTitleColor:cheapColor forState:UIControlStateNormal];
            [cheapBtn setTitleColor:cheapColor forState:UIControlStateHighlighted];
        }
        NSString *cheapTitle = GXKComposingStateCached(vc) ? @"重输" : @"换行";
        if (![[cheapBtn titleForState:UIControlStateNormal] isEqualToString:cheapTitle]) {
            [cheapBtn setTitle:cheapTitle forState:UIControlStateNormal];
            [cheapBtn setTitle:cheapTitle forState:UIControlStateHighlighted];
            cheapBtn.accessibilityLabel = cheapTitle;
        }
        gUpdatingActionKey = NO;
        return;
    }

    UIView *currentKey = GXKFindNineKeyEmojiKey(root);
    UIView<GXKNativeIconContent> *icon = GXKNativeIconForKey(currentKey);
    id model = icon ? ((id<GXKNativeSoftKeyContent>)currentKey).softKeyDef : nil;
    UIColor *color = icon.foregroundColor;
    if (!currentKey || !icon || !GXKModelHasNativeActions(model) || ![color isKindOfClass:[UIColor class]]) {
        GXKDetachActionKey(); // 26键、未知/不完整布局完全保持原生，不猜测替代键。
        gUpdatingActionKey = NO;
        return;
    }

    UIView *host = GXKActionHostForKey(currentKey);
    if (!host) {
        GXKDetachActionKey();
        gUpdatingActionKey = NO;
        return;
    }
    if (gEmojiSoftKeyView != currentKey || gActionNativeIcon != icon || gActionSoftKeyDef != model ||
        !gActionKeyButton || gActionKeyButton.superview != host) {
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
        // 重扫后键可能换了宿主容器：按新键重新解析，不能沿用旧键的宿主。
        host = GXKActionHostForKey(currentKey);
        if (!host) {
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
        btn.autoresizingMask = UIViewAutoresizingNone; // 每帧按currentKey换算frame，不随父视图拉伸。
        [btn addTarget:gActionTarget action:@selector(onActionKeyTapped:) forControlEvents:UIControlEventTouchUpInside];
        gEmojiSoftKeyView = currentKey;
        gActionNativeIcon = icon;
        gActionSoftKeyDef = model;
        gActionHost = host;
        gActionKeyButton = btn;
        // 挂在宿主容器：GKBSoftKeyView的hitTest只做自身bounds判定，其子视图永不参与命中。
        [host addSubview:btn];
        btn.frame = [currentKey convertRect:currentKey.bounds toView:host];
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
    gActionHost = host; // 廉价路径依赖该宿主引用，绑定未重建时也要补齐。
    if (btn.superview != host) [host addSubview:btn];
    CGRect targetRect = [currentKey convertRect:currentKey.bounds toView:host];
    if (!CGRectEqualToRect(btn.frame, targetRect)) btn.frame = targetRect;
    UIFont *font = GXKNativeActionFont(currentKey, root);
    if (![btn.titleLabel.font isEqual:font]) btn.titleLabel.font = font;
    if (![[btn titleColorForState:UIControlStateNormal] isEqual:color]) {
        [btn setTitleColor:color forState:UIControlStateNormal];
        [btn setTitleColor:color forState:UIControlStateHighlighted];
    }
    NSString *title = GXKComposingStateCached(vc) ? @"重输" : @"换行";
    if (![[btn titleForState:UIControlStateNormal] isEqualToString:title]) {
        [btn setTitle:title forState:UIControlStateNormal];
        [btn setTitle:title forState:UIControlStateHighlighted];
        btn.accessibilityLabel = title;
    }
    if (btn.hidden) btn.hidden = NO;
    if (host.subviews.lastObject != btn) [host bringSubviewToFront:btn];
    gUpdatingActionKey = NO;
}

#pragma mark - 视图控制器生命周期 Hook

static void GXKApplyTelemetryBlockIfNeeded(void);

static void gkx_textDidChange(id self, SEL _cmd, id textInput) {
    if (gOrigTextDidChange) gOrigTextDidChange(self, _cmd, textInput);
    __weak UIViewController *weakVC = (UIViewController *)self;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *vc = weakVC;
        if (vc && vc == gCurrentVC) {
            GXKRefreshComposingState(vc); // 组字状态只在此处与布局事件里全树扫描一次。
            GXKUpdateActionKey(vc);
        }
    });
}

static void gkx_viewDidLayoutSubviews(id self, SEL _cmd) {
    if (gOrigViewDidLayoutSubviews) gOrigViewDidLayoutSubviews(self, _cmd);
    if ((UIViewController *)self == gCurrentVC) {
        GXKRefreshComposingState((UIViewController *)self);
        GXKUpdateActionKey((UIViewController *)self);
    }
}

static void gkx_viewWillAppear(id self, SEL _cmd, BOOL animated) {
    if (gOrigViewWillAppear) gOrigViewWillAppear(self, _cmd, animated);
    if ((UIViewController *)self != gCurrentVC) GXKDetachActionKey();
    gCurrentVC = (UIViewController *)self;
    GXKRefreshComposingState((UIViewController *)self); // 新会话先取一次真实组字状态。
    GXKApplyTelemetryBlockIfNeeded(); // 兜底：构造函数时framework若未就绪，这里补一次。

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
        gComposingActive = NO; // 扩展隐藏后组字缓存作废，下次出现重新采样。
        [gStatePollTimer invalidate];
        gStatePollTimer = nil;
        GXKDetachActionKey();
        GXKReleaseHaptics(); // 扩展隐藏后不常驻触觉引擎。
    }
    if (gOrigViewWillDisappear) gOrigViewWillDisappear(self, _cmd, animated);
}

static void gkx_viewDidAppear(id self, SEL _cmd, BOOL animated) {
    if (gOrigViewDidAppear) gOrigViewDidAppear(self, _cmd, animated);
    if ((UIViewController *)self == gCurrentVC) {
        GXKRefreshComposingState((UIViewController *)self);
        GXKUpdateActionKey((UIViewController *)self);
    }
}

#pragma mark - 隐私上报拦截 (只掐 clearcut 与 Breakpad 上报)

// 只替换上报出口本身，不碰初始化、自检、返回值被使用的入口。
// 翻译(translation.googleapis.com)、YouTube(www.googleapis.com/youtube)、天气(www.weather.com)
// 走完全不同的链路，不受影响。
static void gxk_noop_void(id self, SEL _cmd) {}
static void gxk_noop_void_obj(id self, SEL _cmd, id obj) {}
static void gxk_noop_void_bool(id self, SEL _cmd, BOOL flag) {}
static void gxk_noop_void_u64(id self, SEL _cmd, unsigned long long v) {}
static void gxk_noop_void_u64_u64(id self, SEL _cmd, unsigned long long a, unsigned long long b) {}
static BOOL gxk_noop_bool_no(id self, SEL _cmd) { return NO; }

// 逐条替换；类或方法不存在就跳过，换新版Gboard时自然降级为不拦截。
static void GXKDisableOne(NSString *className, NSString *selName, IMP imp) {
    Class cls = NSClassFromString(className);
    if (!cls) return;
    SEL sel = NSSelectorFromString(selName);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    method_setImplementation(m, imp);
}

static void GXKDisableTelemetryUpload(void) {
    // CCTClearcutLogger：事件根本不落盘，上游埋点自然失效。
    GXKDisableOne(@"CCTClearcutLogger", @"log:", (IMP)gxk_noop_void_obj);
    GXKDisableOne(@"CCTClearcutLogger", @"logWithExtension:", (IMP)gxk_noop_void_obj);
    GXKDisableOne(@"CCTClearcutLogger", @"logCounters:", (IMP)gxk_noop_void_obj);
    // CCTClearcutUploader：不启动任何自动/周期上传。
    GXKDisableOne(@"CCTClearcutUploader", @"startAutoUpload", (IMP)gxk_noop_void);
    GXKDisableOne(@"CCTClearcutUploader", @"startPeriodicUploadWithTimeInterval:", (IMP)gxk_noop_void_u64);
    GXKDisableOne(@"CCTClearcutUploader", @"startPeriodicUploadWithTimeInterval:leeway:",
                  (IMP)gxk_noop_void_u64_u64);
    GXKDisableOne(@"CCTClearcutUploader", @"startAutoUploadOnBackground", (IMP)gxk_noop_void);
    GXKDisableOne(@"CCTClearcutUploader", @"startAutoUploadOnForegroundWithDelay:", (IMP)gxk_noop_void_u64);
    GXKDisableOne(@"CCTClearcutUploader", @"startCollectForDebugPeriodicUpload", (IMP)gxk_noop_void);
    // GKBClearcutUploader：扩展自身的上传入口。
    GXKDisableOne(@"GKBClearcutUploader", @"uploadClearcutLogs", (IMP)gxk_noop_void);
    GXKDisableOne(@"GKBClearcutUploader", @"shouldUploadClearcutLogs", (IMP)gxk_noop_bool_no);
    // Breakpad：不启动崩溃捕获，历史残留也不补发。
    GXKDisableOne(@"BreakpadController", @"start:", (IMP)gxk_noop_void_bool);
    GXKDisableOne(@"BreakpadController", @"sendStoredCrashReports", (IMP)gxk_noop_void);
    GXK_LOG(@"[*] 隐私上报已拦截 (clearcut + Breakpad)");
}

// 幂等入口：framework在构造函数阶段可能尚未加载，首次viewWillAppear再补一次。
static void GXKApplyTelemetryBlockIfNeeded(void) {
    static BOOL blocked = NO;
    if (blocked) return;
    if (!NSClassFromString(@"CCTClearcutLogger") && !NSClassFromString(@"BreakpadController")) return;
    GXKDisableTelemetryUpload();
    blocked = YES;
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

    // 只掐无意义上报；翻译/YouTube/天气不受影响。
    GXKApplyTelemetryBlockIfNeeded();
}
