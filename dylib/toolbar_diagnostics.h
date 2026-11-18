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
    return [parts componentsJoinedByString:@" <- "];
}

static NSString *GXKToolbarDiagnosticView(UIView *view, UIView *root) {
    if (!view) return @"none";
    BOOL bound = view == root || [view isDescendantOfView:root];
    NSString *inRoot = bound ? NSStringFromCGRect([view convertRect:view.bounds toView:root]) : @"unbound";
    return [NSString stringWithFormat:@"%@ frame=%@ bounds=%@ root=%@ hidden=%d alpha=%.2f clips=%d transform=%@",
            GXKToolbarDiagnosticIdentity(view), NSStringFromCGRect(view.frame), NSStringFromCGRect(view.bounds),
            inRoot, view.hidden, (double)view.alpha, view.clipsToBounds, NSStringFromCGAffineTransform(view.transform)];
}

// Bounded, read-only counterpart of the existing bottommost-image heuristic.
// These are VIEW/image rectangles, not opaque pixel bounds or proof of which image is G.
static NSString *GXKToolbarDiagnosticGlyph(UIView *logo, UIView *row, CGRect *outGlyph) {
    *outGlyph = CGRectZero;
    if (!logo || !row || logo.superview != row) return @"unbound";
    NSMutableArray<UIView *> *pending = [NSMutableArray arrayWithObject:logo];
    NSMutableArray<NSString *> *images = [NSMutableArray array];
    CGRect own = [logo convertRect:logo.bounds toView:row];
    CGFloat bestBottom = -CGFLOAT_MAX, bestArea = 0.0;
    NSUInteger visited = 0, imageCount = 0;
    BOOL truncated = NO;
    while (pending.count && visited < GXK_DIAGNOSTIC_MAX_NODES) {
        UIView *view = pending.lastObject;
        [pending removeLastObject];
        visited++;
        if (view != logo && (view.hidden || view.alpha < 0.05)) continue;
        UIImage *image = nil;
        BOOL draws = [view isKindOfClass:[UIImageView class]];
        if (draws) image = ((UIImageView *)view).image;
        else if ([view respondsToSelector:@selector(image)]) {
            id candidate = [(id<GXKNativeIconContent>)view image];
            if ([candidate isKindOfClass:[UIImage class]]) { draws = YES; image = candidate; }
        }
        CGRect rect = [view convertRect:view.bounds toView:row];
        if (view != logo && draws && !CGRectIsEmpty(rect) && GXKToolbarIconSized(rect)) {
            imageCount++;
            if (images.count < 8) [images addObject:[NSString stringWithFormat:
                @"%@ row=%@ imageSize=%@ scale=%.2f mode=%ld alignInsets=%@", GXKToolbarDiagnosticIdentity(view),
                NSStringFromCGRect(rect), image ? NSStringFromCGSize(image.size) : @"none",
                image ? (double)image.scale : 0.0, (long)view.contentMode,
                image ? NSStringFromUIEdgeInsets(image.alignmentRectInsets) : @"none"]];
            if (!CGRectIsEmpty(own) && !CGRectIntersectsRect(rect, own)) continue;
            CGFloat bottom = CGRectGetMaxY(rect), area = rect.size.width * rect.size.height;
            if (bestArea == 0.0 || bottom > bestBottom + 0.5 ||
                (fabs(bottom - bestBottom) <= 0.5 && area > bestArea)) {
                bestBottom = bottom; bestArea = area; *outGlyph = rect;
            }
            continue;
        }
        for (UIView *child in view.subviews.reverseObjectEnumerator) {
            if (pending.count >= GXK_DIAGNOSTIC_MAX_NODES) { truncated = YES; break; }
            [pending addObject:child];
        }
    }
    truncated = truncated || pending.count > 0;
    NSString *mode = @"images";
    if (bestArea == 0.0 && !CGRectIsEmpty(own)) {
        CGFloat side = MAX(8.0, MIN(own.size.height, 44.0));
        *outGlyph = CGRectMake(CGRectGetMinX(own), CGRectGetMaxY(own) - side, side, side);
        mode = @"fallback-square";
    }
    return [NSString stringWithFormat:@"mode=%@ visited=%lu truncated=%d images=%lu listed=%lu picked=%@\n  %@",
            mode, (unsigned long)visited, truncated, (unsigned long)imageCount, (unsigned long)images.count,
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

static NSString *GXKToolbarDiagnosticSnapshot(UIViewController *vc) {
    UIView *root = vc.view, *row = gToolbarRow, *logo = gToolbarLogoView;
    UILabel *source = gToolbarStyleSource;
    UIStackView *stack = gToolbarStack;
    // This validates the historical observation's identity/tree binding, not its freshness.
    BOOL usedValid = root && row && logo && logo.superview == row &&
                     (row == root || [row isDescendantOfView:root]) &&
                     row == gToolbarDiagnosticBandRow && logo == gToolbarDiagnosticBandLogo;
    CGRect fresh = CGRectZero;
    NSString *glyph = GXKToolbarDiagnosticGlyph(logo, row, &fresh);
    CGFloat usedMid = CGRectGetMidY(gToolbarDiagnosticUsedGlyph);
    CGFloat bandMid = CGRectGetMidY(gToolbarBand);
    return [NSString stringWithFormat:
        @"composingCached=%d stackHidden=%d feedbackActive=%d\nselectedFont=%@/%.2f sourceCurrentFont=%@/%.2f\nsource=%@\nsourceChain=%@\nroot=%@\nrow=%@\nrowParent=%@\nlogo=%@\nbody=%@\nstack=%@\nbandRow=%@ cacheValid=%d epoch=%lu\nusedValid=%d usedGlyphRow=%@ unclampedTop=%.2f finalTop=%.2f usedBandDeltaY=%.2f freshBandDeltaY=%.2f usedObservationUptime=%.3f\nfreshGlyph: %@\n%@",
        gComposingActive, stack.hidden, GXKToolbarDiagnosticNow() < gToolbarDiagnosticFeedbackUntil,
        gToolbarFont.fontName ?: @"fallback-16", gToolbarFont ? (double)gToolbarFont.pointSize : 16.0,
        source.font.fontName ?: @"none", (double)source.font.pointSize,
        GXKToolbarDiagnosticView(source, root), GXKToolbarDiagnosticChain(source),
        GXKToolbarDiagnosticView(root, root), GXKToolbarDiagnosticView(row, root),
        GXKToolbarDiagnosticView(row.superview, root), GXKToolbarDiagnosticView(logo, root),
        GXKToolbarDiagnosticView(gToolbarNineBody, root), GXKToolbarDiagnosticView(stack, root),
        NSStringFromCGRect(gToolbarBand), gToolbarBandCacheValid, (unsigned long)gToolbarBandEpoch,
        usedValid, NSStringFromCGRect(gToolbarDiagnosticUsedGlyph), (double)gToolbarDiagnosticUnclampedTop,
        (double)gToolbarBand.origin.y, (double)(bandMid - usedMid), (double)(bandMid - CGRectGetMidY(fresh)),
        gToolbarDiagnosticBandAt, glyph, GXKToolbarDiagnosticButtons(stack, root)];
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

static void GXKToolbarDiagnosticToggle(UIViewController *vc, UIButton *button) {
    if (gToolbarDiagnosticSamples) {
        GXKToolbarDiagnosticStop(vc, @"manual-stop");
        NSString *header = [NSString stringWithFormat:
            @"GXK toolbar diagnostic v1\niOS=%@ samples=%lu dropped=%lu stop=%@\nCoordinates: UIKit points; root=keyboard root, band/glyph=row space.\nFont pointSize is configured, NOT actual auto-shrunk drawing size.\nFresh glyph uses bounded image-view heuristic, NOT opaque image pixels; truncated=1 is incomplete.\nusedValid checks current identity/tree binding only, NOT geometry freshness.\nusedValid=0 means used geometry is unbound/mismatched; ignore its deltas.\nStart/stop snapshots are immediate; the 0.1 s interval applies to regular refresh reads only.\nrefresh-mask: 1 composing, 2 fast, 4 scan-failed, 8 reuse-resampled, 16 new-resampled, 32 feedback-settle.\nNo input text, key label text, accessibility IDs, disk writes or network uploads.\n",
            [UIDevice currentDevice].systemVersion, (unsigned long)gToolbarDiagnosticSamples.count,
            (unsigned long)gToolbarDiagnosticDropped, gToolbarDiagnosticStopReason ?: @"unknown"];
        [UIPasteboard generalPasteboard].string = [header stringByAppendingString:
            [gToolbarDiagnosticSamples componentsJoinedByString:@""]];
        gToolbarDiagnosticSamples = nil;
        gToolbarDiagnosticLastSnapshot = nil;
        gToolbarDiagnosticChars = 0;
        GXKFlashTitle(button, @"已复制");
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
    gToolbarDiagnosticFeedbackUntil = GXKToolbarDiagnosticNow() + 1.25;
    GXKFlashTitle(button, @"诊断");
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
