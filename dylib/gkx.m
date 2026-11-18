// gkx.m — Gboard iOS 键盘定制 dylib (极简重制版)
//
// 核心范围：
//   1. 外部万象词库 (user_dictionary.db) 自动部署到 App Group 共享容器
//   2. 九键界面回车键上方表情键替换为「重输」/「换行」动态切换按键
//   3. 九键 G 图标 band 内嵌工具栏：全选/复制/粘贴/剪切/收起（原地复用，不加高度）
//   4. G 图标展开页去掉 YouTube / 联系人两页
//   5. 搜索历史每行右侧叠 ×，点掉即删（列表 + 持久化记录）
//   6. G 图标「常用语」分页：点一条直接上屏，可固定面板连续输入；主 App 设置主菜单里维护
// 其余一切界面与输入逻辑均完全保持 Gboard 官方原生！

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <string.h>
#import <math.h>

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
// 按需轮询剩余补帧次数：事件把它抬高，归零后停表，空闲时零唤醒。
static NSInteger gPollTicks;

// 组字状态缓存：全树扫描只在布局/文本事件里跑，0.2s轮询只读缓存。
static BOOL gComposingActive;
// 词库部署一次性：本进程内成功比对/拷贝后不再重复访问磁盘。
static BOOL gDictDeploySettled;
// 触觉复用：避免每次点击分配generator并丢失prepare预热。
static UIImpactFeedbackGenerator *gFbMedium;
static UIImpactFeedbackGenerator *gFbLight;
// prepare 会让 Taptic 引擎保持预热，闲置不释放就是白耗电；2 秒没再点就撒手。
static NSTimer *gHapticIdleTimer;
#define GXK_HAPTIC_IDLE_SECONDS 2.0

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

    // 词库只随包放一份（主 App 的 Frameworks 下），这里按「谁在跑」逐条找：
    // 主 App 进程直接命中 Frameworks；键盘扩展要先试自己 bundle，再退回主 App 的 Frameworks。
    NSBundle *mainBundle = [NSBundle mainBundle];
    NSString *bundleDir = [mainBundle bundlePath];
    NSArray<NSString *> *candidates = @[
        [mainBundle pathForResource:@"user_dictionary" ofType:@"db"] ?: @"",
        [bundleDir stringByAppendingPathComponent:@"Frameworks/user_dictionary.db"],
        [[bundleDir stringByAppendingPathComponent:@"../../Frameworks/user_dictionary.db"] stringByStandardizingPath],
    ];
    NSString *bundlePath = nil;
    for (NSString *candidate in candidates) {
        if (candidate.length > 0 && [fm fileExistsAtPath:candidate]) { bundlePath = candidate; break; }
    }
    if (!bundlePath) {
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

// 类名判定缓存：九键键盘树里同类视图成百上千，每个节点都做一次 NSStringFromClass +
// 两次 containsString，是整趟扫描里最贵的固定开销。按类指针只算一次。
enum { GXKViewKindPlain = 0, GXKViewKindComposing = 1, GXKViewKindSoftKey = 2 };
static NSMutableDictionary *gViewKindCache;

static NSInteger GXKViewKind(UIView *view) {
    if (!gViewKindCache) gViewKindCache = [NSMutableDictionary dictionary];
    Class cls = [view class];
    NSValue *key = [NSValue valueWithPointer:(__bridge const void *)cls];
    NSNumber *cached = gViewKindCache[key];
    if (cached) return cached.integerValue;
    NSString *name = NSStringFromClass(cls);
    NSInteger kind = GXKViewKindPlain;
    if ([name isEqualToString:@"GKBSoftKeyView"]) {
        kind = GXKViewKindSoftKey;
    } else if ([name containsString:@"Composing"] || [name containsString:@"Preedit"]) {
        kind = GXKViewKindComposing;
    }
    gViewKindCache[key] = @(kind);
    return kind;
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

        NSInteger kind = GXKViewKind(v);

        // 判定 1: 扫描 Composing 与 Preedit 视图中是否有拼音文字
        if (kind == GXKViewKindComposing) {
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
        if (kind == GXKViewKindSoftKey) {
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

// 全树扫描节流：布局事件一秒可能来几十次，最多 0.25 秒扫一次；
// 被跳过的这一次排一个尾随扫描，状态不会卡在旧值上。
#define GXK_COMPOSING_SCAN_MIN_INTERVAL 0.25
static CFTimeInterval gComposingScanAt;
static BOOL gComposingScanScheduled;

static void GXKUpdateActionKey(UIViewController *vc);
static void GXKUpdateToolbar(UIViewController *vc);
static void GXKScheduleComposingScan(void);

// 事件驱动的状态刷新：代理有mark就是YES（O(1)）；否则跑一次全树（受节流约束）。
static void GXKRefreshComposingState(UIViewController *vc) {
    if (!vc) { gComposingActive = NO; return; }
    if (GXKComposingFromProxy(vc)) { gComposingActive = YES; return; }
    CFTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (gComposingScanAt > 0.0 && now - gComposingScanAt < GXK_COMPOSING_SCAN_MIN_INTERVAL) {
        GXKScheduleComposingScan();
        return;
    }
    gComposingScanAt = now;
    gComposingActive = GXKComposingFullScan(vc);
}

// 尾随扫描：只在状态真的翻转时才触发一次界面刷新，没翻转就什么都不做。
static void GXKScheduleComposingScan(void) {
    if (gComposingScanScheduled) return;
    gComposingScanScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(GXK_COMPOSING_SCAN_MIN_INTERVAL * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        gComposingScanScheduled = NO;
        UIViewController *vc = gCurrentVC;
        if (!vc || !vc.isViewLoaded) return;
        if (GXKComposingFromProxy(vc)) { gComposingActive = YES; return; }
        gComposingScanAt = CFAbsoluteTimeGetCurrent();
        BOOL composing = GXKComposingFullScan(vc);
        if (composing == gComposingActive) return;
        gComposingActive = composing;
        GXKUpdateActionKey(vc);
        GXKUpdateToolbar(vc);
    });
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

// 扫描热路径的类指针缓存：NSClassFromString 每次都要查运行时类表，
// 而下面这些类名是在 1500 节点的循环里对每个软键都要用的，只解析一次就够。
// 类晚于首次调用才加载时仍会重试，只有解析成功才写入缓存。
static Class gCachedKeyClass;
static Class gCachedNineKeyClass;
static Class gCachedQwertyClass;
static Class gCachedFixedLayoutClass;
static Class gCachedLogoClass;
static Class gCachedIconClass;

static Class GXKClassCached(NSString *name, Class *slot) {
    if (*slot) return *slot;
    Class cls = NSClassFromString(name);
    if (cls) *slot = cls;
    return cls;
}

// 九键本身继承自26键类：必须先识别九键，再排除最近的26键祖先。
static UIView *GXKNineKeyBodyForKey(UIView *key, UIView *root) {
    Class nineClass = GXKClassCached(@"GKB9KeysSoftKeyboardView", &gCachedNineKeyClass);
    Class qwertyClass = GXKClassCached(@"GKBZhQwertySoftKeyboardView", &gCachedQwertyClass);
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
    Class keyClass = GXKClassCached(@"GKBSoftKeyView", &gCachedKeyClass);
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
    Class keyClass = GXKClassCached(@"GKBSoftKeyView", &gCachedKeyClass);
    Class nineClass = GXKClassCached(@"GKB9KeysSoftKeyboardView", &gCachedNineKeyClass);
    Class qwertyClass = GXKClassCached(@"GKBZhQwertySoftKeyboardView", &gCachedQwertyClass);
    Class fixedClass = GXKClassCached(@"GKBSoftKeyboardViewWithFixedLayout", &gCachedFixedLayoutClass);
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
    Class iconClass = GXKClassCached(@"GKBImageViewWithBackground", &gCachedIconClass);
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

#import "native_key_style.h"

static UIFont *GXKNativeActionFont(UIView *key, UIView *root) {
    UIView *body = GXKNineKeyBodyForKey(key, root);
    return GXKNativeKeyFont(body, root);
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

static void GXKReleaseHaptics(void) {
    [gHapticIdleTimer invalidate];
    gHapticIdleTimer = nil;
    gFbMedium = nil;
    gFbLight = nil;
}

// 每次点击重置一次「闲置释放」倒计时：连续点击时不重建 generator，停手 2 秒后归零。
static void GXKScheduleHapticRelease(void) {
    [gHapticIdleTimer invalidate];
    gHapticIdleTimer = [NSTimer scheduledTimerWithTimeInterval:GXK_HAPTIC_IDLE_SECONDS
                                                      repeats:NO
                                                        block:^(NSTimer *timer) {
        gHapticIdleTimer = nil;
        gFbMedium = nil;
        gFbLight = nil;
    }];
}

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
        GXKScheduleHapticRelease();
    }
}

#pragma mark - 顶部工具条 (只借 G 图标行，绝不改键盘高度)

// 方案 A：G 图标所在的那条 band 原生就有，工具条整条接管它。
// 不新增约束、不改根视图高度、不碰候选行与预编辑行；组字中整条让位给原生。
static void GXKUpdateToolbar(UIViewController *vc);

@interface GXKToolbarTarget : NSObject
@property (nonatomic, weak) UIViewController *controller;
- (void)onSelectAll:(UIButton *)sender;
- (void)onCopy:(UIButton *)sender;
- (void)onPaste:(UIButton *)sender;
- (void)onCut:(UIButton *)sender;
- (void)onDismissKeyboard:(UIButton *)sender;
- (void)onToolbarDiagnostic:(UILongPressGestureRecognizer *)gesture; // [DEBUG-toolbar]
- (void)deleteBeforeCursor:(NSUInteger)count;
- (BOOL)refuseWhileComposing:(UIButton *)sender;
- (id<UITextDocumentProxy>)proxy;
@end

static __weak UIStackView *gToolbarStack;
static __weak UIView *gToolbarRow;
static __weak UIView *gToolbarHost;
static __weak UIView *gToolbarLogoView;
static __weak UIView *gToolbarNineBody;
static CGRect gToolbarBand;
// band 只由「宿主行尺寸 + G 图标位置 + 同行可见邻居」决定。后者的判定要沿父链 convertRect，
// 是这条路径上唯一还会每拍重复的工作：用邻居几何算一个签名，签名没变就直接复用上次结果。
static __weak UIView *gToolbarBandCacheRow;
static __weak UIView *gToolbarBandCacheLogo;
static CGSize gToolbarBandCacheRowSize;
static CGRect gToolbarBandCacheLogoFrame;
static CGRect gToolbarBandCacheGlyph;
static CGRect gToolbarBandCacheRowInRoot;
static CGRect gToolbarBandCacheRootBounds;
static NSUInteger gToolbarBandCacheSignature;
static NSUInteger gToolbarBandCacheEpoch;
static BOOL gToolbarBandCacheValid;
static BOOL gToolbarBandCacheHit;
static CGRect gToolbarBandCacheBand;
// 挂载、撤走、归还装饰都会改变「谁挡在 band 里」，这些时机自增代次让缓存失效。
static NSUInteger gToolbarBandEpoch;
static BOOL gUpdatingToolbar;
static GXKToolbarTarget *gToolbarTarget;
// 本拍工具条要用的字体：取自同键盘原生 UILabel，主题/字号变了跟着变。
static UIFont *gToolbarFont;
// [DEBUG-toolbar] 弱引用只记实际被选中的来源，不参与字体选择或延长原生标签生命周期。
static __weak UILabel *gToolbarStyleSource;
static void GXKToolbarDiagnosticBandObserved(UIView *row, UIView *logo, CGRect glyph, CGFloat unclampedTop);

// 工具条四条几何约束：复用 stack 时先撤旧约束，避免常量层层叠加。
static NSArray<NSLayoutConstraint *> *gToolbarConstraints;
// 「全选」记下的文本与时间：紧接着的「剪切」直接作用于同一段内容，不再要求系统选区。
static NSString *gToolbarSelectAllText;
static NSTimeInterval gToolbarSelectAllAt;
// 单次剪切最多删这么多字符：documentContext 本身会被系统截断，这里再兜一层上限。
#define GXK_CUT_MAX_CHARS 4000
// 全选之后多少秒内点剪切仍视为「剪全部」。
#define GXK_SELECT_ALL_WINDOW 15.0

// [DEBUG-toolbar] Coordinate only diagnostic-owned titles with ordinary error feedback.
static NSString *GXKToolbarDiagnosticFlashBaseline(UIButton *button);
static BOOL GXKToolbarDiagnosticFeedbackOwns(UIButton *button);

// 点击反馈只改标题 1.1 秒，不弹面板、不改几何：键盘扩展里最省事也最不容易卡。
static void GXKFlashTitle(UIButton *button, NSString *text) {
    if (!button || !text.length) return;
    NSString *original = GXKToolbarDiagnosticFlashBaseline(button);
    if (!original.length) return;
    [button setTitle:text forState:UIControlStateNormal];
    __weak UIButton *weakButton = button;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIButton *live = weakButton;
        if (live && !GXKToolbarDiagnosticFeedbackOwns(live)) [live setTitle:original forState:UIControlStateNormal];
    });
}

#import "toolbar_layout.h"
#import "toolbar_visibility.h"

// Identified native key owns font; a verified current icon owns neutral theme tint.
static UIColor *GXKToolbarTextStyle(UIView *body, UIFont **outFont) {
    UIView *root = gCurrentVC.isViewLoaded ? gCurrentVC.view : nil;
    UILabel *label = GXKNativeKeyStyleLabel(body, root);
    if (outFont) {
        *outFont = label.font ?: GXKNativeKeyFont(body, root);
        gToolbarStyleSource = label;
    }
    if (body && GXKNineKeyBodyForKey(gEmojiSoftKeyView, root) == body &&
        GXKKeyIsVisible(gEmojiSoftKeyView, root) && GXKNativeIconForKey(gEmojiSoftKeyView) == gActionNativeIcon) {
        UIColor *color = gActionNativeIcon.foregroundColor;
        if ([color isKindOfClass:[UIColor class]]) return color;
    }
    if ([label.textColor isKindOfClass:[UIColor class]]) return label.textColor;
    if (@available(iOS 13.0, *)) return [UIColor labelColor];
    return [UIColor darkGrayColor];
}

static UIColor *GXKToolbarTint(UIView *body) {
    return GXKToolbarTextStyle(body, NULL);
}

// [DEBUG-toolbar] 默认关闭；保留到修复包完成真机字体/对齐/点击验证，随后撤掉诊断接线。
#import "toolbar_diagnostics.h"

static void GXKDetachToolbar(void) {
    UIStackView *stack = gToolbarStack;
    gToolbarStack = nil;
    gToolbarRow = nil;
    gToolbarHost = nil;
    gToolbarLogoView = nil;
    gToolbarNineBody = nil;
    gToolbarBand = CGRectZero;
    gToolbarBandEpoch++; // 撤走工具条后邻居集合变了，缓存必须失效。
    gToolbarBandCacheValid = NO;
    [stack removeFromSuperview];
    if (gToolbarConstraints) {
        [NSLayoutConstraint deactivateConstraints:gToolbarConstraints];
        gToolbarConstraints = nil;
    }
    gToolbarObstacleComplete = NO;
}

// 工具条按钮：只在右侧画一条细分割线，让五个格子读起来像原生分栏，而不是五段浮空文字。
// 用子类而不是往 stack 里塞分隔视图：FillEqually 只均分 arrangedSubviews，
// 多一个视图就把五个按钮的宽度挤歪了。
@interface GXKToolbarButton : UIButton
@property (nonatomic, strong) UIView *gxkDivider;
@end

@implementation GXKToolbarButton
- (void)layoutSubviews {
    [super layoutSubviews];
    UIView *divider = self.gxkDivider;
    if (!divider) return;
    CGFloat inset = floor(self.bounds.size.height * 0.28);
    divider.frame = CGRectMake(self.bounds.size.width - 0.5, inset, 0.5,
                               MAX(0.0, self.bounds.size.height - inset * 2.0));
}
@end

static UIStackView *GXKMakeToolbar(UIView *row, UIColor *tint) {
    // 字体优先用原生标签的字体（通常 Roboto 16pt），拿不到才退回同尺寸系统字体。
    UIFont *font = gToolbarFont ?: ([UIFont fontWithName:@"Roboto-Regular" size:16.0] ?:
                                    [UIFont systemFontOfSize:16.0 weight:UIFontWeightRegular]);
    NSArray<NSString *> *titles = @[@"全选", @"复制", @"粘贴", @"剪切", @"收起"];
    NSArray<NSString *> *actions = @[@"onSelectAll:", @"onCopy:", @"onPaste:", @"onCut:", @"onDismissKeyboard:"];
    UIStackView *stack = [[UIStackView alloc] initWithFrame:row.bounds];
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.distribution = UIStackViewDistributionFillEqually;
    stack.alignment = UIStackViewAlignmentFill;
    stack.spacing = 0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    // 不铺不透明底色：底色一铺就是一条"新增横带"，和原生顶栏割裂。
    // 文字色本来就取自原生标签，透明底反而最像原生。
    stack.backgroundColor = [UIColor clearColor];
    for (NSUInteger i = 0; i < titles.count; i++) {
        GXKToolbarButton *button = [GXKToolbarButton buttonWithType:UIButtonTypeCustom];
        button.backgroundColor = [UIColor clearColor];
        button.adjustsImageWhenHighlighted = NO;
        button.titleLabel.adjustsFontSizeToFitWidth = YES;
        button.titleLabel.minimumScaleFactor = 0.75;
        button.titleLabel.font = font;
        [button setTitle:titles[i] forState:UIControlStateNormal];
        [button setTitleColor:tint forState:UIControlStateNormal];
        [button setTitleColor:[tint colorWithAlphaComponent:0.45] forState:UIControlStateHighlighted];
        button.accessibilityLabel = titles[i];
        if (i + 1 < titles.count) {
            // 分割线用主文字色降透明度，深浅两套主题都不用另配颜色。
            UIView *divider = [[UIView alloc] initWithFrame:CGRectZero];
            divider.backgroundColor = [tint colorWithAlphaComponent:0.18];
            divider.userInteractionEnabled = NO;
            [button addSubview:divider];
            button.gxkDivider = divider;
        }
        [button addTarget:gToolbarTarget action:NSSelectorFromString(actions[i]) forControlEvents:UIControlEventTouchUpInside];
        if (i == 1) { // [DEBUG-toolbar] 仅「复制」长按诊断，普通点击不变。
            UILongPressGestureRecognizer *diagnostic = [[UILongPressGestureRecognizer alloc]
                initWithTarget:gToolbarTarget action:@selector(onToolbarDiagnostic:)];
            diagnostic.minimumPressDuration = 0.8;
            diagnostic.cancelsTouchesInView = YES;
            [button addGestureRecognizer:diagnostic];
            button.accessibilityHint = @"长按开始工具栏诊断，再长按停止并复制报告";
        }
        [stack addArrangedSubview:button];
    }
    return stack;
}

static void GXKSyncToolbarStyle(UIView *body) {
    UIFont *font = nil;
    UIColor *tint = GXKToolbarTextStyle(body, &font);
    gToolbarFont = font;
    for (UIView *view in gToolbarStack.arrangedSubviews) {
        if (![view isKindOfClass:[UIButton class]]) continue;
        UIButton *button = (UIButton *)view;
        if (![button.titleLabel.font isEqual:font]) button.titleLabel.font = font;
        if (![[button titleColorForState:UIControlStateNormal] isEqual:tint]) {
            [button setTitleColor:tint forState:UIControlStateNormal];
            [button setTitleColor:[tint colorWithAlphaComponent:0.45] forState:UIControlStateHighlighted];
        }
        if ([button isKindOfClass:[GXKToolbarButton class]])
            ((GXKToolbarButton *)button).gxkDivider.backgroundColor = [tint colorWithAlphaComponent:0.18];
    }
}

static void GXKUpdateToolbar(UIViewController *vc) {
    if (gUpdatingToolbar || !vc || vc != gCurrentVC || !vc.isViewLoaded) return;
    gUpdatingToolbar = YES;
    UIView *root = vc.view;
    GXKToolbarDiagnosticBegin(vc);
    BOOL composing = GXKComposingStateCached(vc);
    BOOL bound = gToolbarStack && gToolbarHost == root && gToolbarStack.superview == root &&
                 gToolbarRow && gToolbarLogoView.superview == gToolbarRow &&
                 GXKKeyIsVisible(gToolbarLogoView, root) && GXKKeyIsVisible(gToolbarRow, root) && GXKKeyIsVisible(gToolbarNineBody, root);
    if (bound) {
        GXKSyncToolbarStyle(gToolbarNineBody);
        CGRect band = CGRectZero;
        BOOL measured = GXKToolbarBand(gToolbarRow, gToolbarLogoView, root, &band);
        CGRect hostBand = measured ? [gToolbarRow convertRect:band toView:root] : CGRectZero;
        BOOL clear = measured && GXKToolbarNativeSpaceClear(root, gToolbarLogoView, hostBand);
        if (composing || !clear) {
            gToolbarStack.hidden = YES;
            GXKToolbarDiagnosticRequest(vc, composing ? @"composing-hidden" : @"native-content-hidden");
            gUpdatingToolbar = NO;
            return;
        }
        if (CGRectEqualToRect(band, gToolbarBand) && CGRectEqualToRect(hostBand, gToolbarStack.frame)) {
            gToolbarStack.hidden = NO;
            if (root.subviews.lastObject != gToolbarStack) [root bringSubviewToFront:gToolbarStack];
            GXKToolbarDiagnosticRequest(vc, @"fast-unchanged");
            gUpdatingToolbar = NO;
            return;
        }
    }
    UIView *row = nil, *logo = nil, *body = nil;
    CGRect band = CGRectZero;
    GXKToolbarDiagnosticResetGates(); // A fresh scan cannot inherit a prior bound-path attempt.
    if (!GXKToolbarScan(root, &row, &logo, &body, &band)) {
        GXKDetachToolbar();
        GXKToolbarDiagnosticRequest(vc, @"scan-failed");
        gUpdatingToolbar = NO;
        return;
    }
    CGRect hostBand = [row convertRect:band toView:root];
    BOOL clear = GXKToolbarNativeSpaceClear(root, logo, hostBand);
    BOOL reuse = gToolbarStack && gToolbarRow == row && gToolbarLogoView == logo &&
                 gToolbarHost == root && gToolbarStack.superview == root;
    if (!reuse) GXKDetachToolbar();
    if (!gToolbarTarget) gToolbarTarget = [[GXKToolbarTarget alloc] init];
    gToolbarTarget.controller = vc;
    UIFont *font = nil;
    UIColor *tint = GXKToolbarTextStyle(body, &font);
    gToolbarFont = font;
    UIStackView *stack = reuse ? gToolbarStack : GXKMakeToolbar(root, tint);
    stack.backgroundColor = [UIColor clearColor];
    gToolbarStack = stack;
    gToolbarRow = row;
    gToolbarHost = root;
    gToolbarLogoView = logo;
    gToolbarNineBody = body;
    gToolbarBand = band; // Keep row-neighbour and diagnostic coordinates separate from host coordinates.
    GXKSyncToolbarStyle(body);
    stack.hidden = composing || !clear;
    if (stack.superview != root) [root addSubview:stack];
    if (gToolbarConstraints) [NSLayoutConstraint deactivateConstraints:gToolbarConstraints];
    gToolbarConstraints = @[
        [stack.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:hostBand.origin.x - root.bounds.origin.x],
        [stack.widthAnchor constraintEqualToConstant:hostBand.size.width],
        [stack.topAnchor constraintEqualToAnchor:root.topAnchor constant:hostBand.origin.y - root.bounds.origin.y],
        [stack.heightAnchor constraintEqualToConstant:hostBand.size.height],
    ];
    [NSLayoutConstraint activateConstraints:gToolbarConstraints];
    [root bringSubviewToFront:stack];
    GXKToolbarDiagnosticRequest(vc, reuse ? @"reuse-resampled" : @"new-resampled");
    gUpdatingToolbar = NO;
}

@implementation GXKToolbarTarget

// [DEBUG-toolbar] 单次长按只处理 began，抬手不触发普通复制。
- (void)onToolbarDiagnostic:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    UIViewController *vc = self.controller;
    UIButton *button = [gesture.view isKindOfClass:[UIButton class]] ? (UIButton *)gesture.view : nil;
    if (!vc || vc != gCurrentVC || !button ||
        ![gToolbarStack.arrangedSubviews containsObject:button]) return;
    GXKToolbarDiagnosticToggle(vc, button);
}

- (id<UITextDocumentProxy>)proxy {
    UIViewController *vc = self.controller;
    if (!vc || vc != gCurrentVC || ![vc isKindOfClass:[UIInputViewController class]]) return nil;
    return ((UIInputViewController *)vc).textDocumentProxy;
}

// 组字中改宿主文本会破坏拼音会话：先让用户完成或取消输入。
- (BOOL)refuseWhileComposing:(UIButton *)sender {
    UIViewController *vc = self.controller;
    if (!vc || vc != gCurrentVC) return YES;
    if (!GXKComposingStateCached(vc)) return NO;
    GXKFlashTitle(sender, @"先完成拼音");
    GXKImpact(UIImpactFeedbackStyleLight);
    return YES;
}

- (void)onSelectAll:(UIButton *)sender {
    // iOS 键盘扩展没有 selectAll：这里把光标前后上下文整体送进剪贴板，语义是"复制全部"。
    // 长文本下 documentContext 会被系统截断，这是平台上限，不是本补丁的取舍。
    if ([self refuseWhileComposing:sender]) return;
    id<UITextDocumentProxy> proxy = self.proxy;
    if (!proxy) return;
    NSString *before = proxy.documentContextBeforeInput ?: @"";
    NSString *after = proxy.documentContextAfterInput ?: @"";
    NSString *text = [before stringByAppendingString:after];
    if (!text.length) { GXKFlashTitle(sender, @"无文本"); return; }
    [UIPasteboard generalPasteboard].string = text;
    // 记下这次「全选」覆盖的范围：紧接着点「剪切」直接按这段文本落地，不再要求系统选区。
    gToolbarSelectAllText = text;
    gToolbarSelectAllAt = [NSDate timeIntervalSinceReferenceDate];
    GXKImpact(UIImpactFeedbackStyleLight); // 成功不闪提示：连点时不改标题就不重排、不卡。
}

- (void)onCopy:(UIButton *)sender {
    if ([self refuseWhileComposing:sender]) return;
    id<UITextDocumentProxy> proxy = self.proxy;
    if (!proxy) return;
    NSString *text = proxy.selectedText;
    if (!text.length) {
        text = [(proxy.documentContextBeforeInput ?: @"") stringByAppendingString:(proxy.documentContextAfterInput ?: @"")];
    }
    if (!text.length) { GXKFlashTitle(sender, @"无文本"); return; }
    [UIPasteboard generalPasteboard].string = text;
    GXKImpact(UIImpactFeedbackStyleLight);
}

- (void)onPaste:(UIButton *)sender {
    if ([self refuseWhileComposing:sender]) return;
    id<UITextDocumentProxy> proxy = self.proxy;
    NSString *text = [UIPasteboard generalPasteboard].string;
    if (!proxy || !text.length) { GXKFlashTitle(sender, @"剪贴板空"); return; }
    [proxy insertText:text];
    GXKImpact(UIImpactFeedbackStyleLight);
}

// 光标前逐字删除：只在用户明确点了「剪切」且确实有内容时才走，且总量有上限。
// 先删「光标前」再删「光标后」是不可能的（扩展无法移动光标），所以只处理光标前那一段。
- (void)deleteBeforeCursor:(NSUInteger)count {
    id<UITextDocumentProxy> proxy = self.proxy;
    if (!proxy) return;
    NSUInteger limit = MIN(count, (NSUInteger)GXK_CUT_MAX_CHARS);
    for (NSUInteger i = 0; i < limit; i++) [proxy deleteBackward];
}

- (void)onCut:(UIButton *)sender {
    if ([self refuseWhileComposing:sender]) return;
    id<UITextDocumentProxy> proxy = self.proxy;
    if (!proxy) return;
    NSString *selected = proxy.selectedText;
    if (selected.length) {
        [UIPasteboard generalPasteboard].string = selected;
        [proxy deleteBackward]; // 有选区时删掉的就是选区本身。
        gToolbarSelectAllText = nil;
        GXKImpact(UIImpactFeedbackStyleLight);
        return;
    }
    // 刚点过「全选」：把当时记下的内容直接剪切，等价于"全选→剪切"，不要求系统选区。
    NSTimeInterval since = [NSDate timeIntervalSinceReferenceDate] - gToolbarSelectAllAt;
    NSString *remembered = gToolbarSelectAllText;
    if (remembered.length && since >= 0.0 && since <= GXK_SELECT_ALL_WINDOW) {
        NSString *before = proxy.documentContextBeforeInput ?: @"";
        NSString *after = proxy.documentContextAfterInput ?: @"";
        NSString *current = [before stringByAppendingString:after];
        // 只在文本没变过时按"全选"语义剪掉光标前那一段，避免误删新输入的内容。
        if ([current isEqualToString:remembered] && before.length) {
            [UIPasteboard generalPasteboard].string = remembered;
            gToolbarSelectAllText = nil;
            [self deleteBeforeCursor:before.length];
            GXKImpact(UIImpactFeedbackStyleLight);
            return;
        }
    }
    // 其余情况绝不逐字删除：旧版按上下文长度循环 deleteBackward，长文本会卡死键盘扩展。
    GXKFlashTitle(sender, @"先选中");
    GXKImpact(UIImpactFeedbackStyleLight);
}

- (void)onDismissKeyboard:(UIButton *)sender {
    UIViewController *vc = self.controller;
    if (!vc || vc != gCurrentVC || ![vc isKindOfClass:[UIInputViewController class]]) return;
    GXKImpact(UIImpactFeedbackStyleLight);
    [(UIInputViewController *)vc dismissKeyboard]; // 公开 API，结束宿主编辑会话。
}

@end

#pragma mark - 按需轮询 (事件驱动，空闲即停表)

static void GXKUpdateActionKey(UIViewController *vc);

// 一次事件后只保留约 1 秒的补帧窗口；窗口内没有新事件就停表，不再每秒空唤醒 5 次。
#define GXK_POLL_BURST 5
// 组字状态没翻转时的极小窗口：普通打字只补两帧，不再每键拉起整轮刷新。
#define GXK_POLL_SETTLE 2

static void GXKStopPolling(void) {
    if (gStatePollTimer) {
        [gStatePollTimer invalidate];
        gStatePollTimer = nil;
    }
    gPollTicks = 0;
}

static void GXKBumpPolling(NSInteger ticks) {
    if (ticks > gPollTicks) gPollTicks = ticks;
    if (gStatePollTimer || gPollTicks <= 0 || !gCurrentVC) return;
    gStatePollTimer = [NSTimer scheduledTimerWithTimeInterval:0.20 repeats:YES block:^(NSTimer *timer) {
        UIViewController *vc = gCurrentVC;
        if (!vc || gPollTicks <= 0) { // 没有待刷新内容：停表，等下一个事件再启动。
            GXKStopPolling();
            return;
        }
        gPollTicks--;
        GXKUpdateActionKey(vc);
        GXKUpdateToolbar(vc);
    }];
    // scheduledTimerWithTimeInterval: 已经把表挂到默认模式；再挂 CommonModes 会让 0.2 秒轮询
    // 在滚动、动画、触摸跟踪期间继续抢主线程，那正是「动画卡顿」的来源。只留默认模式。
}

@interface GXKActionKeyTarget : NSObject
- (void)onActionKeyTapped:(UIButton *)sender;
- (void)onActionKeyDiagnostic:(UILongPressGestureRecognizer *)gesture;
@end

static void GXKUpdateActionKey(UIViewController *vc);

@implementation GXKActionKeyTarget
// [DEBUG-toolbar] The patch key remains reachable when the toolbar has detached.
- (void)onActionKeyDiagnostic:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    UIViewController *vc = gCurrentVC;
    UIButton *button = [gesture.view isKindOfClass:[UIButton class]] ? (UIButton *)gesture.view : nil;
    if (!vc || !vc.isViewLoaded || ![vc isKindOfClass:[UIInputViewController class]] ||
        !button || button != gActionKeyButton || button.superview != gActionHost ||
        !GXKKeyIsVisible(button, vc.view) ||
        GXKNineKeyBodyForKey(gEmojiSoftKeyView, vc.view) == nil ||
        GXKActionHostForKey(gEmojiSoftKeyView) != gActionHost ||
        GXKNativeIconForKey(gEmojiSoftKeyView) != gActionNativeIcon ||
        ((id<GXKNativeSoftKeyContent>)gEmojiSoftKeyView).softKeyDef != gActionSoftKeyDef ||
        !GXKModelHasNativeActions(gActionSoftKeyDef)) return;
    GXKToolbarDiagnosticToggle(vc, button); // No input action or layout mutation.
}

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
    GXKBumpPolling(GXK_POLL_BURST); // 原生刷新可能在点击后几帧才到，给补帧窗口。
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
        UIFont *cheapFont = GXKNativeActionFont(gEmojiSoftKeyView, root);
        if (![cheapBtn.titleLabel.font isEqual:cheapFont]) cheapBtn.titleLabel.font = cheapFont;
        NSString *cheapTitle = GXKComposingStateCached(vc) ? @"重输" : @"换行";
        if (!(cheapBtn == gToolbarDiagnosticFeedbackButton && GXKToolbarDiagnosticNow() < gToolbarDiagnosticFeedbackUntil) &&
            ![[cheapBtn titleForState:UIControlStateNormal] isEqualToString:cheapTitle]) {
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
        // [DEBUG-toolbar] Scoped to our button, never native G or the keyboard root.
        UILongPressGestureRecognizer *diagnostic = [[UILongPressGestureRecognizer alloc]
            initWithTarget:gActionTarget action:@selector(onActionKeyDiagnostic:)];
        diagnostic.minimumPressDuration = 0.8;
        diagnostic.cancelsTouchesInView = YES;
        [btn addGestureRecognizer:diagnostic];
        btn.accessibilityHint = @"长按开始工具栏诊断，再长按停止并复制报告";
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
    if (!(btn == gToolbarDiagnosticFeedbackButton && GXKToolbarDiagnosticNow() < gToolbarDiagnosticFeedbackUntil) &&
        ![[btn titleForState:UIControlStateNormal] isEqualToString:title]) {
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
static void GXKApplyMiniAppAndSuggestionHooks(void);
static void GXKInstallPhrasesHooks(void);
static void GXKInstallMainAppHooks(void);
static void GXKDetachPhrasesPanel(void);
static id GXKPhrasesPickerItem(void);
static NSString *GXKPickerItemIdentifier(id item);

static void gkx_textDidChange(id self, SEL _cmd, id textInput) {
    if (gOrigTextDidChange) gOrigTextDidChange(self, _cmd, textInput);
    gToolbarContentEpoch++;
    __weak UIViewController *weakVC = (UIViewController *)self;
    // 同一帧内可能连来多次文本回调：只让最后一次真正刷新，前面排队的直接丢弃。
    // 否则一次按键就能排出好几轮全量刷新，主线程被重复工作占满。
    static NSUInteger gTextChangeSeq;
    NSUInteger seq = ++gTextChangeSeq;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (seq != gTextChangeSeq) return; // 后面还有更新的回调，交给它刷新。
        UIViewController *vc = weakVC;
        if (vc && vc == gCurrentVC) {
            BOOL wasComposing = gComposingActive;
            GXKRefreshComposingState(vc); // 组字状态只在此处与布局事件里全树扫描一次。
            GXKUpdateActionKey(vc);
            GXKUpdateToolbar(vc);
            // 只有组字状态翻转才需要完整补帧窗口；普通打字补两帧就够，
            // 否则连续输入会让定时器永远跑不完，等于持续每秒 5 次全量刷新。
            GXKBumpPolling((wasComposing != gComposingActive) ? GXK_POLL_BURST : GXK_POLL_SETTLE);
        }
    });
}

static void gkx_viewDidLayoutSubviews(id self, SEL _cmd) {
    if (gOrigViewDidLayoutSubviews) gOrigViewDidLayoutSubviews(self, _cmd);
    if ((UIViewController *)self != gCurrentVC) return;
    gToolbarContentEpoch++;
    // 布局回调一帧内可能来几十次（任何 setNeedsLayout 都会触发）：
    // 合并成一次异步刷新，只保留最后一次，避免同一帧反复全量重算。
    static NSUInteger gLayoutSeq;
    NSUInteger seq = ++gLayoutSeq;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (seq != gLayoutSeq) return;
        UIViewController *vc = gCurrentVC;
        if (!vc || !vc.isViewLoaded) return;
        GXKRefreshComposingState(vc);
        GXKUpdateActionKey(vc);
        GXKUpdateToolbar(vc);
    });
}

static void gkx_viewWillAppear(id self, SEL _cmd, BOOL animated) {
    if (gOrigViewWillAppear) gOrigViewWillAppear(self, _cmd, animated);
    if ((UIViewController *)self != gCurrentVC) {
        GXKDetachActionKey();
        GXKDetachToolbar();
    }
    if (gCurrentVC != (UIViewController *)self) GXKResetNativeKeyStyle();
    gToolbarContentEpoch++;
    gCurrentVC = (UIViewController *)self;
    GXKRefreshComposingState((UIViewController *)self); // 新会话先取一次真实组字状态。
    GXKApplyTelemetryBlockIfNeeded(); // 兜底：构造函数时framework若未就绪，这里补一次。
    GXKApplyMiniAppAndSuggestionHooks(); // 分页裁剪与历史删除：类未就绪时下次出现再试。
    GXKInstallPhrasesHooks(); // 常用语分页：同上。
    GXKInstallMainAppHooks(); // 主 App 侧入口（键盘进程里类不存在，自然跳过）。

    // 部署外部万象词库
    GXKEnsureUserDictionaryDeployed();

    // 轮询只补足组字/原生主题内容刷新；布局切换由layout回调立即重新定位。
    // 这里只给一小段补帧窗口，窗口走完自动停表。
    GXKBumpPolling(GXK_POLL_BURST);
    GXKUpdateToolbar((UIViewController *)self); // 首帧先尝试挂载，失败即保持原生。
}

static void gkx_viewWillDisappear(id self, SEL _cmd, BOOL animated) {
    // 先撤销当前绑定，原生生命周期引起的布局/异步事件不得重建旧按钮。
    if ((UIViewController *)self == gCurrentVC) {
        GXKToolbarDiagnosticStop((UIViewController *)self, @"keyboard-disappear"); // [DEBUG-toolbar]
        GXKResetNativeKeyStyle();
        gToolbarObstacleRoot = nil;
        gToolbarObstacles = nil;
        gToolbarKeyboardBodies = nil;
        gToolbarObstacleComplete = NO;
        gCurrentVC = nil;
        gComposingActive = NO; // 扩展隐藏后组字缓存作废，下次出现重新采样。
        GXKStopPolling();
        GXKDetachActionKey();
        GXKDetachToolbar(); // 扩展隐藏后工具条随宿主一起撤走，下次出现重新定位。
        GXKDetachPhrasesPanel(); // 常用语面板随扩展隐藏一起撤走。
        GXKReleaseHaptics(); // 扩展隐藏后不常驻触觉引擎。
    }
    if (gOrigViewWillDisappear) gOrigViewWillDisappear(self, _cmd, animated);
}

static void gkx_viewDidAppear(id self, SEL _cmd, BOOL animated) {
    if (gOrigViewDidAppear) gOrigViewDidAppear(self, _cmd, animated);
    if ((UIViewController *)self == gCurrentVC) {
        GXKRefreshComposingState((UIViewController *)self);
        GXKUpdateActionKey((UIViewController *)self);
        GXKUpdateToolbar((UIViewController *)self);
        GXKBumpPolling(GXK_POLL_BURST);
    }
}

#pragma mark - G 图标分页裁剪 + 搜索历史单条删除

// 两件事都只改「原实现返回后的结果」，不碰布局、不加高度：
//   1. 从 G 图标展开页的分页条里去掉 YouTube 与联系人两页（三层兜底）。
//   2. 搜索历史每一行右侧叠一个 ×，点掉即从列表与持久化记录里删掉该条。
// 任一类或方法在新版 Gboard 里消失就跳过，自然降级为原生行为。

#define GXK_PHRASES_PANEL_TAG   0x47584B50  // 'GXKP'
#define GXK_PHRASES_PIN_TAG     0x47584B51
#define GXK_PHRASES_CLOSE_TAG   0x47584B52
#define GXK_PHRASES_TITLE_TAG   0x47584B54
#define GXK_PHRASES_TABLE_TAG   0x47584B55
#define GXK_PHRASES_HINT_TAG    0x47584B56
#define GXK_PHRASES_EDIT_TAG    0x47584B57
#define GXK_PHRASES_CELL_ID     @"GXKPhraseCell"
#define GXK_PHRASES_IDENTIFIER  @"gxk_phrases"

#define GXK_SUGGESTION_X_TAG 0x47584B58  // 'GXKX'
static char GXKSuggestionTextKey;  // 关联对象键：必须用静态地址，字符串字面量会被合并。

static BOOL gxk_mini_app_hooked = NO;
static BOOL gxk_suggestion_hooked = NO;

// 这两个 getter 返回 flag 对象，原实现指针必须按 id 返回声明，否则返回值被丢弃。
static id (*gOrigEnableYouTubeMiniApp)(id, SEL);
static id (*gOrigEnableContactsMiniApp)(id, SEL);
static BOOL (*gOrigIsMiniAppEnabled)(id, SEL, id);
static id (*gOrigAvailablePickerItems)(id, SEL);
static void (*gOrigShowSuggestions)(id, SEL, id);
static id (*gOrigCellForRow)(id, SEL, id, id);

// 分页 identifier 判定：youtube / contacts / gif / sticker 四类一律不放行。
// 常量符号在二进制里取不到可靠值，故用字符串匹配；gif 与 sticker 用整词判，
// 避免包含匹配把 "gift" 这类无关分页一起误杀。
static BOOL GXKIdentifierExcluded(id identifier) {
    NSString *text = nil;
    if ([identifier isKindOfClass:[NSString class]]) {
        text = (NSString *)identifier;
    } else if (identifier && [identifier respondsToSelector:@selector(identifier)]) {
        id value = ((id (*)(id, SEL))objc_msgSend)(identifier, @selector(identifier));
        if ([value isKindOfClass:[NSString class]]) text = value;
    }
    if (text.length == 0) return NO;
    NSString *lower = [text lowercaseString];
    if ([lower isEqualToString:@"gif"] || [lower isEqualToString:@"sticker"]) return YES;
    return [lower rangeOfString:@"youtube"].location != NSNotFound ||
           [lower rangeOfString:@"contacts"].location != NSNotFound;
}

// GKBFeatureFlagManager 的这两个 getter 返回的是 GKBBoolFeatureFlag 对象而非 BOOL，
// 直接返回 NO 会类型错乱，这里返回一个 value==NO 的真实 flag 实例。
static id GXKDisabledFeatureFlag(void) {
    static id flag = nil;
    static BOOL tried = NO;
    if (!tried) {
        tried = YES;
        Class cls = NSClassFromString(@"GKBBoolFeatureFlag");
        if (cls) {
            id obj = [[cls alloc] init];
            // 默认值本就是 NO，KVC 只是为了确保关闭；失败也照用该实例。
            @try { [obj setValue:@NO forKey:@"value"]; } @catch (__unused NSException *e) {}
            flag = obj;
        }
    }
    return flag;
}

// 优先把原 flag 的 value 改成 NO（保留 key 与对象身份，外部观察者不会拿到 nil key）；
// 改不动才退回一个自建 flag，最差情况由下面两层过滤兜住。
static id GXKFlagTurnedOff(id original) {
    if (original) {
        @try {
            [original setValue:@NO forKey:@"value"];
            return original;
        } @catch (__unused NSException *e) {}
    }
    return GXKDisabledFeatureFlag();
}

static id gxk_enableYouTubeMiniApp(id self, SEL _cmd) {
    id original = gOrigEnableYouTubeMiniApp ? gOrigEnableYouTubeMiniApp(self, _cmd) : nil;
    return GXKFlagTurnedOff(original);
}

static id gxk_enableContactsMiniApp(id self, SEL _cmd) {
    id original = gOrigEnableContactsMiniApp ? gOrigEnableContactsMiniApp(self, _cmd) : nil;
    return GXKFlagTurnedOff(original);
}

static BOOL gxk_isMiniAppEnabled(id self, SEL _cmd, id identifier) {
    if (GXKIdentifierExcluded(identifier)) return NO;
    return gOrigIsMiniAppEnabled ? gOrigIsMiniAppEnabled(self, _cmd, identifier) : YES;
}

static id gxk_availablePickerItems(id self, SEL _cmd) {
    id items = gOrigAvailablePickerItems ? gOrigAvailablePickerItems(self, _cmd) : nil;
    if (![items isKindOfClass:[NSArray class]]) return items;
    NSArray *list = (NSArray *)items;
    NSMutableArray *kept = [NSMutableArray arrayWithCapacity:list.count + 1];
    BOOL hasPhrases = NO;
    for (id item in list) {
        if (GXKIdentifierExcluded(item)) continue;
        NSString *ident = GXKPickerItemIdentifier(item);
        if (ident && [ident isEqualToString:GXK_PHRASES_IDENTIFIER]) hasPhrases = YES;
        [kept addObject:item];
    }
    // 常用语排在地图之后、其余原生分页之前，位置与原生命令一致。
    id phrases = GXKPhrasesPickerItem();
    if (phrases && !hasPhrases) [kept addObject:phrases];
    return kept;
}

static void GXKSwizzleOrSkip(NSString *className, NSString *selName, IMP imp, void **orig) {
    Class cls = NSClassFromString(className);
    if (!cls) return;
    Method m = class_getInstanceMethod(cls, NSSelectorFromString(selName));
    if (!m) return;
    if (orig) *orig = (void *)method_getImplementation(m);
    method_setImplementation(m, imp);
}

static void GXKInstallMiniAppHooks(void) {
    if (gxk_mini_app_hooked) return;
    if (!NSClassFromString(@"GKBMiniAppManager")) return; // framework 还没加载，下次再试。
    GXKSwizzleOrSkip(@"GKBFeatureFlagManager", @"enableYouTubeMiniApp",
                     (IMP)gxk_enableYouTubeMiniApp, (void **)&gOrigEnableYouTubeMiniApp);
    GXKSwizzleOrSkip(@"GKBFeatureFlagManager", @"enableContactsMiniApp",
                     (IMP)gxk_enableContactsMiniApp, (void **)&gOrigEnableContactsMiniApp);
    GXKSwizzleOrSkip(@"GKBMiniAppExtensionBase", @"isMiniAppEnabled:",
                     (IMP)gxk_isMiniAppEnabled, (void **)&gOrigIsMiniAppEnabled);
    GXKSwizzleOrSkip(@"GKBMiniAppManager", @"availablePickerItems",
                     (IMP)gxk_availablePickerItems, (void **)&gOrigAvailablePickerItems);
    gxk_mini_app_hooked = YES;
    GXK_LOG(@"[*] 已裁剪 G 图标分页: 去掉 YouTube / 联系人");
}

static __weak id gSuggestionView;

static void gxk_showSuggestions(id self, SEL _cmd, id suggestions) {
    if (gOrigShowSuggestions) gOrigShowSuggestions(self, _cmd, suggestions);
    gSuggestionView = self; // 只记宿主，删哪一条由点击时的显示文字决定。
}

static NSString *GXKSuggestionTextForCell(UIView *cell) {
    if (!cell) return nil;
    @try {
        id label = [cell valueForKey:@"suggestionLabel"];
        if ([label isKindOfClass:[UILabel class]]) {
            NSString *text = ((UILabel *)label).text;
            if (text.length > 0) return text;
        }
    } @catch (__unused NSException *e) {}
    return nil;
}

// 从当前建议数组里按显示文字定位那一条：不猜行序，避免倒序排列时删错。
static NSInteger GXKSuggestionIndexForText(id view, NSString *text) {
    if (!view || text.length == 0) return NSNotFound;
    id raw = nil;
    @try { raw = [view valueForKey:@"suggestions"]; } @catch (__unused NSException *e) { return NSNotFound; }
    if (![raw isKindOfClass:[NSArray class]]) return NSNotFound;
    NSArray *list = (NSArray *)raw;
    NSUInteger total = list.count;
    for (NSUInteger i = 0; i < total; i++) {
        id item = list[i];
        NSString *candidate = nil;
        @try {
            id value = [item valueForKey:@"strippedText"];
            if ([value isKindOfClass:[NSString class]]) candidate = value;
        } @catch (__unused NSException *e) {}
        if (candidate.length == 0 && [item isKindOfClass:[NSString class]]) candidate = item;
        if (candidate.length == 0) continue;
        if ([candidate isEqualToString:text]) return (NSInteger)i;
    }
    for (NSUInteger i = 0; i < total; i++) {
        id item = list[i];
        NSString *candidate = nil;
        @try {
            id value = [item valueForKey:@"strippedText"];
            if ([value isKindOfClass:[NSString class]]) candidate = value;
        } @catch (__unused NSException *e) {}
        if (candidate.length == 0) continue;
        if ([candidate rangeOfString:text].location != NSNotFound ||
            [text rangeOfString:candidate].location != NSNotFound) return (NSInteger)i;
    }
    return NSNotFound;
}

// 只删不造：遍历所有带 RecentQueries 的键，命中才写回，没有命中一个字节都不动。
static void GXKRemovePersistedRecentQuery(NSString *text) {
    if (text.length == 0) return;
    NSMutableArray *stores = [NSMutableArray array];
    NSUserDefaults *standard = [NSUserDefaults standardUserDefaults];
    if (standard) [stores addObject:standard];
    NSUserDefaults *group = [[NSUserDefaults alloc] initWithSuiteName:GXKGroup];
    if (group) [stores addObject:group];
    for (NSUserDefaults *defaults in stores) {
        NSDictionary *all = [defaults dictionaryRepresentation];
        if (![all isKindOfClass:[NSDictionary class]]) continue;
        for (NSString *key in all) {
            if (![key isKindOfClass:[NSString class]]) continue;
            if ([key rangeOfString:@"RecentQueries" options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
            id value = all[key];
            if (![value isKindOfClass:[NSArray class]]) continue;
            NSArray *list = (NSArray *)value;
            NSMutableArray *kept = [NSMutableArray arrayWithCapacity:list.count];
            BOOL changed = NO;
            for (id entry in list) {
                if ([entry isKindOfClass:[NSString class]] && [(NSString *)entry isEqualToString:text]) {
                    changed = YES;
                    continue;
                }
                [kept addObject:entry];
            }
            if (changed) [defaults setObject:kept forKey:key];
        }
    }
}

@interface GXKSuggestionTarget : NSObject
- (void)onDeleteSuggestion:(UIButton *)sender;
@end

static GXKSuggestionTarget *gSuggestionTarget;

@implementation GXKSuggestionTarget
- (void)onDeleteSuggestion:(UIButton *)sender {
    id view = gSuggestionView;
    NSString *text = objc_getAssociatedObject(sender, &GXKSuggestionTextKey);
    if (!view || text.length == 0) return;
    NSInteger index = GXKSuggestionIndexForText(view, text);
    if (index == NSNotFound) return;
    id raw = nil;
    @try { raw = [view valueForKey:@"suggestions"]; } @catch (__unused NSException *e) { return; }
    if (![raw isKindOfClass:[NSArray class]]) return;
    NSMutableArray *next = [(NSArray *)raw mutableCopy];
    if (index < 0 || (NSUInteger)index >= next.count) return;
    [next removeObjectAtIndex:(NSUInteger)index];
    GXKImpact(UIImpactFeedbackStyleLight);
    if ([view respondsToSelector:@selector(showSuggestions:)]) {
        ((void (*)(id, SEL, id))objc_msgSend)(view, @selector(showSuggestions:), next);
    }
    GXKRemovePersistedRecentQuery(text);
}
@end

static void GXKAttachSuggestionDelete(UIView *cell, UITableView *table) {
    if (!cell) return;
    // cell 在运行时是 UITableViewCell，但静态类型是 UIView：只有真是 cell 才取 contentView。
    UIView *host = cell;
    if ([cell isKindOfClass:[UITableViewCell class]]) {
        UIView *content = ((UITableViewCell *)cell).contentView;
        if (content) host = content;
    }
    NSString *text = GXKSuggestionTextForCell(cell);
    UIButton *button = [host viewWithTag:GXK_SUGGESTION_X_TAG];
    if (text.length == 0) {
        if (button) [button removeFromSuperview];
        return;
    }
    if (!button) {
        if (!gSuggestionTarget) gSuggestionTarget = [[GXKSuggestionTarget alloc] init];
        button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.tag = GXK_SUGGESTION_X_TAG;
        [button setTitle:@"×" forState:UIControlStateNormal];
        button.titleLabel.font = [UIFont systemFontOfSize:19.0 weight:UIFontWeightRegular];
        button.accessibilityLabel = @"删除这条搜索记录";
        [button addTarget:gSuggestionTarget action:@selector(onDeleteSuggestion:)
         forControlEvents:UIControlEventTouchUpInside];
        [host addSubview:button];
    }
    objc_setAssociatedObject(button, &GXKSuggestionTextKey, text, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    CGFloat side = 28.0;
    CGFloat width = CGRectGetWidth(cell.bounds);
    if (width < side * 2.0 && table) width = CGRectGetWidth(table.bounds);
    if (width < side * 2.0) width = 320.0;
    CGFloat height = CGRectGetHeight(cell.bounds);
    if (height <= 0) height = 44.0;
    button.frame = CGRectMake(width - side - 4.0, (height - side) / 2.0, side, side);
    button.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin |
                              UIViewAutoresizingFlexibleTopMargin |
                              UIViewAutoresizingFlexibleBottomMargin;
    if (host.subviews.lastObject != button) [host bringSubviewToFront:button];
}

static id gxk_cellForRow(id self, SEL _cmd, id tableView, id indexPath) {
    id cell = gOrigCellForRow ? gOrigCellForRow(self, _cmd, tableView, indexPath) : nil;
    if ([cell isKindOfClass:[UIView class]]) {
        UITableView *table = [tableView isKindOfClass:[UITableView class]] ? (UITableView *)tableView : nil;
        GXKAttachSuggestionDelete((UIView *)cell, table);
    }
    return cell;
}

static void GXKInstallSuggestionHooks(void) {
    if (gxk_suggestion_hooked) return;
    if (!NSClassFromString(@"GKBQuerySuggestionsView")) return;
    GXKSwizzleOrSkip(@"GKBQuerySuggestionsView", @"showSuggestions:",
                     (IMP)gxk_showSuggestions, (void **)&gOrigShowSuggestions);
    GXKSwizzleOrSkip(@"GKBQuerySuggestionsView", @"tableView:cellForRowAtIndexPath:",
                     (IMP)gxk_cellForRow, (void **)&gOrigCellForRow);
    gxk_suggestion_hooked = YES;
    GXK_LOG(@"[*] 搜索历史已加单条删除按钮");
}

static void GXKApplyMiniAppAndSuggestionHooks(void) {
    GXKInstallMiniAppHooks();
    GXKInstallSuggestionHooks();
}

#pragma mark - G 图标「常用语」分页 + 主 App 维护入口

// 常用语存在 App Group 的 NSUserDefaults 里，键盘与主 App 共用同一份数据。
// 分页本身是自建覆盖层：不实现整套 mini app 协议，只在分页条上多一项并接管它的选中事件。

static NSString *const GXKPhrasesKey = @"GXKPhrases";
static NSString *const GXKPhrasesPinnedKey = @"GXKPhrasesPinned";
// 编辑器改完通知键盘面板刷新，避免两处入口看到不同步的列表。
static NSString *const GXKPhrasesChangedNotification = @"GXKPhrasesChangedNotification";

static BOOL gxk_phrases_hooked = NO;
static BOOL gxk_settings_hooked = NO;
static void (*gOrigMiniAppPickerDidSelect)(id, SEL, id, id, unsigned long long);
static void (*gOrigArtMiniAppPickerDidSelect)(id, SEL, id, id, unsigned long long);
static id (*gOrigSettingsMainMenu)(id, SEL); // mainMenuPageDescriptor 返回 id。
static void (*gOrigSettingsPageDidSelect)(id, SEL, id, id);
static __weak UIView *gPhrasesPanelView;
static __weak id gPhrasesMiniAppHost;

static NSUserDefaults *GXKPhraseDefaults(void) {
    static NSUserDefaults *defaults = nil;
    static BOOL tried = NO;
    if (!tried) {
        tried = YES;
        defaults = [[NSUserDefaults alloc] initWithSuiteName:GXKGroup];
        if (!defaults) defaults = [NSUserDefaults standardUserDefaults];
    }
    return defaults;
}

static NSMutableArray<NSString *> *GXKPhraseList(void) {
    NSMutableArray *list = [NSMutableArray array];
    id raw = [GXKPhraseDefaults() objectForKey:GXKPhrasesKey];
    if (![raw isKindOfClass:[NSArray class]]) return list;
    for (id item in (NSArray *)raw) {
        if ([item isKindOfClass:[NSString class]] && ((NSString *)item).length > 0) {
            [list addObject:(NSString *)item];
        }
    }
    return list;
}

static void GXKPhraseSave(NSArray<NSString *> *list) {
    NSUserDefaults *defaults = GXKPhraseDefaults();
    if (!defaults) return;
    [defaults setObject:(list ?: @[]) forKey:GXKPhrasesKey];
    [defaults synchronize];
}

static BOOL GXKPhrasesPinned(void) {
    return [GXKPhraseDefaults() boolForKey:GXKPhrasesPinnedKey];
}

static void GXKPhrasesSetPinned(BOOL pinned) {
    NSUserDefaults *defaults = GXKPhraseDefaults();
    if (!defaults) return;
    [defaults setBool:pinned forKey:GXKPhrasesPinnedKey];
    // 钉子状态只有键盘进程自己读，不跨进程，不必强制同步落盘。
    // 常用语正文（GXKPhraseSave）必须保留 synchronize：主 App 编辑、键盘读取，跨进程要立刻可见。
}

// 部署目标 12.0：systemBlue / systemBackground 都是 iOS 13 才有的，统一在这里兜底。
static UIColor *GXKPhraseTintColor(void) {
    if (@available(iOS 13.0, *)) return [UIColor systemBlueColor];
    return [UIColor colorWithRed:0.0 green:0.478 blue:1.0 alpha:1.0];
}

// 常用语面板原先写死浅灰底 + darkTextColor，键盘换成深色皮肤后整块面板仍是白底黑字，
// 和键盘本体割裂。这里改成直接取「键盘本体实际颜色」：底色用键盘体里面积最大的那块
// 不透明背景，文字色用同键盘原生标签色，再按底色亮度兜一层对比度保护。
// 不读系统外观开关：Gboard 皮肤可以跟系统外观不一致，只有键盘自己的颜色说了算。
static CGFloat GXKPhraseColorBrightness(UIColor *color) {
    if (![color isKindOfClass:[UIColor class]]) return 0.5;
    CGFloat r = 0.5, g = 0.5, b = 0.5, a = 1.0;
    if (![color getRed:&r green:&g blue:&b alpha:&a]) {
        CGFloat white = 0.5;
        if (![color getWhite:&white alpha:&a]) return 0.5;
        r = g = b = white;
    }
    return 0.299 * r + 0.587 * g + 0.114 * b;
}

// 键盘皮肤：键盘体里面积最大的那块不透明底色。九键单块键帽约占 1/9，候选条也到不了 1/4，
// 25% 的面积门槛刚好挡住键帽与装饰块；整条链都取不到就返回 nil，由上层退回系统色。
static UIColor *GXKPhraseSkinColor(UIView *body) {
    if (!body) return nil;
    CGFloat bodyArea = CGRectGetWidth(body.bounds) * CGRectGetHeight(body.bounds);
    if (bodyArea <= 0.0) return nil;
    UIColor *best = nil;
    CGFloat bestArea = bodyArea * 0.25;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:body];
    NSUInteger visited = 0;
    while (stack.count && visited++ < 800) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        if (view.isHidden || view.alpha < 0.5) continue;
        UIColor *color = view.backgroundColor;
        CGColorRef cg = [color isKindOfClass:[UIColor class]] ? color.CGColor : NULL;
        if (cg && CGColorGetAlpha(cg) >= 0.9) {
            CGFloat area = CGRectGetWidth(view.bounds) * CGRectGetHeight(view.bounds);
            if (area > bestArea) {
                bestArea = area;
                best = color;
            }
        }
        [stack addObjectsFromArray:view.subviews];
    }
    return best;
}

// 深浅判定以键盘底色为准：0.5 就是中灰，深色皮肤一律落在下面、浅色皮肤在上面。
// 底色取不到才退回原生文字亮度（0.55 让中灰文字也判浅色，跟键盘浅色皮肤对齐）。
static BOOL GXKPhrasePrefersDark(UIView *body, UIColor *skin, UITraitCollection *traits) {
    if ([skin isKindOfClass:[UIColor class]]) return GXKPhraseColorBrightness(skin) < 0.5;
    if (body) {
        UIColor *native = GXKToolbarTextStyle(body, NULL);
        if ([native isKindOfClass:[UIColor class]]) return GXKPhraseColorBrightness(native) > 0.55;
    }
    // 主 App 进程里没有键盘体，退回系统标签色在当前外观下的解析值。
    if (@available(iOS 13.0, *)) {
        UIColor *probe = [UIColor labelColor];
        if (traits && [probe respondsToSelector:@selector(resolvedColorWithTraitCollection:)]) {
            probe = [probe resolvedColorWithTraitCollection:traits];
        }
        return GXKPhraseColorBrightness(probe) > 0.55;
    }
    return NO;
}

static UIColor *GXKPhraseBackgroundColor(UIColor *skin, BOOL dark) {
    if ([skin isKindOfClass:[UIColor class]]) return skin;
    if (dark) return [UIColor colorWithRed:0.12 green:0.12 blue:0.13 alpha:1.0];
    if (@available(iOS 13.0, *)) return [UIColor systemBackgroundColor];
    return [UIColor whiteColor];
}

// 文字色优先用键盘原生标签色，但必须和面板底色反着来：白字落浅底会直接看不见。
static UIColor *GXKPhrasePrimaryTextColor(UIColor *native, BOOL dark) {
    if ([native isKindOfClass:[UIColor class]] &&
        (GXKPhraseColorBrightness(native) > 0.5) == dark) {
        return native;
    }
    if (dark) return [UIColor colorWithRed:0.94 green:0.94 blue:0.96 alpha:1.0];
    return [UIColor darkTextColor];
}

// 次级文字与分割线都由主文字色降透明度得到，和键盘同色系，与仓库其它跟随皮肤的地方一致。
static UIColor *GXKPhraseSecondaryTextColor(UIColor *native, BOOL dark) {
    return [GXKPhrasePrimaryTextColor(native, dark) colorWithAlphaComponent:0.62];
}

static UIColor *GXKPhraseSeparatorColor(UIColor *native, BOOL dark) {
    return [GXKPhrasePrimaryTextColor(native, dark) colorWithAlphaComponent:0.14];
}

// 分页条上的图标：直接画一个「语」字，避免依赖资源包里的图片名。
static UIImage *GXKPhrasesIcon(void) {
    static UIImage *image = nil;
    static BOOL tried = NO;
    if (tried) return image;
    tried = YES;
    @try {
        UIGraphicsImageRenderer *renderer =
            [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(24.0, 24.0)];
        image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
            [[UIColor clearColor] setFill];
            UIRectFill(CGRectMake(0.0, 0.0, 24.0, 24.0));
            NSDictionary *attrs = @{NSFontAttributeName: [UIFont systemFontOfSize:15.0 weight:UIFontWeightMedium],
                                    NSForegroundColorAttributeName: [UIColor darkGrayColor]};
            CGSize size = [@"语" sizeWithAttributes:attrs];
            [@"语" drawAtPoint:CGPointMake((24.0 - size.width) / 2.0, (24.0 - size.height) / 2.0)
                withAttributes:attrs];
        }];
    } @catch (__unused NSException *e) {
        image = nil;
    }
    return image;
}

static id GXKKeyboardProxy(void) {
    UIViewController *vc = gCurrentVC;
    if (!vc) return nil;
    if (![vc respondsToSelector:@selector(textDocumentProxy)]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(vc, @selector(textDocumentProxy));
}

// 键盘扩展进程里绝不允许出现任何需要系统键盘的输入控件（UIAlertController 带输入框、
// 内联 UITextField）。输入框要键盘，键盘就是这个扩展自己，系统会递归激活同一扩展并杀进程。
// 真机实测：G 图标 → 常用语 → 编辑 → 新增，必闪退；删除与上屏不受影响。
static BOOL GXKIsKeyboardExtension(void) {
    static BOOL keyboard = NO;
    static BOOL tried = NO;
    if (!tried) {
        tried = YES;
        keyboard = [[[NSBundle mainBundle] bundlePath] hasSuffix:@".appex"];
    }
    return keyboard;
}

static void GXKInsertPhraseText(NSString *text) {
    if (text.length == 0) return;
    id proxy = GXKKeyboardProxy();
    if (!proxy || ![proxy respondsToSelector:@selector(insertText:)]) {
        GXK_LOG(@"[!] 常用语上屏失败：输入代理不可用");
        return;
    }
    ((void (*)(id, SEL, id))objc_msgSend)(proxy, @selector(insertText:), text);
}

// 编辑入口：键盘面板右上角「编辑」与主 App 设置主菜单里的「常用语」共用这一个函数。
static void GXKPresentPhrasesEditor(UIViewController *from);

@interface GXKPhrasesPanel : UIView <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) NSMutableArray<NSString *> *items;
@property (nonatomic, strong) UIButton *pinButton;
// 当前配色是否深色：面板叠在键盘体上，深浅只能从键盘本体的原生文字色反推。
@property (nonatomic, assign) BOOL darkAppearance;
@property (nonatomic, assign) BOOL appearanceApplied;
// 当前套用的键盘皮肤色与原生文字色：单元格与钉子按钮都从这里取，保证同一帧一致。
@property (nonatomic, strong) UIColor *skinColor;
@property (nonatomic, strong) UIColor *nativeTextColor;
// 上一次套用的两个亮度值，用来判断「颜色真变了」而不是「回调又来了」。
@property (nonatomic, assign) CGFloat skinBrightness;
@property (nonatomic, assign) CGFloat textBrightness;
- (void)reloadItems;
- (void)dismissPanel;
- (void)onEdit:(UIButton *)sender;
- (void)onPhrasesChanged:(NSNotification *)note;
- (UIViewController *)gxkHostController;
@end

@implementation GXKPhrasesPanel

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    // 底色在 gxkApplyAppearance 里定：这一刻还没有父视图，拿不到键盘本体的颜色。
    self.backgroundColor = GXKPhraseBackgroundColor(nil, NO);
    self.skinBrightness = -1.0;
    self.textBrightness = -1.0;
    self.tag = GXK_PHRASES_PANEL_TAG;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectZero];
    title.tag = GXK_PHRASES_TITLE_TAG;
    title.text = @"常用语";
    title.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
    title.textColor = GXKPhrasePrimaryTextColor(nil, NO);
    [self addSubview:title];

    UIButton *pin = [UIButton buttonWithType:UIButtonTypeSystem];
    pin.tag = GXK_PHRASES_PIN_TAG;
    pin.titleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightMedium];
    pin.accessibilityLabel = @"固定常用语面板";
    [pin addTarget:self action:@selector(onPin:) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:pin];
    _pinButton = pin;

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.tag = GXK_PHRASES_CLOSE_TAG;
    [close setTitle:@"×" forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont systemFontOfSize:20.0 weight:UIFontWeightRegular];
    close.accessibilityLabel = @"关闭常用语";
    [close addTarget:self action:@selector(onClose:) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:close];

    // 维护入口：不依赖主 App 设置页，键盘里就能增删改。
    UIButton *edit = [UIButton buttonWithType:UIButtonTypeSystem];
    edit.tag = GXK_PHRASES_EDIT_TAG;
    [edit setTitle:@"编辑" forState:UIControlStateNormal];
    edit.titleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightMedium];
    edit.accessibilityLabel = @"管理常用语";
    [edit addTarget:self action:@selector(onEdit:) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:edit];

    UITableView *table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    table.tag = GXK_PHRASES_TABLE_TAG;
    table.dataSource = self;
    table.delegate = self;
    table.rowHeight = 40.0;
    table.backgroundColor = [UIColor clearColor];
    table.separatorInset = UIEdgeInsetsZero;
    table.separatorColor = GXKPhraseSeparatorColor(nil, NO);
    [self addSubview:table];
    _table = table;

    UILabel *hint = [[UILabel alloc] initWithFrame:CGRectZero];
    hint.tag = GXK_PHRASES_HINT_TAG;
    hint.text = @"还没有常用语。先复制文字再点右上角「编辑」→「+」，或打开 Gboard App → 设置 → 常用语。";
    hint.font = [UIFont systemFontOfSize:13.0];
    hint.textColor = GXKPhraseSecondaryTextColor(nil, NO);
    hint.numberOfLines = 0;
    hint.textAlignment = NSTextAlignmentCenter;
    [self addSubview:hint];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onPhrasesChanged:)
                                                 name:GXKPhrasesChangedNotification
                                               object:nil];
    [self reloadItems];
    [self gxkApplyAppearance];
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

// 键盘体：工具条扫到的九键体就是键盘实际皮肤所在。拿不到就返回 nil，让调用方退回系统外观。
- (UIView *)gxkStyleSource {
    UIView *body = gToolbarNineBody;
    if (body && body.window) return body;
    return nil;
}

// 面板与单元格的深浅配色统一从这里刷；深浅没变就不重绘，避免 trait 回调里反复 reload。
- (void)gxkApplyAppearance {
    UIView *body = [self gxkStyleSource];
    UIColor *skin = GXKPhraseSkinColor(body);
    UIColor *native = body ? GXKToolbarTextStyle(body, NULL) : nil;
    if (![native isKindOfClass:[UIColor class]]) native = nil;
    BOOL dark = GXKPhrasePrefersDark(body, skin, self.traitCollection);
    CGFloat skinBrightness = GXKPhraseColorBrightness(skin);
    CGFloat textBrightness = GXKPhraseColorBrightness(native);
    // 深浅没变、两个色值也没变才算「没变化」：只比 dark 会让两套深色皮肤之间不刷新。
    if (self.appearanceApplied && dark == self.darkAppearance &&
        fabs(skinBrightness - self.skinBrightness) < 0.02 &&
        fabs(textBrightness - self.textBrightness) < 0.02) {
        return;
    }
    self.darkAppearance = dark;
    self.appearanceApplied = YES;
    self.skinBrightness = skinBrightness;
    self.textBrightness = textBrightness;
    self.skinColor = skin;
    self.nativeTextColor = native;

    self.backgroundColor = GXKPhraseBackgroundColor(skin, dark);
    UIView *title = [self viewWithTag:GXK_PHRASES_TITLE_TAG];
    if ([title isKindOfClass:[UILabel class]]) ((UILabel *)title).textColor = GXKPhrasePrimaryTextColor(native, dark);
    UIView *hint = [self viewWithTag:GXK_PHRASES_HINT_TAG];
    if ([hint isKindOfClass:[UILabel class]]) ((UILabel *)hint).textColor = GXKPhraseSecondaryTextColor(native, dark);
    self.table.separatorColor = GXKPhraseSeparatorColor(native, dark);
    [self updatePinTitle];
    [self.table reloadData]; // 单元格文字色跟着换。
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self gxkApplyAppearance];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    [self gxkApplyAppearance];
}

- (void)onPhrasesChanged:(NSNotification *)note {
    [self reloadItems];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = CGRectGetWidth(self.bounds);
    CGFloat height = CGRectGetHeight(self.bounds);
    UIView *title = [self viewWithTag:GXK_PHRASES_TITLE_TAG];
    title.frame = CGRectMake(16.0, 8.0, 120.0, 24.0);
    UIButton *close = (UIButton *)[self viewWithTag:GXK_PHRASES_CLOSE_TAG];
    close.frame = CGRectMake(MAX(width - 44.0, 200.0), 4.0, 36.0, 32.0);
    UIButton *edit = (UIButton *)[self viewWithTag:GXK_PHRASES_EDIT_TAG];
    edit.frame = CGRectMake(MAX(width - 92.0, 150.0), 6.0, 44.0, 28.0);
    self.pinButton.frame = CGRectMake(MAX(width - 168.0, 96.0), 6.0, 72.0, 28.0);
    self.table.frame = CGRectMake(0.0, 38.0, width, MAX(height - 38.0, 0.0));
    UIView *hint = [self viewWithTag:GXK_PHRASES_HINT_TAG];
    hint.frame = CGRectMake(24.0, 44.0, MAX(width - 48.0, 0.0), 60.0);
    [self updatePinTitle];
}

- (void)updatePinTitle {
    BOOL pinned = GXKPhrasesPinned();
    [self.pinButton setTitle:(pinned ? @"已固定" : @"固定") forState:UIControlStateNormal];
    UIColor *idle = GXKPhraseSecondaryTextColor(self.nativeTextColor, self.darkAppearance);
    [self.pinButton setTitleColor:(pinned ? GXKPhraseTintColor() : idle)
                         forState:UIControlStateNormal];
}

- (void)reloadItems {
    self.items = GXKPhraseList();
    [self.table reloadData];
    UIView *hint = [self viewWithTag:GXK_PHRASES_HINT_TAG];
    if (hint) hint.hidden = (self.items.count > 0);
    [self updatePinTitle];
}

- (void)onPin:(UIButton *)sender {
    GXKImpact(UIImpactFeedbackStyleLight);
    GXKPhrasesSetPinned(!GXKPhrasesPinned());
    [self updatePinTitle];
}

- (void)onClose:(UIButton *)sender {
    GXKImpact(UIImpactFeedbackStyleLight);
    [self dismissPanel];
}

- (void)onEdit:(UIButton *)sender {
    GXKImpact(UIImpactFeedbackStyleLight);
    UIViewController *host = [self gxkHostController];
    if (!host) {
        GXK_LOG(@"[!] 常用语编辑：找不到宿主控制器");
        return;
    }
    GXKPresentPhrasesEditor(host);
}

- (UIViewController *)gxkHostController {
    UIResponder *responder = self;
    while (responder) {
        if ([responder isKindOfClass:[UIViewController class]]) return (UIViewController *)responder;
        responder = responder.nextResponder;
    }
    return gCurrentVC;
}

- (void)dismissPanel {
    id host = gPhrasesMiniAppHost;
    [self removeFromSuperview];
    gPhrasesPanelView = nil;
    gPhrasesMiniAppHost = nil;
    if (host && [host respondsToSelector:@selector(deactivate)]) {
        @try {
            ((void (*)(id, SEL))objc_msgSend)(host, @selector(deactivate));
        } @catch (__unused NSException *e) {}
    }
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.items.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:GXK_PHRASES_CELL_ID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                     reuseIdentifier:GXK_PHRASES_CELL_ID];
    }
    NSString *text = (indexPath.row < (NSInteger)self.items.count) ? self.items[indexPath.row] : @"";
    cell.textLabel.text = text;
    cell.textLabel.font = [UIFont systemFontOfSize:15.0];
    cell.textLabel.numberOfLines = 2;
    // 单元格默认底色是系统白，深色面板上会亮成一条白块，必须跟着面板走。
    cell.backgroundColor = [UIColor clearColor];
    cell.textLabel.textColor = GXKPhrasePrimaryTextColor(self.nativeTextColor, self.darkAppearance);
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:NO];
    if (indexPath.row >= (NSInteger)self.items.count) return;
    GXKImpact(UIImpactFeedbackStyleLight);
    GXKInsertPhraseText(self.items[indexPath.row]);
    // 没固定就点一条关面板；固定了就一直留着连续输入。
    if (!GXKPhrasesPinned()) [self dismissPanel];
}

@end

static void GXKShowPhrasesPanel(id miniAppHost) {
    UIViewController *vc = gCurrentVC;
    if (!vc || !vc.isViewLoaded) {
        GXK_LOG(@"[!] 常用语分页：键盘宿主未就绪");
        return;
    }
    UIView *existing = [vc.view viewWithTag:GXK_PHRASES_PANEL_TAG];
    if (existing) [existing removeFromSuperview];
    GXKPhrasesPanel *panel = [[GXKPhrasesPanel alloc] initWithFrame:vc.view.bounds];
    [vc.view addSubview:panel];
    [vc.view bringSubviewToFront:panel];
    gPhrasesPanelView = panel;
    gPhrasesMiniAppHost = miniAppHost;
    GXK_LOG(@"[*] 常用语分页已展开，共 %lu 条", (unsigned long)panel.items.count);
}

static void GXKDetachPhrasesPanel(void) {
    UIView *panel = gPhrasesPanelView;
    if (panel) [panel removeFromSuperview];
    gPhrasesPanelView = nil;
    gPhrasesMiniAppHost = nil;
}

static NSString *GXKPickerItemIdentifier(id item) {
    if (!item) return nil;
    if ([item isKindOfClass:[NSString class]]) return (NSString *)item;
    if ([item respondsToSelector:@selector(identifier)]) {
        id value = ((id (*)(id, SEL))objc_msgSend)(item, @selector(identifier));
        if ([value isKindOfClass:[NSString class]]) return (NSString *)value;
    }
    return nil;
}

// 分页条只认 GKBExtensionSegmentedControlItem。GKBExtensionSegmentedControl 的
// buttonWithControlItem: 与 addButtonsAndAutolayoutForNewItems: 会逐项发
// badgeableViewType / controlItemType / accessibilityIdentifier / accessibilityLabel，
// GKBAppStripItem 这几条一条都不响应；真机表现就是打开分页条即
// "-[GKBAppStripItem badgeableViewType]: unrecognized selector" 崩掉整个键盘扩展。
// 九键的表情键被换成了重输/换行，历史上从没打开过这条链路，所以 26 键第一次点表情才暴露。
static id GXKPhrasesPickerItem(void) {
    static id item = nil;
    static BOOL tried = NO;
    if (tried) return item;
    tried = YES;
    Class itemClass = NSClassFromString(@"GKBExtensionSegmentedControlItem");
    if (!itemClass) return nil;
    @try {
        // 这个类只有无参 init，属性必须逐个 set；setIdentifier: 内部会同步
        // accessibilityIdentifier，分页条按钮的可访问性标识因此与原生项一致。
        id obj = [[itemClass alloc] init];
        if ([obj respondsToSelector:@selector(setIdentifier:)]) {
            ((void (*)(id, SEL, id))objc_msgSend)(obj, @selector(setIdentifier:), GXK_PHRASES_IDENTIFIER);
        }
        if ([obj respondsToSelector:@selector(setName:)]) {
            ((void (*)(id, SEL, id))objc_msgSend)(obj, @selector(setName:), @"常用语");
        }
        if ([obj respondsToSelector:@selector(setIcon:)]) {
            UIImage *icon = GXKPhrasesIcon();
            if (icon) ((void (*)(id, SEL, id))objc_msgSend)(obj, @selector(setIcon:), icon);
        }
        if ([obj respondsToSelector:@selector(setAccessibilityLabel:)]) {
            ((void (*)(id, SEL, id))objc_msgSend)(obj, @selector(setAccessibilityLabel:), @"常用语");
        }
        item = obj;
    } @catch (__unused NSException *e) {
        item = nil;
    }
    return item;
}

// 艺术字扩展的原实现内部会 objc_msgSendSuper2 回基类，而基类那份已经被换成这个函数。
// 不设护栏就是：原实现 → super → 这里 → 原实现 … 无限递归，最后踩到栈保护页 SIGSEGV
// （真机 2026-11-17 21:57 的崩溃栈就是 gxk_miniAppPickerDidSelect 与 Gboard +0x2e8be8 交替七层）。
static BOOL gxk_artSelectInFlight = NO;

static void gxk_miniAppPickerDidSelect(id self, SEL _cmd, id picker, id item, unsigned long long index) {
    NSString *ident = GXKPickerItemIdentifier(item);
    if (ident && [ident isEqualToString:GXK_PHRASES_IDENTIFIER]) {
        GXKShowPhrasesPanel(self);
        return;
    }
    // 回落到「本次被替换的那一个」原实现：基类与艺术字扩展各有一份。
    Class artClass = NSClassFromString(@"GKBArtExtension");
    if (gOrigArtMiniAppPickerDidSelect && artClass && [self isKindOfClass:artClass]) {
        if (gxk_artSelectInFlight) {
            // 第二次进来 = 艺术字原实现的 super 调用，这里必须交给基类的原实现，不能再回艺术字。
            if (gOrigMiniAppPickerDidSelect) gOrigMiniAppPickerDidSelect(self, _cmd, picker, item, index);
            return;
        }
        gxk_artSelectInFlight = YES;
        @try {
            gOrigArtMiniAppPickerDidSelect(self, _cmd, picker, item, index);
        } @finally {
            // 异常也要清标记，否则这条分页此后永远走不到艺术字原实现。
            gxk_artSelectInFlight = NO;
        }
        return;
    }
    if (gOrigMiniAppPickerDidSelect) gOrigMiniAppPickerDidSelect(self, _cmd, picker, item, index);
}

static void GXKInstallPhrasesHooks(void) {
    if (gxk_phrases_hooked) return;
    if (!NSClassFromString(@"GKBMiniAppExtensionBase")) return;
    GXKSwizzleOrSkip(@"GKBMiniAppExtensionBase", @"miniAppPicker:didSelectItem:atIndex:",
                     (IMP)gxk_miniAppPickerDidSelect, (void **)&gOrigMiniAppPickerDidSelect);
    // GKBArtExtension 自己实现了一份 delegate，不挂它的话「常用语」在艺术字分页条上会变成死项。
    GXKSwizzleOrSkip(@"GKBArtExtension", @"miniAppPicker:didSelectItem:atIndex:",
                     (IMP)gxk_miniAppPickerDidSelect, (void **)&gOrigArtMiniAppPickerDidSelect);
    gxk_phrases_hooked = YES;
    GXK_LOG(@"[*] 常用语分页已接入 G 图标");
}

#pragma mark - 主 App：常用语维护入口（设置主菜单里的一行）

// 主 App「设置」主页的内容由 GKBSettingsViewController 的 mainMenuPageDescriptor 描述，
// 真正上屏的是 GKBSettingsPageViewController。要加一行只能改这份 descriptor：
// 复制一行原生条目（沿用它的 type / settingID，渲染与原生完全一致），只换标题与 key。
static NSString *const GXKPhrasesRowKey = @"GXKPhrasesRow";

// 这些类在 dylib 里没有头文件，一律用 objc_msgSend 显式取，避免编译器按静态类型挑方法。
static NSArray *GXKSectionsOf(id object) {
    if (!object || ![object respondsToSelector:@selector(sections)]) return nil;
    id sections = ((id (*)(id, SEL))objc_msgSend)(object, @selector(sections));
    return [sections isKindOfClass:[NSArray class]] ? (NSArray *)sections : nil;
}

static NSArray *GXKRowsOf(id object) {
    if (!object || ![object respondsToSelector:@selector(rows)]) return nil;
    id rows = ((id (*)(id, SEL))objc_msgSend)(object, @selector(rows));
    return [rows isKindOfClass:[NSArray class]] ? (NSArray *)rows : nil;
}

static NSString *GXKKeyOf(id object) {
    if (!object || ![object respondsToSelector:@selector(key)]) return nil;
    id key = ((id (*)(id, SEL))objc_msgSend)(object, @selector(key));
    return [key isKindOfClass:[NSString class]] ? (NSString *)key : nil;
}

// 从现有条目里挑一个样板：优先「搜索设置」，退而键盘/主题/语言，都没有就取第一条带 key 的行。
static id GXKPhrasesRowTemplate(NSArray *sections, id *outSection) {
    NSArray *preferred = @[@"SearchSettings", @"KeyboardSettings", @"Themes", @"Languages"];
    id fallback = nil;
    id fallbackSection = nil;
    for (id section in sections) {
        NSArray *rows = GXKRowsOf(section);
        if (!rows) continue;
        for (id row in rows) {
            NSString *key = GXKKeyOf(row);
            if (!key) continue;
            if (!fallback) {
                fallback = row;
                fallbackSection = section;
            }
            for (NSString *needle in preferred) {
                if ([key rangeOfString:needle].location != NSNotFound) {
                    if (outSection) *outSection = section;
                    return row;
                }
            }
        }
    }
    if (outSection) *outSection = fallbackSection;
    return fallback;
}

static BOOL GXKSettingsRowIsOurs(id row) {
    NSString *key = GXKKeyOf(row);
    return key ? [key isEqualToString:GXKPhrasesRowKey] : NO;
}

static id GXKPhrasesSettingsRow(id template) {
    Class itemClass = NSClassFromString(@"GKBSettingsItem");
    if (!itemClass || !template) return nil;
    long long type = 0;
    long long settingID = 0;
    if ([template respondsToSelector:@selector(type)]) {
        type = ((long long (*)(id, SEL))objc_msgSend)(template, @selector(type));
    }
    if ([template respondsToSelector:@selector(settingID)]) {
        settingID = ((long long (*)(id, SEL))objc_msgSend)(template, @selector(settingID));
    }
    id row = ((id (*)(id, SEL, long long, long long, id, id, id))objc_msgSend)(
        [itemClass alloc], @selector(initWithType:settingID:title:accessibilityIdentifier:key:),
        type, settingID, @"常用语", @"gxk_phrases_row", GXKPhrasesRowKey);
    return row;
}

// 幂等：descriptor 每次打开设置都会重新生成，所以每次调用都检查一遍。
static void GXKInjectPhrasesRow(id descriptor) {
    NSArray *sections = GXKSectionsOf(descriptor);
    if (sections.count == 0) return;
    id targetSection = nil;
    id template = GXKPhrasesRowTemplate(sections, &targetSection);
    if (!template || !targetSection) {
        GXK_LOG(@"[!] 设置主菜单里找不到可复制的行，跳过常用语入口");
        return;
    }
    NSArray *rows = GXKRowsOf(targetSection);
    if (!rows) return;
    NSMutableArray *newRows = [NSMutableArray arrayWithCapacity:rows.count + 1];
    NSUInteger insertAt = rows.count;
    for (NSUInteger i = 0; i < rows.count; i++) {
        id row = rows[i];
        if (GXKSettingsRowIsOurs(row)) return; // 已经加过了。
        [newRows addObject:row];
        if (row == template) insertAt = i + 1;
    }
    id ours = GXKPhrasesSettingsRow(template);
    if (!ours) return;
    if (insertAt > newRows.count) insertAt = newRows.count;
    [newRows insertObject:ours atIndex:insertAt];
    if (![targetSection respondsToSelector:@selector(setRows:)]) return;
    ((void (*)(id, SEL, id))objc_msgSend)(targetSection, @selector(setRows:), newRows);
    GXK_LOG(@"[*] 设置主菜单已插入「常用语」一行");
}

static id gxk_settingsMainMenu(id self, SEL _cmd) {
    id descriptor = gOrigSettingsMainMenu ? gOrigSettingsMainMenu(self, _cmd) : nil;
    GXKInjectPhrasesRow(descriptor);
    return descriptor;
}

// 设置页的点击先经过 page VC：在这里认出自己那一行，直接弹编辑器，绝不进原生分支。
// 兜底：pageDescriptor 若是 mainMenuPageDescriptor 的副本，按行对象认不出自己那一行，
// 但屏幕上显示的文字一定是「常用语」。这里直接读被点 cell 的文本。
static BOOL GXKViewShowsPhrasesTitle(UIView *view, NSUInteger depth) {
    if (!view || depth > 8) return NO;
    if ([view isKindOfClass:[UILabel class]]) {
        NSString *text = ((UILabel *)view).text;
        if ([text isEqualToString:@"常用语"]) return YES;
    }
    for (UIView *child in view.subviews) {
        if (GXKViewShowsPhrasesTitle(child, depth + 1)) return YES;
    }
    return NO;
}

static BOOL GXKCellShowsPhrasesTitle(id collectionView, id indexPath) {
    if (![collectionView respondsToSelector:@selector(cellForItemAtIndexPath:)]) return NO;
    id cell = ((id (*)(id, SEL, id))objc_msgSend)(collectionView, @selector(cellForItemAtIndexPath:), indexPath);
    if (![cell isKindOfClass:[UIView class]]) return NO;
    return GXKViewShowsPhrasesTitle((UIView *)cell, 0);
}

// 先认行对象（key 对上），认不出再认屏幕上那格显示的文字——两条路都不依赖 descriptor 的
// 内部结构，因为上屏的 descriptor 可能是 mainMenuPageDescriptor 的副本。
static BOOL GXKIsPhrasesRowSelected(id self, id collectionView, id indexPath) {
    if (![indexPath isKindOfClass:[NSIndexPath class]]) return NO;
    if ([self respondsToSelector:@selector(pageDescriptor)]) {
        id descriptor = ((id (*)(id, SEL))objc_msgSend)(self, @selector(pageDescriptor));
        NSArray *sections = GXKSectionsOf(descriptor);
        NSInteger section = ((NSInteger (*)(id, SEL))objc_msgSend)(indexPath, @selector(section));
        NSInteger row = ((NSInteger (*)(id, SEL))objc_msgSend)(indexPath, @selector(row));
        if (sections && section >= 0 && (NSUInteger)section < sections.count) {
            NSArray *rows = GXKRowsOf(sections[(NSUInteger)section]);
            if (rows && row >= 0 && (NSUInteger)row < rows.count) {
                if (GXKSettingsRowIsOurs(rows[(NSUInteger)row])) return YES;
            }
        }
    }
    return GXKCellShowsPhrasesTitle(collectionView, indexPath);
}

static void gxk_settingsPageDidSelect(id self, SEL _cmd, id collectionView, id indexPath) {
    if (GXKIsPhrasesRowSelected(self, collectionView, indexPath)) {
        if ([collectionView respondsToSelector:@selector(deselectItemAtIndexPath:animated:)]) {
            ((void (*)(id, SEL, id, BOOL))objc_msgSend)(
                collectionView, @selector(deselectItemAtIndexPath:animated:), indexPath, NO);
        }
        if ([self isKindOfClass:[UIViewController class]]) {
            GXKPresentPhrasesEditor((UIViewController *)self);
        }
        return;
    }
    if (gOrigSettingsPageDidSelect) gOrigSettingsPageDidSelect(self, _cmd, collectionView, indexPath);
}

static void GXKInstallMainAppHooks(void) {
    if (gxk_settings_hooked) return;
    if (!NSClassFromString(@"GKBSettingsViewController")) return;
    GXKSwizzleOrSkip(@"GKBSettingsViewController", @"mainMenuPageDescriptor",
                     (IMP)gxk_settingsMainMenu, (void **)&gOrigSettingsMainMenu);
    GXKSwizzleOrSkip(@"GKBSettingsPageViewController", @"collectionView:didSelectItemAtIndexPath:",
                     (IMP)gxk_settingsPageDidSelect, (void **)&gOrigSettingsPageDidSelect);
    gxk_settings_hooked = YES;
    GXK_LOG(@"[*] 主 App 设置入口已接入（常用语）");
}

@interface GXKPhrasesEditorController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) NSMutableArray<NSString *> *items;
// 以 modal 方式包在 UINavigationController 里时，自己给一个「完成」按钮关掉。
@property (nonatomic, assign) BOOL dismissable;
// 与键盘面板同一套深浅判断；主 App 里没有键盘体时退回系统外观。
@property (nonatomic, assign) BOOL darkAppearance;
@property (nonatomic, strong) UIColor *nativeTextColor;
@end

@implementation GXKPhrasesEditorController

- (instancetype)init {
    self = [super initWithNibName:nil bundle:nil];
    if (!self) return nil;
    self.title = @"常用语";
    _items = GXKPhraseList();
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = GXKPhraseBackgroundColor(nil, NO);
    UITableView *table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    table.dataSource = self;
    table.delegate = self;
    table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    table.backgroundColor = [UIColor clearColor];
    table.separatorColor = GXKPhraseSeparatorColor(nil, NO);
    [self.view addSubview:table];
    self.table = table;
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                      target:self
                                                      action:@selector(onAdd:)];
    if (self.dismissable) {
        self.navigationItem.leftBarButtonItem =
            [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                          target:self
                                                          action:@selector(onDone:)];
    }
    [self gxkApplyAppearance];
}

- (void)gxkApplyAppearance {
    UIView *body = (gToolbarNineBody && gToolbarNineBody.window) ? gToolbarNineBody : nil;
    UIColor *skin = GXKPhraseSkinColor(body);
    UIColor *native = body ? GXKToolbarTextStyle(body, NULL) : nil;
    if (![native isKindOfClass:[UIColor class]]) native = nil;
    BOOL dark = GXKPhrasePrefersDark(body, skin, self.traitCollection);
    self.darkAppearance = dark;
    self.nativeTextColor = native;
    self.view.backgroundColor = GXKPhraseBackgroundColor(skin, dark);
    self.table.separatorColor = GXKPhraseSeparatorColor(native, dark);
    [self.table reloadData]; // 单元格文字色跟着换。
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    [self gxkApplyAppearance];
}

- (void)onDone:(id)sender {
    [self dismissViewControllerAnimated:YES completion:nil];
}

// 键盘进程里没有任何"能打字"的入口：UIAlertController 带输入框、内联 UITextField 都会去要
// 系统键盘，而系统键盘就是这个扩展自己，真机上必被系统杀掉（实测：点「新增」直接闪退）。
// 所以键盘内新增/修改一律走剪贴板：先把文字复制好，再回来点按钮。这样全程不需要键盘。
// 键盘进程里连"无输入框的 alert"都不能弹：扩展内 present 任何控制器都会再拉一次呈现上下文，
// 真机上照样崩（实测：剪贴板为空时点「+」直接闪退）。所以提示一律改成导航标题闪一下。
- (void)gxkFlashHint:(NSString *)text {
    if (!text.length) return;
    self.title = text;
    __weak GXKPhrasesEditorController *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        weakSelf.title = @"常用语";
    });
}

- (NSString *)gxkPasteboardCandidate {
    UIPasteboard *board = [UIPasteboard generalPasteboard];
    NSString *text = board.string;
    if (![text isKindOfClass:[NSString class]]) return nil;
    text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return text.length ? text : nil;
}

- (void)gxkAddFromPasteboard {
    NSString *text = [self gxkPasteboardCandidate];
    if (!text) {
        [self gxkFlashHint:@"先复制文字"];
        GXK_LOG(@"[*] 剪贴板为空，已提示先复制文字");
        return;
    }
    if (![self.items containsObject:text]) {
        [self.items addObject:text];
        GXKPhraseSave(self.items);
        [self.table reloadData];
        [[NSNotificationCenter defaultCenter] postNotificationName:GXKPhrasesChangedNotification object:nil];
    }
    GXK_LOG(@"[*] 常用语已从剪贴板加入，共 %lu 条", (unsigned long)self.items.count);
}

- (void)onAdd:(id)sender {
    if (GXKIsKeyboardExtension()) {
        [self gxkAddFromPasteboard];
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"新增常用语"
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"要上屏的文字";
    }];
    __weak GXKPhrasesEditorController *weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        NSString *text = alert.textFields.firstObject.text;
        if (text.length == 0) return;
        [weakSelf.items addObject:text];
        GXKPhraseSave(weakSelf.items);
        [weakSelf.table reloadData];
        [[NSNotificationCenter defaultCenter] postNotificationName:GXKPhrasesChangedNotification object:nil];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.items.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellID = @"GXKPhraseEditCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellID];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cellID];
    cell.textLabel.text = (indexPath.row < (NSInteger)self.items.count) ? self.items[indexPath.row] : @"";
    cell.textLabel.numberOfLines = 2;
    cell.backgroundColor = [UIColor clearColor];
    cell.textLabel.textColor = GXKPhrasePrimaryTextColor(self.nativeTextColor, self.darkAppearance);
    return cell;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
                                            forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete) return;
    if (indexPath.row >= (NSInteger)self.items.count) return;
    [self.items removeObjectAtIndex:indexPath.row];
    GXKPhraseSave(self.items);
    [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
    [[NSNotificationCenter defaultCenter] postNotificationName:GXKPhrasesChangedNotification object:nil];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:NO];
    if (indexPath.row >= (NSInteger)self.items.count) return;
    NSString *current = self.items[indexPath.row];
    if (GXKIsKeyboardExtension()) {
        // 键盘进程：用剪贴板内容替换这条，全程不弹输入框。
        NSString *text = [self gxkPasteboardCandidate];
        if (!text) {
            [self gxkFlashHint:@"先复制新文字"];
            GXK_LOG(@"[*] 剪贴板为空，已提示先复制新文字");
            return;
        }
        [self.items replaceObjectAtIndex:indexPath.row withObject:text];
        GXKPhraseSave(self.items);
        [self.table reloadData];
        [[NSNotificationCenter defaultCenter] postNotificationName:GXKPhrasesChangedNotification object:nil];
        GXK_LOG(@"[*] 常用语已用剪贴板内容替换第 %ld 条", (long)indexPath.row);
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"编辑常用语"
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = current;
    }];
    __weak GXKPhrasesEditorController *weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        NSString *text = alert.textFields.firstObject.text;
        if (text.length == 0) return;
        [weakSelf.items replaceObjectAtIndex:indexPath.row withObject:text];
        GXKPhraseSave(weakSelf.items);
        [weakSelf.table reloadData];
        [[NSNotificationCenter defaultCenter] postNotificationName:GXKPhrasesChangedNotification object:nil];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

// 统一入口：一律全屏 modal。GOO 自绘导航容器不保证能正常展示 push 进来的控制器，
// 之前挂在「搜索设置」导航栏的那版点开就是白屏，所以这里不再走 push。
static void GXKPresentPhrasesEditor(UIViewController *from) {
    if (!from) return;
    UIViewController *host = from;
    while (host.presentedViewController && host.presentedViewController != host) {
        host = host.presentedViewController;
    }
    GXKPhrasesEditorController *editor = [[GXKPhrasesEditorController alloc] init];
    editor.dismissable = YES;
    UINavigationController *wrapper = [[UINavigationController alloc] initWithRootViewController:editor];
    wrapper.modalPresentationStyle = UIModalPresentationFullScreen;
    [host presentViewController:wrapper animated:YES completion:nil];
    GXK_LOG(@"[*] 常用语编辑器已弹出");
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

// 通用空实现：埋点方法参数从 0 个到 16 个不等，多余实参在 ARM64 上不读取即可。
static void gxk_noop_any(id self, SEL _cmd, ...) {}

// GKBClearcutClient：78 个 log* 埋点入口全部置空，事件不再构造。
// 运行时枚举方法表，只处理「名字以 log 开头且返回 void」的方法；
// 有返回值的读方法(isEnabled/isRegexRule:/featureFlagEventsForDailyLog 等)一律不动。
static void GXKDisableClearcutClientEvents(void) {
    Class cls = NSClassFromString(@"GKBClearcutClient");
    if (!cls) return;
    unsigned int total = 0;
    Method *methods = class_copyMethodList(cls, &total);
    if (!methods) return;
    unsigned int blockedCount = 0;
    for (unsigned int i = 0; i < total; i++) {
        const char *name = sel_getName(method_getName(methods[i]));
        if (!name || strncmp(name, "log", 3) != 0) continue;
        const char *types = method_getTypeEncoding(methods[i]);
        if (!types || types[0] != 'v') continue; // 有返回值的读方法绝不动。
        method_setImplementation(methods[i], (IMP)gxk_noop_any);
        blockedCount++;
    }
    free(methods);
    GXK_LOG(@"[*] GKBClearcutClient 埋点已置空: %u/%u", blockedCount, total);
}

// 幂等入口：framework在构造函数阶段可能尚未加载，首次viewWillAppear再补一次。
static void GXKApplyTelemetryBlockIfNeeded(void) {
    static BOOL blocked = NO;
    if (blocked) return;
    if (!NSClassFromString(@"CCTClearcutLogger") && !NSClassFromString(@"BreakpadController")) return;
    GXKDisableTelemetryUpload();
    GXKDisableClearcutClientEvents();
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

    // 主 App 进程里根本没有键盘控制器，viewWillAppear 那套接线永远不触发，
    // 所以设置主菜单的「常用语」入口必须在这里挂一次；键盘进程里这些类不存在，自然跳过。
    GXKInstallMainAppHooks();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        GXKInstallMainAppHooks(); // 类加载晚于构造阶段时补一次。
    });
}
