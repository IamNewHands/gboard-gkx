#!/usr/bin/env python3
"""Static diagnostic contracts; these do not execute UIKit or prove on-device behavior."""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def function_body(source, signature):
    start = source.index(signature)
    brace = source.index("{", start)
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if not depth:
                return source[start:index + 1]
    raise AssertionError(f"unbalanced braces for {signature}")


class ToolbarDiagnosticContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.main = (ROOT / "dylib/gkx.m").read_text(encoding="utf-8")
        cls.diag = (ROOT / "dylib/toolbar_diagnostics.h").read_text(encoding="utf-8")
        cls.layout = (ROOT / "dylib/toolbar_layout.h").read_text(encoding="utf-8")
        cls.visibility = (ROOT / "dylib/toolbar_visibility.h").read_text(encoding="utf-8")
        cls.code = re.sub(r"//[^\n]*", "", cls.diag)

    def body(self, name):
        return function_body(self.diag, name)

    def test_helper_is_included_after_style_before_toolbar_creation(self):
        include = self.main.index('#import "toolbar_diagnostics.h"')
        self.assertLess(self.main.index("static UIColor *GXKToolbarTextStyle"), include)
        self.assertLess(include, self.main.index("static UIStackView *GXKMakeToolbar"))

    def test_actual_style_selection_records_weak_source_without_new_scan(self):
        self.assertIn("static __weak UILabel *gToolbarStyleSource;", self.main)
        style = function_body(self.main, "static UIColor *GXKToolbarTextStyle")
        self.assertIn("UILabel *label = GXKNativeKeyStyleLabel(body, root);", style)
        self.assertRegex(style, r"\*outFont = label\.font \?: GXKNativeKeyFont\(body, root\);\s*gToolbarStyleSource = label;")
        self.assertNotIn("arrayWithObject:", style)
        self.assertNotIn("GXKToolbarTextStyle(", self.code)

    def test_band_observer_records_unclamped_measured_geometry_without_owning_math(self):
        band = function_body(self.layout, "static BOOL GXKToolbarBand(")
        observed = band.index("GXKToolbarDiagnosticBandObserved(row, logo, glyph, top)")
        self.assertLess(band.index("CGFloat top = CGRectGetMidY(glyph) - barHeight * 0.5;"), observed)
        self.assertLess(observed, band.index("CGRect candidate = CGRectMake(left, top, right - left, barHeight)"))
        for expression in ("barHeight < 28.0", "right - left >= 200.0", "CGRectContainsRect(root.bounds, candidateInRoot)"):
            self.assertIn(expression, band)
        self.assertNotIn("barHeight > height", band)
        self.assertNotIn("if (top < 0.0)", band)
        observer = self.body("static void GXKToolbarDiagnosticBandObserved")
        for value in ("gToolbarDiagnosticBandRow = row;", "gToolbarDiagnosticBandLogo = logo;",
                      "gToolbarDiagnosticUsedGlyph = glyph;", "gToolbarDiagnosticUnclampedTop = unclampedTop;"):
            self.assertIn(value, observer)
        self.assertNotIn("GXKToolbarGlyphRect(", observer)
        self.assertIn("usedValid=", self.diag)

    def test_glyph_anchor_reuses_layout_owner_without_local_fallback(self):
        glyph = self.body("static NSString *GXKToolbarDiagnosticGlyph")
        self.assertIn("if (!logo || !row || logo.superview != row)", glyph)
        self.assertIn("BOOL measured = GXKToolbarGlyphRect(logo, row, outGlyph);", glyph)
        self.assertLess(glyph.index("GXKToolbarGlyphRect(logo, row, outGlyph)"),
                        glyph.index("while (pending.count"))
        self.assertIn("BOOL valid = GXKToolbarImageRect(view, row, &rect);", glyph)
        self.assertIn("mode=visible-native-layer measured=%d", glyph)
        self.assertIn("NSStringFromCGRect(*outGlyph)", glyph)
        # Detail may describe view bounds, but cannot replace the owner's picked geometry.
        self.assertEqual(["*outGlyph = CGRectZero;"], re.findall(r"\*outGlyph\s*=[^;]*;", glyph))
        for retired in ("fallback-square", "contentMode", "bestBottom", "bestArea", "CGRectMake(", "alignmentRectInsets"):
            self.assertNotIn(retired, glyph)

    def test_layer_evidence_is_bounded_current_and_preserves_original_contents_identity(self):
        glyph = self.body("static NSString *GXKToolbarDiagnosticGlyph")
        self.assertIn("[image isKindOfClass:[UIImage class]]", glyph)
        self.assertIn("CALayer *layer = view.layer;", glyph)
        self.assertRegex(glyph, r"for \(CALayer \*ancestor = layer; ancestor && depth\+\+ < 16; ancestor = ancestor\.superlayer\)")
        self.assertIn("if (ancestor == gCurrentVC.view.layer) { layerChainReachedRoot = YES; break; }", glyph)
        for evidence in ("layer.contentsGravity", "layer.contentsScale", "layer.contents == (__bridge id)image.CGImage",
                         "layer.contentsRect", "layer.contentsCenter", "image.capInsets", "image.imageOrientation",
                         "ancestor.bounds", "ancestor.position", "ancestor.masksToBounds", "ancestor.mask != nil",
                         "ancestor.hidden", "ancestor.opacity", "ancestor.animationKeys.count > 0",
                         "CATransform3DIsIdentity(ancestor.transform)"):
            self.assertIn(evidence, glyph)
        for field in ("visible=", "viewRow=", "layerImageAPI=", "gravity=", "contentsScale=", "contentsMatch=",
                      "contentsRect=", "contentsCenter=", "capInsets=", "orientation=", "masks=", "animated="):
            self.assertIn(field, glyph)

    def test_shared_measurement_and_layer_detail_remain_read_only(self):
        glyph = self.body("static NSString *GXKToolbarDiagnosticGlyph")
        for forbidden in ("setImage:", "setContents:", "setOpacity:", "addSublayer:", "removeFromSuperlayer",
                          "renderInContext:", "UIGraphics", "CGContext", "CGImageCreate", "GXKToolbarBand(",
                          "GXKNativeKeyFont(", "GXKToolbarNativeSpaceClear(", "GXKUpdateToolbar("):
            self.assertNotIn(forbidden, glyph)
        self.assertNotRegex(glyph, r"\.(?:image|contents|contentsScale|contentsGravity|contentsRect|contentsCenter|"
                           r"mask|masksToBounds|hidden|opacity|bounds|position|transform|sublayerTransform)\s*=(?!=)")

    def test_used_geometry_requires_current_tree_binding_not_freshness(self):
        snapshot = self.body("static NSString *GXKToolbarDiagnosticSnapshot")
        for binding in ("root && row && logo", "logo.superview == row",
                        "row == root || [row isDescendantOfView:root]",
                        "row == gToolbarDiagnosticBandRow", "logo == gToolbarDiagnosticBandLogo"):
            self.assertIn(binding, snapshot)
        self.assertIn("NOT geometry freshness", self.diag)
        self.assertIn("Start/stop snapshots are immediate", self.diag)

    def test_toolbar_copy_has_opt_in_gesture_and_began_is_single_action(self):
        make = function_body(self.main, "static UIStackView *GXKMakeToolbar")
        self.assertIn("if (i == 1)", make)
        self.assertIn("diagnostic.minimumPressDuration = 0.8;", make)
        self.assertIn("diagnostic.cancelsTouchesInView = YES;", make)
        handler = function_body(self.main, "- (void)onToolbarDiagnostic:(UILongPressGestureRecognizer *)gesture {")
        self.assertIn("gesture.state != UIGestureRecognizerStateBegan", handler)
        self.assertIn("vc != gCurrentVC", handler)
        self.assertIn("containsObject:button", handler)
        self.assertIn("GXKToolbarDiagnosticToggle", handler)

    def test_independent_entry_does_not_depend_on_toolbar_binding(self):
        handler = function_body(self.main, "- (void)onActionKeyDiagnostic:(UILongPressGestureRecognizer *)gesture {")
        for guard in ("gesture.state != UIGestureRecognizerStateBegan", "vc.isViewLoaded",
                      "button != gActionKeyButton", "button.superview != gActionHost",
                      "GXKKeyIsVisible(button, vc.view)", "GXKNineKeyBodyForKey(gEmojiSoftKeyView, vc.view)",
                      "GXKActionHostForKey(gEmojiSoftKeyView) != gActionHost",
                      "GXKNativeIconForKey(gEmojiSoftKeyView) != gActionNativeIcon",
                      "softKeyDef != gActionSoftKeyDef", "GXKModelHasNativeActions(gActionSoftKeyDef)"):
            self.assertIn(guard, handler)
        self.assertIn("GXKToolbarDiagnosticToggle(vc, button)", handler)
        for forbidden in ("gToolbarTarget", "gToolbarStack", "gToolbarRow", "insertText:", "deleteBackward", "onActionKeyTapped"):
            self.assertNotIn(forbidden, handler)
        update = function_body(self.main, "static void GXKUpdateActionKey(UIViewController *vc) {")
        self.assertIn("initWithTarget:gActionTarget action:@selector(onActionKeyDiagnostic:)", update)
        self.assertIn("diagnostic.minimumPressDuration = 0.8;", update)
        self.assertIn("diagnostic.cancelsTouchesInView = YES;", update)
        self.assertIn("[btn addGestureRecognizer:diagnostic];", update)
        self.assertIn("action:@selector(onActionKeyTapped:) forControlEvents:UIControlEventTouchUpInside", update)
        self.assertNotRegex(update, r"\[(?:root|host|currentKey|icon) addGestureRecognizer:")

    def test_feedback_is_protected_in_both_action_key_paths(self):
        update = function_body(self.main, "static void GXKUpdateActionKey(UIViewController *vc) {")
        for button in ("cheapBtn", "btn"):
            self.assertIn(button + " == gToolbarDiagnosticFeedbackButton && GXKToolbarDiagnosticNow() < gToolbarDiagnosticFeedbackUntil", update)
        toggle = self.body("static void GXKToolbarDiagnosticToggle")
        self.assertEqual(2, toggle.count("GXKToolbarDiagnosticFeedback(vc, button,"))
        feedback = self.body("static void GXKToolbarDiagnosticFeedback")
        self.assertIn("generation = ++gToolbarDiagnosticFeedbackGeneration", feedback)
        self.assertIn("generation != gToolbarDiagnosticFeedbackGeneration", feedback)
        restore = self.body("static BOOL GXKToolbarDiagnosticRestoreFeedbackTitle")
        self.assertIn("liveVC.view != root", restore)
        self.assertIn("live != gActionKeyButton", restore)
        self.assertIn('GXKComposingStateCached(liveVC) ? @"重输" : @"换行"', restore)
        self.assertIn("forState:UIControlStateHighlighted", restore)
        self.assertNotIn("original", re.sub(r"//[^\n]*", "", feedback + restore))
        self.assertNotIn("GXKFlashTitle", toggle)
        shared, action = restore.split("if (actionKey) {", 1)
        self.assertNotIn("GXKKeyIsVisible", shared)
        self.assertIn("![live isDescendantOfView:liveVC.view]", shared)
        self.assertIn("GXKKeyIsVisible(live, liveVC.view)", action)
        self.assertIn("else if (![gToolbarStack.arrangedSubviews containsObject:live]) return NO;", action)
        self.assertIn("GXKToolbarDiagnosticRestoreFeedbackTitle(weakVC, live, weakRoot, actionKey)", feedback)

    def test_cross_button_feedback_restores_previous_before_superseding_generation(self):
        feedback = self.body("static void GXKToolbarDiagnosticFeedback(")
        self.assertIn("previous && previous != button", feedback)
        restore = feedback.index("GXKToolbarDiagnosticRestoreFeedbackTitle(gToolbarDiagnosticFeedbackOwner, previous,")
        self.assertLess(restore, feedback.index("gToolbarDiagnosticFeedbackButton = button;"))
        self.assertLess(restore, feedback.index("++gToolbarDiagnosticFeedbackGeneration"))
        self.assertIn("gToolbarDiagnosticFeedbackRoot, gToolbarDiagnosticFeedbackActionKey", feedback)
        self.assertIn("gToolbarDiagnosticFeedbackRoot = vc.view;", feedback)
        self.assertIn("static __weak UIViewController *gToolbarDiagnosticFeedbackOwner;", self.diag)
        self.assertIn("static __weak UIView *gToolbarDiagnosticFeedbackRoot;", self.diag)

    def test_copy_error_flash_cannot_restore_diagnostic_title_or_overwrite_new_feedback(self):
        flash = function_body(self.main, "static void GXKFlashTitle(")
        self.assertIn("NSString *original = GXKToolbarDiagnosticFlashBaseline(button);", flash)
        self.assertIn("live && !GXKToolbarDiagnosticFeedbackOwns(live)", flash)
        baseline = self.body("static NSString *GXKToolbarDiagnosticFlashBaseline")
        self.assertIn("button == gToolbarDiagnosticFeedbackButton && !gToolbarDiagnosticFeedbackActionKey", baseline)
        self.assertIn('[gToolbarStack.arrangedSubviews containsObject:button]) return @"复制";', baseline)
        self.assertIn("return [button titleForState:UIControlStateNormal];", baseline)
        owns = self.body("static BOOL GXKToolbarDiagnosticFeedbackOwns")
        self.assertIn("button == gToolbarDiagnosticFeedbackButton && GXKToolbarDiagnosticNow() < gToolbarDiagnosticFeedbackUntil", owns)

    def test_failed_scan_survey_reads_all_logo_roles_without_promoting_them(self):
        survey = self.body("static NSString *GXKToolbarDiagnosticLogoSurvey")
        self.assertIn('NSClassFromString(@"GKBHeaderLogoView")', survey)
        self.assertIn("arrayWithObject:root", survey)
        self.assertIn("visited++ < 1500", survey)
        self.assertIn("pending.count >= 1500) { truncated = YES; break; }", survey)
        self.assertIn("logos.count < 6", survey)
        self.assertIn("count > logos.count", survey)
        self.assertNotIn("if (view.hidden", survey)
        self.assertNotIn("if (view.isHidden", survey)
        self.assertIn("GXKToolbarDiagnosticGlyph(view, view.superview, &glyph)", survey)
        for forbidden in ("GXKToolbarScan(", "GXKToolbarBand(", "GXKUpdateToolbar(", "GXKToolbarNativeSpaceClear(", "outLogo", "gToolbarLogoView ="):
            self.assertNotIn(forbidden, survey)
        self.assertIn("GXKToolbarDiagnosticLogoSurvey(root)", self.body("static NSString *GXKToolbarDiagnosticSnapshot"))

    def test_last_production_decision_survives_detach_without_feedback_overwrite(self):
        request = self.body("static void GXKToolbarDiagnosticRequest")
        self.assertLess(request.index("gToolbarDiagnosticLastDecision = reason"), request.index("!gToolbarDiagnosticActive"))
        self.assertIn('![reason isEqualToString:@"feedback-settle"]', request)
        for field in ("lastDecision=", "decisionOwnerCurrent=", "scanGate=", "bandGate=", "bandCandidateRoot=",
                      "spaceGate=", "spaceBandRoot=", "blocker=", "blockerChain=", "obstacleComplete=", "logoCandidate["):
            self.assertIn(field, self.diag)
        space = function_body(self.visibility, "static BOOL GXKToolbarNativeSpaceClear")
        self.assertIn('gToolbarSpaceGate = @"independent-qwerty";', space)
        self.assertIn("gToolbarSpaceBlocker = body;", space)
        self.assertIn('gToolbarSpaceGate = @"native-obstacle";', space)
        self.assertIn("gToolbarSpaceBlocker = view;", space)
        for gate in ("no-measurable-logo", "nine-body-missing", "tree-incomplete", "row-size", "band-unavailable"):
            self.assertIn('@"' + gate + '"', self.layout)

    def test_each_image_attempt_exposes_contract_and_clipping_evidence(self):
        glyph = self.body("static NSString *GXKToolbarDiagnosticGlyph")
        self.assertIn("NSString *imageGate = gToolbarImageGate", glyph)
        for expression in ("layerImage == image", "image.CGImage != NULL", "image.images.count",
                           "CATransform3DIsIdentity(ancestor.sublayerTransform)", "gToolbarImageDrawnRoot", "gToolbarImageVisibleRoot"):
            self.assertIn(expression, glyph)
        for field in ("imageGate=", "layerImageMatch=", "CGImage=", "imageFrames=", "drawnRoot=", "visibleRoot=", "clipRoot=", "visibleIconSized="):
            self.assertIn(field, glyph)
        self.assertIn("imageCount > images.count", glyph)
        self.assertIn("Last gate labels/spaceBand describe the last production call", self.diag)

    def test_production_gates_are_attempt_scoped_and_root_bound(self):
        reset = self.body("static void GXKToolbarDiagnosticResetGates")
        for line in ('gToolbarScanGate = @"not-evaluated";', 'gToolbarBandGate = @"not-evaluated";',
                     'gToolbarSpaceGate = @"not-evaluated";', "gToolbarSpaceBlocker = nil;",
                     "gToolbarSpaceBand = CGRectZero;", "gToolbarBandCandidateRoot = CGRectZero;"):
            self.assertIn(line, reset)
        begin = self.body("static void GXKToolbarDiagnosticBegin")
        self.assertIn("gToolbarDiagnosticLastRoot = vc.view;", begin)
        self.assertIn("GXKToolbarDiagnosticResetGates();", begin)
        update = function_body(self.main, "static void GXKUpdateToolbar(UIViewController *vc) {")
        self.assertLess(update.index("GXKToolbarDiagnosticBegin(vc)"), update.index("if (bound)"))
        self.assertLess(update.index("GXKToolbarDiagnosticResetGates()"), update.index("GXKToolbarScan(root,"))
        snapshot = self.body("static NSString *GXKToolbarDiagnosticSnapshot")
        self.assertIn("root == gToolbarDiagnosticLastRoot", snapshot)
        self.assertNotIn("gToolbarDiagnosticLastOwner =", self.body("static void GXKToolbarDiagnosticRequest"))

    def test_ancestor_coverage_cannot_claim_complete_before_root(self):
        glyph = self.body("static NSString *GXKToolbarDiagnosticGlyph")
        self.assertIn("BOOL layerChainReachedRoot = NO;", glyph)
        self.assertIn("BOOL layerChainTruncated = !layerChainReachedRoot;", glyph)
        self.assertIn("truncated = truncated || layerChainTruncated;", glyph)
        self.assertIn("layerChainReachedRoot=%d layerChainTruncated=%d", glyph)
        chain = self.body("static NSString *GXKToolbarDiagnosticChain")
        self.assertIn('chainTruncated=%d", view != nil', chain)

    def test_all_refresh_results_request_diagnostics(self):
        update = function_body(self.main, "static void GXKUpdateToolbar(UIViewController *vc) {")
        for reason in ("composing-hidden", "native-content-hidden", "fast-unchanged", "scan-failed", "reuse-resampled", "new-resampled"):
            self.assertIn('@"' + reason + '"', update)

    def test_disabled_capture_returns_before_expensive_reads(self):
        request = self.body("static void GXKToolbarDiagnosticRequest")
        self.assertLess(request.index("!gToolbarDiagnosticActive"), request.index("GXKToolbarDiagnosticCapture"))
        capture = self.body("static void GXKToolbarDiagnosticCapture")
        self.assertLess(capture.index("!gToolbarDiagnosticActive"), capture.index("GXKToolbarDiagnosticSnapshot"))
        self.assertNotIn("NSTimer", self.code)
        self.assertNotIn("GXKComposingFullScan", self.code)
        for production_owner in ("GXKNativeKeyStyleLabel(", "GXKNativeKeyFont(", "GXKToolbarNativeSpaceClear(",
                                 "GXKToolbarBand(", "GXKUpdateToolbar("):
            self.assertNotIn(production_owner, self.code)

    def test_delayed_reads_are_coalesced_and_generation_guarded(self):
        request = self.body("static void GXKToolbarDiagnosticRequest")
        self.assertIn("if (gToolbarDiagnosticQueued) return;", request)
        self.assertIn("gToolbarDiagnosticPendingReasons |=", request)
        self.assertIn("gToolbarDiagnosticLastAt + GXK_DIAGNOSTIC_INTERVAL", request)
        self.assertIn("generation != gToolbarDiagnosticGeneration", request)
        self.assertIn("__weak UIViewController *weakVC", request)
        self.assertIn("dispatch_get_main_queue()", request)

    def test_samples_and_glyph_scan_have_explicit_bounds_and_coverage(self):
        for define in ("SECONDS 60.0", "INTERVAL 0.10", "MAX_SAMPLES 80", "MAX_CHARS 196608", "MAX_NODES 128"):
            self.assertIn("GXK_DIAGNOSTIC_" + define, self.diag)
        glyph = self.body("static NSString *GXKToolbarDiagnosticGlyph")
        self.assertRegex(glyph, r"visited(?:\+\+)? < GXK_DIAGNOSTIC_MAX_NODES")
        self.assertIn("pending.count >= GXK_DIAGNOSTIC_MAX_NODES", glyph)
        self.assertIn("images.count < 8", glyph)
        self.assertIn("truncated=%d", glyph)
        capture = self.body("static void GXKToolbarDiagnosticCapture")
        self.assertIn("isEqualToString:gToolbarDiagnosticLastSnapshot", capture)
        self.assertIn("gToolbarDiagnosticSamples.count > 1", capture)
        self.assertIn("removeObjectAtIndex:1", capture)
        self.assertIn("gToolbarDiagnosticChars + sample.length > GXK_DIAGNOSTIC_MAX_CHARS", capture)
        self.assertIn("gToolbarDiagnosticDropped++", capture)

    def test_report_does_not_read_user_content_or_persist(self):
        for forbidden in ("documentContext", "selectedText", "insertText:", "deleteBackward", ".text", "attributedText",
                          "accessibilityIdentifier", "NSUserDefaults", "NSFileManager", "NSURLSession", "NSLog"):
            self.assertNotIn(forbidden, self.code)
        self.assertEqual(1, self.code.count("[UIPasteboard generalPasteboard].string ="))
        stop = self.body("static void GXKToolbarDiagnosticStop")
        self.assertNotIn("UIPasteboard", stop)
        self.assertIn("gToolbarDiagnosticGeneration++", stop)

    def test_no_layout_or_font_writes_in_helper(self):
        for forbidden in ("layoutIfNeeded", "setNeedsLayout", "setFont:", "addSubview:", "constraintEqual", "presentViewController"):
            self.assertNotIn(forbidden, self.code)
        self.assertNotRegex(self.code, r"\.(?:frame|bounds|font|hidden|alpha|transform)\s*=")

    def test_reports_required_fields_without_claiming_effective_drawing_size(self):
        for field in ("selectedFont=", "sourceCurrentFont=", "sourceChain=", "buttonW=", "labelW=", "naturalFixed=",
                      "minScale=", "rowParent=", "unclampedTop=", "finalTop=", "freshBandDeltaY=", "imageSize="):
            self.assertIn(field, self.diag)
        self.assertIn("NOT actual auto-shrunk drawing size", self.diag)
        self.assertIn("NOT opaque image pixels", self.diag)

    def test_feedback_follows_baseline_and_timeout_never_auto_copies(self):
        toggle = self.body("static void GXKToolbarDiagnosticToggle")
        start = toggle[toggle.index("gToolbarDiagnosticSamples = [NSMutableArray array];"):]
        self.assertLess(start.index('GXKToolbarDiagnosticCapture(vc, @"start-before-feedback"'),
                        start.index('GXKToolbarDiagnosticFeedback(vc, button, @"诊断")'))
        self.assertIn("gToolbarDiagnosticFeedbackUntil", start)
        timeout = start[start.index("GXK_DIAGNOSTIC_SECONDS * NSEC_PER_SEC"):]
        self.assertIn('@"timeout-60s"', timeout)
        self.assertNotIn("UIPasteboard", timeout)
        gone = function_body(self.main, "static void gkx_viewWillDisappear")
        self.assertLess(gone.index("GXKToolbarDiagnosticStop"), gone.index("gCurrentVC = nil"))

    def test_no_multiline_string_literals_or_unbalanced_delimiters(self):
        # Lexical guard catches accidental literal newlines from code-generation escaping.
        strings = re.findall(r'"(?:\\.|[^"\\])*"', self.code)
        self.assertTrue(strings)
        for literal in strings:
            self.assertNotIn("\n", literal)
        rest = re.sub(r'"(?:\\.|[^"\\])*"', '""', self.code)
        opens = []
        matching = {')': '(', ']': '[', '}': '{'}
        for char in rest:
            if char in "([{":
                opens.append(char)
            elif char in ")]}":
                self.assertTrue(opens, char)
                self.assertEqual(matching[char], opens.pop())
        self.assertFalse(opens)


if __name__ == "__main__":
    unittest.main()
