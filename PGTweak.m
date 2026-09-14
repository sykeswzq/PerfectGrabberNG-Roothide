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

#pragma mark - 诊断日志

static void PGLog(const char *msg) {
    if (!sLogPath) return;
    @try {
        NSString *line = [NSString stringWithFormat:@"%s | %@\n", msg, [NSDate date]];
        NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:sLogPath];
        if (h) {
            [h seekToEndOfFile];
            [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [h closeFile];
        }
    } @catch (NSException *e) {}
}

static void PGInitLogPath(void) {
    if (sLogPath) return;
    @try {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *doc = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
        NSMutableArray *cands = [NSMutableArray array];
        if (doc.length) [cands addObject:[doc stringByAppendingPathComponent:@"pgng_diag.log"]];
        [cands addObject:@"/var/mobile/pgng_diag.log"];
        [cands addObject:[PGJbRoot() stringByAppendingPathComponent:@"var/mobile/pgng_diag.log"]];
        for (NSString *p in cands) {
            if ([fm fileExistsAtPath:p] ||
                [@"" writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:NULL]) {
                sLogPath = p;
                PGLog([NSString stringWithFormat:@"log_path=%@", p].UTF8String);
                break;
            }
        }
    } @catch (NSException *e) {}
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

        _token += 1;
        NSInteger my = _token;
        NSTimeInterval d = PGDuration();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (my == _token) [self pg_hide];
        });
    } @catch (NSException *e) {}
}

- (void)pg_hide {
    if (!_infoView) return;
    _infoView.alpha = 0.0;
    _infoView.transform = CGAffineTransformIdentity;
}
@end

#pragma mark - 入口（回归 v2.0.12 稳定模式）

static NSString *PGDiagStatus(void) {
    NSMutableArray *a = [NSMutableArray array];
    @try {
        [a addObject:[NSString stringWithFormat:@"mainBundle=%@", [[NSBundle mainBundle] bundleIdentifier] ?: @"(null)"]];
        NSArray *args = [[NSProcessInfo processInfo] arguments];
        [a addObject:[NSString stringWithFormat:@"exe=%@", args.count ? args[0] : @"(?)"]];
        [a addObject:[NSString stringWithFormat:@"resolved=%@", PGAppBundleID()]];
        [a addObject:[NSString stringWithFormat:@"system=%@ selected=%@",
                      PGIsSystemProcess() ? @"Y" : @"N",
                      PGCurrentAppSelected() ? @"Y" : @"N"]];
        [a addObject:[NSString stringWithFormat:@"sharedApp=%@", [UIApplication sharedApplication] ? @"Y" : @"N"]];
    } @catch (NSException *e) { [a addObject:@"err"]; }
    return [a componentsJoinedByString:@" "];
}

__attribute__((constructor))
static void PGInit(void) {
    @autoreleasepool {
        const char *exe = getprogname();
        if (!exe) return;

        // C 层路径过滤：排除系统进程
        if (strncmp(exe, "/System", 7) == 0) return;
        if (strncmp(exe, "/usr", 4) == 0) return;
        if (strncmp(exe, "/bin", 4) == 0) return;
        if (strncmp(exe, "/sbin", 5) == 0) return;
        if (strncmp(exe, "/Library", 8) == 0) return;
        if (strstr(exe, "SpringBoard")) return;
        if (strstr(exe, "/var/jb")) return;
        if (strstr(exe, "/var/lib")) return;
        if (!strstr(exe, ".app/")) return;

        // 初始化日志路径
        PGInitLogPath();

        NSString *bid = PGAppBundleID();
        PGLog([NSString stringWithFormat:@"constructor: bid=%@", bid].UTF8String);
        PGLog([NSString stringWithFormat:@"diagnostics: %@", PGDiagStatus()].UTF8String);

        // 越狱管理类 App：window 结构特殊，注入易崩，直接跳过
        if ([bid isEqualToString:@"com.coolstar.SileoStore"] ||
            [bid isEqualToString:@"com.rile.ios.Sileo"] ||
            [bid isEqualToString:@"com.tigisoftware.Filza"] ||
            [bid isEqualToString:@"com.saurik.Cydia"] ||
            [bid isEqualToString:@"com.zebra.renati"] ||
            [bid hasPrefix:@"com.opa334."]) {
            return;
        }

        // ★ 关键：直接在构造函数期注册通知，不做懒加载
        // 原因：PGLazyInit 模式会导致 didFinishLaunching 先于懒加载触发时
        //       observer 永远不注册，窗口不创建 → 用户感知为"注入无效"

        // 注册设置变更通知
        notify_register_dispatch(PGNotifyName, &sNotifyToken, dispatch_get_main_queue(), ^(int t) {
            [[PGOverlay shared] pg_reload];
        });

        // 多时机触发安装
        void (^tryInstall)(void) = ^{
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [[PGOverlay shared] pg_install];
            });
        };

        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
            PGLog("notify: didFinishLaunching");
            tryInstall();
        }];

        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
            PGLog("notify: didBecomeActive");
            tryInstall();
        }];

        // 兜底：dylib 在 App 已激活后才注入的情况
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UIApplication *app = [UIApplication sharedApplication];
            if (app && app.applicationState == UIApplicationStateActive) {
                PGLog("delay: 2s fallback install");
                [[PGOverlay shared] pg_install];
            }
        });
    }
}
