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

    def test_toolbar_decorations_scanned_once_per_band(self):
        """同一 band 只扫一次装饰，没东西可藏时不再每拍重走 800 节点。"""
        self.assertIn("static BOOL gToolbarDecorationsScanned;", self.source)
        self.assertIn("static CGRect gToolbarDecorationsBand;", self.source)
        sync = function_body(self.source, "static void GXKSyncToolbarDecorations(BOOL composing) {")
        self.assertIn("gToolbarDecorationsScanned", sync)
        self.assertIn("CGRectEqualToRect(gToolbarDecorationsBand, gToolbarBand)", sync)
        self.assertIn("gToolbarDecorationsBand = gToolbarBand;", sync)
        # 归还装饰时必须清掉扫描备忘，否则下次挂载会漏扫。
        restore = function_body(self.source, "static void GXKRestoreToolbarDecorations(void) {")
        self.assertIn("gToolbarDecorationsScanned = NO;", restore)

    def test_toolbar_reuses_stack_and_constraints(self):
        """同一宿主行复用 stack 与按钮，约束先撤后加，不层层叠加。"""
        self.assertIn("static NSArray<NSLayoutConstraint *> *gToolbarConstraints;", self.source)
        update = function_body(self.source, "static void GXKUpdateToolbar(UIViewController *vc) {")
        self.assertIn("BOOL reuse = (gToolbarStack && gToolbarRow == row", update)
        self.assertIn("UIStackView *stack = reuse ? gToolbarStack : GXKMakeToolbar(row, tint);", update)
        self.assertIn("deactivateConstraints:gToolbarConstraints", update)
        self.assertIn("activateConstraints:gToolbarConstraints", update)
        # 重建路径必须先撤掉旧约束；两条路径都不得漏掉旧约束。
        # 扫描失败分支更早就会 GXKDetachToolbar()，这里只看复用判定之后那一次。
        self.assertLess(update.index("BOOL reuse ="),
                        update.index("GXKDetachToolbar();", update.index("BOOL reuse =")))
        detach = function_body(self.source, "static void GXKDetachToolbar(void) {")
        self.assertIn("deactivateConstraints:gToolbarConstraints", detach)
        self.assertIn("gToolbarConstraints = nil;", detach)

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
            body = function_body(self.source, signature)
            self.assertNotIn("NSClassFromString", body, signature)
            self.assertIn("GXKClassCached(", body, signature)

    def test_toolbar_band_starts_right_of_logo_and_matches_icon_height(self):
        """工具条贴 G 图标右侧、竖向对齐图标本身，而不是另起一条横贯整行的带。"""
        band = function_body(self.source, "static BOOL GXKToolbarBand(UIView *row, UIView *logo, UIView *root, CGRect *outBand) {")
        # 左边界必须被推到 G 图形右缘之后：压在图形上就得把它 alpha 归零，
        # 而归零后会露出图标底图，真机上表现为"条下面又冒出半个 G"。
        # 必须用图形矩形而不是 logo 视图矩形：视图常是整行宽，用视图右缘会把
        # left 推到整行之外，宽度不足 200pt，工具条整条消失（真机实测）。
        self.assertIn("if (GXKToolbarGlyphRect(logo, row, &glyphInRow)) glyph = glyphInRow;", band)
        # 邻居左右也按图形矩形判：logo 视图整行宽时，右边界会落到行末盖住功能图标。
        self.assertIn("if (CGRectGetMaxX(r) <= CGRectGetMinX(glyph) + 0.5) {", band)
        self.assertIn("} else if (CGRectGetMinX(r) >= CGRectGetMaxX(glyph) - 0.5) {", band)
        self.assertLess(band.index("if (GXKToolbarGlyphRect(logo, row, &glyphInRow))"), band.index("CGFloat left = 0.0;"))
        self.assertIn("CGFloat iconRight = CGRectGetMaxX(glyph);", band)
        self.assertIn("if (iconRight > left) left = iconRight + 4.0;", band)
        # 竖向取图形高度并居中；拿不到图形高度才退回整行。
        self.assertIn("CGFloat barHeight = glyph.size.height;", band)
        # 图形可能只有 20pt，条高兜底 28pt，否则 16pt 的字会被挤扁。
        self.assertIn("if (barHeight < 28.0) barHeight = 28.0;", band)
        self.assertIn("CGFloat top = CGRectGetMidY(glyph) - barHeight * 0.5;", band)
        # 图形矩形取 logo 子树里面积最大的图标级图片矩形。
        # 真机实测：并集整行底图会把竖向中心拉到行中间，文字比 G 图标高一行；
        # 而 logo.frame 本身也可能偏上一截，所以两者都不能直接信。
        glyph = function_body(self.source, "static BOOL GXKToolbarGlyphRect(UIView *view, UIView *base, CGRect *outRect) {")
        self.assertIn("GXKToolbarGlyphCollect(view, base, found)", glyph)
        self.assertIn("if (area > bestArea) {", glyph)
        self.assertIn("if (!CGRectIsEmpty(own) && !CGRectIntersectsRect(rect, own)) continue;", glyph)
        self.assertNotIn("CGRectUnion", glyph)
        # logo 在真机上会出现两次（头行一个、候选行一个），必须按图形面积挑，
        # 不能"第一个命中就用"。
        scan = function_body(self.source, "static BOOL GXKToolbarScan(UIView *root, UIView **outRow, UIView **outLogo, UIView **outBody, CGRect *outBand) {")
        self.assertIn("CGFloat bestGlyphArea = 0.0;", scan)
        self.assertIn("if (better) {", scan)
        self.assertIn("bestGlyphArea = area;", scan)
        self.assertNotIn("if (!logo && [view isKindOfClass:logoClass]", scan)
        collect = function_body(self.source, "static void GXKToolbarGlyphCollect(UIView *view, UIView *base, NSMutableArray<NSValue *> *out) {")
        self.assertIn("isKindOfClass:[UIImageView class]", collect)
        self.assertIn("convertRect:sub.bounds toView:base", collect)
        # 整行宽的底图不是图标，必须按尺寸排除，否则竖向中心会被它拉偏。
        sized = function_body(self.source, "static BOOL GXKToolbarIconSized(CGRect rect) {")
        self.assertIn("size.width <= 64.0", sized)
        self.assertIn("size.height <= 64.0", sized)
        self.assertIn("CGRectMake(left, top, right - left, barHeight)", band)
        # 不再整行满高：满高就是用户截图里那条突兀的横带。
        self.assertNotIn("CGRectMake(left, 0.0, right - left, height)", band)

    def test_toolbar_has_no_opaque_background(self):
        """工具条不铺不透明底色，也不再对 G 图标做 alpha 归零。"""
        self.assertNotIn("GXKToolbarSurface", self.source)
        make = function_body(self.source, "static UIStackView *GXKMakeToolbar(UIView *row, UIColor *tint) {")
        self.assertIn("stack.backgroundColor = [UIColor clearColor];", make)
        update = function_body(self.source, "static void GXKUpdateToolbar(UIViewController *vc) {")
        self.assertIn("stack.backgroundColor = [UIColor clearColor];", update)
        self.assertNotIn("logo.alpha = 0.0;", update)
        # 挂载点必须用 band 的竖向偏移，否则 band 算对了也贴不到图标那一行。
        self.assertIn("constraintEqualToAnchor:row.topAnchor constant:band.origin.y", update)

    def test_toolbar_band_reuses_result_when_neighbours_unchanged(self):
        """邻居几何没变就不重新沿父链算可见性，band 直接复用上次结果。"""
        self.assertIn("static NSUInteger gToolbarBandEpoch;", self.source)
        band = function_body(self.source, "static BOOL GXKToolbarBand(UIView *row, UIView *logo, UIView *root, CGRect *outBand) {")
        self.assertIn("gToolbarBandCacheSignature == signature", band)
        self.assertIn("gToolbarBandCacheEpoch == gToolbarBandEpoch", band)
        self.assertIn("CGSizeEqualToSize(gToolbarBandCacheRowSize, row.bounds.size)", band)
        # 缓存命中必须提前返回，且返回的是上次的判定结果。
        self.assertLess(band.index("if (gToolbarBandCacheValid &&"), band.index("CGFloat left = 0.0;"))
        self.assertIn("return gToolbarBandCacheHit;", band)
        # 挂载与撤走都会改变邻居集合，必须让缓存失效。
        detach = function_body(self.source, "static void GXKDetachToolbar(void) {")
        self.assertIn("gToolbarBandEpoch++;", detach)
        self.assertIn("gToolbarBandCacheValid = NO;", detach)
        restore = function_body(self.source, "static void GXKRestoreToolbarDecorations(void) {")
        self.assertIn("gToolbarBandEpoch++;", restore)
        self.assertIn("gToolbarBandCacheValid = NO;", restore)


if __name__ == "__main__":
    unittest.main(verbosity=2)
