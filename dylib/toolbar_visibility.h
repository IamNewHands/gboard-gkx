// Current native contents outrank the toolbar. Discovery is event-scoped; reuse reads live views.
#ifndef GXK_TOOLBAR_VISIBILITY_H
#define GXK_TOOLBAR_VISIBILITY_H
static __weak UIView *gToolbarObstacleRoot;
static __weak UIView *gToolbarObstacleLogo;
static NSHashTable<UIView *> *gToolbarObstacles;
static NSHashTable<UIView *> *gToolbarKeyboardBodies;
static NSUInteger gToolbarContentEpoch;
static NSUInteger gToolbarObstacleEpoch;
static BOOL gToolbarObstacleComplete;
// [DEBUG-toolbar] Last production decision survives stack detachment.
static NSString *gToolbarSpaceGate;
static __weak UIView *gToolbarSpaceBlocker;
static CGRect gToolbarSpaceBand;

static BOOL GXKToolbarContentBlocks(UIView *view, UIView *root, CGRect band) {
    if (!GXKKeyIsVisible(view, root)) return NO;
    CGRect rect = [view convertRect:view.bounds toView:root];
    if (CGRectIsEmpty(CGRectIntersection(rect, band))) return NO;
    if ([view isKindOfClass:[UICollectionView class]]) {
        UICollectionView *collection = (UICollectionView *)view;
        if (collection.visibleCells.count) return YES;
        NSInteger sections = collection.numberOfSections;
        if (sections > 64) return YES;
        for (NSInteger section = 0; section < sections; section++) {
            if ([collection numberOfItemsInSection:section] > 0) return YES;
        }
        return NO;
    }
    if ([view isKindOfClass:[UILabel class]]) {
        UILabel *label = (UILabel *)view;
        return label.text.length > 0 || label.attributedText.length > 0;
    }
    Class keyClass = GXKClassCached(@"GKBSoftKeyView", &gCachedKeyClass);
    if ((keyClass && [view isKindOfClass:keyClass]) || [view isKindOfClass:[UIButton class]]) return YES;
    if ([view respondsToSelector:@selector(image)]) {
        UIImage *image = [(id<GXKNativeIconContent>)view image];
        return [image isKindOfClass:[UIImage class]] && GXKToolbarIconSized(view.bounds);
    }
    return YES; // Native keys and buttons own their hit regions.
}

static BOOL GXKToolbarNativeSpaceClear(UIView *root, UIView *logo, CGRect band) {
    gToolbarSpaceGate = @"invalid-band-binding";
    gToolbarSpaceBlocker = nil;
    gToolbarSpaceBand = band;
    if (!root || !logo || !CGRectContainsRect(root.bounds, band)) return NO;
    BOOL rebuild = gToolbarObstacleRoot != root || gToolbarObstacleLogo != logo ||
                   gToolbarObstacleEpoch != gToolbarContentEpoch ||
                   !gToolbarObstacleComplete;
    if (!rebuild) {
        for (UIView *view in gToolbarObstacles) {
            if (![view isDescendantOfView:root]) { rebuild = YES; break; }
        }
    }
    if (rebuild) {
        gToolbarObstacleRoot = root;
        gToolbarObstacleLogo = logo;
        gToolbarObstacleEpoch = gToolbarContentEpoch;
        gToolbarObstacleComplete = NO;
        gToolbarObstacles = [NSHashTable weakObjectsHashTable];
        gToolbarKeyboardBodies = [NSHashTable weakObjectsHashTable];
        Class keyClass = GXKClassCached(@"GKBSoftKeyView", &gCachedKeyClass);
        Class nineClass = GXKClassCached(@"GKB9KeysSoftKeyboardView", &gCachedNineKeyClass);
        Class qwertyClass = GXKClassCached(@"GKBZhQwertySoftKeyboardView", &gCachedQwertyClass);
        gToolbarSpaceGate = @"keyboard-class-unavailable";
        if (!keyClass || !nineClass || !qwertyClass) return NO;
        NSMutableArray<UIView *> *pending = [NSMutableArray arrayWithObject:root];
        NSUInteger visited = 0;
        while (pending.count && visited++ < 800) {
            UIView *view = pending.lastObject;
            [pending removeLastObject];
            if (view == logo || view == gToolbarStack || view == gActionKeyButton) continue;
            // Hidden keyboard owners are registered too: a 9→26 switch can reuse both objects.
            if ([view isKindOfClass:nineClass] || [view isKindOfClass:qwertyClass])
                [gToolbarKeyboardBodies addObject:view];
            // Include hidden objects in the registry: they may become visible without replacement.
            BOOL key = [view isKindOfClass:keyClass];
            BOOL collection = [view isKindOfClass:[UICollectionView class]];
            BOOL leaf = key || collection || [view isKindOfClass:[UIButton class]];
            // Register the carrier even while its image is nil; contents can appear without an epoch change.
            BOOL icon = [view respondsToSelector:@selector(image)];
            if (leaf || icon || [view isKindOfClass:[UILabel class]]) [gToolbarObstacles addObject:view];
            if (!leaf) [pending addObjectsFromArray:view.subviews];
        }
        gToolbarSpaceGate = @"obstacle-tree-incomplete";
        if (pending.count) return NO;
        gToolbarObstacleComplete = YES;
    }
    // Revalidate owners on every reuse, independently of whether their keys overlap the band.
    Class nineClass = GXKClassCached(@"GKB9KeysSoftKeyboardView", &gCachedNineKeyClass);
    Class qwertyClass = GXKClassCached(@"GKBZhQwertySoftKeyboardView", &gCachedQwertyClass);
    BOOL nineVisible = NO;
    for (UIView *body in gToolbarKeyboardBodies) {
        if (!GXKKeyIsVisible(body, root)) continue;
        if ([body isKindOfClass:nineClass]) nineVisible = YES; // Nine-key inherits the QWERTY class.
        else if ([body isKindOfClass:qwertyClass]) {
            gToolbarSpaceGate = @"independent-qwerty";
            gToolbarSpaceBlocker = body;
            return NO;
        }
    }
    gToolbarSpaceGate = @"nine-body-not-visible";
    if (!nineVisible) return NO;
    for (UIView *view in gToolbarObstacles) {
        if (GXKToolbarContentBlocks(view, root, band)) {
            gToolbarSpaceGate = @"native-obstacle";
            gToolbarSpaceBlocker = view;
            return NO;
        }
    }
    gToolbarSpaceGate = @"space-clear";
    return YES;
}
#endif
