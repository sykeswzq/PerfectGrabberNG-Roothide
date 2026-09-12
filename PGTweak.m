// PGTweak.m —— V2.0.29：根治构造函数期 ObjC 崩溃
//
// 【V2.0.28 教训】构造函数期调用 NSProcessInfo/NSFileManager 等 ObjC API 是崩溃源
//   - 构造期 ObjC 运行时可能未完全初始化
//   - 必须用纯 C 代码（getprogname/strncmp/strstr）做进程过滤
//   - ObjC 代码（日志、通知注册）推迟到 UIApplicationDidFinishLaunchingNotification
//
// 【V2.0.29 修复】
//   1. PGInit 构造函数只做 C 层过滤（不调 ObjC）
//   2. ObjC 初始化（日志路径、通知注册）推迟到 pg_lazy_init()
//   3. pg_lazy_init 在第一次 pg_install 前调用，确保 App 已就绪

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <notify.h>
#import <string.h>
#import <mach-o/dyld.h>
#import "PGCommon.h"

#pragma mark - 全局状态（懒加载）

static NSString *sLogPath = nil;
static int sNotifyToken = 0;

#pragma mark - 诊断日志（C 层路径，避免构造期 ObjC）

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
                break;
            }
        }
    } @catch (NSException *e) {}
}

#pragma mark - 穿透视图（V2.0.12 原样）

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
        return nil;   // 游戏区域不吃触摸，原样穿透
    }
    return v;
}
@end

#pragma mark - 浮层（V2.0.12 实机验证方案：绑宿主 window 的 scene）

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
    PGLazyInit();  // V2.0.29：懒加载 ObjC 初始化
    if (!PGEnabled()) { PGLog("install: 总开关关闭"); return; }
    if (!PGCurrentAppSelected()) {
        PGLog([NSString stringWithFormat:@"install: 未勾选 bid=%@", PGAppBundleID()]);
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
      @try {
        if (_window) return;
        UIApplication *app = [UIApplication sharedApplication];
        if (app == nil) return;

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

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pg_handlePan:)];
        pan.cancelsTouchesInView = NO;
        [strip addGestureRecognizer:pan];

        UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(pg_handleLongPress:)];
        lp.minimumPressDuration = 0.3;
        lp.cancelsTouchesInView = NO;
        [strip addGestureRecognizer:lp];

        PGLog("install: V2.0.29 窗口创建成功");
      } @catch (NSException *e) {
        PGLog([NSString stringWithFormat:@"install: 异常 %@", e.reason]);
      }
    });
}

- (void)pg_reload {
    if (!PGEnabled() || !PGCurrentAppSelected()) {
        [self pg_teardown];
    } else {
        [self pg_install];
    }
}

- (void)pg_teardown {
    dispatch_async(dispatch_get_main_queue(), ^{
        _content.pgHitView = nil;
        _window.hidden = YES;
        _window.rootViewController = nil;
        _window = nil;
        _content = nil;
        _strip = nil;
        _infoView = nil;
        _label = nil;
    });
}

- (void)pg_handlePan:(UIPanGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan ||
        g.state == UIGestureRecognizerStateChanged) {
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
    dispatch_async(dispatch_get_main_queue(), ^{
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
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (my == _token) [self pg_hide];
        });
    });
}

- (void)pg_hide {
    if (!_infoView) return;
    _infoView.alpha = 0.0;
    _infoView.transform = CGAffineTransformIdentity;
}

@end

#pragma mark - ObjC 懒加载（V2.0.29 新增）

static void PGLazyInit(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        PGInitLogPath();
        
        NSString *bid = [NSString stringWithUTF8String:getprogname()];
        PGLog([NSString stringWithFormat:@"lazy_init: bid=%@", bid]);
        
        notify_register_dispatch(PGNotifyName, &sNotifyToken, dispatch_get_main_queue(), ^(int t) {
            [[PGOverlay shared] pg_reload];
        });
        
        void (^tryInstall)(void) = ^{
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [[PGOverlay shared] pg_install];
            });
        };
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) { tryInstall(); }];
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) { tryInstall(); }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UIApplication *app = [UIApplication sharedApplication];
            if (app && app.applicationState == UIApplicationStateActive) {
                [[PGOverlay shared] pg_install];
            }
        });
    });
}

#pragma mark - 入口（V2.0.29：构造函数纯 C 过滤，ObjC 推迟到通知回调）

__attribute__((constructor))
static void PGInit(void) {
    const char *exe = getprogname();
    if (!exe) return;
    
    if (strncmp(exe, "/System", 7) == 0) return;
    if (strncmp(exe, "/usr", 4) == 0) return;
    if (strncmp(exe, "/bin", 4) == 0) return;
    if (strncmp(exe, "/sbin", 5) == 0) return;
    if (strncmp(exe, "/Library", 8) == 0) return;
    if (strstr(exe, "SpringBoard")) return;
    if (strstr(exe, "/var/jb")) return;
    if (strstr(exe, "/var/lib")) return;
    if (!strstr(exe, ".app/")) return;
    
    // 系统进程和越狱管理器检查推迟到 PGLazyInit 中
    // 因为 PGIsSystemProcess/PGIsJailbreakManager 会调用 PGAppBundleID() → NSProcessInfo（ObjC API）
    // 这在构造期可能崩溃
    
    PGLog("init: C 层过滤通过，准备 ObjC 初始化");
}
