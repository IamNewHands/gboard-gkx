// gkx.m — Gboard iOS 增强 dylib
// Phase 0: 只验证注入链路是否生效（键盘顶部出现 GXK 标记）
//
// 构建：clang -dynamiclib -arch arm64 -miphoneos-version-min=12.0
// 注入：LIEF 给 Gboard.appex/Gboard 加 LC_LOAD_DYLIB @rpath/libgkx.dylib

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <os/log.h>

#define GXK_TAG 0x47584B31  // 'GXK1'

static os_log_t gLog;

static void (*gOrigViewDidLoad)(id, SEL);

static void gkx_viewDidLoad(id self, SEL _cmd) {
    if (gOrigViewDidLoad) {
        gOrigViewDidLoad(self, _cmd);
    }

    UIViewController *vc = (UIViewController *)self;
    UIView *root = vc.view;
    if (!root) {
        return;
    }
    if ([root viewWithTag:GXK_TAG]) {
        return;  // 已经挂过
    }

    UILabel *badge = [[UILabel alloc] initWithFrame:CGRectMake(6, 2, 96, 16)];
    badge.tag = GXK_TAG;
    badge.text = @"GXK OK";
    badge.font = [UIFont boldSystemFontOfSize:10];
    badge.textColor = [UIColor whiteColor];
    badge.backgroundColor = [UIColor colorWithRed:0.10 green:0.60 blue:0.30 alpha:0.85];
    badge.textAlignment = NSTextAlignmentCenter;
    badge.layer.cornerRadius = 3;
    badge.clipsToBounds = YES;
    badge.userInteractionEnabled = NO;

    [root addSubview:badge];

    os_log(gLog, "gkx: badge attached to %{public}s (subviews=%lu)",
           class_getName([vc class]),
           (unsigned long)root.subviews.count);
}

__attribute__((constructor))
static void gkx_init(void) {
    gLog = os_log_create("com.iamnewhands.gkx", "core");

    Class cls = NSClassFromString(@"GKBUIInputViewController");
    if (!cls) {
        os_log(gLog, "gkx: GKBUIInputViewController not found");
        return;
    }

    Method m = class_getInstanceMethod(cls, @selector(viewDidLoad));
    if (!m) {
        os_log(gLog, "gkx: viewDidLoad not found on %s", class_getName(cls));
        return;
    }

    gOrigViewDidLoad = (void (*)(id, SEL))method_getImplementation(m);
    method_setImplementation(m, (IMP)gkx_viewDidLoad);

    os_log(gLog, "gkx: hooked %s viewDidLoad", class_getName(cls));
}
