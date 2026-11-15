"""Offline contracts for the injected action key; no claim of UIKit execution.

Run exactly this file, not discovery over legacy gkx-test-* directories:
    python tests/test_action_key.py
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "dylib/gkx.m"


def function_body(source, signature):
    """Read a bounded function implementation, including nested braces."""
    start = source.index(signature)
    start = source.index("{", start)
    level = 1
    end = start + 1
    while level and end < len(source):
        level += (source[end] == "{") - (source[end] == "}")
        end += 1
    if level:
        raise AssertionError(f"Unterminated function: {signature}")
    return source[start + 1:end - 1]


class ActionKeySourceContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = SOURCE.read_text(encoding="utf-8")

    def test_newline_is_a_newline_not_backslash_n(self):
        self.assertIn('[proxy insertText:@"\\n"]', self.source)
        self.assertNotIn('[proxy insertText:@"\\\\n"]', self.source)

    def test_no_coordinate_or_dictionary_fallback_for_key_identity(self):
        finder = function_body(self.source, "static UIView *GXKFindNineKeyEmojiKey(UIView *root)")
        self.assertIn("restorationIdentifier", finder)
        self.assertIn("GXKEmojiKeyID", finder)
        for retired in ("allSoftKeys", "_allSoftKeys", "rightColX", "maxCandidateY", "99999", "bestCandidate"):
            self.assertNotIn(retired, self.source)

    def test_body_classification_checks_nine_before_qwerty(self):
        owner = function_body(self.source, "static UIView *GXKNineKeyBodyForKey(UIView *key, UIView *root)")
        self.assertLess(owner.index("GKB9KeysSoftKeyboardView"), owner.index("GKBZhQwertySoftKeyboardView"))
        self.assertIn("return nil", owner)

    def test_ambiguous_visible_emoji_is_not_chosen_by_tree_order(self):
        finder = function_body(self.source, "static UIView *GXKFindNineKeyEmojiKey(UIView *root)")
        self.assertRegex(finder, r"if\s*\(candidate\s*&&\s*candidate\s*!=\s*v\)\s*return nil")

    def test_layout_boundary_revalidates_key(self):
        layout = function_body(self.source, "static void gkx_viewDidLayoutSubviews(id self, SEL _cmd)")
        self.assertIn("gOrigViewDidLayoutSubviews", layout)
        self.assertIn("GXKUpdateActionKey", layout)

    def test_tap_revalidates_sender_identity_and_binding(self):
        tap = function_body(self.source, "- (void)onActionKeyTapped:(UIButton *)sender")
        self.assertIn("sender != gActionKeyButton", tap)
        self.assertIn("GXKFindNineKeyEmojiKey", tap)
        self.assertIn("softKeyDef", tap)
        self.assertIn("gActionSoftKeyDef", tap)

    def test_native_keycap_is_not_hidden_or_repainted(self):
        action = self.source[self.source.index("#pragma mark - 动作键目标与更新"):]
        for retired in ("GXKRestoreKeySubviews", "sub.hidden = YES", "sub.hidden = NO", "cornerRadius", "colorWithWhite:0.35", "colorWithRed:0.82", "userInterfaceStyle"):
            self.assertNotIn(retired, action)
        update = function_body(self.source, "static void GXKUpdateActionKey(UIViewController *vc) {")
        self.assertIn("[UIColor clearColor]", update)

    def test_keyboard_touch_methods_are_not_swizzled(self):
        initialization = function_body(self.source, "static void gkx_init(void)")
        for event in ("touchesBegan", "touchesMoved", "touchesEnded", "hitTest"):
            self.assertNotIn(event, initialization)

    def test_disappearance_releases_controller_and_binding(self):
        disappear = function_body(self.source, "static void gkx_viewWillDisappear(id self, SEL _cmd, BOOL animated)")
        self.assertIn("GXKDetachActionKey", disappear)
        self.assertIn("gCurrentVC = nil", disappear)
        # 停表职责收敛到 GXKStopPolling：这里必须调用它，invalidate 在它体内。
        self.assertIn("GXKStopPolling()", disappear)
        stop = function_body(self.source, "static void GXKStopPolling(void) {")
        self.assertIn("invalidate", stop)
        self.assertLess(disappear.index("gCurrentVC = nil"), disappear.index("gOrigViewWillDisappear(self"))

    def test_incomplete_or_detached_tree_fails_closed(self):
        finder = function_body(self.source, "static UIView *GXKFindNineKeyEmojiKey(UIView *root)")
        visible = function_body(self.source, "static BOOL GXKKeyIsVisible(UIView *key, UIView *root)")
        self.assertIn("if (stack.count ||", finder)
        self.assertIn("GXKNineKeyBodyForKey(candidate, root) != visibleBody", finder)
        self.assertIn("v.window != root.window", finder)
        self.assertIn("key.window != root.window", visible)
        self.assertIn("CGRectIntersection", visible)
        self.assertIn("v.clipsToBounds", visible)

    def test_native_icon_uses_verified_content_not_generic_hidden_views(self):
        icon = function_body(self.source, "static UIView<GXKNativeIconContent> *GXKNativeIconForKey(UIView *key)")
        self.assertIn('contents[@"image"]', icon)
        self.assertIn("GKBImageViewWithBackground", icon)
        self.assertIn("isDescendantOfView:key", icon)
        self.assertIn("setHighlightedImage:", icon)
        self.assertNotIn("UIImageView", icon)
        self.assertNotIn("clearLabelAndIcons", self.source)
        self.assertIsNone(re.search(r"softKeyDef\s*=(?!=)", self.source), "Native softKeyDef must remain read-only")

    def test_saved_foregrounds_are_restricted_to_same_native_identity(self):
        detach = function_body(self.source, "static void GXKDetachActionKey(void)")
        identity = detach.index("oldKey.restorationIdentifier")
        normal_restore = detach.index("oldIcon.image = normalImage")
        highlight_restore = detach.index("oldIcon.highlightedImage = highlightedImage")
        self.assertLess(identity, normal_restore)
        self.assertLess(identity, highlight_restore)
        self.assertIn("softKeyDef == oldModel", detach)
        self.assertIn("GXKNativeIconForKey(oldKey) == oldIcon", detach)
        self.assertIn("oldKey.hidden = wasHidden", detach)
        self.assertIn("gActionNormalImage = nil", detach)
        self.assertIn("gActionHighlightedImage = nil", detach)

    def test_rebinding_creates_fresh_button_after_detaching(self):
        update = function_body(self.source, "static void GXKUpdateActionKey(UIViewController *vc) {")
        create = update.index("[UIButton buttonWithType:UIButtonTypeCustom]")
        self.assertLess(update.index("GXKDetachActionKey();", update.index("gEmojiSoftKeyView != currentKey")), create)
        self.assertIn("gActionSoftKeyDef != model", update)
        self.assertIn("gActionKeyButton.superview != host", update)
        self.assertIn("GXKActionHostForKey(currentKey)", update)
        self.assertNotIn("[currentKey addSubview:btn]", update)
        self.assertIn("[currentKey convertRect:currentKey.bounds toView:host]", update)
        self.assertIn("gUpdatingActionKey", update)

    def test_native_theme_and_both_titles_keep_same_transparent_style(self):
        update = function_body(self.source, "static void GXKUpdateActionKey(UIViewController *vc) {")
        self.assertIn("icon.foregroundColor", update)
        self.assertIn("GXKNativeActionFont", update)
        self.assertIn("setTitleColor:color forState:UIControlStateNormal", update)
        self.assertIn("setTitleColor:color forState:UIControlStateHighlighted", update)
        self.assertIn("btn.accessibilityLabel = title", update)
        self.assertNotRegex(update, r"(?:currentKey|icon|root)\.(?:frame|bounds|backgroundColor)\s*=")
        self.assertNotIn("backgroundLayer", re.sub(r"//[^\n]*", "", update))

    def test_mixed_peer_bodies_fail_closed_but_nested_fixed_body_is_not_a_peer(self):
        finder = function_body(self.source, "static UIView *GXKFindNineKeyEmojiKey(UIView *root)")
        self.assertIn("GKB9KeysSoftKeyboardView", finder)
        self.assertIn("GKBZhQwertySoftKeyboardView", finder)
        self.assertIn("GKBSoftKeyboardViewWithFixedLayout", finder)
        self.assertIn("isPeerBody && GXKKeyIsVisible(v, root)", finder)
        self.assertIn("if (!visibleBody) visibleBody = v", finder)
        self.assertIn("else if (![v isDescendantOfView:visibleBody]) return nil", finder)
        self.assertIn("![visibleBody isKindOfClass:nineClass]", finder)
        self.assertIn("GXKNineKeyBodyForKey(candidate, root) != visibleBody", finder)

    def test_rebinding_rescans_controller_root_and_key_after_native_refresh(self):
        update = function_body(self.source, "static void GXKUpdateActionKey(UIViewController *vc) {")
        rebind = update[update.index("gEmojiSoftKeyView != currentKey"):]
        detach = rebind.index("GXKDetachActionKey();")
        controller = rebind.index("vc != gCurrentVC || !vc.isViewLoaded || vc.view != root", detach)
        select = rebind.index("currentKey = GXKFindNineKeyEmojiKey(root)", controller)
        content = rebind.index("icon = GXKNativeIconForKey(currentKey)", select)
        create = rebind.index("[UIButton buttonWithType:UIButtonTypeCustom]", content)
        self.assertLess(detach, controller)
        self.assertLess(controller, select)
        self.assertLess(select, content)
        self.assertLess(content, create)

    def test_empty_native_model_is_rejected_on_updates_and_taps(self):
        predicate = function_body(self.source, "static BOOL GXKModelHasNativeActions(id model)")
        self.assertIn("respondsToSelector:@selector(actionsArray)", predicate)
        self.assertIn("isKindOfClass:[NSArray class]", predicate)
        self.assertIn("actions.count > 0", predicate)
        self.assertNotIn("setActions", predicate)
        tap = function_body(self.source, "- (void)onActionKeyTapped:(UIButton *)sender")
        update = function_body(self.source, "static void GXKUpdateActionKey(UIViewController *vc) {")
        self.assertIn("!GXKModelHasNativeActions(gActionSoftKeyDef)", tap)
        self.assertGreaterEqual(update.count("!GXKModelHasNativeActions(model)"), 2)

    def test_fresh_binding_requires_current_foreground_not_previous_images(self):
        update = function_body(self.source, "static void GXKUpdateActionKey(UIViewController *vc) {")
        fresh = update[update.index("gEmojiSoftKeyView != currentKey"):update.index("[UIButton buttonWithType:UIButtonTypeCustom]")]
        self.assertIn("[icon.image isKindOfClass:[UIImage class]]", fresh)
        self.assertIn("[icon.highlightedImage isKindOfClass:[UIImage class]]", fresh)
        self.assertIn("!hasForeground", fresh)
        self.assertNotIn("gActionNormalImage", fresh)
        self.assertNotIn("gActionHighlightedImage", fresh)

    def test_font_lookup_does_not_construct_array_with_nil_owner(self):
        font = function_body(self.source, "static UIFont *GXKNativeActionFont(UIView *key, UIView *root)")
        self.assertLess(font.index("if (!body) return"), font.index("arrayWithObject:body"))

    def test_queued_updates_are_bound_to_original_controller(self):
        tap = function_body(self.source, "- (void)onActionKeyTapped:(UIButton *)sender")
        changed = function_body(self.source, "static void gkx_textDidChange(id self, SEL _cmd, id textInput)")
        self.assertIn("__weak UIViewController *weakVC = vc", tap)
        self.assertIn("currentVC == gCurrentVC", tap)
        self.assertIn("UIViewController *vc = weakVC", changed)
        self.assertIn("vc == gCurrentVC", changed)


if __name__ == "__main__":
    unittest.main(verbosity=2)
