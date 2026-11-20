// [FEATURE-symbol] 九键符号页：双击锁定常驻、单击延时回拼音、成对符号自动补全。
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
//
// 锁定（gSymbolLocked）：双击一次 = 常驻符号页，此后每次单击只上屏、不再回拼音；
// 再双击同一格解除，或切到拼音/数字/表情等任何别的页面也自动解除（见 GXKSymbolNoteLayout）。
// 触感一律走 gkx.m 的全局 GXKImpact：锁定时 Medium、解除时 Light，不再自建 generator。
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
static BOOL gSymbolLocked; // 双击锁定：YES 时符号页常驻，单击不回拼音。
static NSUInteger gSymbolPairToken; // 补全重试的序号：新的一击作废旧的重试。

// 开符号 -> 闭符号。符号页上屏的是布局里定义的全角变体（｛［＜｢），
// 所以全角、半角、日文半角、制表四套都要列全：漏一个，就有一个符号永远不成对。
static NSDictionary<NSString *, NSString *> *GXKSymbolPairTable(void) {
    static NSDictionary<NSString *, NSString *> *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = @{
            // 圆括号
            @"（": @"）", @"(": @")",
            // 方括号：全角、半角、六角
            @"【": @"】", @"［": @"］", @"[": @"]", @"〔": @"〕",
            // 花括号：全角、半角
            @"｛": @"｝", @"{": @"}",
            // 尖括号：书名、单书名、全角、半角
            @"《": @"》", @"〈": @"〉", @"＜": @"＞", @"<": @">",
            // 引号类：直角、双直角、日文半角、制表
            @"「": @"」", @"『": @"』", @"｢": @"｣", @"〘": @"〙", @"〚": @"〛",
            @"“": @"”", @"‘": @"’",
            // 开闭同形的双引号：先查表命中，再由上下文配平否决
            @"\"": @"\"", @"＂": @"＂",
        };
    });
    return table;
}

// 开闭同形的字符：查表永远命中，必须靠上下文决定这一击是开还是收。
static BOOL GXKSymbolIsAmbiguous(NSString *ch) {
    return [ch isEqualToString:@"\""] || [ch isEqualToString:@"＂"];
}

static NSString *GXKSymbolCloserForChar(NSString *ch) {
    if (![ch isKindOfClass:[NSString class]] || !ch.length) return nil;
    return GXKSymbolPairTable()[ch];
}

// before 是刚上屏之后的光标前文本（末字符就是这一击）：含这一击数到奇数次 = 开。
static BOOL GXKSymbolAmbiguousOpens(NSString *ch, NSString *before) {
    if (!ch.length || ![before isKindOfClass:[NSString class]]) return YES;
    unichar target = [ch characterAtIndex:0];
    NSUInteger count = 0;
    for (NSUInteger i = 0; i < before.length; i++) {
        if ([before characterAtIndex:i] == target) count++;
    }
    return (count % 2) == 1;
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

// 单击后延时回拼音；这段时间内的第二次 fire 会把它取消。
// 已锁定则不排程：常驻期间每一击都只上屏。
static void GXKSymbolScheduleReturn(void) {
    GXKSymbolCancelReturn();
    if (gSymbolLocked) return;
    dispatch_block_t work = dispatch_block_create(0, ^{
        gSymbolReturnWork = nil;
        if (GXKSymbolPageActive()) GXKSymbolSwitchToPrime(); // 已经离开就不重复切
    });
    gSymbolReturnWork = work;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(GXK_SYMBOL_RETURN_DELAY * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), work);
}

// 真正补右半边：光标前文本里必须已经含有这一击，配平判断才准。
static void GXKSymbolInsertPair(NSString *typed) {
    id<UITextDocumentProxy> proxy = GXKSymbolProxy();
    if (!proxy || !typed.length) return;
    NSString *closer = GXKSymbolCloserForChar(typed);
    if (!closer.length) return;
    NSString *before = proxy.documentContextBeforeInput;
    // 双引号开闭同形：前面已经有一个没配对的，这一击就是收尾，不再补第二个。
    if (GXKSymbolIsAmbiguous(typed) && [before isKindOfClass:[NSString class]] &&
        !GXKSymbolAmbiguousOpens(typed, before)) return;
    [proxy insertText:closer];
    SEL moveSel = NSSelectorFromString(@"adjustTextPositionByCharacterOffset:");
    if ([proxy respondsToSelector:moveSel]) {
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(proxy, moveSel, (NSInteger)-1);
    }
}

// 等这一击真正落进宿主文本再补：宿主同步写入时第一次就命中，异步写入时最多重试 8 次（约 120ms）。
// 每次 fire 带一个 token，新的一击会作废旧的重试，所以既不会补两次，也不会补到下一格。
static void GXKSymbolPairAttempt(NSString *preText, UIView *anchor,
                                NSUInteger token, int attempt) {
    if (token != gSymbolPairToken) { gDiagPairGiveUp++; return; } // [DIAG-punct]
    // 用按下那一刻的键视图当锚点复查是否还在符号页：这条判定就是 fire 里判 YES 的同一条，
    // 不依赖会被布局回调作废的 BFS 缓存——换页后键视图的祖先链会隐藏或脱离，这里立刻为 NO，
    // 于是绝不会把右半边补到拼音页的文本里。
    if (anchor && !GXKSymbolViewIsOnSymbolPage(anchor)) {
        gDiagPairOffPage++; // [DIAG-punct] anchor 判定离页：补全被静默丢弃的头号嫌疑
        GXKPunctDiagLog(@"pair offPage a=%d pre=%ld", attempt, (long)preText.length);
        return;
    }
    id<UITextDocumentProxy> proxy = GXKSymbolProxy();
    if (!proxy) return;
    NSString *before = proxy.documentContextBeforeInput;
    if (![before isKindOfClass:[NSString class]]) before = @"";
    NSString *last = before.length > 0 ? [before substringFromIndex:before.length - 1] : nil;
    // 「这一击已经落进宿主」只认一种形态：末尾恰好追加了一个字符。
    //   · 用整串比对而不是比长度：选中一段后按键替换，长度可以不变；
    //   · 必须是「追加」而不是「变短」：退格后留下的末字符也是成对符号，
    //     只看末字符会把右半边补到退格之后，凭空多出一个符号。
    // documentContextBeforeInput 有长度上限：超长时窗口整体右移一格，长度不变、只丢首字符，
    // 所以两种形态都要认，否则长文本下补全会悄悄失效。
    BOOL appended = (before.length == preText.length + 1 && [before hasPrefix:preText]) ||
                    (before.length == preText.length && preText.length > 0 &&
                     [before hasPrefix:[preText substringFromIndex:1]]);
    if (appended) {
        // 以宿主真正落下的末字符为准，不看键面画的是什么：键面画全角、布局里发的可能是半角。
        BOOL closer = last.length > 0 && GXKSymbolCloserForChar(last) != nil;
        GXKPunctDiagLog(@"pair ok a=%d before=%ld pre=%ld last=%@ closer=%d",
                        attempt, (long)before.length, (long)preText.length, last ?: @"nil", (int)closer);
        if (closer) {
            gSymbolPairToken++; // 一次 fire 只补一次
            gDiagPairOk++;
            GXKSymbolInsertPair(last);
        }
        return; // 追加了：要么补完，要么这一击本就不是成对符号
    }
    if (![before isEqualToString:preText]) {
        // [DIAG-punct] 变了但不是追加：窗口右移超过 1 字符、或宿主改写了别的内容。
        gDiagPairGiveUp++;
        GXKPunctDiagLog(@"pair changed a=%d before=%ld pre=%ld", attempt,
                        (long)before.length, (long)preText.length);
        return; // 变了但不是追加（删除/替换/多字插入）：不补
    }
    if (attempt >= 8) {
        gDiagPairTimeout++;
        GXKPunctDiagLog(@"pair timeout before=%ld pre=%ld same=%d", (long)before.length,
                        (long)preText.length, (int)[before isEqualToString:preText]);
        return; // 宿主还没写进来就放弃：宁可不补，也不猜错位置
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.015 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        GXKSymbolPairAttempt(preText, anchor, token, attempt + 1);
    });
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
        // 双击的第二击：不上屏，只翻转锁定。
        // 锁定 -> 常驻（取消已排的回拼音）；解除 -> 留在本页，下一击恢复「上屏后回拼音」。
        GXKSymbolCancelReturn();
        gSymbolLocked = !gSymbolLocked;
        gSymbolLastFireView = nil;
        gSymbolLastFireAt = 0;
        // 触感复用 gkx.m 的全局 generator：锁定时 Medium（更重，表示「按住了」），解除时 Light。
        GXKImpact(gSymbolLocked ? UIImpactFeedbackStyleMedium : UIImpactFeedbackStyleLight);
        return;
    }

    if (onSymbolPage) {
        gSymbolLastFireView = view;
        gSymbolLastFireAt = now;
    } else {
        // 这一击不在符号页：锁定就地解除，不等布局回调（切页后立刻打字也能复位）。
        // 同时作废还没落地的补全重试，免得它把右半边补进这一击所在的页面。
        gSymbolPairToken++;
        gSymbolLocked = NO;
        gSymbolLastFireView = nil;
        gSymbolLastFireAt = 0;
        GXKSymbolCancelReturn();
    }

    // 转发之前先存一份光标前文本：宿主是同步写还是异步写，靠「内容变了没有」判定。
    NSString *preText = @"";
    if (onSymbolPage) {
        id<UITextDocumentProxy> probe = GXKSymbolProxy();
        NSString *pre = probe ? probe.documentContextBeforeInput : nil;
        if ([pre isKindOfClass:[NSString class]]) preText = pre;
    }

    if (gOrigSymbolFireEvent) gOrigSymbolFireEvent(self, _cmd, bundle, event); // 其余一律原样转发

    if (onSymbolPage) {
        // [DIAG-punct] 这一击的入口证据：锚点是否判在符号页、光标前文本多长。
        gDiagFire++;
        GXKPunctDiagLog(@"fire ident=%@ pre=%ld locked=%d view=%d",
                        view.restorationIdentifier ?: @"nil", (long)preText.length,
                        (int)gSymbolLocked, view != nil);
        // 文本由原生同步写入宿主，补全与回拼音都排在下一拍，避免和这一次提交抢光标。
        // 这里不再复查「是否还在符号页」：布局回调会在提交与补全之间让页面缓存失效，
        // 一旦复查落空，补全就被静默跳过——那正是「有时只补半边」的来源之一。
        // 是否在符号页改由重试里的键视图锚点判定，那条判定不吃这个缓存。
        NSUInteger token = ++gSymbolPairToken;
        UIView *anchor = view; // 只在这一击的重试窗口内强引用，最多 120ms
        dispatch_async(dispatch_get_main_queue(), ^{
            GXKSymbolPairAttempt(preText, anchor, token, 0);
        });
        GXKSymbolScheduleReturn();
    }
}

// 布局变化后校正锁定：离开符号页（切拼音/数字/表情）就自动解除。
// 由 gkx_viewDidLayoutSubviews 调用，本身不做任何扫描，只读布局阶段已经算好的缓存。
static void GXKSymbolNoteLayout(void) {
    if (!gSymbolLocked) return;
    if (GXKSymbolPageActive()) return;
    gSymbolLocked = NO;
    GXKSymbolCancelReturn();
}

static BOOL GXKSymbolShouldReturnToPrime(id self, SEL _cmd, id key) {
    // 九键符号页不自动切走；其它页面（26 键符号页等）保持原生行为。
    if (GXKSymbolPageActive()) return NO;
    // 不在这页了：锁定和残留状态一起清掉，下次进来从「单击」重新开始。
    gSymbolLocked = NO;
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
