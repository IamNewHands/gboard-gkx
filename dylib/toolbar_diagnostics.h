// [DEBUG-toolbar] Temporary, opt-in toolbar investigation; included by gkx.m only.
// Owns capture lifecycle/reporting, never owns keyboard layout or typography.
#ifndef GXK_TOOLBAR_DIAGNOSTICS_H
#define GXK_TOOLBAR_DIAGNOSTICS_H

#define GXK_DIAGNOSTIC_SECONDS 60.0
#define GXK_DIAGNOSTIC_INTERVAL 0.10
#define GXK_DIAGNOSTIC_MAX_SAMPLES 80
#define GXK_DIAGNOSTIC_MAX_CHARS 196608
#define GXK_DIAGNOSTIC_MAX_NODES 128

static BOOL gToolbarDiagnosticActive;
static __weak UIViewController *gToolbarDiagnosticLastOwner;
static __weak UIView *gToolbarDiagnosticLastRoot;
static NSUInteger gToolbarDiagnosticFeedbackGeneration;
static NSString *gToolbarDiagnosticLastDecision;
static __weak UIButton *gToolbarDiagnosticFeedbackButton;
static __weak UIViewController *gToolbarDiagnosticOwner;
static NSMutableArray<NSString *> *gToolbarDiagnosticSamples;
static NSString *gToolbarDiagnosticLastSnapshot;
static NSTimeInterval gToolbarDiagnosticStartedAt;
static NSTimeInterval gToolbarDiagnosticLastAt;
static NSTimeInterval gToolbarDiagnosticFeedbackUntil;
static NSUInteger gToolbarDiagnosticGeneration;
static NSUInteger gToolbarDiagnosticChars;
static NSUInteger gToolbarDiagnosticDropped;
static NSUInteger gToolbarDiagnosticPendingReasons;
static BOOL gToolbarDiagnosticQueued;
static NSString *gToolbarDiagnosticStopReason;
// Last geometry actually used by the production band calculation, even before opt-in.
// Weak identities + scalars only; a cache hit deliberately leaves this observation unchanged.
static __weak UIView *gToolbarDiagnosticBandRow;
static __weak UIView *gToolbarDiagnosticBandLogo;
static CGRect gToolbarDiagnosticUsedGlyph;
static CGFloat gToolbarDiagnosticUnclampedTop;
static NSTimeInterval gToolbarDiagnosticBandAt;

// Reset labels before every production attempt; absent branches are never old evidence.
static void GXKToolbarDiagnosticResetGates(void) {
    gToolbarScanGate = @"not-evaluated";
    gToolbarBandGate = @"not-evaluated";
    gToolbarBandCandidateRoot = CGRectZero;
    gToolbarRightBoundary = nil;
    gToolbarRightBoundaryRect = CGRectZero;
    gToolbarSpaceGate = @"not-evaluated";
    gToolbarSpaceBand = CGRectZero;
    gToolbarSpaceBlocker = nil;
}

static void GXKToolbarDiagnosticBegin(UIViewController *vc) {
    gToolbarDiagnosticLastOwner = vc;
    gToolbarDiagnosticLastRoot = vc.view;
    gToolbarDiagnosticLastDecision = @"in-progress";
    GXKToolbarDiagnosticResetGates();
}

static NSTimeInterval GXKToolbarDiagnosticNow(void) {
    return [NSProcessInfo processInfo].systemUptime;
}

static void GXKToolbarDiagnosticBandObserved(UIView *row, UIView *logo, CGRect glyph, CGFloat unclampedTop) {
    gToolbarDiagnosticBandRow = row;
    gToolbarDiagnosticBandLogo = logo;
    gToolbarDiagnosticUsedGlyph = glyph;
    gToolbarDiagnosticUnclampedTop = unclampedTop;
    gToolbarDiagnosticBandAt = GXKToolbarDiagnosticNow();
}

static NSString *GXKToolbarDiagnosticIdentity(UIView *view) {
    return view ? [NSString stringWithFormat:@"%@:%p", NSStringFromClass(view.class), (__bridge void *)view] : @"none";
}

// Class/index chain identifies the chosen role without reading native label text or IDs.
static NSString *GXKToolbarDiagnosticChain(UIView *view) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSUInteger depth = 0; view && depth < 8; depth++, view = view.superview) {
        NSUInteger index = view.superview ? [view.superview.subviews indexOfObjectIdenticalTo:view] : NSNotFound;
        [parts addObject:[NSString stringWithFormat:@"%@[%@]", GXKToolbarDiagnosticIdentity(view),
                         index == NSNotFound ? @"root" : [@(index) stringValue]]];
    }
    return [[parts componentsJoinedByString:@" <- "] stringByAppendingFormat:@" chainTruncated=%d", view != nil];
}

static NSString *GXKToolbarDiagnosticView(UIView *view, UIView *root) {
    if (!view) return @"none";
    BOOL bound = view == root || [view isDescendantOfView:root];
    NSString *inRoot = bound ? NSStringFromCGRect([view convertRect:view.bounds toView:root]) : @"unbound";
    return [NSString stringWithFormat:@"%@ frame=%@ bounds=%@ root=%@ hidden=%d alpha=%.2f clips=%d transform=%@",
            GXKToolbarDiagnosticIdentity(view), NSStringFromCGRect(view.frame), NSStringFromCGRect(view.bounds),
            inRoot, view.hidden, (double)view.alpha, view.clipsToBounds, NSStringFromCGAffineTransform(view.transform)];
}

// Share the layout owner's anchor. Diagnostic detail reads only image/layer geometry, never native text.
static NSString *GXKToolbarDiagnosticGlyph(UIView *logo, UIView *row, CGRect *outGlyph) {
    *outGlyph = CGRectZero;
    if (!logo || !row || logo.superview != row) return @"unbound";
    BOOL measured = GXKToolbarGlyphRect(logo, row, outGlyph);
    NSMutableArray<UIView *> *pending = [NSMutableArray arrayWithObject:logo];
    NSMutableArray<NSString *> *images = [NSMutableArray array];
    NSUInteger visited = 0, imageCount = 0;
    BOOL truncated = NO;
    while (pending.count && visited++ < GXK_DIAGNOSTIC_MAX_NODES) {
        UIView *view = pending.lastObject;
        [pending removeLastObject];
        UIImage *image = nil;
        if ([view respondsToSelector:@selector(image)]) image = [(id<GXKNativeIconContent>)view image];
        if ([image isKindOfClass:[UIImage class]]) {
            imageCount++;
            if (images.count < 8) {
                CALayer *layer = view.layer;
                CGRect rect = CGRectZero;
                BOOL valid = GXKToolbarImageRect(view, row, &rect);
                NSString *imageGate = gToolbarImageGate ?: @"not-run";
                CGRect drawnRoot = gToolbarImageDrawnRoot, visibleRoot = gToolbarImageVisibleRoot;
                BOOL layerImageAPI = [layer respondsToSelector:@selector(image)];
                UIImage *layerImage = layerImageAPI ? [(id<GXKNativeIconContent>)layer image] : nil;
                NSMutableArray<NSString *> *chain = [NSMutableArray array];
                NSUInteger depth = 0;
                BOOL layerChainReachedRoot = NO;
                for (CALayer *ancestor = layer; ancestor && depth++ < 16; ancestor = ancestor.superlayer) {
                    [chain addObject:[NSString stringWithFormat:@"%@ bounds=%@ position=%@ masks=%d mask=%d hidden=%d opacity=%.2f animated=%d transform=%d sublayerTransform=%d clipRoot=%@",
                        NSStringFromClass(ancestor.class), NSStringFromCGRect(ancestor.bounds), NSStringFromCGPoint(ancestor.position),
                        ancestor.masksToBounds, ancestor.mask != nil, ancestor.hidden, (double)ancestor.opacity,
                        ancestor.animationKeys.count > 0, !CATransform3DIsIdentity(ancestor.transform),
                        !CATransform3DIsIdentity(ancestor.sublayerTransform),
                        NSStringFromCGRect([ancestor convertRect:ancestor.bounds toLayer:gCurrentVC.view.layer])]];
                    if (ancestor == gCurrentVC.view.layer) { layerChainReachedRoot = YES; break; }
                }
                BOOL layerChainTruncated = !layerChainReachedRoot;
                truncated = truncated || layerChainTruncated;
                [chain addObject:[NSString stringWithFormat:@"layerChainReachedRoot=%d layerChainTruncated=%d",
                                  layerChainReachedRoot, layerChainTruncated]];
                [images addObject:[NSString stringWithFormat:
                    @"%@ measured=%d imageGate=%@ visible=%@ viewRow=%@ imageSize=%@ imageScale=%.2f layer=%@ layerImageAPI=%d gravity=%@ contentsScale=%.2f contentsMatch=%d contentsRect=%@ contentsCenter=%@ capInsets=%@ orientation=%ld layerImageMatch=%d CGImage=%d pixels=%lux%lu imageFrames=%lu drawnRoot=%@ visibleRoot=%@ visibleIconSized=%d\n    %@",
                    GXKToolbarDiagnosticIdentity(view), valid, imageGate, NSStringFromCGRect(rect),
                    NSStringFromCGRect([view convertRect:view.bounds toView:row]), NSStringFromCGSize(image.size), (double)image.scale,
                    NSStringFromClass(layer.class), [layer respondsToSelector:@selector(image)], layer.contentsGravity,
                    (double)layer.contentsScale, layer.contents == (__bridge id)image.CGImage,
                    NSStringFromCGRect(layer.contentsRect), NSStringFromCGRect(layer.contentsCenter),
                    NSStringFromUIEdgeInsets(image.capInsets), (long)image.imageOrientation, layerImage == image, image.CGImage != NULL,
                    (unsigned long)(image.CGImage ? CGImageGetWidth(image.CGImage) : 0),
                    (unsigned long)(image.CGImage ? CGImageGetHeight(image.CGImage) : 0),
                    (unsigned long)image.images.count, NSStringFromCGRect(drawnRoot), NSStringFromCGRect(visibleRoot),
                    GXKToolbarIconSized(visibleRoot), [chain componentsJoinedByString:@"\n    "]]];
            }
        }
        for (UIView *child in view.subviews) {
            if (pending.count >= GXK_DIAGNOSTIC_MAX_NODES) { truncated = YES; break; }
            [pending addObject:child];
        }
    }
    return [NSString stringWithFormat:@"mode=visible-native-layer measured=%d visited=%lu truncated=%d images=%lu listed=%lu picked=%@\n  %@",
            measured, (unsigned long)visited, truncated || pending.count > 0 || imageCount > images.count, (unsigned long)imageCount, (unsigned long)images.count,
            NSStringFromCGRect(*outGlyph), [images componentsJoinedByString:@"\n  "]];
}


static NSString *GXKToolbarDiagnosticButtons(UIStackView *stack, UIView *root) {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    // Only fixed patch titles are measured. Never read text from a native key or document proxy.
    NSArray<NSString *> *titles = @[@"全选", @"复制", @"粘贴", @"剪切", @"收起"];
    NSUInteger index = 0;
    for (UIView *view in stack.arrangedSubviews) {
        if (index >= titles.count) break;
        if (![view isKindOfClass:[UIButton class]]) { index++; continue; }
        UIButton *button = (UIButton *)view;
        UILabel *label = button.titleLabel;
        UIFont *font = label.font;
        CGSize natural = font ? [titles[index] sizeWithAttributes:@{NSFontAttributeName:font}] : CGSizeZero;
        CGRect content = [button contentRectForBounds:button.bounds];
        CGRect titleRect = [button titleRectForContentRect:content];
        CGRect textRect = [label textRectForBounds:label.bounds limitedToNumberOfLines:label.numberOfLines];
        [lines addObject:[NSString stringWithFormat:
            @"button[%lu] %@ font=%@/%.2f buttonW=%.2f labelW=%.2f naturalFixed=%@ shrink=%d minScale=%.2f lines=%ld break=%ld\n  label=%@\n  content=%@ titleRect=%@ textRect=%@ contentInsets=%@ titleInsets=%@",
            (unsigned long)index, GXKToolbarDiagnosticView(button, root), font.fontName ?: @"none",
            (double)font.pointSize, (double)button.bounds.size.width, (double)label.bounds.size.width,
            NSStringFromCGSize(natural), label.adjustsFontSizeToFitWidth, (double)label.minimumScaleFactor,
            (long)label.numberOfLines, (long)label.lineBreakMode, GXKToolbarDiagnosticView(label, root),
            NSStringFromCGRect(content), NSStringFromCGRect(titleRect), NSStringFromCGRect(textRect),
            NSStringFromUIEdgeInsets(button.contentEdgeInsets), NSStringFromUIEdgeInsets(button.titleEdgeInsets)]];
        index++;
    }
    return [lines componentsJoinedByString:@"\n"];
}

// [DEBUG-toolbar] Discovery is opt-in only and independent of the production stack binding.
// Hidden logos remain evidence; this never promotes one to the production anchor.
static NSString *GXKToolbarDiagnosticLogoSurvey(UIView *root) {
    if (!root) return @"logoSurvey=unbound";
    Class logoClass = NSClassFromString(@"GKBHeaderLogoView");
    NSMutableArray<UIView *> *pending = [NSMutableArray arrayWithObject:root];
    NSMutableArray<NSString *> *logos = [NSMutableArray array];
    NSUInteger visited = 0, count = 0;
    BOOL truncated = NO;
    while (pending.count && visited++ < 1500) {
        UIView *view = pending.lastObject;
        [pending removeLastObject];
        if (view == gToolbarStack || view == gActionKeyButton) continue;
        if (logoClass && [view isKindOfClass:logoClass]) {
            count++;
            if (logos.count < 6) {
                CGRect glyph = CGRectZero;
                NSString *detail = GXKToolbarDiagnosticGlyph(view, view.superview, &glyph);
                [logos addObject:[NSString stringWithFormat:@"logoCandidate[%lu] visible=%d\n  %@\n  chain=%@\n  %@",
                    (unsigned long)count, GXKKeyIsVisible(view, root), GXKToolbarDiagnosticView(view, root),
                    GXKToolbarDiagnosticChain(view), detail]];
            }
        }
        for (UIView *child in view.subviews) {
            if (pending.count >= 1500) { truncated = YES; break; }
            [pending addObject:child];
        }
    }
    return [NSString stringWithFormat:@"logoSurvey visited=%lu truncated=%d candidates=%lu listed=%lu classAvailable=%d\n%@",
        (unsigned long)visited, truncated || pending.count > 0 || count > logos.count, (unsigned long)count,
        (unsigned long)logos.count, logoClass != nil, [logos componentsJoinedByString:@"\n"]];
}

static NSString *GXKToolbarDiagnosticSnapshot(UIViewController *vc) {
    UIView *root = vc.view, *row = gToolbarRow, *logo = gToolbarLogoView;
    UILabel *source = gToolbarStyleSource;
    UIStackView *stack = gToolbarStack;
    // Preserve production evidence before the read-only glyph survey updates image labels.
    NSString *decision = gToolbarDiagnosticLastDecision ?: @"none";
    NSString *scanGate = gToolbarScanGate ?: @"not-run";
    NSString *spaceGate = gToolbarSpaceGate ?: @"not-run";
    NSString *blocker = GXKToolbarDiagnosticView(gToolbarSpaceBlocker, root);
    NSString *blockerChain = GXKToolbarDiagnosticChain(gToolbarSpaceBlocker);
    NSString *rightBoundary = GXKToolbarDiagnosticView(gToolbarRightBoundary, root);
    NSString *rightBoundaryChain = GXKToolbarDiagnosticChain(gToolbarRightBoundary);
    CGRect rightBoundaryRect = gToolbarRightBoundaryRect;
    // This validates the historical observation's identity/tree binding, not its freshness.
    BOOL usedValid = root && row && logo && logo.superview == row &&
                     (row == root || [row isDescendantOfView:root]) &&
                     row == gToolbarDiagnosticBandRow && logo == gToolbarDiagnosticBandLogo;
    CGRect fresh = CGRectZero;
    NSString *glyph = GXKToolbarDiagnosticGlyph(logo, row, &fresh);
    CGFloat usedMid = CGRectGetMidY(gToolbarDiagnosticUsedGlyph);
    CGFloat bandMid = CGRectGetMidY(gToolbarBand);
    return [NSString stringWithFormat:
        @"composingCached=%d stackHidden=%d feedbackActive=%d\nlastDecision=%@ decisionOwnerCurrent=%d scanGate=%@ bandGate=%@ bandCandidateRoot=%@ spaceGate=%@ spaceBandRoot=%@ obstacleComplete=%d obstacles=%lu keyboardBodies=%lu contentEpoch=%lu obstacleEpoch=%lu\nrightBound=%@\nrightBoundContentRoot=%@\nrightBoundChain=%@\nblocker=%@\nblockerChain=%@\nactionButton=%@\nselectedFont=%@/%.2f sourceCurrentFont=%@/%.2f\nsource=%@\nsourceChain=%@\nroot=%@\nrow=%@\nrowParent=%@\nlogo=%@\nbody=%@\nstack=%@\nbandRow=%@ cacheValid=%d epoch=%lu\nusedValid=%d usedGlyphRow=%@ unclampedTop=%.2f finalTop=%.2f usedBandDeltaY=%.2f freshBandDeltaY=%.2f usedObservationUptime=%.3f\nfreshGlyph: %@\n%@",
        gComposingActive, stack.hidden, GXKToolbarDiagnosticNow() < gToolbarDiagnosticFeedbackUntil,
        decision, vc == gToolbarDiagnosticLastOwner && root == gToolbarDiagnosticLastRoot, scanGate, gToolbarBandGate ?: @"not-run",
        NSStringFromCGRect(gToolbarBandCandidateRoot), spaceGate, NSStringFromCGRect(gToolbarSpaceBand),
        gToolbarObstacleComplete, (unsigned long)gToolbarObstacles.count, (unsigned long)gToolbarKeyboardBodies.count,
        (unsigned long)gToolbarContentEpoch, (unsigned long)gToolbarObstacleEpoch,
        rightBoundary, NSStringFromCGRect(rightBoundaryRect), rightBoundaryChain, blocker, blockerChain,
        GXKToolbarDiagnosticView(gActionKeyButton, root),
        gToolbarFont.fontName ?: @"fallback-16", gToolbarFont ? (double)gToolbarFont.pointSize : 16.0,
        source.font.fontName ?: @"none", (double)source.font.pointSize,
        GXKToolbarDiagnosticView(source, root), GXKToolbarDiagnosticChain(source),
        GXKToolbarDiagnosticView(root, root), GXKToolbarDiagnosticView(row, root),
        GXKToolbarDiagnosticView(row.superview, root), GXKToolbarDiagnosticView(logo, root),
        GXKToolbarDiagnosticView(gToolbarNineBody, root), GXKToolbarDiagnosticView(stack, root),
        NSStringFromCGRect(gToolbarBand), gToolbarBandCacheValid, (unsigned long)gToolbarBandEpoch,
        usedValid, NSStringFromCGRect(gToolbarDiagnosticUsedGlyph), (double)gToolbarDiagnosticUnclampedTop,
        (double)gToolbarBand.origin.y, (double)(bandMid - usedMid), (double)(bandMid - CGRectGetMidY(fresh)),
        gToolbarDiagnosticBandAt, glyph, [GXKToolbarDiagnosticButtons(stack, root) stringByAppendingFormat:@"\n%@", GXKToolbarDiagnosticLogoSurvey(root)]];
}

static void GXKToolbarDiagnosticCapture(UIViewController *vc, NSString *reason, BOOL force) {
    if (!gToolbarDiagnosticActive || vc != gToolbarDiagnosticOwner || !vc.isViewLoaded) return;
    NSTimeInterval now = GXKToolbarDiagnosticNow();
    if (!force && now < gToolbarDiagnosticFeedbackUntil) return;
    NSString *snapshot = GXKToolbarDiagnosticSnapshot(vc);
    gToolbarDiagnosticLastAt = now;
    if (!force && [snapshot isEqualToString:gToolbarDiagnosticLastSnapshot]) return;
    gToolbarDiagnosticLastSnapshot = snapshot;
    NSString *sample = [NSString stringWithFormat:@"\n--- t=%.3f reason=%@ ---\n%@\n",
                        now - gToolbarDiagnosticStartedAt, reason, snapshot];
    // Keep the initial baseline and newest transitions rather than losing the cleared/end state.
    while (gToolbarDiagnosticSamples.count > 1 &&
           (gToolbarDiagnosticSamples.count >= GXK_DIAGNOSTIC_MAX_SAMPLES ||
            gToolbarDiagnosticChars + sample.length > GXK_DIAGNOSTIC_MAX_CHARS)) {
        gToolbarDiagnosticChars -= gToolbarDiagnosticSamples[1].length;
        [gToolbarDiagnosticSamples removeObjectAtIndex:1];
        gToolbarDiagnosticDropped++;
    }
    if (gToolbarDiagnosticChars + sample.length > GXK_DIAGNOSTIC_MAX_CHARS) {
        gToolbarDiagnosticDropped++;
        return;
    }
    [gToolbarDiagnosticSamples addObject:sample];
    gToolbarDiagnosticChars += sample.length;
}

static NSUInteger GXKToolbarDiagnosticReason(NSString *reason) {
    if ([reason isEqualToString:@"composing-hidden"]) return 1;
    if ([reason isEqualToString:@"fast-unchanged"]) return 2;
    if ([reason isEqualToString:@"scan-failed"]) return 4;
    if ([reason isEqualToString:@"reuse-resampled"]) return 8;
    if ([reason isEqualToString:@"new-resampled"]) return 16;
    return 32;
}

static void GXKToolbarDiagnosticRequest(UIViewController *vc, NSString *reason) {
    if (![reason isEqualToString:@"feedback-settle"]) {
        gToolbarDiagnosticLastDecision = reason; // Fixed production status only, even when capture is off.
    }
    if (!gToolbarDiagnosticActive || vc != gToolbarDiagnosticOwner) return;
    gToolbarDiagnosticPendingReasons |= GXKToolbarDiagnosticReason(reason);
    if (gToolbarDiagnosticQueued) return;
    gToolbarDiagnosticQueued = YES;
    NSUInteger generation = gToolbarDiagnosticGeneration;
    __weak UIViewController *weakVC = vc;
    NSTimeInterval due = MAX(gToolbarDiagnosticLastAt + GXK_DIAGNOSTIC_INTERVAL, gToolbarDiagnosticFeedbackUntil);
    NSTimeInterval delay = MAX(0.0, due - GXKToolbarDiagnosticNow());
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (generation != gToolbarDiagnosticGeneration || !gToolbarDiagnosticActive) return;
        gToolbarDiagnosticQueued = NO;
        NSUInteger reasons = gToolbarDiagnosticPendingReasons;
        gToolbarDiagnosticPendingReasons = 0;
        UIViewController *live = weakVC;
        if (!live || live != gCurrentVC) return;
        // Reading on a later main-queue turn lets ordinary UIKit layout finish; no layoutIfNeeded.
        GXKToolbarDiagnosticCapture(live, [NSString stringWithFormat:@"refresh-mask=%lu", (unsigned long)reasons], NO);
    });
}

static void GXKToolbarDiagnosticStop(UIViewController *vc, NSString *reason) {
    if (!gToolbarDiagnosticActive) return;
    GXKToolbarDiagnosticCapture(vc, reason, YES);
    gToolbarDiagnosticActive = NO;
    gToolbarDiagnosticStopReason = reason;
    gToolbarDiagnosticOwner = nil;
    gToolbarDiagnosticGeneration++; // Invalidates queued samples and the one-shot timeout.
    gToolbarDiagnosticQueued = NO;
    gToolbarDiagnosticPendingReasons = 0;
}

// Feedback restores the live action state, never a captured transient/old title.
static __weak UIViewController *gToolbarDiagnosticFeedbackOwner;
static __weak UIView *gToolbarDiagnosticFeedbackRoot;
static BOOL gToolbarDiagnosticFeedbackActionKey;

static BOOL GXKToolbarDiagnosticRestoreFeedbackTitle(UIViewController *liveVC, UIButton *live, UIView *root, BOOL actionKey) {
    if (!live || !liveVC || liveVC != gCurrentVC || !liveVC.isViewLoaded ||
        liveVC.view != root || ![live isDescendantOfView:liveVC.view]) return NO;
    NSString *title = @"复制";
    if (actionKey) {
        if (!GXKKeyIsVisible(live, liveVC.view) || live != gActionKeyButton || live.superview != gActionHost ||
            GXKNineKeyBodyForKey(gEmojiSoftKeyView, liveVC.view) == nil ||
            GXKActionHostForKey(gEmojiSoftKeyView) != gActionHost ||
            GXKNativeIconForKey(gEmojiSoftKeyView) != gActionNativeIcon ||
            ((id<GXKNativeSoftKeyContent>)gEmojiSoftKeyView).softKeyDef != gActionSoftKeyDef ||
            !GXKModelHasNativeActions(gActionSoftKeyDef)) return NO;
        title = GXKComposingStateCached(liveVC) ? @"重输" : @"换行";
    } else if (![gToolbarStack.arrangedSubviews containsObject:live]) return NO;
    [live setTitle:title forState:UIControlStateNormal];
    [live setTitle:title forState:UIControlStateHighlighted];
    live.accessibilityLabel = title;
    return YES;
}

// Ordinary Copy failures must never capture a diagnostic title as their baseline.
static NSString *GXKToolbarDiagnosticFlashBaseline(UIButton *button) {
    if (button == gToolbarDiagnosticFeedbackButton && !gToolbarDiagnosticFeedbackActionKey &&
        [gToolbarStack.arrangedSubviews containsObject:button]) return @"复制";
    return [button titleForState:UIControlStateNormal];
}

static BOOL GXKToolbarDiagnosticFeedbackOwns(UIButton *button) {
    return button == gToolbarDiagnosticFeedbackButton && GXKToolbarDiagnosticNow() < gToolbarDiagnosticFeedbackUntil;
}

static void GXKToolbarDiagnosticFeedback(UIViewController *vc, UIButton *button, NSString *text) {
    // A new endpoint must settle the previous button before invalidating its callback.
    UIButton *previous = gToolbarDiagnosticFeedbackButton;
    if (previous && previous != button) {
        GXKToolbarDiagnosticRestoreFeedbackTitle(gToolbarDiagnosticFeedbackOwner, previous,
            gToolbarDiagnosticFeedbackRoot, gToolbarDiagnosticFeedbackActionKey);
    }
    gToolbarDiagnosticFeedbackButton = button;
    gToolbarDiagnosticFeedbackOwner = vc;
    gToolbarDiagnosticFeedbackRoot = vc.view;
    gToolbarDiagnosticFeedbackActionKey = button == gActionKeyButton;
    gToolbarDiagnosticFeedbackUntil = GXKToolbarDiagnosticNow() + 1.25;
    NSUInteger generation = ++gToolbarDiagnosticFeedbackGeneration;
    BOOL actionKey = gToolbarDiagnosticFeedbackActionKey;
    __weak UIViewController *weakVC = vc;
    __weak UIView *weakRoot = vc.view;
    __weak UIButton *weakButton = button;
    [button setTitle:text forState:UIControlStateNormal];
    [button setTitle:text forState:UIControlStateHighlighted];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIButton *live = weakButton;
        if (generation != gToolbarDiagnosticFeedbackGeneration || live != gToolbarDiagnosticFeedbackButton) return;
        if (GXKToolbarDiagnosticRestoreFeedbackTitle(weakVC, live, weakRoot, actionKey)) {
            gToolbarDiagnosticFeedbackUntil = 0;
        }
    });
}

static void GXKToolbarDiagnosticToggle(UIViewController *vc, UIButton *button) {
    if (gToolbarDiagnosticSamples) {
        GXKToolbarDiagnosticStop(vc, @"manual-stop");
        NSString *header = [NSString stringWithFormat:
            @"GXK toolbar diagnostic v2\niOS=%@ samples=%lu dropped=%lu stop=%@\nCoordinates: UIKit points; root=keyboard root, band/glyph=row space.\nFont pointSize is configured, NOT actual auto-shrunk drawing size.\nFresh glyph uses the shared visible-native-layer measurement, NOT opaque image pixels; truncated=1 is incomplete.\nusedValid checks current identity/tree binding only, NOT geometry freshness.\nusedValid=0 means used geometry is unbound/mismatched; ignore its deltas.\nStart/stop snapshots are immediate; the 0.1 s interval applies to regular refresh reads only.\nrefresh-mask: 1 composing, 2 fast, 4 scan-failed, 8 reuse-resampled, 16 new-resampled, 32 native-content-hidden (also feedback-settle).\nLast gate labels/spaceBand describe the last production call, NOT a fresh rescan; decisionOwnerCurrent=0 is stale. Each attempt resets gates/band/blocker; not-evaluated means this branch was not reached. Registry counts/epochs are historical cache state, not obstacle proof. band-cache-rejected repeats cached candidate geometry, not a fresh calculation.\nLogo survey includes hidden/unmeasurable candidates independently of the stack; listed/truncated limit coverage.\nLong press Copy or the patch action key for 0.8 s to start/stop; normal tap remains unchanged.\nNo input text, key label text, accessibility IDs, disk writes or network uploads.\n",
            [UIDevice currentDevice].systemVersion, (unsigned long)gToolbarDiagnosticSamples.count,
            (unsigned long)gToolbarDiagnosticDropped, gToolbarDiagnosticStopReason ?: @"unknown"];
        [UIPasteboard generalPasteboard].string = [header stringByAppendingString:
            [gToolbarDiagnosticSamples componentsJoinedByString:@""]];
        gToolbarDiagnosticSamples = nil;
        gToolbarDiagnosticLastSnapshot = nil;
        gToolbarDiagnosticChars = 0;
        GXKToolbarDiagnosticFeedback(vc, button, @"已复制");
        return;
    }
    gToolbarDiagnosticSamples = [NSMutableArray array];
    gToolbarDiagnosticOwner = vc;
    gToolbarDiagnosticActive = YES;
    gToolbarDiagnosticStartedAt = GXKToolbarDiagnosticNow();
    gToolbarDiagnosticLastAt = 0;
    gToolbarDiagnosticFeedbackUntil = 0;
    gToolbarDiagnosticChars = 0;
    gToolbarDiagnosticDropped = 0;
    gToolbarDiagnosticStopReason = nil;
    gToolbarDiagnosticLastSnapshot = nil;
    NSUInteger generation = ++gToolbarDiagnosticGeneration;
    GXKToolbarDiagnosticCapture(vc, @"start-before-feedback", YES);
    // The initial sample precedes feedback. Delay later reads until its title has restored.
    GXKToolbarDiagnosticFeedback(vc, button, @"诊断");
    GXKToolbarDiagnosticRequest(vc, @"feedback-settle");
    __weak UIViewController *weakVC = vc;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(GXK_DIAGNOSTIC_SECONDS * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (generation != gToolbarDiagnosticGeneration || !gToolbarDiagnosticActive) return;
        GXKToolbarDiagnosticStop(weakVC, @"timeout-60s");
        // Keep the bounded report in memory; only an explicit next long press writes clipboard.
    });
}

#endif
