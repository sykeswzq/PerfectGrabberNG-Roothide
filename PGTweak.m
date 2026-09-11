// PGTweak.m —— V2.0.22：roothide 下原神(Untiy/Metal) 闪退根治
//
// V2.0.22 改动（针对 roothide + 原神 SIGKILL 无日志闪退）：
//   ★ 根因：roothide 环境下给 Unity/Metal 游戏进程新建【绑定 scene 的 UIWindow 浮层】
//     (initWithWindowScene: + windowLevel=Alert+1 + hidden=NO) 会在加载期与游戏渲染循环 /
//     roothide 的 UIKit shim 冲突，内核直接 SIGKILL（无崩溃日志）。
//     二进制对比证实：Netskao 的 rootless 原版(原神能跑)【从不创建 UIWindow】，
//     只 MSHookMessageEx 钩子 + initWithFrame: 建 UIView 后 addSubview: 挂到已有视图层级。
//     rootless(Dopamine) 对同一套 UIWindow 代码容忍度更高所以不崩；roothide 不行。
//   ★ 修复：彻底移除 UIWindow / windowScene / connectedScenes / windowLevel / rootViewController。
//     改为取游戏 keyWindow -> addSubview: 一个普通 UIView 容器(PGPassthroughView)，
//     下拉手势直接挂在容器上；显示/隐藏只调胶囊 alpha。对齐能跑版机制，崩点被移除。
//   ★ 保留：下拉/下滑/长按三手势、触摸穿透(PGPassthroughView)、电量/时间刷新、常驻模式。
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <notify.h>
#import <string.h>
#import <mach-o/dyld.h>
#import "PGCommon.h"

#pragma mark - 诊断日志（写失败即静默，不影响功能）

static void PGLog(NSString *s) {
    @try {
        static NSString *path = nil;
        static BOOL tried = NO;
        if (!tried) {
            tried = YES;
            NSFileManager *fm = [NSFileManager defaultManager];
            // App 沙盒 Documents 一定可写（第三方 App 写 /var/mobile 常被拒）
            NSString *doc = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
            NSMutableArray *cands = [NSMutableArray array];
            if (doc.length) [cands addObject:[doc stringByAppendingPathComponent:@"pgng_diag.log"]];
            [cands addObject:@"/var/mobile/pgng_diag.log"];
            [cands addObject:[PGJbRoot() stringByAppendingPathComponent:@"var/mobile/pgng_diag.log"]];
            for (NSString *p in cands) {
                if ([fm fileExistsAtPath:p] ||
                    [@"" writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:NULL]) {
                    path = p; break;
                }
            }
        }
        if (!path.length) return;
        NSString *line = [NSString stringWithFormat:@"%@ | %@\n", [NSDate date], s];
        NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
        if (h) {
            [h seekToEndOfFile];
            [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [h closeFile];
        }
    } @catch (NSException *e) {}
}

#pragma mark - 穿透视图：只有顶部条区域吃触摸，其余穿透给游戏

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
        return nil; // 游戏区域不吃触摸，原样穿透
    }
    return v;
}
@end

#pragma mark - 浮层（V2.0.22：不再自建 UIWindow，挂到游戏 keyWindow 上）

@interface PGOverlay : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)shared;
- (void)pg_install;
- (void)pg_reload;
@end

// V2.0.22：取游戏 keyWindow（iOS 13+ 多 scene 安全），不再取/建 UIWindowScene。
static UIWindow *PGPickKeyWindow(void) {
    UIApplication *app = [UIApplication sharedApplication];
    if (!app) return nil;
    // 优先 isKeyWindow 且可见的窗口
    for (UIWindow *win in app.windows) {
        if (win.isKeyWindow && !win.isHidden) return win;
    }
    // 兜底：任意可见窗口
    for (UIWindow *win in app.windows) {
        if (!win.isHidden) return win;
    }
    // 再兜底：deprecated keyWindow / 最后一个窗口
    if (app.keyWindow) return app.keyWindow;
    return app.windows.lastObject;
}

@implementation PGOverlay {
    UIWindow *_hostWindow;          // 仅用于 bringSubviewToFront / 状态栏高度，不做浮层
    PGPassthroughView *_content;    // 直接 addSubview 到 keyWindow 的容器
    UIView *_strip;
    UIView *_infoView;
    UILabel *_label;
    BOOL _pulled;
    NSInteger _token;
    NSTimer *_keepTimer;
}

+ (instancetype)shared {
    static PGOverlay *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[PGOverlay alloc] init]; });
    return s;
}

- (void)pg_install {
    if (_content) return;
    if (!PGEnabled()) { PGLog(@"install: 总开关关闭"); return; }
    if (!PGCurrentAppSelected()) {
        PGLog([NSString stringWithFormat:@"install: 未勾选 bid=%@", PGAppBundleID()]);
        return;
    }
    [self pg_tryInstallWithRetry:0];
}

- (void)pg_tryInstallWithRetry:(int)n {
    dispatch_async(dispatch_get_main_queue(), ^{
      @try {
        if (_content) return;
        UIApplication *app = [UIApplication sharedApplication];
        if (!app) return;

        // V2.0.22：取游戏 keyWindow，把容器 UIView 直接 addSubview 上去（不建 UIWindow）。
        UIWindow *kw = PGPickKeyWindow();
        if (!kw) { PGLog(@"install: 拿不到 keyWindow，跳过"); return; }

        PGPassthroughView *cv = [[PGPassthroughView alloc] initWithFrame:kw.bounds];
        cv.backgroundColor = [UIColor clearColor];
        cv.opaque = NO;
        cv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        cv.pgHitView = nil;
        [kw addSubview:cv];
        [kw bringSubviewToFront:cv];   // 置顶，盖在游戏 UI 之上
        _hostWindow = kw;
        _content = cv;
        PGLog(@"install: 容器已 addSubview 到 keyWindow（无 UIWindow）");

        // 顶部触发条（透明，高度 120，更容易摸中）
        UIView *strip = [[UIView alloc] initWithFrame:CGRectZero];
        strip.backgroundColor = [UIColor clearColor];
        strip.translatesAutoresizingMaskIntoConstraints = NO;
        [cv addSubview:strip];
        [NSLayoutConstraint activateConstraints:@[
            [strip.leadingAnchor constraintEqualToAnchor:cv.leadingAnchor],
            [strip.trailingAnchor constraintEqualToAnchor:cv.trailingAnchor],
            [strip.topAnchor constraintEqualToAnchor:cv.topAnchor],
            [strip.heightAnchor constraintEqualToConstant:120.0]
        ]];
        cv.pgHitView = strip;
        _strip = strip;

        // 状态栏高度：把胶囊挪到灵动岛下方（iPhone 14 Pro 灵动岛约 y=11~48）
        CGFloat sbh = 0;
        if (@available(iOS 13.0, *)) {
            if (kw.windowScene && kw.windowScene.statusBarManager) {
                sbh = kw.windowScene.statusBarManager.statusBarFrame.size.height;
            }
        }
        if (sbh <= 0) sbh = app.statusBarFrame.size.height;
        if (sbh <= 0) sbh = 54.0;    // iPhone 14 Pro 兜底
        CGFloat infoTop = sbh + 4.0;

        // 时间+电量胶囊
        UIView *info = [[UIView alloc] initWithFrame:CGRectZero];
        info.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.55];
        info.layer.cornerRadius = 14.0;
        info.layer.masksToBounds = YES;
        info.layer.borderWidth = 1.0;                                 // 白色细描边：亮背景也看得清
        info.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.35].CGColor;
        info.alpha = 0.0;
        info.userInteractionEnabled = YES;                            // 点一下可临时隐藏
        info.translatesAutoresizingMaskIntoConstraints = NO;
        [strip addSubview:info];
        [NSLayoutConstraint activateConstraints:@[
            [info.centerXAnchor constraintEqualToAnchor:strip.centerXAnchor],
            [info.topAnchor constraintEqualToAnchor:strip.topAnchor constant:infoTop],
            [info.heightAnchor constraintEqualToConstant:30.0],
            [info.widthAnchor constraintGreaterThanOrEqualToConstant:120.0]
        ]];
        _infoView = info;

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                              action:@selector(pg_handleTap:)];
        tap.cancelsTouchesInView = NO;
        [info addGestureRecognizer:tap];

        UILabel *lb = [[UILabel alloc] initWithFrame:CGRectZero];
        lb.textColor = [UIColor whiteColor];
        lb.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
        lb.textAlignment = NSTextAlignmentCenter;
        lb.translatesAutoresizingMaskIntoConstraints = NO;
        [info addSubview:lb];
        [NSLayoutConstraint activateConstraints:@[
            [lb.leadingAnchor constraintEqualToAnchor:info.leadingAnchor constant:12.0],
            [lb.trailingAnchor constraintEqualToAnchor:info.trailingAnchor constant:-12.0],
            [lb.topAnchor constraintEqualToAnchor:info.topAnchor],
            [lb.bottomAnchor constraintEqualToAnchor:info.bottomAnchor]
        ]];
        _label = lb;

        // 触发 1：下拉手势（阈值 12pt，不设速度门槛，缓慢下拉也命中）
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pg_handlePan:)];
        pan.cancelsTouchesInView = NO;
        pan.delegate = self;
        [strip addGestureRecognizer:pan];

        // 触发 2：下滑 swipe（pan 被宿主手势干扰时兜底）
        UISwipeGestureRecognizer *swipe = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(pg_handleSwipeDown:)];
        swipe.direction = UISwipeGestureRecognizerDirectionDown;
        swipe.cancelsTouchesInView = NO;
        swipe.delegate = self;
        [strip addGestureRecognizer:swipe];

        // 触发 3：顶部长按 0.3s
        UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(pg_handleLongPress:)];
        lp.minimumPressDuration = 0.3;
        lp.cancelsTouchesInView = NO;
        lp.delegate = self;
        [strip addGestureRecognizer:lp];

        // ★ V2.0.11：禁用电池监控，防止游戏进程 hook 导致崩溃
        // [UIDevice currentDevice].batteryMonitoringEnabled = YES;
        PGLog(@"install: 完成");

        // 自检闪现一次、1 秒后（避免游戏进程动画闪烁）。无动画，直接 alpha。
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self pg_showFor:2.0];
        });
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
        [_keepTimer invalidate]; _keepTimer = nil;
        _content.pgHitView = nil;
        [_content removeFromSuperview];
        _content = nil; _hostWindow = nil; _strip = nil; _infoView = nil; _label = nil;
    });
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)a
shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)b {
    return YES;   // 三个手势互不排斥，任一命中即触发
}

- (void)pg_handlePan:(UIPanGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan || g.state == UIGestureRecognizerStateChanged) {
        if (_pulled) return;
        CGPoint t = [g translationInView:_strip];
        if (t.y > 12.0) { _pulled = YES; PGLog(@"trigger: pan"); [self pg_show]; }
    } else if (g.state == UIGestureRecognizerStateEnded ||
               g.state == UIGestureRecognizerStateCancelled ||
               g.state == UIGestureRecognizerStateFailed) {
        _pulled = NO;
    }
}

- (void)pg_handleSwipeDown:(UISwipeGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateRecognized) { PGLog(@"trigger: swipe"); [self pg_show]; }
}

- (void)pg_handleLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan) { PGLog(@"trigger: longpress"); [self pg_show]; }
}

- (void)pg_show {
    [self pg_showFor:PGDuration()];
}

// d 秒后自动隐藏（PGKeepOn 常驻模式不排隐藏，由定时器持续刷新）
- (void)pg_showFor:(NSTimeInterval)d {
    if (!PGEnabled() || !PGCurrentAppSelected()) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!_content || !_label) return;
        // 确保容器仍在 keyWindow 上且置顶（游戏可能重建/重排 window）
        UIWindow *kw = PGPickKeyWindow();
        if (kw && _content.superview != kw) [kw addSubview:_content];
        if (kw) [kw bringSubviewToFront:_content];

        [self pg_updateText];

        // V2.0.22：无动画，直接 alpha（避免 Metal 进程动画干扰渲染）
        _infoView.alpha = 1.0;
        _infoView.transform = CGAffineTransformIdentity;
        if (PGKeepOn()) { [self pg_startKeepTimer]; return; }
        _token += 1;
        NSInteger my = _token;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (my == _token) [self pg_hide];
        });
    });
}

- (void)pg_updateText {
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
}

// 常驻模式：30 秒刷新一次时间/电量，并确保胶囊在前台可见
- (void)pg_startKeepTimer {
    if (_keepTimer) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (_keepTimer || !_content) return;
        _keepTimer = [NSTimer timerWithTimeInterval:30.0
                                             target:self
                                           selector:@selector(pg_keepTick)
                                           userInfo:nil
                                            repeats:YES];
        [[NSRunLoop mainRunLoop] addTimer:_keepTimer forMode:NSRunLoopCommonModes];
    });
}

- (void)pg_keepTick {
    if (!PGKeepOn() || !_content || !_label) { [_keepTimer invalidate]; _keepTimer = nil; return; }
    UIWindow *kw = PGPickKeyWindow();
    if (kw && _content.superview != kw) [kw addSubview:_content];
    if (kw) [kw bringSubviewToFront:_content];
    [self pg_updateText];
    _infoView.alpha = 1.0;
}

// 点一下胶囊：临时隐藏（常驻模式 5 秒后自动回来，非常驻模式等下次触发）
- (void)pg_handleTap:(UITapGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateRecognized) return;
    if (!_infoView || _infoView.alpha < 0.5) return;
    PGLog(@"trigger: tap-hide");
    [self pg_hide];
    if (PGKeepOn()) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (PGKeepOn()) [self pg_show];
        });
    }
}

- (void)pg_hide {
    if (!_infoView) return;
    _infoView.alpha = 0.0;
    _infoView.transform = CGAffineTransformIdentity;
}
@end

#pragma mark - 入口

__attribute__((constructor))
static void PGInit(void) {
    // ★ 纯 C 层第一道闸（在任何 ObjC 之前）：正向白名单，杜绝安全模式。
    const char *img0 = _dyld_get_image_name(0);
    if (!img0 || !img0[0]) return;
    const char *p = img0;
    if (strncmp(p, "/System", 7) == 0) return;
    if (strncmp(p, "/usr", 4) == 0) return;
    if (strncmp(p, "/bin", 4) == 0) return;
    if (strncmp(p, "/sbin", 5) == 0) return;
    if (strncmp(p, "/Library", 8) == 0) return;
    if (strstr(p, "SpringBoard")) return;
    if (strstr(p, "/var/jb")) return;
    if (strstr(p, "/var/lib")) return;
    if (!strstr(p, ".app/")) return;

    @autoreleasepool {
        if (PGIsSystemProcess()) return;
        if (PGIsJailbreakManager()) return;

        PGLog([NSString stringWithFormat:@"init: 已进入 bid=%@ img=%s", PGAppBundleID(), img0]);

        int token = 0;
        notify_register_dispatch(PGNotifyName, &token, dispatch_get_main_queue(), ^(int t) {
            [[PGOverlay shared] pg_reload];
        });

        // roothide 在 didFinishLaunching 之后才注入 dylib，只监听 DidFinishLaunching 会错过。
        // 同时监听 DidBecomeActive，并额外做多次兜底，确保必然安装。
        void (^tryInstall)(void) = ^{
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [[PGOverlay shared] pg_install];
            });
        };
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *n) { tryInstall(); }];
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *n) { tryInstall(); }];
        // 兜底：构造后 2 秒直接尝试（覆盖 roothide 注入过晚、通知已错过的情况）
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [[PGOverlay shared] pg_install];
        });
    }
}
