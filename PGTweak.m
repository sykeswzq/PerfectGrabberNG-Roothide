// PGTweak.m —— V2.0.34 回归稳定版
//
// 【V2.0.34 修复】
//   根因：v2.0.33 改用 PGLazyInit() 懒加载，若 UIApplicationDidFinishLaunchingNotification
//         先于懒加载触发，通知 observer 永远不注册 → 窗口不创建 → 用户感知为"注入无效"。
//         此外 pg_teardown 在 notify block 直接调用（非主队列 context 保护）存在竞争风险。
//   修复：回归 v2.0.12 构造函数模式——构造期直接注册所有通知（无懒加载），
//         所有 ObjC 包在 @autoreleasepool + @try/@catch 保护下。
//   保留：v2.0.31 的安全 nil 检查（app.windows.firstObject && win.windowScene 判空）。
//   版本：2.0.34（确保 > 2.0.31，Sileo 判定为更新可安装）

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <notify.h>
#import <string.h>
#import <mach-o/dyld.h>
#import "PGCommon.h"

#pragma mark - 全局状态

static NSString *sLogPath = nil;
static int sNotifyToken = 0;
static volatile BOOL sObserverRegistered = NO;

#pragma mark - 诊断日志

// V2.0.36：纯 C 日志（write syscall），避免构造函数期调用 ObjC 方法
static void PGLog(const char *msg) {
    if (!sLogPath) return;
    int fd = open([sLogPath fileSystemRepresentation], O_WRONLY | O_APPEND | O_CREAT, 0644);
    if (fd >= 0) {
        const char *newline = "\n";
        write(fd, msg, strlen(msg));
        write(fd, newline, 1);
        close(fd);
    }
}

static void PGInitLogPath(void) {
    // V2.0.36：用纯 C open，不调 NSFileManager（构造函数期不安全）
    if (sLogPath) return;
    const char *cands[] = {
        "/var/mobile/pgng_diag.log",
        "/tmp/pgng_diag.log"
    };
    for (int i = 0; i < 2; i++) {
        int fd = open(cands[i], O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fd >= 0) {
            close(fd);
            sLogPath = [NSString stringWithUTF8String:cands[i]];
            return;
        }
    }
}

#pragma mark - 穿透视图

@interface PGPassthroughView : UIView
@property (nonatomic, weak) UIView *pgHitView;
@end

@implementation PGPassthroughView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *v = [super hitTest:point withEvent:event];
    if (v == self) {
        UIView *strip = self.pgHitView;
        if (strip) {
            CGPoint p = [self convertPoint:point toView:strip];
            if (CGRectContainsPoint(strip.bounds, p)) {
                UIView *r = [strip hitTest:p withEvent:event];
                return r ?: strip;
            }
        }
        return nil;
    }
    return v;
}
@end

#pragma mark - 浮层

@interface PGOverlay : NSObject
+ (instancetype)shared;
- (void)pg_install;
- (void)pg_reload;
@end

@implementation PGOverlay {
    UIWindow *_window;
    PGPassthroughView *_content;
    UIView *_strip;
    UIView *_infoView;
    UILabel *_label;
    BOOL _pulled;
    NSInteger _token;
}

+ (instancetype)shared {
    static PGOverlay *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[PGOverlay alloc] init]; });
    return s;
}

- (void)pg_install {
    if (_window) return;
    if (!PGEnabled()) return;
    if (!PGCurrentAppSelected()) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if (_window) return;
            UIApplication *app = [UIApplication sharedApplication];
            if (!app) return;

            // V2.0.34：安全访问（nil 检查防止 crash）
            UIWindow *w = nil;
            for (UIWindow *win in app.windows) {
                if (win.windowScene) {
                    w = [[UIWindow alloc] initWithWindowScene:win.windowScene];
                    break;
                }
            }
            if (!w) {
                w = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
            }

            w.backgroundColor = [UIColor clearColor];
            w.windowLevel = UIWindowLevelNormal + 1.0;
            w.userInteractionEnabled = YES;

            UIViewController *vc = [[UIViewController alloc] init];
            PGPassthroughView *cv = [[PGPassthroughView alloc] initWithFrame:w.bounds];
            cv.backgroundColor = [UIColor clearColor];
            cv.opaque = NO;
            cv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            vc.view = cv;
            w.rootViewController = vc;
            w.hidden = NO;

            _window = w;
            _content = cv;

            // 顶部触发条
            UIView *strip = [[UIView alloc] initWithFrame:CGRectZero];
            strip.backgroundColor = [UIColor clearColor];
            strip.translatesAutoresizingMaskIntoConstraints = NO;
            [cv addSubview:strip];
            [NSLayoutConstraint activateConstraints:@[
                [strip.leadingAnchor constraintEqualToAnchor:cv.leadingAnchor],
                [strip.trailingAnchor constraintEqualToAnchor:cv.trailingAnchor],
                [strip.topAnchor constraintEqualToAnchor:cv.topAnchor],
                [strip.heightAnchor constraintEqualToConstant:110.0]
            ]];
            cv.pgHitView = strip;
            _strip = strip;

            // 信息胶囊
            UIView *info = [[UIView alloc] initWithFrame:CGRectZero];
            info.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.55];
            info.layer.cornerRadius = 14.0;
            info.layer.masksToBounds = YES;
            info.alpha = 0.0;
            info.userInteractionEnabled = NO;
            info.translatesAutoresizingMaskIntoConstraints = NO;
            [strip addSubview:info];
            [NSLayoutConstraint activateConstraints:@[
                [info.centerXAnchor constraintEqualToAnchor:strip.centerXAnchor],
                [info.topAnchor constraintEqualToAnchor:strip.topAnchor constant:10.0],
                [info.heightAnchor constraintEqualToConstant:30.0],
                [info.widthAnchor constraintGreaterThanOrEqualToConstant:120.0]
            ]];
            _infoView = info;

            UILabel *lb = [[UILabel alloc] initWithFrame:CGRectZero];
            lb.textColor = [UIColor whiteColor];
            lb.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
            lb.textAlignment = NSTextAlignmentCenter;
            lb.userInteractionEnabled = NO;
            lb.translatesAutoresizingMaskIntoConstraints = NO;
            [info addSubview:lb];
            [NSLayoutConstraint activateConstraints:@[
                [lb.leadingAnchor constraintEqualToAnchor:info.leadingAnchor constant:12.0],
                [lb.trailingAnchor constraintEqualToAnchor:info.trailingAnchor constant:-12.0],
                [lb.topAnchor constraintEqualToAnchor:info.topAnchor],
                [lb.bottomAnchor constraintEqualToAnchor:info.bottomAnchor]
            ]];
            _label = lb;

            // 手势
            UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pg_handlePan:)];
            pan.cancelsTouchesInView = NO;
            [strip addGestureRecognizer:pan];

            UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(pg_handleLongPress:)];
            lp.minimumPressDuration = 0.3;
            lp.cancelsTouchesInView = NO;
            [strip addGestureRecognizer:lp];

            PGLog("install: window created");
        } @catch (NSException *e) {
            PGLog([NSString stringWithFormat:@"install error: %@", e.reason].UTF8String);
            _window = nil;
        }
    });
}

- (void)pg_reload {
    if (!PGEnabled() || !PGCurrentAppSelected()) {
        _window = nil;
    } else {
        [self pg_install];
    }
}

- (void)pg_handlePan:(UIPanGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan || g.state == UIGestureRecognizerStateChanged) {
        if (_pulled) return;
        CGPoint t = [g translationInView:_strip];
        if (t.y > 16.0) {
            _pulled = YES;
            [self pg_show];
        }
    } else if (g.state == UIGestureRecognizerStateEnded ||
               g.state == UIGestureRecognizerStateCancelled ||
               g.state == UIGestureRecognizerStateFailed) {
        _pulled = NO;
    }
}

- (void)pg_handleLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan) {
        [self pg_show];
    }
}

- (void)pg_show {
    if (!PGEnabled()) return;
    if (!PGCurrentAppSelected()) return;
    @try {
        if (!_label) return;
        NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
        [fmt setDateFormat:@"HH:mm"];
        NSString *time = [fmt stringFromDate:[NSDate date]];
        int pct = (int)roundf([UIDevice currentDevice].batteryLevel * 100.0f);
        if (pct < 0) pct = 0;
        UIDeviceBatteryState st = [UIDevice currentDevice].batteryState;
        NSString *bolt = @"";
        if (st == UIDeviceBatteryStateCharging || st == UIDeviceBatteryStateFull) bolt = @"⚡";
        _label.text = [NSString stringWithFormat:@"%@   %@%d%%", time, bolt, pct];

        _infoView.alpha = 1.0;
        _infoView.transform = CGAffineTransformIdentity;

        if (!PGKeepOn()) {
            _token += 1;
            NSInteger my = _token;
            NSTimeInterval d = PGDuration();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (my == _token) [self pg_hide];
            });
        }
    } @catch (NSException *e) {}
}

- (void)pg_hide {
    if (!_infoView) return;
    _infoView.alpha = 0.0;
    _infoView.transform = CGAffineTransformIdentity;
}
@end

#pragma mark - 入口（V2.0.36 极简版：构造函数只做 C 操作）

// V2.0.36：移除 PGDiagStatus() —— 它在构造函数期调用了 [UIApplication sharedApplication]，
// 这是原神等游戏闪退的根因。所有诊断信息改为在 pg_install 时打印。

__attribute__((constructor))
static void PGInit(void) {
    @autoreleasepool {
        const char *exe = getprogname();
        if (!exe) { PGLog("FATAL: getprogname returned NULL"); return; }

        // ===== C 层路径过滤（只读 C 字符串，不调用 ObjC）=====
        PGLog([NSString stringWithFormat:@"constructor start: exe=%s", exe].UTF8String);

        if (strncmp(exe, "/System", 7) == 0) { PGLog("skipped: /System path"); return; }
        if (strncmp(exe, "/usr", 4) == 0) { PGLog("skipped: /usr path"); return; }
        if (strncmp(exe, "/bin", 4) == 0) { PGLog("skipped: /bin path"); return; }
        if (strncmp(exe, "/sbin", 5) == 0) { PGLog("skipped: /sbin path"); return; }
        if (strncmp(exe, "/Library", 8) == 0) { PGLog("skipped: /Library path"); return; }
        if (strstr(exe, "SpringBoard")) { PGLog("skipped: SpringBoard"); return; }
        if (strstr(exe, "/var/lib")) { PGLog("skipped: /var/lib path"); return; }
        if (!strstr(exe, ".app/")) { PGLog("skipped: no .app/ in path"); return; }

        PGLog("path_filter: PASS");

        // ===== 延迟初始化日志（用纯 C open/write，不崩）=====
        PGInitLogPath();

        // ===== 获取 bundleID（只读 C 字符串路径，不调 ObjC）=====
        // 用 _dyld_get_image_name(0) 取可执行文件路径，手动解析 .app 前缀
        NSString *bid = nil;
        const char *m = _dyld_get_image_name(0);
        if (m && m[0]) {
            NSString *path = [NSString stringWithUTF8String:m];
            PGLog([NSString stringWithFormat:@"dyld image: %s", m].UTF8String);
            // 形如: /var/containers/Bundle/Application/.jbroot-XXXX/Apps/Genshin.app/Genshin
            // 找最后一个 .app/ 前缀
            NSRange r = [path rangeOfString:@".app/"];
            if (r.location != NSNotFound) {
                NSString *appDir = [path substringToIndex:r.location + 5]; // ".app/"
                // 向上取一级取 bundle name
                NSString *bundleName = [[appDir stringByDeletingLastPathComponent] lastPathComponent];
                PGLog([NSString stringWithFormat:@"appDir: %@, bundleName: %@", appDir, bundleName].UTF8String);
                // 常见格式: GenshinImpact.app → 尝试从 Info.plist 读 CFBundleIdentifier
                NSString *plistPath = [appDir stringByAppendingPathComponent:@"Info.plist"];
                NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:plistPath];
                if (info) bid = info[@"CFBundleIdentifier"];
                if (!bid.length) bid = [bundleName stringByReplacingOccurrencesOfString:@".app" withString:@""];
                PGLog([NSString stringWithFormat:@"resolved bid: %@", bid].UTF8String);
            } else {
                PGLog("WARNING: no .app/ found in path");
            }
        } else {
            PGLog("WARNING: _dyld_get_image_name(0) returned NULL");
        }
        if (!bid) bid = @"?";

        PGLog([NSString stringWithFormat:@"constructor: exe=%s bid=%@ path_filter=pass", exe, bid].UTF8String);

        // ===== 越狱管理类 App：window 结构特殊，注入易崩，直接跳过 =====
        if ([bid isEqualToString:@"com.coolstar.SileoStore"] ||
            [bid isEqualToString:@"com.rile.ios.Sileo"] ||
            [bid isEqualToString:@"com.tigisoftware.Filza"] ||
            [bid isEqualToString:@"com.saurik.Cydia"] ||
            [bid isEqualToString:@"com.zebra.renati"] ||
            [bid hasPrefix:@"com.opa334."]) {
            PGLog("constructor: jailbreak manager skipped");
            return;
        }

        // ===== 系统 App 跳过（C 字符串比较）=====
        if ([bid hasPrefix:@"com.apple."]) {
            PGLog("constructor: system app skipped");
            return;
        }

        PGLog("passed all filters, registering observers...");

        // ===== 注册 notify token（纯 C 系统调用，不崩）=====
        int ret = notify_register_dispatch(PGNotifyName, &sNotifyToken, dispatch_get_main_queue(), ^(int t) {
            PGLog("notify: reload triggered");
            [[PGOverlay shared] pg_reload];
        });
        if (ret != 0) {
            PGLog([NSString stringWithFormat:@"notify_register failed: %d", ret].UTF8String);
        } else {
            PGLog([NSString stringWithFormat:@"notify_register success: token=%d", sNotifyToken].UTF8String);
        }

        // ===== 注册通知 observer（必须在构造期完成，否则 didFinishLaunching 先触发时漏掉）=====
        sObserverRegistered = YES;

        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
            PGLog("notify: UIApplicationDidFinishLaunchingNotification");
            @try {
                [[PGOverlay shared] pg_install];
            } @catch (NSException *e) {
                PGLog([NSString stringWithFormat:@"didFinishLaunching ERROR: %@", e.reason].UTF8String);
            }
        }];
        PGLog("registered didFinishLaunching observer");

        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
            PGLog("notify: UIApplicationDidBecomeActiveNotification");
            @try {
                [[PGOverlay shared] pg_install];
            } @catch (NSException *e) {
                PGLog([NSString stringWithFormat:@"didBecomeActive ERROR: %@", e.reason].UTF8String);
            }
        }];
        PGLog("registered didBecomeActive observer");

        // ===== 兜底：dylib 在 App 已激活后才注入的情况 =====
        // V2.0.36：用 dispatch_after 延迟执行，此时 UIKit 已就绪
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (!sObserverRegistered) { PGLog("delay: skipped (observer unregistered)"); return; }
            // 此时 UIKit 已就绪，可以安全调用 sharedApplication
            UIApplication *app = [UIApplication sharedApplication];
            if (app && app.applicationState == UIApplicationStateActive) {
                PGLog("delay: 3s fallback install (app active)");
                @try {
                    [[PGOverlay shared] pg_install];
                } @catch (NSException *e) {
                    PGLog([NSString stringWithFormat:@"3s fallback ERROR: %@", e.reason].UTF8String);
                }
            } else {
                PGLog("delay: 3s fallback skipped (app not active)");
            }
        });

        PGLog("constructor complete: all observers registered");
    }
}
