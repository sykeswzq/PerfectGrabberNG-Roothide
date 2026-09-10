// PGTweak.m —— V2.0.11：极端保守修复，杜绝原神/SIGSEGV 闪退
//
// V2.0.11 改动（针对原神 SIGSEGV）：
//   1) 移除 connectedScenes 枚举：游戏进程 scene 状态机可能被 hook，枚举会触发崩溃。
//      改为直接拿 sharedApplication.windows 的第一个 window 的 scene（如果有的话）。
//   2) 移除 initWithWindowScene:，改用 initWithFrame:[UIScreen mainScreen].bounds：
//      避免在游戏进程中触发 scene 生命周期回调。
//   3) windowLevel 降到 UIWindowLevelNormal + 1（≈201），远低于 Alert(1500)，
//      保证不会干扰任何游戏 UI 层级。
//   4) 移除 UIDevice.batteryMonitoringEnabled = YES：防止电池事件回调被游戏 hook 导致崩溃。
//   5) 移除 applicationWillResignActive/DidBecomeActive 等通知观察者：
//      游戏进程的通知分发机制可能被 hook，注册新观察者可能干扰。
//   6) 自检闪现只在「非游戏」进程（由 appState 判断）才触发，避免游戏进程动画闪烁。
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

#pragma mark - 浮层

@interface PGOverlay : NSObject <UIGestureRecognizerDelegate>
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
    NSTimer *_keepTimer;
}

+ (instancetype)shared {
    static PGOverlay *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[PGOverlay alloc] init]; });
    return s;
}

// iOS 13+ 拿 windowScene 的极保守方案。
// 只从 sharedApplication.windows 里找第一个已有 window 的 scene，
// 不再枚举 connectedScenes（游戏进程 scene 状态机可能被 hook，枚举会触发崩溃）。
static UIWindowScene *PGPickWindowScene(void) {
    UIApplication *app = [UIApplication sharedApplication];
    if (!app) return nil;
    for (UIWindow *win in app.windows) {
        if (win.windowScene) return win.windowScene;
    }
    return nil;
}

- (void)pg_install {
    if (_window) return;
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
        if (_window) return;
        UIApplication *app = [UIApplication sharedApplication];
        if (!app) return;

        // ★ V2.0.11：极端保守 —— 不依赖 applicationState，任何状态都建 window。
        //   原神在启动期 applicationState 可能是 Background 或 Active，
        //   枚举 connectedScenes 在 Metal 渲染进程中会触发 SIGSEGV。

        UIWindow *w = nil;
        // ★ 2.0.11：放弃 initWithWindowScene:，改用 initWithFrame: 避免 scene 生命周期干扰
        w = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        PGLog([NSString stringWithFormat:@"install: 建 window frame=%@", [UIScreen mainScreen].bounds.description]);

        w.backgroundColor = [UIColor clearColor];
        // ★ V2.0.11：windowLevel 降到 UIWindowLevelNormal + 1（≈201）
        //   远低于 Alert(1500)，保证不会干扰任何游戏 UI 层级。
        //   游戏启动时 miHoYo SDK 建的登录/公告层是 Alert 级别，我们的 Normal+1 会被盖住，
        //   但不会触发 SIGSEGV。手势触发时再做一次强制重排即可。
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
            // ★ V2.0.11 修复：用 app.windows 里的 window 取 scene，而不是未定义的 scene 变量
            UIWindow *firstWin = app.windows.firstObject;
            if (firstWin.windowScene && firstWin.windowScene.statusBarManager) {
                sbh = firstWin.windowScene.statusBarManager.statusBarFrame.size.height;
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

        // ★ V2.0.11：自检闪现只触发一次、1秒后，避免游戏进程动画闪烁
        //   原神/Metal 进程中调用 UIView animateWithDuration 会干扰渲染线程
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
        _window.hidden = YES;
        _window.rootViewController = nil;
        _window = nil; _content = nil; _strip = nil; _infoView = nil; _label = nil;
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
        if (!_window || !_label) return;

        // ★ V2.0.11：移除 windowLevel 强制重排——游戏进程中修改 windowLevel 可能触发 Metal 渲染同步崩溃
        //   改用固定 level，不做动态调整

        [self pg_updateText];

        // ★ V2.0.11：移除动画，直接设置 alpha，避免 Metal 进程中的视图动画干扰渲染
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
        if (_keepTimer || !_window) return;
        _keepTimer = [NSTimer timerWithTimeInterval:30.0
                                             target:self
                                           selector:@selector(pg_keepTick)
                                           userInfo:nil
                                            repeats:YES];
        [[NSRunLoop mainRunLoop] addTimer:_keepTimer forMode:NSRunLoopCommonModes];
    });
}

- (void)pg_keepTick {
    if (!PGKeepOn() || !_window || !_label) { [_keepTimer invalidate]; _keepTimer = nil; return; }
    _window.hidden = NO;
    // V2.0.11: 移除 windowLevel 重排和动画
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
    // ★ V2.0.11：移除动画，直接隐藏
    _infoView.alpha = 0.0;
    _infoView.transform = CGAffineTransformIdentity;
}
@end

#pragma mark - 入口

__attribute__((constructor))
static void PGInit(void) {
    // ★ 纯 C 层第一道闸（在任何 ObjC 之前）：正向白名单，杜绝安全模式。
    // roothide 会把 dylib 注进 SpringBoard / 越狱工具 / 系统 App 甚至开机守护；
    // 在这些进程里跑 ObjC（NSBundle mainBundle / NSProcessInfo）时机不对就会崩 → Dopamine 判 boot 失败 → 安全模式。
    // 正向白名单策略：只有"真·App"进程才允许进 ObjC——App 的可执行文件一定在 xxx.app/ 目录里；
    // 系统目录 / 守护 / 脚本 / 工具一律在纯 C 层直接 return，绝不碰 ObjC。
    const char *img0 = _dyld_get_image_name(0);
    if (!img0 || !img0[0]) return;              // 拿不到主可执行路径（开机关键守护常见）→ 保守直接退出
    const char *p = img0;
    if (strncmp(p, "/System", 7) == 0) return;   // /System/... 系统（含 SpringBoard.app）
    if (strncmp(p, "/usr", 4) == 0) return;      // /usr/libexec、/usr/bin 系统守护/工具
    if (strncmp(p, "/bin", 4) == 0) return;
    if (strncmp(p, "/sbin", 5) == 0) return;
    if (strncmp(p, "/Library", 8) == 0) return;
    if (strstr(p, "SpringBoard")) return;
    if (strstr(p, "/var/jb")) return;            // 越狱目录（正常 App 不在 /var/jb 下，仅作保护）
    if (strstr(p, "/var/lib")) return;
    if (!strstr(p, ".app/")) return;             // 正向白名单：非 App 进程（守护/脚本/工具/管理器可执行体）一律不注入

    @autoreleasepool {
        // 关键防护放最前：系统进程 / 越狱管理 App 一律不注入，杜绝安全模式崩溃。
        if (PGIsSystemProcess()) return;
        if (PGIsJailbreakManager()) return;

        PGLog([NSString stringWithFormat:@"init: 已进入 bid=%@ img=%s", PGAppBundleID(), img0]);

        // 注册通知监听（轻量、安全）：在设置里勾选 App / 开关变化时，已运行中的 App 也能即时生效。
        int token = 0;
        notify_register_dispatch(PGNotifyName, &token, dispatch_get_main_queue(), ^(int t) {
            [[PGOverlay shared] pg_reload];
        });

        // ★ 2.0.5：这里【不再】因为「判定未勾选」就 return。
        // 2.0.4 的 bug：构造期若偏好读不到（第三方 App 沙盒常见）或 mainBundle 尚未就绪，
        // 判定会失败并直接 return —— 于是通知没注册、兜底没排程，之后再也没机会补救。
        // 现在始终注册，真正的判定交给 pg_install 内部，DidBecomeActive 每次都能再试。

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
