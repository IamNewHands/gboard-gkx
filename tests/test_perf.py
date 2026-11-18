#!/usr/bin/env python3
"""性能改动源码契约：轮询必须走廉价路径，全树扫描不得留在定时器里。"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "dylib/gkx.m"


def function_body(source: str, signature: str) -> str:
    """按大括号配对截取函数体，包含嵌套块。"""
    start = source.index(signature)
    brace = source.index("{", start)
    depth = 0
    for i in range(brace, len(source)):
        ch = source[i]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return source[start:i + 1]
    raise AssertionError(f"unbalanced braces for {signature}")


class PerfContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = SOURCE.read_text(encoding="utf-8")
        cls.layout = (ROOT / "dylib/toolbar_layout.h").read_text(encoding="utf-8")
        cls.visibility = (ROOT / "dylib/toolbar_visibility.h").read_text(encoding="utf-8")

    def test_timer_body_never_scans_full_tree(self):
        """定时器只在按需窗口内跑，且体内绝不做全树扫描。"""
        pump = function_body(self.source, "static void GXKBumpPolling(NSInteger ticks) {")
        self.assertIn("scheduledTimerWithTimeInterval", pump)
        body = pump[pump.index("scheduledTimerWithTimeInterval"):]
        self.assertNotIn("GXKFindNineKeyEmojiKey", body)
        self.assertNotIn("GXKComposingFullScan", body)
        self.assertIn("GXKUpdateActionKey(vc)", body)
        # 生命周期入口只抬计数，不直接建表；建表只在 GXKBumpPolling 里发生一次。
        appear = function_body(self.source, "static void gkx_viewWillAppear(id self, SEL _cmd, BOOL animated)")
        self.assertIn("GXKBumpPolling(GXK_POLL_BURST)", appear)
        self.assertNotIn("scheduledTimerWithTimeInterval", appear)

    def test_polling_stops_when_idle(self):
        """空闲必须停表：计数归零后 invalidate，隐藏时也停表。"""
        pump = function_body(self.source, "static void GXKBumpPolling(NSInteger ticks) {")
        self.assertIn("gPollTicks <= 0", pump)
        self.assertIn("GXKStopPolling()", pump)
        self.assertIn("gPollTicks--", pump)
        stop = function_body(self.source, "static void GXKStopPolling(void) {")
        self.assertIn("[gStatePollTimer invalidate]", stop)
        self.assertIn("gStatePollTimer = nil", stop)
        self.assertIn("gPollTicks = 0", stop)
        gone = function_body(self.source, "static void gkx_viewWillDisappear(id self, SEL _cmd, BOOL animated)")
        self.assertIn("GXKStopPolling()", gone)
        # 旧的无条件常驻表必须消失，否则空闲仍每秒唤醒 5 次。
        self.assertNotIn("if (!gStatePollTimer) {", self.source)

    def test_update_has_cheap_path_before_full_scan(self):
        update = function_body(self.source, "static void GXKUpdateActionKey(UIViewController *vc) {")
        cheap = update.index("GXKComposingStateCached")
        full = update.index("GXKFindNineKeyEmojiKey(root)")
        self.assertLess(cheap, full, "cheap path must run before the full tree scan")
        head = update[:full]
        self.assertIn("gActionKeyButton.superview == gActionHost", head)
        self.assertIn("GXKKeyIsVisible(gEmojiSoftKeyView, root)", head)
        self.assertIn("GXKModelHasNativeActions(gActionSoftKeyDef)", head)

    def test_cheap_path_still_fails_closed(self):
        update = function_body(self.source, "static void GXKUpdateActionKey(UIViewController *vc) {")
        head = update[:update.index("GXKFindNineKeyEmojiKey(root)")]
        for required in (
            "gEmojiSoftKeyView &&",
            "gActionNativeIcon &&",
            "gActionSoftKeyDef &&",
            "gActionKeyButton &&",
            "gActionHost &&",
        ):
            self.assertIn(required, head)
        self.assertIn("GXKNativeIconForKey(gEmojiSoftKeyView) == gActionNativeIcon", head)
        self.assertIn("softKeyDef == gActionSoftKeyDef", head)

    def test_cheap_path_keeps_native_foreground_stripped(self):
        update = function_body(self.source, "static void GXKUpdateActionKey(UIViewController *vc) {")
        head = update[:update.index("GXKFindNineKeyEmojiKey(root)")]
        self.assertIn("cheapIcon.image = nil", head)
        self.assertIn("cheapIcon.highlightedImage = nil", head)
        self.assertIn("gActionNormalImage = cheapIcon.image", head)

    def test_composing_scan_is_event_driven_not_polled(self):
        self.assertIn("static void GXKRefreshComposingState(UIViewController *vc)", self.source)
        self.assertIn("static BOOL GXKComposingStateCached(UIViewController *vc)", self.source)
        refresh = function_body(self.source, "static void GXKRefreshComposingState(UIViewController *vc)")
        self.assertIn("GXKComposingFromProxy(vc)", refresh)
        self.assertIn("GXKComposingFullScan(vc)", refresh)
        cached = function_body(self.source, "static BOOL GXKComposingStateCached(UIViewController *vc)")
        self.assertNotIn("GXKComposingFullScan", cached)
        for hook in (
            "static void gkx_textDidChange(id self, SEL _cmd, id textInput)",
            "static void gkx_viewDidLayoutSubviews(id self, SEL _cmd)",
        ):
            body = function_body(self.source, hook)
            self.assertIn("GXKRefreshComposingState", body, hook)

    def test_dictionary_deploy_is_once_per_process(self):
        deploy = function_body(self.source, "static void GXKEnsureUserDictionaryDeployed(void)")
        first = deploy.index("gDictDeploySettled")
        self.assertLess(first, deploy.index("defaultManager"))
        self.assertIn("if (gDictDeploySettled) return;", deploy)
        self.assertGreaterEqual(deploy.count("gDictDeploySettled = YES"), 2)

    def test_haptics_are_reused_and_released(self):
        impact = function_body(self.source, "static void GXKImpact(UIImpactFeedbackStyle style)")
        self.assertIn("if (!gFbMedium)", impact)
        self.assertIn("if (!gFbLight)", impact)
        self.assertIn("[gFbMedium prepare]", impact)
        self.assertIn("[gFbLight prepare]", impact)
        self.assertEqual(impact.count("initWithStyle:"), 2, "generators must be created at most once each")
        tap = function_body(self.source, "- (void)onActionKeyTapped:(UIButton *)sender")
        self.assertNotIn("initWithStyle:", tap, "tap must not allocate a generator")
        release = function_body(self.source, "static void GXKReleaseHaptics(void)")
        self.assertIn("gFbMedium = nil", release)
        self.assertIn("gFbLight = nil", release)
        gone = function_body(self.source, "static void gkx_viewWillDisappear(id self, SEL _cmd, BOOL animated)")
        self.assertIn("GXKReleaseHaptics()", gone)
        self.assertIn("gComposingActive = NO", gone)

    def test_view_kind_cache_avoids_per_node_class_strings(self):
        """类名判定必须按类指针缓存，不能在每个节点上重新拼字符串。"""
        cache = function_body(self.source, "static NSInteger GXKViewKind(UIView *view) {")
        self.assertIn("gViewKindCache", cache)
        self.assertIn("NSValue valueWithPointer", cache)
        self.assertIn("NSStringFromClass", cache)
        # 缓存命中必须提前返回，否则缓存没有意义。
        self.assertLess(cache.index("if (cached) return cached.integerValue;"),
                        cache.index("NSStringFromClass"))
        scan = function_body(self.source, "static BOOL GXKComposingFullScan(UIViewController *vc) {")
        self.assertIn("GXKViewKind(v)", scan)
        self.assertNotIn("NSStringFromClass", scan, "scan must not format class names per node")
        self.assertNotIn("containsString:@\"Composing\"", scan)

    def test_composing_scan_is_throttled_with_trailing_pass(self):
        """全树扫描必须节流，且被跳过的那次要有尾随扫描兜住状态。"""
        self.assertIn("#define GXK_COMPOSING_SCAN_MIN_INTERVAL 0.25", self.source)
        refresh = function_body(self.source, "static void GXKRefreshComposingState(UIViewController *vc)")
        self.assertIn("CFAbsoluteTimeGetCurrent()", refresh)
        self.assertIn("GXK_COMPOSING_SCAN_MIN_INTERVAL", refresh)
        self.assertIn("GXKScheduleComposingScan()", refresh)
        # 代理已明确有 mark 时仍然走 O(1) 路径，不受节流影响。
        self.assertLess(refresh.index("GXKComposingFromProxy(vc)"),
                        refresh.index("CFAbsoluteTimeGetCurrent()"))
        trailing = function_body(self.source, "static void GXKScheduleComposingScan(void) {")
        self.assertIn("dispatch_after", trailing)
        self.assertIn("gComposingScanScheduled", trailing)
        self.assertIn("GXKComposingFullScan(vc)", trailing)
        # 状态没翻转时不得触发界面刷新。
        self.assertIn("if (composing == gComposingActive) return;", trailing)

    def test_plain_typing_uses_short_settle_window(self):
        """普通打字只补两帧；只有组字状态翻转才拉起完整补帧窗口。"""
        self.assertIn("#define GXK_POLL_BURST 5", self.source)
        self.assertIn("#define GXK_POLL_SETTLE 2", self.source)
        typed = function_body(self.source, "static void gkx_textDidChange(id self, SEL _cmd, id textInput)")
        self.assertIn("BOOL wasComposing = gComposingActive;", typed)
        self.assertIn("GXKBumpPolling((wasComposing != gComposingActive) ? GXK_POLL_BURST : GXK_POLL_SETTLE);", typed)

    def test_native_obstacle_registry_is_weak_event_scoped_and_complete(self):
        """Discovery is event-scoped; hidden carriers remain eligible for live changes."""
        registry = function_body(self.visibility, "static BOOL GXKToolbarNativeSpaceClear(")
        for required in ("gToolbarObstacleRoot != root", "gToolbarObstacleLogo != logo",
                         "gToolbarObstacleEpoch != gToolbarContentEpoch", "!gToolbarObstacleComplete",
                         "[NSHashTable weakObjectsHashTable]", "visited++ < 800",
                         "if (pending.count) return NO;", "gToolbarObstacleComplete = YES;"):
            self.assertIn(required, registry)
        discover = registry[registry.index("if (rebuild) {"):registry.index("gToolbarObstacleComplete = YES;")]
        self.assertNotRegex(discover, r"view\.(?:hidden|isHidden|alpha)")
        self.assertIn("[view isDescendantOfView:root]", registry)
        for signature in ("static void gkx_textDidChange(", "static void gkx_viewDidLayoutSubviews(",
                          "static void gkx_viewWillAppear("):
            self.assertIn("gToolbarContentEpoch++;", function_body(self.source, signature))
        detach = function_body(self.source, "static void GXKDetachToolbar(void) {")
        self.assertIn("gToolbarObstacleComplete = NO;", detach)

    def test_keyboard_owner_registry_shares_complete_discovery_without_hidden_pruning(self):
        registry = function_body(self.visibility, "static BOOL GXKToolbarNativeSpaceClear(")
        discover = registry[registry.index("if (rebuild) {"):registry.index("gToolbarObstacleComplete = YES;")]
        self.assertIn("static NSHashTable<UIView *> *gToolbarKeyboardBodies;", self.visibility)
        self.assertIn("gToolbarKeyboardBodies = [NSHashTable weakObjectsHashTable];", discover)
        self.assertIn("if (!keyClass || !nineClass || !qwertyClass) return NO;", discover)
        self.assertIn("if ([view isKindOfClass:nineClass] || [view isKindOfClass:qwertyClass])", discover)
        self.assertIn("[gToolbarKeyboardBodies addObject:view];", discover)
        self.assertEqual(1, registry.count("NSMutableArray<UIView *> *pending"))
        self.assertNotIn("GXKKeyIsVisible(", discover)
        self.assertNotRegex(discover, r"view\.(?:hidden|alpha)")
        self.assertLess(discover.index("[gToolbarKeyboardBodies addObject:view]"),
                        discover.index("if (!leaf)"))
        self.assertIn("if (pending.count) return NO;", discover)

    def test_reuse_requires_live_nine_owner_and_rejects_independent_qwerty_without_band_overlap(self):
        registry = function_body(self.visibility, "static BOOL GXKToolbarNativeSpaceClear(")
        live = registry[registry.index("gToolbarObstacleComplete = YES;") + len("gToolbarObstacleComplete = YES;"):]
        owners = live[live.index("BOOL nineVisible = NO;"):live.index("for (UIView *view in gToolbarObstacles)")]
        self.assertIn("for (UIView *body in gToolbarKeyboardBodies)", owners)
        self.assertIn("if (!GXKKeyIsVisible(body, root)) continue;", owners)
        code = re.sub(r"//[^\n]*", "", owners)
        self.assertRegex(code, r"if \(\[body isKindOfClass:nineClass\]\) nineVisible = YES;\s*"
                              r"else if \(\[body isKindOfClass:qwertyClass\]\) return NO;")
        self.assertIn("if (!nineVisible) return NO;", owners)
        for band_condition in ("band", "CGRect", "GXKToolbarContentBlocks", "convertRect:"):
            self.assertNotIn(band_condition, owners)
        self.assertNotIn("if (rebuild)", live)
        self.assertLess(live.index("if (!nineVisible) return NO;"), live.index("GXKToolbarContentBlocks(view, root, band)"))

    def test_native_content_is_checked_live_not_alpha_masked(self):
        blocks = function_body(self.visibility, "static BOOL GXKToolbarContentBlocks(")
        for required in ("GXKKeyIsVisible(view, root)", "CGRectIntersection(rect, band)",
                         "collection.visibleCells.count", "numberOfItemsInSection:section",
                         "label.text.length > 0", "label.attributedText.length > 0"):
            self.assertIn(required, blocks)
        registry = function_body(self.visibility, "static BOOL GXKToolbarNativeSpaceClear(")
        self.assertIn("CGRectContainsRect(root.bounds, band)", registry)
        self.assertIn("GXKToolbarContentBlocks(view, root, band)", registry)
        for native_class in ("GKBSoftKeyView", "UICollectionView", "UIButton", "UILabel"):
            self.assertIn(native_class, registry)
        toolbar = self.source[self.source.index("#pragma mark - 顶部工具条"):self.source.index("#pragma mark - 按需轮询")]
        code = re.sub(r"//[^\n]*", "", toolbar + self.visibility)
        self.assertNotRegex(code, r"\.alpha\s*=(?!=)")
        for retired in ("GXKSyncToolbarDecorations", "GXKRestoreToolbarDecorations", "gToolbarDecorations"):
            self.assertNotIn(retired, code)

    def test_native_image_carrier_is_registered_empty_and_contents_checked_live(self):
        registry = function_body(self.visibility, "static BOOL GXKToolbarNativeSpaceClear(")
        discover = registry[registry.index("if (rebuild) {"):registry.index("gToolbarObstacleComplete = YES;")]
        self.assertIn("BOOL icon = [view respondsToSelector:@selector(image)];", discover)
        self.assertIn("if (leaf || icon || [view isKindOfClass:[UILabel class]]) [gToolbarObstacles addObject:view];", discover)
        self.assertNotIn("[(id<GXKNativeIconContent>)view image]", discover)
        blocks = function_body(self.visibility, "static BOOL GXKToolbarContentBlocks(")
        self.assertIn("UIImage *image = [(id<GXKNativeIconContent>)view image];", blocks)
        self.assertIn("[image isKindOfClass:[UIImage class]] && GXKToolbarIconSized(view.bounds)", blocks)
        priority = "if ((keyClass && [view isKindOfClass:keyClass]) || [view isKindOfClass:[UIButton class]]) return YES;"
        self.assertIn(priority, blocks)
        self.assertLess(blocks.index(priority), blocks.index("if ([view respondsToSelector:@selector(image)])"))
        live_reuse = registry[registry.index("gToolbarObstacleComplete = YES;"):]
        self.assertIn("GXKToolbarContentBlocks(view, root, band)", live_reuse)

    def test_toolbar_reuses_root_host_stack_and_replaces_constraints(self):
        """Same row/logo/root may reuse; only the patch stack receives constraints."""
        self.assertIn("static NSArray<NSLayoutConstraint *> *gToolbarConstraints;", self.source)
        update = function_body(self.source, "static void GXKUpdateToolbar(UIViewController *vc) {")
        reuse = update[update.index("BOOL reuse ="):update.index("if (!reuse)")]
        for identity in ("gToolbarRow == row", "gToolbarLogoView == logo", "gToolbarHost == root",
                         "gToolbarStack.superview == root"):
            self.assertIn(identity, reuse)
        self.assertIn("UIStackView *stack = reuse ? gToolbarStack : GXKMakeToolbar(root, tint);", update)
        self.assertIn("if (!reuse) GXKDetachToolbar();", update)
        self.assertLess(update.index("deactivateConstraints:gToolbarConstraints"),
                        update.index("gToolbarConstraints = @["))
        self.assertLess(update.index("gToolbarConstraints = @["),
                        update.index("[NSLayoutConstraint activateConstraints:gToolbarConstraints"))
        detach = function_body(self.source, "static void GXKDetachToolbar(void) {")
        for cleanup in ("deactivateConstraints:gToolbarConstraints", "gToolbarConstraints = nil;",
                        "gToolbarHost = nil;", "gToolbarBandCacheValid = NO;"):
            self.assertIn(cleanup, detach)

    def test_haptics_released_after_idle(self):
        """Taptic 引擎不能一直预热：停手 2 秒就释放 generator。"""
        self.assertIn("#define GXK_HAPTIC_IDLE_SECONDS 2.0", self.source)
        self.assertIn("static NSTimer *gHapticIdleTimer;", self.source)
        impact = function_body(self.source, "static void GXKImpact(UIImpactFeedbackStyle style) {")
        self.assertIn("GXKScheduleHapticRelease();", impact)
        schedule = function_body(self.source, "static void GXKScheduleHapticRelease(void) {")
        self.assertIn("[gHapticIdleTimer invalidate]", schedule)
        self.assertIn("GXK_HAPTIC_IDLE_SECONDS", schedule)
        self.assertIn("repeats:NO", schedule)
        # 释放必须真的把两个 generator 置空。
        self.assertIn("gFbMedium = nil;", schedule)
        self.assertIn("gFbLight = nil;", schedule)
        release = function_body(self.source, "static void GXKReleaseHaptics(void) {")
        self.assertIn("[gHapticIdleTimer invalidate]", release)

    def test_pin_toggle_skips_forced_sync(self):
        """钉子状态只有键盘自己读，不跨进程，不必强制落盘；常用语正文必须保留。"""
        pinned = function_body(self.source, "static void GXKPhrasesSetPinned(BOOL pinned) {")
        # 只看真实调用，注释里提到 synchronize 不算。
        self.assertNotIn("[defaults synchronize];", pinned)
        self.assertIn("setBool:pinned forKey:GXKPhrasesPinnedKey", pinned)
        save = function_body(self.source, "static void GXKPhraseSave(NSArray<NSString *> *list) {")
        self.assertIn("[defaults synchronize];", save)

    def test_dictionary_ships_once_and_is_found_from_both_processes(self):
        """词库只随包放一份；扩展进程要能沿 bundle 往上找到主 App 的 Frameworks。"""
        inject = (ROOT / "tools/inject.py").read_text(encoding="utf-8")
        self.assertNotIn("dict_dst_appex", inject)
        self.assertIn('dict_dst_fw = os.path.join(fw, "user_dictionary.db")', inject)
        deploy = function_body(self.source, "static void GXKEnsureUserDictionaryDeployed(void) {")
        # 候选路径必须逐个 fileExistsAtPath 验证，不能拿到第一个非 nil 就用。
        self.assertIn("for (NSString *candidate in candidates)", deploy)
        self.assertIn("[fm fileExistsAtPath:candidate]", deploy)
        self.assertIn("../../Frameworks/user_dictionary.db", deploy)

    def test_polling_never_joins_common_modes(self):
        """0.2 秒轮询只挂默认模式：挂 CommonModes 会在滚动/动画期间继续抢主线程。"""
        pump = function_body(self.source, "static void GXKBumpPolling(NSInteger ticks) {")
        self.assertIn("scheduledTimerWithTimeInterval", pump)
        self.assertNotIn("NSRunLoopCommonModes", pump)
        self.assertNotIn("addTimer:", pump)
        self.assertNotIn("NSRunLoopCommonModes", self.source)

    def test_high_frequency_callbacks_coalesce_to_last_one(self):
        """同一帧内多次文本/布局回调只让最后一次刷新，前面排队的直接丢弃。"""
        typed = function_body(self.source, "static void gkx_textDidChange(id self, SEL _cmd, id textInput)")
        self.assertIn("NSUInteger seq = ++gTextChangeSeq;", typed)
        self.assertIn("if (seq != gTextChangeSeq) return;", typed)
        # 丢弃判定必须在真正的刷新之前，否则合并没有意义。
        self.assertLess(typed.index("if (seq != gTextChangeSeq) return;"),
                        typed.index("GXKRefreshComposingState(vc)"))
        layout = function_body(self.source, "static void gkx_viewDidLayoutSubviews(id self, SEL _cmd)")
        self.assertIn("NSUInteger seq = ++gLayoutSeq;", layout)
        self.assertIn("if (seq != gLayoutSeq) return;", layout)
        self.assertLess(layout.index("if (seq != gLayoutSeq) return;"),
                        layout.index("GXKRefreshComposingState(vc)"))
        # 布局回调不得再同步跑全量刷新，必须整体挪进异步块。
        sync_part = layout[:layout.index("dispatch_async")]
        self.assertNotIn("GXKUpdateToolbar", sync_part)
        self.assertNotIn("GXKUpdateActionKey", sync_part)

    def test_hot_scan_paths_cache_class_pointers(self):
        """扫描热路径只解析一次类指针，不在每个软键上重复 NSClassFromString。"""
        self.assertIn("static Class GXKClassCached(NSString *name, Class *slot)", self.source)
        helper = function_body(self.source, "static Class GXKClassCached(NSString *name, Class *slot)")
        # 解析失败（类还没加载）不能写缓存，否则永远补不上。
        self.assertIn("if (*slot) return *slot;", helper)
        self.assertIn("if (cls) *slot = cls;", helper)
        for signature in (
            "static UIView *GXKNineKeyBodyForKey(UIView *key, UIView *root)",
            "static UIView *GXKActionHostForKey(UIView *key)",
            "static UIView *GXKFindNineKeyEmojiKey(UIView *root)",
            "static BOOL GXKToolbarScan(UIView *root, UIView **outRow, UIView **outLogo, UIView **outBody, CGRect *outBand)",
            "static UIView<GXKNativeIconContent> *GXKNativeIconForKey(UIView *key)",
        ):
            owner = self.layout if "GXKToolbarScan" in signature else self.source
            body = function_body(owner, signature)
            self.assertNotIn("NSClassFromString", body, signature)
            self.assertIn("GXKClassCached(", body, signature)

    def test_toolbar_band_uses_measured_glyph_without_row_height_clamp(self):
        """A short header cannot move the text away from the live G center."""
        band = function_body(self.layout, "static BOOL GXKToolbarBand(")
        measured = band.index("GXKToolbarGlyphRect(logo, row, &glyph)")
        self.assertLess(measured, band.index("if (gToolbarBandCacheValid &&"))
        self.assertIn("if (!GXKToolbarGlyphRect(logo, row, &glyph))", band)
        self.assertIn("gToolbarBandCacheValid = NO; return NO;", band)
        for geometry in ("CGRectGetMaxX(r) <= CGRectGetMinX(glyph) + 0.5",
                         "CGRectGetMinX(r) >= CGRectGetMaxX(glyph) - 0.5",
                         "CGFloat iconRight = CGRectGetMaxX(glyph);", "left = iconRight + 4.0;",
                         "CGFloat barHeight = glyph.size.height;", "if (barHeight < 28.0) barHeight = 28.0;",
                         "CGFloat top = CGRectGetMidY(glyph) - barHeight * 0.5;",
                         "[row convertRect:candidate toView:root]", "right - left >= 200.0",
                         "CGRectContainsRect(root.bounds, candidateInRoot)"):
            self.assertIn(geometry, band)
        self.assertNotRegex(band, r"barHeight\s*>\s*(?:height|row\.bounds\.size\.height)")
        self.assertNotRegex(band, r"top\s*=\s*(?:0(?:\.0)?|MAX\(|MIN\(|height\s*-)")
        self.assertNotIn("CGRectMake(left, 0.0, right - left, height)", band)

    def test_image_measurement_requires_identified_original_foreground_layer(self):
        image = function_body(self.layout, "static BOOL GXKToolbarImageRect(")
        for required in ('NSClassFromString(@"GKBImageLayer")', "isKindOfClass:imageLayerClass",
                         "isKindOfClass:[UIImage class]", "respondsToSelector:@selector(image)",
                         "[(id<GXKNativeIconContent>)layer image] != image",
                         "layer.contents != (__bridge id)image.CGImage", "!image.CGImage",
                         "image.imageOrientation != UIImageOrientationUp", "image.images.count",
                         "UIEdgeInsetsEqualToEdgeInsets(image.capInsets, UIEdgeInsetsZero)", "layer.mask",
                         "CGRectEqualToRect(layer.contentsRect, CGRectMake(0, 0, 1, 1))",
                         "CGRectEqualToRect(layer.contentsCenter, CGRectMake(0, 0, 1, 1))"):
            self.assertIn(required, image)
        self.assertNotIn("view.contentMode", image)
        self.assertNotIn("view.frame", image)
        self.assertNotIn("view.bounds", image)
        self.assertNotIn("image.size", image)
        self.assertNotIn("renderInContext", image)

    def test_image_geometry_uses_layer_pixel_scale_and_only_proven_gravity(self):
        image = function_body(self.layout, "static BOOL GXKToolbarImageRect(")
        for required in ("!isfinite(layer.contentsScale)", "layer.contentsScale <= 0.0",
                         "CGImageGetWidth(image.CGImage) / layer.contentsScale",
                         "CGImageGetHeight(image.CGImage) / layer.contentsScale",
                         "layer.contentsGravity isEqualToString:kCAGravityCenter",
                         "if (![layer.contentsGravity isEqualToString:kCAGravityResizeAspect]) return NO;",
                         "MIN(bounds.size.width / size.width, bounds.size.height / size.height)",
                         "CGRectGetMidX(bounds) - size.width * 0.5", "CGRectGetMidY(bounds) - size.height * 0.5",
                         "[layer convertRect:drawn toLayer:root.layer]"):
            self.assertIn(required, image)
        self.assertNotIn("kCAGravityResizeAspectFill", image)
        finite = function_body(self.layout, "static BOOL GXKToolbarFiniteRect(")
        for required in ("!CGRectIsNull(rect)", "!CGRectIsInfinite(rect)", "!CGRectIsEmpty(rect)",
                         "isfinite(rect.origin.x)", "isfinite(rect.origin.y)",
                         "isfinite(rect.size.width)", "isfinite(rect.size.height)"):
            self.assertIn(required, finite)

    def test_image_measurement_clips_live_ancestors_and_rejects_complex_or_detached_geometry(self):
        image = function_body(self.layout, "static BOOL GXKToolbarImageRect(")
        for required in ("!root.window", "view.window != root.window", "![base isDescendantOfView:root]",
                         "![view isDescendantOfView:root]", "depth++ < 64", "ancestor = ancestor.superlayer",
                         "ancestor.hidden", "ancestor.opacity < 0.05", "ancestor.mask", "ancestor.animationKeys.count",
                         "!CATransform3DIsIdentity(ancestor.transform)",
                         "!CATransform3DIsIdentity(ancestor.sublayerTransform)",
                         "if (ancestor.masksToBounds)", "[ancestor convertRect:ancestor.bounds toLayer:root.layer]",
                         "visible = CGRectIntersection(visible, clip)", "if (!GXKToolbarFiniteRect(visible)) return NO;",
                         "if (ancestor == root.layer)", "CGRectIntersection(visible, root.layer.bounds)",
                         "[root.layer convertRect:visible toLayer:base.layer]", "!GXKToolbarIconSized(measured)"):
            self.assertIn(required, image)
        success = image.index("return YES;")
        self.assertLess(image.index("visible = CGRectIntersection(visible, clip)"), success)
        self.assertLess(image.index("if (ancestor == root.layer)"), success)
        self.assertEqual(image.count("return YES;"), 1)
        self.assertIn("if (outRect) *outRect = CGRectZero;", image)
        self.assertIn("if (outRect) *outRect = measured;", image)
        code = re.sub(r"//[^\n]*", "", image)
        self.assertNotRegex(code, r"\.(?:bounds|frame|hidden|opacity|transform|sublayerTransform|mask|contentsScale|contentsGravity)\s*=(?!=)")
        self.assertRegex(code, r"return NO;\s*}\s*$")

    def test_glyph_requires_live_measured_image_and_complete_bounded_scan(self):
        collect = function_body(self.layout, "static void GXKToolbarGlyphCollect(")
        for required in ("GXKToolbarImageRect(sub, base, &rect)", "visited++ < 128",
                         "[out addObject:[NSValue valueWithCGRect:rect]]", "if (pending.count) [out removeAllObjects]"):
            self.assertIn(required, collect)
        self.assertNotIn("convertRect:sub.bounds", collect)
        glyph = function_body(self.layout, "static BOOL GXKToolbarGlyphRect(")
        for required in ("GXKToolbarGlyphCollect(view, base, found)", "CGFloat bottom = CGRectGetMaxY(rect);",
                         "bottom > bestBottom + 0.5", "if (better)", "if (bestArea <= 0.0) return NO;"):
            self.assertIn(required, glyph)
        self.assertNotIn("CGRectUnion", glyph)
        self.assertNotIn("if (area > bestArea)", glyph)
        self.assertNotIn("view.bounds", glyph)
        self.assertNotIn("fallback-square", re.sub(r"//[^\n]*", "", glyph))
        sized = function_body(self.layout, "static BOOL GXKToolbarIconSized(")
        for limit in ("size.width >= 8.0", "size.height >= 8.0", "size.width <= 64.0", "size.height <= 64.0"):
            self.assertIn(limit, sized)

    def test_logo_selection_requires_complete_nine_key_scan_not_tree_order(self):
        scan = function_body(self.layout, "static BOOL GXKToolbarScan(")
        for required in ("NSMutableArray<NSArray *> *logoCandidates", "if (stack.count || !body || qwertyVisible || !logoCandidates.count) return NO;",
                         "if (!GXKToolbarGlyphRect(view, root, &glyph) || CGRectIsEmpty(glyph))",
                         "CGRect bodyRect = [body convertRect:body.bounds toView:root];",
                         "CGFloat gap = CGRectGetMinY(bodyRect) - CGRectGetMaxY(glyph);",
                         "BOOL better = (!logo || gap < bestGap - 0.5)"):
            self.assertIn(required, scan)
        self.assertLess(scan.index("isKindOfClass:nineClass"), scan.index("isKindOfClass:qwertyClass"))
        self.assertNotIn("if (!logo && [view isKindOfClass:logoClass]", scan)

    def test_root_host_coordinates_do_not_grow_or_repaint_native_keyboard(self):
        update = function_body(self.source, "static void GXKUpdateToolbar(UIViewController *vc) {")
        for required in ("[row convertRect:band toView:root]", "gToolbarHost = root;",
                         "[root addSubview:stack]", "gToolbarBand = band;",
                         "constraintEqualToAnchor:root.leadingAnchor constant:hostBand.origin.x - root.bounds.origin.x",
                         "constraintEqualToAnchor:root.topAnchor constant:hostBand.origin.y - root.bounds.origin.y",
                         "[stack.heightAnchor constraintEqualToConstant:hostBand.size.height]"):
            self.assertIn(required, update)
        self.assertNotIn("[row addSubview:stack]", update)
        self.assertNotRegex(update, r"\[(?:root|row|body|logo)\.heightAnchor\s+constraint")
        self.assertNotRegex(update, r"(?:root|row|body|logo)\.(?:frame|bounds|alpha|hidden|backgroundColor)\s*=(?!=)")
        self.assertNotIn("GXKToolbarSurface", self.source)
        make = function_body(self.source, "static UIStackView *GXKMakeToolbar(")
        self.assertIn("stack.backgroundColor = [UIColor clearColor];", make)
        self.assertIn("stack.backgroundColor = [UIColor clearColor];", update)

    def test_toolbar_cache_includes_fresh_glyph_and_root_geometry(self):
        band = function_body(self.layout, "static BOOL GXKToolbarBand(")
        for required in ("gToolbarBandCacheSignature == signature", "gToolbarBandCacheEpoch == gToolbarBandEpoch",
                         "CGSizeEqualToSize(gToolbarBandCacheRowSize, row.bounds.size)",
                         "CGRectEqualToRect(gToolbarBandCacheGlyph, glyph)",
                         "CGRectEqualToRect(gToolbarBandCacheRowInRoot, rowInRoot)",
                         "CGRectEqualToRect(gToolbarBandCacheRootBounds, root.bounds)",
                         "gToolbarBandCacheGlyph = glyph;", "gToolbarBandCacheRowInRoot = rowInRoot;",
                         "gToolbarBandCacheRootBounds = root.bounds;", "return gToolbarBandCacheHit;"):
            self.assertIn(required, band)
        self.assertLess(band.index("GXKToolbarGlyphRect(logo, row, &glyph)"), band.index("if (gToolbarBandCacheValid &&"))
        self.assertLess(band.index("if (gToolbarBandCacheValid &&"), band.index("CGFloat left = 0.0;"))
        detach = function_body(self.source, "static void GXKDetachToolbar(void) {")
        self.assertIn("gToolbarBandEpoch++;", detach)
        self.assertIn("gToolbarBandCacheValid = NO;", detach)

    def test_fast_toolbar_reuse_rechecks_style_band_and_native_content(self):
        update = function_body(self.source, "static void GXKUpdateToolbar(UIViewController *vc) {")
        fast = update[:update.index("UIView *row = nil")]
        for required in ("gToolbarHost == root", "gToolbarStack.superview == root",
                         "GXKSyncToolbarStyle(gToolbarNineBody)", "GXKToolbarBand(gToolbarRow, gToolbarLogoView, root, &band)",
                         "GXKToolbarNativeSpaceClear(root, gToolbarLogoView, hostBand)",
                         "if (composing || !clear)", "gToolbarStack.hidden = YES;"):
            self.assertIn(required, fast)
        self.assertLess(fast.index("GXKToolbarNativeSpaceClear"), fast.index('"fast-unchanged"'))
        self.assertIn("stack.hidden = composing || !clear;", update)


if __name__ == "__main__":
    unittest.main(verbosity=2)
