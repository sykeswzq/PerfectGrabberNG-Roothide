// PGTweak.m —— V2.0.38 极简安全版
//
// 策略：构造函数期完全不使用 ObjC，所有操作延迟到 3 秒后
// 使用纯 C write() 写日志，零 ObjC 依赖

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <notify.h>
#import <string.h>
#import <unistd.h>
#import <mach-o/dyld.h>

#pragma mark - 全局状态

static char sExePath[1024] = {0};
static int sNotifyToken = 0;
static volatile BOOL sObserverRegistered = NO;

#pragma mark - 纯 C 日志（不依赖 NSString）

static void PGWriteLog(const char *msg) {
    const char *logPath = "/var/mobile/pgng_diag.log";
    int fd = open(logPath, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) {
        write(fd, msg, strlen(msg));
        write(fd, "\n", 1);
        close(fd);
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

    @try {
        UIApplication *app = [UIApplication sharedApplication];
        if (!app) return;

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

        PGWriteLog("install: window created OK");
    } @catch (NSException *e) {
        // 无法使用 NSString，直接写固定消息
        PGWriteLog("install error occurred");
        _window = nil;
    }
}

- (void)pg_reload {
    [self pg_install];
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
    if (!_label) return;
    @try {
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
        NSTimeInterval d = 2.0;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (my == _token) _infoView.alpha = 0.0;
        });
    } @catch (NSException *e) {}
}
@end

#pragma mark - 入口（V2.0.38 极简版：构造函数零 ObjC）

__attribute__((constructor))
static void PGInit(void) {
    // ===== 第一步：获取 exe 路径（C 函数，绝对安全）=====
    const char *exe = getprogname();
    if (!exe) return;

    // 复制到静态缓冲区，避免指针悬空
    strncpy(sExePath, exe, sizeof(sExePath) - 1);
    sExePath[sizeof(sExePath) - 1] = '\0';

    // 写日志（纯 C write，不依赖任何 ObjC）
    PGWriteLog("constructor: exe path copied");

    // ===== 第二步：路径过滤（纯 C 字符串比较）=====
    if (strncmp(sExePath, "/System", 7) == 0) {
        PGWriteLog("constructor: system path, skip");
        return;
    }
    if (strncmp(sExePath, "/usr", 4) == 0) {
        PGWriteLog("constructor: usr path, skip");
        return;
    }
    if (strncmp(sExePath, "/bin", 4) == 0) {
        PGWriteLog("constructor: bin path, skip");
        return;
    }
    if (strncmp(sExePath, "/sbin", 5) == 0) {
        PGWriteLog("constructor: sbin path, skip");
        return;
    }
    if (strncmp(sExePath, "/Library", 8) == 0) {
        PGWriteLog("constructor: library path, skip");
        return;
    }
    if (strstr(sExePath, "SpringBoard")) {
        PGWriteLog("constructor: SpringBoard, skip");
        return;
    }
    if (strstr(sExePath, "/var/lib")) {
        PGWriteLog("constructor: var/lib path, skip");
        return;
    }
    if (!strstr(sExePath, ".app/")) {
        PGWriteLog("constructor: not .app/, skip");
        return;
    }

    PGWriteLog("constructor: exe passed path filter");

    // ===== 第三步：延迟所有 ObjC 操作 3 秒 =====
    // 此时不调用任何 ObjC，只调度一个 block
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        PGWriteLog("delay: 3s fallback start");

        // 注册 notify token
        int ret = notify_register_dispatch("com.sykes.perfectgrabberng.reload", &sNotifyToken,
                                           dispatch_get_main_queue(), ^(int t) {
            [[PGOverlay shared] pg_reload];
        });
        if (ret != 0) {
            char msg[64];
            snprintf(msg, sizeof(msg), "notify_register failed: %d", ret);
            PGWriteLog(msg);
        } else {
            PGWriteLog("notify_register success");
        }
        sObserverRegistered = YES;

        // 注册通知 observers
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
            PGWriteLog("notify: didFinishLaunching");
            [[PGOverlay shared] pg_install];
        }];
        PGWriteLog("registered didFinishLaunching observer");

        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
            PGWriteLog("notify: didBecomeActive");
            [[PGOverlay shared] pg_install];
        }];
        PGWriteLog("registered didBecomeActive observer");

        // 如果 App 已经激活，直接安装
        UIApplication *app = [UIApplication sharedApplication];
        if (app && app.applicationState == UIApplicationStateActive) {
            PGWriteLog("delay: app active, install immediately");
            [[PGOverlay shared] pg_install];
        } else {
            PGWriteLog("delay: app not active yet, waiting for notifications");
        }

        PGWriteLog("constructor: all setup complete");
    });
}
