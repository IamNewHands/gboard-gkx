// Native typography is owned by the identified return key, never tree-order labels.
#ifndef GXK_NATIVE_KEY_STYLE_H
#define GXK_NATIVE_KEY_STYLE_H

static __weak UIView *gNativeStyleBody;
static __weak UIView *gNativeStyleKey;
static __weak UILabel *gNativeStyleLabel;
static CFTimeInterval gNativeStyleScanAt;

static void GXKResetNativeKeyStyle(void) {
    gNativeStyleBody = nil;
    gNativeStyleKey = nil;
    gNativeStyleLabel = nil;
    gNativeStyleScanAt = 0;
}

static UILabel *GXKNativeReturnLabel(UIView *key, UIView *body, UIView *root) {
    Class keyClass = GXKClassCached(@"GKBSoftKeyView", &gCachedKeyClass);
    if (!key || !body || !root || !keyClass || ![key isKindOfClass:keyClass] || ![key isDescendantOfView:body] ||
        ![key.restorationIdentifier isEqualToString:@"key_pos_9keys_return"] ||
        !GXKKeyIsVisible(key, root) || ![key respondsToSelector:@selector(idToViewDict)]) return nil;
    NSDictionary *contents = ((id<GXKNativeSoftKeyContent>)key).idToViewDict;
    UILabel *label = [contents isKindOfClass:[NSDictionary class]] ? contents[@"label"] : nil;
    if (![label isKindOfClass:[UILabel class]] || ![label isDescendantOfView:key] ||
        ![label.font isKindOfClass:[UIFont class]]) return nil;
    return label;
}

static UILabel *GXKNativeKeyStyleLabel(UIView *body, UIView *root) {
    if (!body || !root || !GXKKeyIsVisible(body, root)) return nil;
    UILabel *live = GXKNativeReturnLabel(gNativeStyleKey, body, root);
    if (gNativeStyleBody == body && live && live == gNativeStyleLabel) return live;
    BOOL sameBody = gNativeStyleBody == body;
    gNativeStyleBody = body;
    gNativeStyleKey = nil;
    gNativeStyleLabel = nil;
    CFTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (sameBody && now - gNativeStyleScanAt < 0.25) return nil;
    gNativeStyleScanAt = now;
    Class keyClass = GXKClassCached(@"GKBSoftKeyView", &gCachedKeyClass);
    if (!keyClass) return nil;
    NSMutableArray<UIView *> *pending = [NSMutableArray arrayWithObject:body];
    UIView *candidate = nil;
    UILabel *selected = nil;
    NSUInteger visited = 0;
    while (pending.count && visited++ < 300) {
        UIView *view = pending.lastObject;
        [pending removeLastObject];
        if (view.hidden || view.alpha < 0.05) continue;
        if ([view isKindOfClass:keyClass]) {
            UILabel *label = GXKNativeReturnLabel(view, body, root);
            if (label) {
                if (candidate && candidate != view) return nil; // Ambiguous owner: do not guess.
                candidate = view;
                selected = label;
            }
            continue; // Key contents cannot own another independent native return key.
        }
        // Candidate/preedit collections are not typography owners.
        if ([view isKindOfClass:[UICollectionView class]]) continue;
        [pending addObjectsFromArray:view.subviews];
    }
    if (pending.count || !selected) return nil; // Incomplete scan never becomes a valid binding.
    gNativeStyleKey = candidate;
    gNativeStyleLabel = selected;
    return selected;
}

static UIFont *GXKNativeKeyFont(UIView *body, UIView *root) {
    UIFont *font = GXKNativeKeyStyleLabel(body, root).font;
    // Verified stock softkey_9keys_label_blue.nib font, not the last candidate font.
    return font ?: [UIFont fontWithName:@"Roboto-Regular" size:16.0] ?: [UIFont systemFontOfSize:16.0];
}

#endif
