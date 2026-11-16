// gkx.m — Gboard iOS 键盘定制 dylib (极简重制版)
//
// 核心范围：
//   1. 外部万象词库 (user_dictionary.db) 自动部署到 App Group 共享容器
//   2. 九键界面回车键上方表情键替换为「重输」/「换行」动态切换按键
//   3. 九键 G 图标 band 内嵌工具栏：全选/复制/粘贴/剪切/收起（原地复用，不加高度）
// 其余一切界面与输入逻辑均完全保持 Gboard 官方原生！

#import <UIKit/UIKit.h>
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
- (void)deleteBeforeCursor:(NSUInteger)count;
- (BOOL)refuseWhileComposing:(UIButton *)sender;
- (id<UITextDocumentProxy>)proxy;
@end

static __weak UIStackView *gToolbarStack;
static __weak UIView *gToolbarRow;
static __weak UIView *gToolbarLogoView;
static __weak UIView *gToolbarNineBody;
static CGRect gToolbarBand;
static BOOL gToolbarLogoWasHidden;
static CGFloat gToolbarLogoWasAlpha = 1.0;
static BOOL gUpdatingToolbar;
static GXKToolbarTarget *gToolbarTarget;

// band 内被工具条盖住的原生图标（九键顶部右侧语音按钮等）：挂载时 alpha=0，撤走时原样归还。
static NSMutableArray<UIView *> *gToolbarHiddenViews;
static NSMutableArray<NSNumber *> *gToolbarHiddenAlphas;
// 「全选」记下的文本与时间：紧接着的「剪切」直接作用于同一段内容，不再要求系统选区。
static NSString *gToolbarSelectAllText;
static NSTimeInterval gToolbarSelectAllAt;
// 单次剪切最多删这么多字符：documentContext 本身会被系统截断，这里再兜一层上限。
#define GXK_CUT_MAX_CHARS 4000
// 全选之后多少秒内点剪切仍视为「剪全部」。
#define GXK_SELECT_ALL_WINDOW 15.0

// 点击反馈只改标题 1.1 秒，不弹面板、不改几何：键盘扩展里最省事也最不容易卡。
static void GXKFlashTitle(UIButton *button, NSString *text) {
    if (!button || !text.length) return;
    NSString *original = [button titleForState:UIControlStateNormal];
    if (!original.length) return;
    [button setTitle:text forState:UIControlStateNormal];
    __weak UIButton *weakButton = button;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIButton *live = weakButton;
        if (live) [live setTitle:original forState:UIControlStateNormal];
    });
}

// 只借 G 图标那一段空白：左右边界各自停在最近一个可见兄弟视图之前。
// 宁可窄到不显示，也绝不盖住候选栏或右侧功能图标。
static BOOL GXKToolbarBand(UIView *row, UIView *logo, UIView *root, CGRect *outBand) {
    if (outBand) *outBand = CGRectZero;
    if (!row || !logo || logo.superview != row) return NO;
    CGFloat width = row.bounds.size.width;
    CGFloat height = row.bounds.size.height;
    CGRect logoRect = logo.frame;
    CGFloat left = 0.0;
    CGFloat right = width;
    for (UIView *sibling in row.subviews) {
        if (sibling == logo || sibling == gToolbarStack) continue; // 自己的条不算邻居。
        if (sibling.isHidden || sibling.alpha < 0.05) continue;
        if (!GXKKeyIsVisible(sibling, root)) continue;
        CGRect r = sibling.frame;
        if (CGRectGetMaxX(r) <= CGRectGetMinX(logoRect) + 0.5) {
            if (CGRectGetMaxX(r) > left) left = CGRectGetMaxX(r);
        } else if (CGRectGetMinX(r) >= CGRectGetMaxX(logoRect) - 0.5) {
            if (CGRectGetMinX(r) < right) right = CGRectGetMinX(r);
        }
    }
    // 五个中文按钮最少要 200pt；不够就整条不显示，保持原生。
    if (right - left < 200.0) return NO;
    if (outBand) *outBand = CGRectMake(left, 0.0, right - left, height);
    return YES;
}

// 一次遍历同时判定：可见九键体、是否还有独立可见的 26 键体、G 图标行。
// 三样缺一就返回 NO，调用方保持原生——宁可不显示工具条，也不猜布局。
static BOOL GXKToolbarScan(UIView *root, UIView **outRow, UIView **outLogo, UIView **outBody, CGRect *outBand) {
    if (outRow) *outRow = nil;
    if (outLogo) *outLogo = nil;
    if (outBody) *outBody = nil;
    if (outBand) *outBand = CGRectZero;
    Class nineClass = NSClassFromString(@"GKB9KeysSoftKeyboardView");
    Class qwertyClass = NSClassFromString(@"GKBZhQwertySoftKeyboardView");
    Class logoClass = NSClassFromString(@"GKBHeaderLogoView");
    if (!root || !root.window || !nineClass || !qwertyClass || !logoClass) return NO;

    UIView *body = nil;
    UIView *logo = nil;
    BOOL qwertyVisible = NO;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    NSUInteger visited = 0;
    while (stack.count && visited++ < 1500) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        // 已绑定的 G 图标在我们挂载期间 alpha 为 0，必须放行，否则每拍都判"找不到 G 行"来回闪。
        BOOL ownLogo = (view == gToolbarLogoView);
        if (!ownLogo && (view.isHidden || view.alpha < 0.05)) continue;
        if (view.window != root.window) continue;
        if ([view isKindOfClass:nineClass]) {
            if (!body && GXKKeyIsVisible(view, root)) body = view;
        } else if ([view isKindOfClass:qwertyClass] && GXKKeyIsVisible(view, root)) {
            qwertyVisible = YES; // 九键继承 26 键类，所以九键必须走上面那条分支。
        }
        if (!logo && [view isKindOfClass:logoClass] && (ownLogo || GXKKeyIsVisible(view, root))) logo = view;
        [stack addObjectsFromArray:view.subviews];
    }
    if (!body || qwertyVisible || !logo) return NO;

    UIView *row = logo.superview;
    if (!row || row == root || !GXKKeyIsVisible(row, root)) return NO;
    CGSize size = row.bounds.size;
    if (size.width < 100 || size.height < 18 || size.height > 110) return NO;

    CGRect band = CGRectZero;
    if (!GXKToolbarBand(row, logo, root, &band)) return NO;

    if (outRow) *outRow = row;
    if (outLogo) *outLogo = logo;
    if (outBody) *outBody = body;
    if (outBand) *outBand = band;
    return YES;
}

// 文字色取同键盘原生键帽的 UILabel 颜色：Gboard 主题可能与系统外观不一致，不能靠 labelColor 猜。
static UIColor *GXKToolbarTint(UIView *body) {
    if (body) {
        NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:body];
        NSUInteger visited = 0;
        while (stack.count && visited++ < 800) {
            UIView *view = stack.lastObject;
            [stack removeLastObject];
            if (view.isHidden || view.alpha < 0.05) continue;
            if ([view isKindOfClass:[UILabel class]]) {
                UIColor *color = ((UILabel *)view).textColor;
                if ([color isKindOfClass:[UIColor class]]) return color;
            }
            [stack addObjectsFromArray:view.subviews];
        }
    }
    if (@available(iOS 13.0, *)) return [UIColor labelColor];
    return [UIColor darkGrayColor]; // 部署目标 12.0：labelColor 不可用。
}

static void GXKRestoreToolbarDecorations(void) {
    for (NSUInteger i = 0; i < gToolbarHiddenViews.count; i++) {
        UIView *view = gToolbarHiddenViews[i];
        if (i < gToolbarHiddenAlphas.count) view.alpha = gToolbarHiddenAlphas[i].doubleValue;
    }
    [gToolbarHiddenViews removeAllObjects];
    [gToolbarHiddenAlphas removeAllObjects];
}

static BOOL GXKViewHasImage(UIView *view) {
    if ([view isKindOfClass:[UIImageView class]]) return YES;
    for (UIView *sub in view.subviews) {
        if (GXKViewHasImage(sub)) return YES;
    }
    return NO;
}

// 工具条只借 band，但 band 里仍可能浮着原生装饰图标（九键顶部右侧那个语音按钮就是：
// 它的祖先空尺寸、不裁剪，几何上逃过 band 计算，视觉上却压在按钮文字上）。
// 这里只挑「图标尺寸 + 含图片 + 与 band 相交」的视图隐藏，命中即整块子树让位；
// 文本、候选词、键帽都不满足这些条件，不会被误伤。撤走工具条时原样归还。
static NSUInteger GXKHideToolbarDecorations(UIView *row, UIView *logo, UIView *root, CGRect band) {
    if (!row || !logo || CGRectIsEmpty(band)) return 0;
    if (!gToolbarHiddenViews) gToolbarHiddenViews = [NSMutableArray array];
    if (!gToolbarHiddenAlphas) gToolbarHiddenAlphas = [NSMutableArray array];
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:row];
    NSUInteger visited = 0;
    while (stack.count && visited++ < 800) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        if (view == row) {
            [stack addObjectsFromArray:view.subviews];
            continue;
        }
        if (view == logo || [view isDescendantOfView:logo] || [logo isDescendantOfView:view]) continue;
        if (view == gToolbarStack || [view isDescendantOfView:gToolbarStack]) continue;
        if (view.isHidden || view.alpha < 0.05) continue;
        CGRect rect = [view convertRect:view.bounds toView:row];
        CGSize size = rect.size;
        BOOL iconSized = size.width >= 8.0 && size.height >= 8.0 && size.width <= 64.0 && size.height <= 64.0;
        if (!iconSized || CGRectIsEmpty(CGRectIntersection(rect, band))) {
            [stack addObjectsFromArray:view.subviews];
            continue;
        }
        if (!GXKViewHasImage(view)) {
            [stack addObjectsFromArray:view.subviews];
            continue;
        }
        [gToolbarHiddenViews addObject:view];
        [gToolbarHiddenAlphas addObject:@(view.alpha)];
        view.alpha = 0.0; // 整块子树已让位，不再向下找。
    }
    if (gToolbarHiddenViews.count) {
        GXK_LOG(@"工具条: 让位原生图标 %lu 个", (unsigned long)gToolbarHiddenViews.count);
    }
    return gToolbarHiddenViews.count;
}

// 组字中工具条整条让位，这时必须把让位的原生图标还回去：否则拼音栏会缺一个按钮。
static void GXKSyncToolbarDecorations(BOOL composing) {
    if (composing) {
        GXKRestoreToolbarDecorations();
        return;
    }
    UIView *row = gToolbarRow;
    UIView *logo = gToolbarLogoView;
    UIViewController *vc = gCurrentVC;
    UIView *root = (vc && vc.isViewLoaded) ? vc.view : nil;
    if (!row || !logo || !root) return;
    if (gToolbarHiddenViews.count == 0) GXKHideToolbarDecorations(row, logo, root, gToolbarBand);
}

// 工具条底色取键盘自身的表面色，而不是透明：万一 band 里还有没被让位的原生素材，
// 也不会从按钮缝隙里透出来。取面积最大的一块不透明背景，比按类名猜稳。
static UIColor *GXKToolbarSurface(UIView *row, UIView *body) {
    UIColor *rowColor = row.backgroundColor;
    if ([rowColor isKindOfClass:[UIColor class]] && CGColorGetAlpha(rowColor.CGColor) > 0.9) return rowColor;
    if (!body) return nil;
    UIColor *best = nil;
    CGFloat bestArea = 0.0;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:body];
    NSUInteger visited = 0;
    while (stack.count && visited++ < 800) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        if (view.isHidden || view.alpha < 0.05) continue;
        UIColor *color = view.backgroundColor;
        if ([color isKindOfClass:[UIColor class]] && CGColorGetAlpha(color.CGColor) > 0.9) {
            CGFloat area = view.bounds.size.width * view.bounds.size.height;
            if (area > bestArea) { bestArea = area; best = color; }
        }
        [stack addObjectsFromArray:view.subviews];
    }
    return best;
}

static void GXKDetachToolbar(void) {
    UIStackView *stack = gToolbarStack;
    UIView *logo = gToolbarLogoView;
    BOOL logoWasHidden = gToolbarLogoWasHidden;
    CGFloat logoWasAlpha = gToolbarLogoWasAlpha;
    gToolbarStack = nil;
    gToolbarRow = nil;
    gToolbarLogoView = nil;
    gToolbarNineBody = nil;
    gToolbarBand = CGRectZero;
    [stack removeFromSuperview];
    GXKRestoreToolbarDecorations();
    if (logo) {
        logo.hidden = logoWasHidden; // G 图标按原状态归还，不替用户决定隐藏。
        logo.alpha = logoWasAlpha;
    }
}

static UIStackView *GXKMakeToolbar(UIView *row, UIColor *tint, UIColor *background) {
    UIFont *font = [UIFont fontWithName:@"Roboto-Regular" size:13.0] ?: [UIFont systemFontOfSize:13.0 weight:UIFontWeightMedium];
    NSArray<NSString *> *titles = @[@"全选", @"复制", @"粘贴", @"剪切", @"收起"];
    NSArray<NSString *> *actions = @[@"onSelectAll:", @"onCopy:", @"onPaste:", @"onCut:", @"onDismissKeyboard:"];
    UIStackView *stack = [[UIStackView alloc] initWithFrame:row.bounds];
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.distribution = UIStackViewDistributionFillEqually;
    stack.alignment = UIStackViewAlignmentFill;
    stack.spacing = 0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.backgroundColor = background; // 遮住被隐藏的 G 图标，避免按钮透明处透出原生图形。
    for (NSUInteger i = 0; i < titles.count; i++) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
        button.backgroundColor = [UIColor clearColor];
        button.adjustsImageWhenHighlighted = NO;
        button.titleLabel.adjustsFontSizeToFitWidth = YES;
        button.titleLabel.minimumScaleFactor = 0.7;
        button.titleLabel.font = font;
        [button setTitle:titles[i] forState:UIControlStateNormal];
        [button setTitleColor:tint forState:UIControlStateNormal];
        [button setTitleColor:[tint colorWithAlphaComponent:0.45] forState:UIControlStateHighlighted];
        button.accessibilityLabel = titles[i];
        [button addTarget:gToolbarTarget action:NSSelectorFromString(actions[i]) forControlEvents:UIControlEventTouchUpInside];
        [stack addArrangedSubview:button];
    }
    return stack;
}

static void GXKUpdateToolbar(UIViewController *vc) {
    if (gUpdatingToolbar || !vc || vc != gCurrentVC || !vc.isViewLoaded) return;
    gUpdatingToolbar = YES;
    UIView *root = vc.view;
    BOOL composing = GXKComposingStateCached(vc);

    // 廉价路径：绑定仍有效且空位没变时只同步显隐，不做全树定位、不改几何。
    if (gToolbarStack && gToolbarRow && gToolbarLogoView && gToolbarRow.window &&
        gToolbarRow.window == root.window && [gToolbarRow isDescendantOfView:root] &&
        GXKKeyIsVisible(gToolbarRow, root)) {
        GXKSyncToolbarDecorations(composing);
        // 组字中工具条整体隐藏，band 已还原成原生宽度，这时不必也不该按 band 重挂。
        if (composing) {
            UIStackView *stack = gToolbarStack;
            if (stack.superview != gToolbarRow) [gToolbarRow addSubview:stack];
            if (!stack.hidden) stack.hidden = YES;
            gUpdatingToolbar = NO;
            return;
        }
        CGRect band = CGRectZero;
        if (GXKToolbarBand(gToolbarRow, gToolbarLogoView, root, &band) &&
            fabs(band.origin.x - gToolbarBand.origin.x) < 0.5 &&
            fabs(band.size.width - gToolbarBand.size.width) < 0.5) {
            UIStackView *stack = gToolbarStack;
            if (stack.superview != gToolbarRow) [gToolbarRow addSubview:stack];
            if (stack.hidden) stack.hidden = NO;
            gUpdatingToolbar = NO;
            return;
        }
    }

    UIView *row = nil;
    UIView *logo = nil;
    UIView *body = nil;
    CGRect band = CGRectZero;
    if (!GXKToolbarScan(root, &row, &logo, &body, &band)) {
        static int logged = 0;
        if (logged < 3) { logged++; GXK_LOG(@"工具条: 无可用空位，保持原生（第 %d 次）", logged); }
        GXKDetachToolbar(); // 26 键、未知布局、找不到 G 行、空位不足：完全保持原生，绝不撑高键盘。
        gUpdatingToolbar = NO;
        return;
    }

    GXKDetachToolbar();
    // 先让 band 内的原生图标（语音按钮等）让位，再按新的可见性重算空位：
    // 被藏掉的邻居不再挡路，五个按钮能分到更多宽度，也不会再被压在下面。
    if (!composing && GXKHideToolbarDecorations(row, logo, root, band) > 0) {
        CGRect widened = CGRectZero;
        if (GXKToolbarBand(row, logo, root, &widened) && widened.size.width > band.size.width) band = widened;
    }
    if (!gToolbarTarget) gToolbarTarget = [[GXKToolbarTarget alloc] init];
    gToolbarTarget.controller = vc;

    UIColor *tint = GXKToolbarTint(body);
    UIColor *surface = GXKToolbarSurface(row, body) ?: [UIColor clearColor];
    UIStackView *stack = GXKMakeToolbar(row, tint, surface);
    gToolbarStack = stack;
    gToolbarRow = row;
    gToolbarLogoView = logo;
    gToolbarNineBody = body;
    gToolbarBand = band;
    gToolbarLogoWasHidden = logo.isHidden;
    gToolbarLogoWasAlpha = logo.alpha;
    // 用 alpha 而不是 hidden：hidden 在 UIStackView 里会把兄弟视图重排，band 一变就反复重挂。
    logo.alpha = 0.0; // 只藏 G 图标本身，同行预编辑/候选视图一律不碰。
    stack.hidden = composing;
    [row addSubview:stack];
    // 只占 band 那一段：左右各贴住相邻可见兄弟的边界，绝不覆盖同行其它内容。
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:band.origin.x],
        [stack.widthAnchor constraintEqualToConstant:band.size.width],
        [stack.topAnchor constraintEqualToAnchor:row.topAnchor],
        [stack.heightAnchor constraintEqualToConstant:band.size.height],
    ]];
    [row bringSubviewToFront:stack];
    GXK_LOG(@"工具条: 宿主 %@ %.0fx%.0f 空位 %.0f@%.0f", NSStringFromClass(row.class),
            row.bounds.size.width, row.bounds.size.height, band.size.width, band.origin.x);
    gUpdatingToolbar = NO;
}

@implementation GXKToolbarTarget

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

// 一次事件后只保留约 3 秒的补帧窗口；窗口内没有新事件就停表，不再每秒空唤醒 5 次。
#define GXK_POLL_BURST 15

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
    [[NSRunLoop mainRunLoop] addTimer:gStatePollTimer forMode:NSRunLoopCommonModes];
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
            GXKUpdateToolbar(vc);
            GXKBumpPolling(GXK_POLL_BURST); // 输入后给一小段补帧窗口。
        }
    });
}

static void gkx_viewDidLayoutSubviews(id self, SEL _cmd) {
    if (gOrigViewDidLayoutSubviews) gOrigViewDidLayoutSubviews(self, _cmd);
    if ((UIViewController *)self == gCurrentVC) {
        GXKRefreshComposingState((UIViewController *)self);
        GXKUpdateActionKey((UIViewController *)self);
        GXKUpdateToolbar((UIViewController *)self);
    }
}

static void gkx_viewWillAppear(id self, SEL _cmd, BOOL animated) {
    if (gOrigViewWillAppear) gOrigViewWillAppear(self, _cmd, animated);
    if ((UIViewController *)self != gCurrentVC) {
        GXKDetachActionKey();
        GXKDetachToolbar();
    }
    gCurrentVC = (UIViewController *)self;
    GXKRefreshComposingState((UIViewController *)self); // 新会话先取一次真实组字状态。
    GXKApplyTelemetryBlockIfNeeded(); // 兜底：构造函数时framework若未就绪，这里补一次。

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
        gCurrentVC = nil;
        gComposingActive = NO; // 扩展隐藏后组字缓存作废，下次出现重新采样。
        GXKStopPolling();
        GXKDetachActionKey();
        GXKDetachToolbar(); // 扩展隐藏后工具条随宿主一起撤走，下次出现重新定位。
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
}
