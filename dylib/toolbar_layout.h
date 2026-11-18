#ifndef GXK_TOOLBAR_LAYOUT_H
#define GXK_TOOLBAR_LAYOUT_H
// [DEBUG-toolbar] Constant rejection labels only; no capture or extra tree walk here.
static NSString *gToolbarImageGate;
static NSString *gToolbarScanGate;
static NSString *gToolbarBandGate;
static CGRect gToolbarImageDrawnRoot, gToolbarImageVisibleRoot;
static CGRect gToolbarBandCandidateRoot;
static CGRect gToolbarGlyphRoot; // Published only by the current Band measurement, never obstacle/diagnostic image reads.
static CGRect gToolbarBandCacheCandidateRoot;
static __weak UIView *gToolbarRightBoundary;
static CGRect gToolbarRightBoundaryRect;
// Read native image-layer geometry; never infer drawing from UIView.contentMode or a full-row logo frame.
static BOOL GXKToolbarIconSized(CGRect rect) {
    CGSize size = rect.size;
    return size.width >= 8.0 && size.height >= 8.0 && size.width <= 64.0 && size.height <= 64.0;
}

static BOOL GXKToolbarFiniteRect(CGRect rect) {
    return !CGRectIsNull(rect) && !CGRectIsInfinite(rect) && !CGRectIsEmpty(rect) &&
           isfinite(rect.origin.x) && isfinite(rect.origin.y) &&
           isfinite(rect.size.width) && isfinite(rect.size.height);
}

// GKBImageViewWithBackground.layer is the foreground GKBImageLayer. Its background is a sibling,
// and template/tinted images use a mask. Only the proven, unmasked original-image path is measured.
static BOOL GXKToolbarVisibleImageRect(UIView *view, UIView *base, CGRect *outRect) {
    if (outRect) *outRect = CGRectZero;
    gToolbarImageGate = @"binding";
    gToolbarImageDrawnRoot = CGRectZero;
    gToolbarImageVisibleRoot = CGRectZero;
    UIView *root = gCurrentVC.view;
    if (!view || !base || !root.window || view.window != root.window ||
        (base != root && ![base isDescendantOfView:root]) || ![view isDescendantOfView:root] ||
        ![view respondsToSelector:@selector(image)]) return NO;
    UIImage *image = [(id<GXKNativeIconContent>)view image];
    CALayer *layer = view.layer;
    Class imageLayerClass = NSClassFromString(@"GKBImageLayer");
    gToolbarImageGate = @"image-layer-contract";
    if (![image isKindOfClass:[UIImage class]] || !imageLayerClass || ![layer isKindOfClass:imageLayerClass] ||
        ![layer respondsToSelector:@selector(image)] || [(id<GXKNativeIconContent>)layer image] != image ||
        !image.CGImage || image.imageOrientation != UIImageOrientationUp || image.images.count ||
        !UIEdgeInsetsEqualToEdgeInsets(image.capInsets, UIEdgeInsetsZero) || layer.mask ||
        layer.contents != (__bridge id)image.CGImage || !isfinite(layer.contentsScale) || layer.contentsScale <= 0.0 ||
        !CGRectEqualToRect(layer.contentsRect, CGRectMake(0, 0, 1, 1)) ||
        !CGRectEqualToRect(layer.contentsCenter, CGRectMake(0, 0, 1, 1))) return NO;
    gToolbarImageGate = @"layer-bounds";
    CGRect bounds = layer.bounds;
    if (!GXKToolbarFiniteRect(bounds)) return NO;
    CGSize size = CGSizeMake(CGImageGetWidth(image.CGImage) / layer.contentsScale,
                             CGImageGetHeight(image.CGImage) / layer.contentsScale);
    gToolbarImageGate = @"contents-gravity";
    if (![layer.contentsGravity isEqualToString:kCAGravityCenter]) {
        if (![layer.contentsGravity isEqualToString:kCAGravityResizeAspect]) return NO;
        CGFloat scale = MIN(bounds.size.width / size.width, bounds.size.height / size.height);
        size = CGSizeMake(size.width * scale, size.height * scale);
    }
    CGRect drawn = CGRectMake(CGRectGetMidX(bounds) - size.width * 0.5,
                              CGRectGetMidY(bounds) - size.height * 0.5, size.width, size.height);
    CGRect visible = [layer convertRect:drawn toLayer:root.layer];
    gToolbarImageDrawnRoot = visible;
    gToolbarImageVisibleRoot = visible;
    NSUInteger depth = 0;
    for (CALayer *ancestor = layer; ancestor && depth++ < 64; ancestor = ancestor.superlayer) {
        gToolbarImageGate = @"ancestor-hidden-mask-animation-transform";
        // Animated/complex geometry is not a stable axis-aligned anchor; retry after native layout settles.
        if (ancestor.hidden || ancestor.opacity < 0.05 || ancestor.mask || ancestor.animationKeys.count ||
            !CATransform3DIsIdentity(ancestor.transform) || !CATransform3DIsIdentity(ancestor.sublayerTransform)) return NO;
        gToolbarImageGate = @"ancestor-clip-empty";
        if (ancestor.masksToBounds) {
            CGRect clip = [ancestor convertRect:ancestor.bounds toLayer:root.layer];
            if (!GXKToolbarFiniteRect(clip)) return NO;
            visible = CGRectIntersection(visible, clip);
            gToolbarImageVisibleRoot = visible;
        }
        if (!GXKToolbarFiniteRect(visible)) return NO;
        if (ancestor == root.layer) {
            visible = CGRectIntersection(visible, root.layer.bounds);
            gToolbarImageVisibleRoot = visible;
            if (!GXKToolbarFiniteRect(visible)) return NO;
            gToolbarImageGate = @"visible-icon-size";
            CGRect measured = [root.layer convertRect:visible toLayer:base.layer];
            if (!GXKToolbarFiniteRect(measured)) return NO;
            gToolbarImageGate = @"measured";
            if (outRect) *outRect = measured;
            return YES;
        }
    }
    gToolbarImageGate = @"layer-ancestry-incomplete";
    return NO; // Detached or incomplete layer ancestry cannot authorize an anchor.
}

// Only anchors require icon size. Physical obstacles may be partially clipped or larger.
static BOOL GXKToolbarImageRect(UIView *view, UIView *base, CGRect *outRect) {
    if (outRect) *outRect = CGRectZero;
    CGRect measured = CGRectZero;
    if (!GXKToolbarVisibleImageRect(view, base, &measured)) return NO;
    gToolbarImageGate = @"visible-icon-size";
    if (!GXKToolbarIconSized(measured)) return NO;
    gToolbarImageGate = @"measured";
    if (outRect) *outRect = measured;
    return YES;
}

static void GXKToolbarGlyphCollect(UIView *view, UIView *base, NSMutableArray<NSValue *> *out) {
    if (!view || !base || !out) return;
    NSMutableArray<UIView *> *pending = [NSMutableArray arrayWithArray:view.subviews];
    NSUInteger visited = 0;
    while (pending.count && visited++ < 128) {
        UIView *sub = pending.lastObject;
        [pending removeLastObject];
        if (sub.hidden || sub.alpha < 0.05) continue;
        CGRect rect = CGRectZero;
        if (GXKToolbarImageRect(sub, base, &rect)) [out addObject:[NSValue valueWithCGRect:rect]];
        else [pending addObjectsFromArray:sub.subviews];
    }
    if (pending.count) [out removeAllObjects]; // No guess from partial traversal.
}

// Among measured images under this logo, retain the bottommost icon-sized one.
// These are visible image rectangles, not opaque-pixel segmentation or a universal G identity proof.
static BOOL GXKToolbarGlyphRect(UIView *view, UIView *base, CGRect *outRect) {
    if (outRect) *outRect = CGRectZero;
    if (!view || !base) return NO;
    NSMutableArray<NSValue *> *found = [NSMutableArray array];
    GXKToolbarGlyphCollect(view, base, found);
    CGRect best = CGRectZero;
    CGFloat bestBottom = -CGFLOAT_MAX;
    CGFloat bestArea = 0.0;
    for (NSValue *value in found) {
        CGRect rect = value.CGRectValue;
        CGFloat bottom = CGRectGetMaxY(rect);
        CGFloat area = rect.size.width * rect.size.height;
        BOOL better = (bestBottom == -CGFLOAT_MAX) || (bottom > bestBottom + 0.5) ||
                      (fabs(bottom - bestBottom) <= 0.5 && area > bestArea);
        if (better) { bestBottom = bottom; bestArea = area; best = rect; }
    }
    if (bestArea <= 0.0) return NO;
    if (outRect) *outRect = best;
    return YES;
}

// Only actual visible native contents delimit the G band; containers alone reserve no pixels.
static BOOL GXKToolbarBand(UIView *row, UIView *logo, UIView *root, CGRect *outBand) {
    gToolbarBandGate = @"band-binding";
    gToolbarBandCandidateRoot = CGRectZero;
    gToolbarGlyphRoot = CGRectZero;
    gToolbarRightBoundary = nil;
    gToolbarRightBoundaryRect = CGRectZero;
    if (outBand) *outBand = CGRectZero;
    if (!row || !logo || logo.superview != row || !root) return NO;
    CGRect logoRect = logo.frame;
    CGRect glyph = CGRectZero;
    if (!GXKToolbarGlyphRect(logo, row, &glyph)) { gToolbarBandGate = @"band-glyph-missing"; gToolbarBandCacheValid = NO; return NO; }
    CGRect rowInRoot = [row convertRect:row.bounds toView:root];
    CGFloat left = CGRectGetMaxX(glyph) + 4.0;
    // The selected G is a native soft key too: its complete hit carrier cannot be covered.
    CGRect logoCarrierRoot = CGRectZero;
    if (!GXKToolbarContentRect(logo, root, &logoCarrierRoot)) {
        gToolbarBandGate = @"band-logo-carrier-unproven"; gToolbarBandCacheValid = NO; return NO;
    }
    CGRect logoCarrier = [row convertRect:logoCarrierRoot fromView:root];
    if (!CGRectIsEmpty(logoCarrier)) left = MAX(left, CGRectGetMaxX(logoCarrier));
    CGFloat right = CGRectGetMaxX(row.bounds);
    CGFloat barHeight = glyph.size.height;
    if (barHeight < 28.0) barHeight = 28.0;
    if (!GXKToolbarFiniteRect(rowInRoot) || barHeight > row.bounds.size.height) {
        gToolbarBandGate = @"band-row-too-short"; gToolbarBandCacheValid = NO; return NO;
    }
    CGFloat top = CGRectGetMidY(glyph) - barHeight * 0.5;
    GXKToolbarDiagnosticBandObserved(row, logo, glyph, top); // Record the unclamped input, not the adjusted hit top.
    // Constrain only our hit area; title/divider retain the separately measured G center.
    top = MAX(CGRectGetMinY(row.bounds), MIN(top, CGRectGetMaxY(row.bounds) - barHeight));
    CGRect strip = [row convertRect:CGRectMake(left, top, MAX(0.0, right - left), barHeight) toView:root];
    CGFloat rightInRoot = CGRectGetMaxX(strip);
    // Re-read contents before cache reuse: image/text/items can change without an epoch event.
    if (!GXKToolbarNativeRightBoundary(root, logo, strip, &rightInRoot)) {
        gToolbarBandGate = @"band-native-space-unproven";
        gToolbarBandCandidateRoot = strip;
        gToolbarBandCacheValid = NO;
        return NO;
    }
    right = [row convertPoint:CGPointMake(rightInRoot, CGRectGetMinY(strip)) fromView:root].x;
    CGRect candidate = CGRectMake(left, top, right - left, barHeight);
    CGRect candidateInRoot = [row convertRect:candidate toView:root];
    gToolbarBandCandidateRoot = candidateInRoot;
    if (gToolbarBandCacheValid && gToolbarBandCacheRow == row && gToolbarBandCacheLogo == logo &&
        CGSizeEqualToSize(gToolbarBandCacheRowSize, row.bounds.size) &&
        CGRectEqualToRect(gToolbarBandCacheLogoFrame, logoRect) &&
        CGRectEqualToRect(gToolbarBandCacheGlyph, glyph) &&
        CGRectEqualToRect(gToolbarBandCacheRowInRoot, rowInRoot) &&
        CGRectEqualToRect(gToolbarBandCacheRootBounds, root.bounds) &&
        CGRectEqualToRect(gToolbarBandCacheCandidateRoot, candidateInRoot) &&
        gToolbarBandCacheEpoch == gToolbarBandEpoch) {
        gToolbarBandGate = gToolbarBandCacheHit ? @"band-cache-hit" : @"band-cache-rejected";
        if (gToolbarBandCacheHit) gToolbarGlyphRoot = [row convertRect:glyph toView:root];
        if (outBand) *outBand = gToolbarBandCacheBand;
        return gToolbarBandCacheHit;
    }
    BOOL hit = right - left >= 200.0 && CGRectContainsRect(row.bounds, candidate) &&
               CGRectContainsRect(root.bounds, candidateInRoot);
    gToolbarBandCacheCandidateRoot = candidateInRoot;
    gToolbarBandGate = hit ? @"band-clear" : right - left < 200.0 ? @"band-width" : @"band-outside-root";
    gToolbarBandCacheRow = row;
    gToolbarBandCacheLogo = logo;
    gToolbarBandCacheRowSize = row.bounds.size;
    gToolbarBandCacheLogoFrame = logoRect;
    gToolbarBandCacheGlyph = glyph;
    gToolbarBandCacheRowInRoot = rowInRoot;
    gToolbarBandCacheRootBounds = root.bounds;
    gToolbarBandCacheEpoch = gToolbarBandEpoch;
    gToolbarBandCacheValid = YES;
    gToolbarBandCacheHit = hit;
    gToolbarBandCacheBand = hit ? candidate : CGRectZero;
    if (hit) gToolbarGlyphRoot = [row convertRect:glyph toView:root];
    if (outBand) *outBand = gToolbarBandCacheBand;
    return hit;
}

// 一次遍历同时判定：可见九键体、是否还有独立可见的 26 键体、G 图标行。
// 三样缺一就返回 NO，调用方保持原生——宁可不显示工具条，也不猜布局。
static BOOL GXKToolbarScan(UIView *root, UIView **outRow, UIView **outLogo, UIView **outBody, CGRect *outBand) {
    gToolbarScanGate = @"root-or-class-unavailable";
    if (outRow) *outRow = nil;
    if (outLogo) *outLogo = nil;
    if (outBody) *outBody = nil;
    if (outBand) *outBand = CGRectZero;
    Class nineClass = GXKClassCached(@"GKB9KeysSoftKeyboardView", &gCachedNineKeyClass);
    Class qwertyClass = GXKClassCached(@"GKBZhQwertySoftKeyboardView", &gCachedQwertyClass);
    Class logoClass = GXKClassCached(@"GKBHeaderLogoView", &gCachedLogoClass);
    if (!root || !root.window || !nineClass || !qwertyClass || !logoClass) return NO;

    UIView *body = nil;
    // G 图标在树里会出现多次（真机实测至少两处：头行一个、候选行一个）。先命中的往往
    // 不是用户看见的那个，挂错了整条工具条就高出一行。先把候选全收下来，等找到九键体
    // 再按"离键位最近的那个 G"挑，不靠遍历顺序。
    NSMutableArray<NSArray *> *logoCandidates = [NSMutableArray array];
    BOOL qwertyVisible = NO;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    NSUInteger visited = 0;
    while (stack.count && visited++ < 1500) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        if (view.isHidden || view.alpha < 0.05) continue;
        if (view.window != root.window) continue;
        if ([view isKindOfClass:nineClass]) {
            if (!body && GXKKeyIsVisible(view, root)) body = view;
        } else if ([view isKindOfClass:qwertyClass] && GXKKeyIsVisible(view, root)) {
            qwertyVisible = YES; // 九键继承 26 键类，所以九键必须走上面那条分支。
        }
        if ([view isKindOfClass:logoClass] && GXKKeyIsVisible(view, root)) {
            CGRect glyph = CGRectZero;
            if (!GXKToolbarGlyphRect(view, root, &glyph) || CGRectIsEmpty(glyph)) {
                continue; // Missing image cannot authorize a fallback-square anchor.
            }
            if (!CGRectIsEmpty(glyph)) {
                [logoCandidates addObject:@[view, [NSValue valueWithCGRect:glyph]]];
            }
        }
        [stack addObjectsFromArray:view.subviews];
    }
    if (stack.count || !body || qwertyVisible || !logoCandidates.count) {
        gToolbarScanGate = stack.count ? @"tree-incomplete" : !body ? @"nine-body-missing" :
                           qwertyVisible ? @"independent-qwerty" : @"no-measurable-logo";
        return NO;
    }

    // 挑"落在九键体正上方、离它最近"的那个 G：工具栏必须和键位同一条竖线，不能高一行。
    CGRect bodyRect = [body convertRect:body.bounds toView:root];
    UIView *logo = nil;
    CGFloat bestGap = CGFLOAT_MAX;
    CGFloat bestBottom = -CGFLOAT_MAX;
    for (NSArray *entry in logoCandidates) {
        UIView *candidate = entry[0];
        CGRect glyph = [entry[1] CGRectValue];
        CGFloat gap = CGRectGetMinY(bodyRect) - CGRectGetMaxY(glyph);
        if (gap < -8.0) gap = -8.0; // 压进键位体里的不算更近，但也不排除。
        BOOL better = (!logo || gap < bestGap - 0.5) ||
                      (fabs(gap - bestGap) <= 0.5 && CGRectGetMaxY(glyph) > bestBottom);
        if (better) {
            logo = candidate;
            bestGap = gap;
            bestBottom = CGRectGetMaxY(glyph);
        }
    }
    gToolbarScanGate = @"logo-choice-missing";
    if (!logo) return NO;

    gToolbarScanGate = @"row-invisible";
    UIView *row = logo.superview;
    if (!row || row == root || !GXKKeyIsVisible(row, root)) return NO;
    gToolbarScanGate = @"row-size";
    CGSize size = row.bounds.size;
    if (size.width < 100 || size.height < 18 || size.height > 110) return NO;

    CGRect band = CGRectZero;
    gToolbarScanGate = @"band-unavailable";
    if (!GXKToolbarBand(row, logo, root, &band)) return NO;
    gToolbarScanGate = @"scan-success";

    if (outRow) *outRow = row;
    if (outLogo) *outLogo = logo;
    if (outBody) *outBody = body;
    if (outBand) *outBand = band;
    return YES;
}

#endif
