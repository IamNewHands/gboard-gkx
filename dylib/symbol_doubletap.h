// [FEATURE-symbol] 九键符号页：双击上屏一次并停留、单击延时回拼音、成对符号自动补全。
//
// 为什么不能「加个双击手势，其余交给原生」：
//   原生单击符号键 = 上屏一次 + 立刻切回拼音页。等手势识别出第二击时，页面早已回到
//   拼音页，第二击落在拼音键上——双击永远拼不出来。所以必须先把「上屏即切走」这一步
//   关掉（-shouldReturnToPrimeOnKey: 在九键符号页恒 NO），停留与否改由本模块按时间窗决定。
//
// 双击的判定放在按键 fire 上，不放手势上：
//   同一格在 0.25 秒内第二次 fire = 双击。这样不依赖「手势回调 vs 原生 fire」的先后，
//   也就不需要任何手势识别器，红线 2（严禁拦截按键触摸事件）连边都不碰。
//
// 为什么是「跳过第二击」而不是「上屏后再删」：
//   跳过只需一行，文本天然只上屏一次；删字符会和成对补全抢同一个光标位置。
//
// 性能：判定「是否在符号页」走两条路——fire 里从被按的键往上找祖先标识（O(深度)），
// 其余场合用按布局失效的缓存（每次布局至多一次全树 BFS），不在打字热路径上做全树扫描。
#ifndef GXK_SYMBOL_DOUBLETAP_H
#define GXK_SYMBOL_DOUBLETAP_H

#import <dispatch/dispatch.h> // dispatch_block_create/cancel：延时回拼音要能被下一击取消

#define GXK_SYMBOL_TAP_WINDOW 0.25    // 两击之间允许的最大间隔，超过即两次单击
#define GXK_SYMBOL_RETURN_DELAY 0.28  // 单击后多久回拼音，必须略大于双击窗口
#define GXK_SYMBOL_PAGE_IDENT @"key_pos_9keys_symbols"

static void (*gOrigSymbolShouldReturnToPrime)(id, SEL, id);
static void (*gOrigSymbolFireEvent)(id, SEL, id, id);
static __weak UIView *gSymbolHostCache;
static BOOL gSymbolPageCacheValid;
static __weak UIView *gSymbolLastFireView;
static NSTimeInterval gSymbolLastFireAt;
static dispatch_block_t gSymbolReturnWork;

// 只有「开括号」才补全：闭括号后面再补一个开括号不是用户要的。
static NSString *GXKSymbolCloserForChar(NSString *ch) {
    static NSDictionary<NSString *, NSString *> *pairs;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        pairs = @{
            @"（": @"）", @"「": @"」", @"『": @"』", @"【": @"】",
            @"《": @"》", @"〈": @"〉", @"〔": @"〕", @"〖": @"〗",
            @"“": @"”", @"‘": @"’",
            @"(": @")", @"[": @"]", @"{": @"}", @"<": @">",
        };
    });
    if (![ch isKindOfClass:[NSString class]]) return nil;
    return pairs[ch];
}

static id<UITextDocumentProxy> GXKSymbolProxy(void) {
    UIViewController *vc = gCurrentVC;
    if (!vc || ![vc isKindOfClass:[UIInputViewController class]]) return nil;
    return ((UIInputViewController *)vc).textDocumentProxy;
}

// 从被按的键往上找符号页标识：命中即当前就在九键符号页。O(深度)，可在 fire 里直接调用。
static BOOL GXKSymbolViewIsOnSymbolPage(UIView *view) {
    NSUInteger depth = 0;
    for (UIView *cursor = view; cursor && depth++ < 24; cursor = cursor.superview) {
        NSString *ident = cursor.restorationIdentifier;
        if ([ident isKindOfClass:[NSString class]] && [ident isEqualToString:GXK_SYMBOL_PAGE_IDENT]) {
            return !cursor.isHidden;
        }
    }
    return NO;
}

// 全树判定：只用于拿不到按键视图的场合（shouldReturnToPrimeOnKey:）。
// 结果按布局缓存，布局一变（换页必然触发布局）就失效，不在打字热路径上重复扫描。
static UIView *GXKSymbolHost(void) {
    UIViewController *vc = gCurrentVC;
    if (!vc || !vc.isViewLoaded) return nil;
    if (gSymbolPageCacheValid) {
        UIView *cached = gSymbolHostCache;
        if (!cached) return nil;
        if (cached.window && !cached.isHidden) return cached;
    }
    UIView *host = GXKProbeSymbolHost(vc.view); // symbol_probe.h 里同一条判定
    gSymbolHostCache = host;
    gSymbolPageCacheValid = YES;
    return host;
}

static void GXKSymbolInvalidatePageCache(void) { gSymbolPageCacheValid = NO; }

static BOOL GXKSymbolPageActive(void) { return GXKSymbolHost() != nil; }

static void GXKSymbolCancelReturn(void) {
    dispatch_block_t work = gSymbolReturnWork;
    gSymbolReturnWork = nil;
    if (work) dispatch_block_cancel(work);
}

// 回拼音：GKBInputViewControllerBase -inputBundleManager -> GKBInputBundle -switchToPrimeKeyboard。
static void GXKSymbolSwitchToPrime(void) {
    UIViewController *vc = gCurrentVC;
    if (!vc) return;
    SEL managerSel = NSSelectorFromString(@"inputBundleManager");
    if (![vc respondsToSelector:managerSel]) return;
    id manager = ((id (*)(id, SEL))objc_msgSend)(vc, managerSel);
    SEL bundleSel = NSSelectorFromString(@"currentInputBundle");
    if (!manager || ![manager respondsToSelector:bundleSel]) return;
    id bundle = ((id (*)(id, SEL))objc_msgSend)(manager, bundleSel);
    SEL switchSel = NSSelectorFromString(@"switchToPrimeKeyboard");
    if (!bundle || ![bundle respondsToSelector:switchSel]) return;
    ((void (*)(id, SEL))objc_msgSend)(bundle, switchSel);
    gSymbolLastFireView = nil;
    gSymbolLastFireAt = 0;
    GXKSymbolInvalidatePageCache();
}

// 单击后延时回拼音；这段时间内的第二次 fire 会把它取消，于是连点一直停在符号页。
static void GXKSymbolScheduleReturn(void) {
    GXKSymbolCancelReturn();
    dispatch_block_t work = dispatch_block_create(0, ^{
        gSymbolReturnWork = nil;
        if (GXKSymbolPageActive()) GXKSymbolSwitchToPrime(); // 已经离开就不重复切
    });
    gSymbolReturnWork = work;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(GXK_SYMBOL_RETURN_DELAY * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), work);
}

// 成对补全：此时原生已把符号写进宿主文本，再补右括号并把光标放回中间。
static void GXKSymbolPairIfNeeded(void) {
    id<UITextDocumentProxy> proxy = GXKSymbolProxy();
    if (!proxy) return;
    NSString *before = proxy.documentContextBeforeInput;
    if (![before isKindOfClass:[NSString class]] || !before.length) return;
    NSString *closer = GXKSymbolCloserForChar([before substringFromIndex:before.length - 1]);
    if (!closer.length) return;
    [proxy insertText:closer];
    SEL moveSel = NSSelectorFromString(@"adjustTextPositionByCharacterOffset:");
    if ([proxy respondsToSelector:moveSel]) {
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(proxy, moveSel, (NSInteger)-1);
    }
}

static void GXKSymbolFireEvent(id self, SEL _cmd, id bundle, id event) {
    SEL viewSel = NSSelectorFromString(@"targetView");
    UIView *view = (bundle && [bundle respondsToSelector:viewSel])
        ? ((id (*)(id, SEL))objc_msgSend)(bundle, viewSel) : nil;
    BOOL onSymbolPage = view ? GXKSymbolViewIsOnSymbolPage(view) : GXKSymbolPageActive();
    NSTimeInterval now = [NSProcessInfo processInfo].systemUptime;
    BOOL sameKey = onSymbolPage && view && view == gSymbolLastFireView &&
                   now - gSymbolLastFireAt < GXK_SYMBOL_TAP_WINDOW;

    if (sameKey) {
        // 双击的第二击：不再上屏，取消回拼音 => 结果恰好是「上屏一次 + 停留」。
        GXKSymbolCancelReturn();
        gSymbolLastFireView = nil;
        gSymbolLastFireAt = 0;
        UIImpactFeedbackGenerator *gen =
            [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [gen prepare];
        [gen impactOccurred];
        return;
    }

    if (onSymbolPage) {
        gSymbolLastFireView = view;
        gSymbolLastFireAt = now;
    } else {
        gSymbolLastFireView = nil;
        gSymbolLastFireAt = 0;
        GXKSymbolCancelReturn();
    }

    if (gOrigSymbolFireEvent) gOrigSymbolFireEvent(self, _cmd, bundle, event); // 其余一律原样转发

    if (onSymbolPage) {
        // 文本由原生同步写入宿主，补全与回拼音都排在下一拍，避免和这一次提交抢光标。
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!GXKSymbolPageActive()) return;
            GXKSymbolPairIfNeeded();
            GXKSymbolScheduleReturn();
        });
    }
}

static BOOL GXKSymbolShouldReturnToPrime(id self, SEL _cmd, id key) {
    // 九键符号页不自动切走；其它页面（26 键符号页等）保持原生行为。
    if (GXKSymbolPageActive()) return NO;
    gSymbolLastFireView = nil;
    gSymbolLastFireAt = 0;
    GXKSymbolCancelReturn();
    if (gOrigSymbolShouldReturnToPrime) {
        return ((BOOL (*)(id, SEL, id))gOrigSymbolShouldReturnToPrime)(self, _cmd, key);
    }
    return YES;
}

static void GXKSymbolInstallHooks(void) {
    static BOOL installed;
    if (installed) return;
    if (!NSClassFromString(@"GKBTapTouchHandler")) return; // framework 未加载，下次再试
    installed = YES;
    // 只挂这两个类自身的单点方法：不碰任何 touchesBegan/Moved/Ended/Cancelled。
    // 原实现只取一次：两个类回退目标都是九键符号键盘那一个。
    GXKSwizzleOrSkip(@"GKBSymbolKeyboard", @"shouldReturnToPrimeOnKey:",
                     (IMP)GXKSymbolShouldReturnToPrime,
                     (void **)&gOrigSymbolShouldReturnToPrime);
    GXKSwizzleOrSkip(@"GKBZhSymbolKeyboard", @"shouldReturnToPrimeOnKey:",
                     (IMP)GXKSymbolShouldReturnToPrime, NULL);
    GXKSwizzleOrSkip(@"GKBTapTouchHandler", @"touchActionBundle:fireEvent:",
                     (IMP)GXKSymbolFireEvent, (void **)&gOrigSymbolFireEvent);
}

#endif  // GXK_SYMBOL_DOUBLETAP_H
