// PGTweak.m —— 游戏内下拉一次，顶部浮出「时间 + 电量」
// 编译：xcrun clang -dynamiclib -fobjc-arc -framework Foundation -framework UIKit
// 说明：本 tweak 不 hook 任何方法（不用 substrate），只在 App 启动后自建一个
//       悬浮窗口监听顶部下拉手势，因此不会被 SpringBoard 注入限制卡住。
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <notify.h>
#import "PGCommon.h"

// 前向声明：诊断函数实现在文件后部，避免 static 函数被先调用时报 implicit declaration
static NSString *PGDiagStatus(void);

#pragma mark - 穿透视图：只有顶部条区域吃触摸，其余全部穿透给游戏

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

#pragma mark - 浮层

@interface PGOverlay : NSObject
+ (instancetype)shared;
- (void)pg_install;
- (void)pg_reload;
@end

@implementation PGOverlay {
    UIWindow *_window;
    PGPassthroughView *_content;
    UIView *_strip;      // 顶部触发区（透明）
    UIView *_infoView;   // 显示时间与电量的胶囊
    UILabel *_label;
    BOOL _pulled;
    NSInteger _token;
    BOOL _proved;        // 调试模式下「已加载」弹窗只弹一次
}

+ (instancetype)shared {
    static PGOverlay *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[PGOverlay alloc] init]; });
    return s;
}

- (void)pg_install {
    if (_window) return;
    BOOL debug = PGDebugEnabled();
    if (!debug && !PGEnabled()) return;          // 调试模式绕过「启用」开关，便于确认注入
    if (!PGCurrentAppSelected()) return;

    dispatch_async(dispatch_get_main_queue(), ^{
      @try {
        if (_window) return;
        UIApplication *app = [UIApplication sharedApplication];
        if (app == nil) return;
        // ★ V2.0.11：移除 applicationState 检查——原神启动期可能是 Background，
        //   过早 return 会导致窗口不创建；游戏进程通知时序特殊，任何检查都可能误判。

        UIWindow *w = nil;
        // ★ V2.0.11：移除 connectedScenes 枚举（游戏进程 scene 状态机可能被 hook，枚举会触发崩溃）
        //   改用 sharedApplication.windows 的第一个 window，取不到则用 initWithFrame: 兜底
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
        // ★ V2.0.11：windowLevel 从 StatusBar+100(≈1100) 降到 Normal+1(≈201)
        //   远低于 Alert(1500)，保证不会干扰任何游戏 UI 层级，也不会触发 Metal 渲染同步
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

        // 顶部触发条：高度 110（更宽更容易摸中），透明
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

        // 显示胶囊
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

        // 下拉手势：从顶部往下拉超过 16pt 即触发（去掉速度门槛，普通下拉即可命中）
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pg_handlePan:)];
        pan.cancelsTouchesInView = NO;
        [strip addGestureRecognizer:pan];

        // 长按兜底：在顶部长按 0.3s 也触发，保证一定出浮层（便于确认功能 & 游戏内下拉不方便时可用）
        UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(pg_handleLongPress:)];
        lp.minimumPressDuration = 0.3;
        lp.cancelsTouchesInView = NO;
        [strip addGestureRecognizer:lp];

        // ★ V2.0.11：禁用电池监控，避免游戏进程 hook 导致崩溃
        // [UIDevice currentDevice].batteryMonitoringEnabled = YES;

        // 调试模式：安装完成后自动显示一次时间胶囊，无需下拉即可确认浮层是否渲染成功
        if (PGDebugEnabled()) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [self pg_show];
            });
        }
      } @catch (NSException *e) {}
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
        // 下拉超过 16pt 即触发：不卡速度门槛，缓慢下拉也能命中
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
    if (!PGDebugEnabled() && !PGEnabled()) return;   // 调试模式绕过「启用」开关
    if (!PGCurrentAppSelected()) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!_label) return;
        // ★ V2.0.11：禁用电池监控，避免游戏进程 hook 导致崩溃
        // [UIDevice currentDevice].batteryMonitoringEnabled = YES;
        NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
        [fmt setDateFormat:@"HH:mm"];
        NSString *time = [fmt stringFromDate:[NSDate date]];
        int pct = (int)roundf([UIDevice currentDevice].batteryLevel * 100.0f);
        if (pct < 0) pct = 0;
        UIDeviceBatteryState st = [UIDevice currentDevice].batteryState;
        NSString *bolt = @"";
        if (st == UIDeviceBatteryStateCharging || st == UIDeviceBatteryStateFull) bolt = @"⚡";
        NSString *dbg = @"";
        if (PGDebugEnabled()) {
            NSString *bid = PGAppBundleID();
            BOOL sel = PGCurrentAppSelected();
            dbg = [NSString stringWithFormat:@"  [%@%@]", bid ?: @"?", sel ? @"" : @"?"];
        }
        _label.text = [NSString stringWithFormat:@"%@   %@%d%%%@", time, bolt, pct, dbg];

        // V2.0.11: 移除动画，直接设置 alpha
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

#pragma mark - 调试模式：证明 dylib 已加载（写入标记文件 + 弹窗）

- (void)pg_debugProve {
    NSString *bid = PGAppBundleID();
    // 文件标记：证明 dylib 已注入进程（多路径写入，沙盒 App 也能在 NSTemporaryDirectory 留痕）
    @try {
        NSString *msg = [NSString stringWithFormat:@"[PGNG] loaded @ %@  bid=%@  | %@\n", [NSDate date], bid, PGDiagStatus()];
        PGWriteDiagAll(@"PGNG_loaded.txt", msg);
    } @catch (NSException *e) {}

    if (!PGDebugEnabled() || _proved) return;   // 弹窗仅调试模式 + 只弹一次
    _proved = YES;
    // 弹窗证明：dylib 确实存在并已运行。
    // presenter 查找三级兜底：① 任意已激活 scene 的窗口 rootVC；② keyWindow；③ 自建临时 window。
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            UIAlertController *a = [UIAlertController alertControllerWithTitle:@"PGNG 已加载"
                                                                       message:[NSString stringWithFormat:@"dylib 注入成功\nbundleID: %@", bid]
                                                                preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            UIViewController *rvc = nil;
            if (@available(iOS 13.0, *)) {
                // V2.0.11: 移除 connectedScenes 枚举
                for (UIWindow *win in [UIApplication sharedApplication].windows) {
                    if (win.rootViewController) { rvc = win.rootViewController; break; }
                }
            }
            if (!rvc) {
                UIWindow *kw = [UIApplication sharedApplication].keyWindow;
                if (kw) rvc = kw.rootViewController;
            }
            while (rvc && rvc.presentedViewController) rvc = rvc.presentedViewController;
            if (rvc) {
                [rvc presentViewController:a animated:YES completion:nil];
            } else {
                // 终极兜底：自建一个 window 弹，保证一定能看到
                UIWindow *pw = nil;
                // V2.0.11: 移除 connectedScenes 枚举
                for (UIWindow *win in [UIApplication sharedApplication].windows) {
                    if (win.windowScene) {
                        pw = [[UIWindow alloc] initWithWindowScene:win.windowScene];
                        break;
                    }
                }
                if (!pw) pw = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
                pw.rootViewController = [[UIViewController alloc] init];
                pw.windowLevel = UIWindowLevelNormal + 1.0;  // V2.0.11: 降低级别，避免游戏进程崩溃
                pw.hidden = NO;
                [pw.rootViewController presentViewController:a animated:YES completion:nil];
            }
        } @catch (NSException *e) {}
    });
}

- (void)pg_hide {
    if (!_infoView) return;
    // ★ V2.0.11：移除动画，直接隐藏
    _infoView.alpha = 0.0;
    _infoView.transform = CGAffineTransformIdentity;
}

@end

#pragma mark - 诊断

// 把当前进程的关键判定一次性输出，方便真机定位"卡在哪个门"。
// mainBundle / exe / resolved：bundle 解析三来源，看哪个能拿到真 bid；
// system/debug/selected：PGCurrentAppSelected 的三道判定；sharedApp：是否有 UI（区分主 App 与无 UI 的后台/扩展进程）。
static NSString *PGDiagStatus(void) {
    NSMutableArray *a = [NSMutableArray array];
    @try {
        [a addObject:[NSString stringWithFormat:@"mainBundle=%@", [[NSBundle mainBundle] bundleIdentifier] ?: @"(null)"]];
        NSArray *args = [[NSProcessInfo processInfo] arguments];
        [a addObject:[NSString stringWithFormat:@"exe=%@", args.count ? args[0] : @"(?)"]];
        [a addObject:[NSString stringWithFormat:@"resolved=%@", PGAppBundleID()]];
        [a addObject:[NSString stringWithFormat:@"system=%@ debug=%@ selected=%@",
                      PGIsSystemProcess() ? @"Y" : @"N",
                      PGDebugEnabled() ? @"Y" : @"N",
                      PGCurrentAppSelected() ? @"Y" : @"N"]];
        [a addObject:[NSString stringWithFormat:@"sharedApp=%@", [UIApplication sharedApplication] ? @"Y" : @"N"]];
    } @catch (NSException *e) { [a addObject:@"err"]; }
    return [a componentsJoinedByString:@" "];
}

#pragma mark - 入口

__attribute__((constructor))
static void PGInit(void) {
    @autoreleasepool {
        // —— 关键防护：系统关键进程（SpringBoard / backboardd 等）不注入 ——
        // 这些进程加载本 dylib 后，pg_install 会创建 UIWindow、pg_debugProve 可能弹窗，
        // 在 SpringBoard 里会直接崩溃 -> 注销即安全模式。1.0.32 加了 .roothidepatch 后
        // roothide 开始把 dylib 也加载进 SpringBoard，触发此崩溃。这里在构造函数最开头拦截。
        if (PGIsSystemProcess()) return;

        // 越狱管理类 App（Sileo/Filza/Cydia/Zebra 等）window 结构特殊，注入浮层极
        // 易触发 bad-access 导致进程闪退（@try/@catch 无法捕获硬件/内存错误）。
        // 这些 App 不需要时间电量浮层，直接跳过，根本不注册任何逻辑。
        NSString *bid = PGAppBundleID();
        if ([bid isEqualToString:@"com.coolstar.SileoStore"] ||
            [bid isEqualToString:@"com.rile.ios.Sileo"] ||
            [bid isEqualToString:@"com.tigisoftware.Filza"] ||
            [bid isEqualToString:@"com.saurik.Cydia"] ||
            [bid isEqualToString:@"com.zebra.renati"] ||
            [bid hasPrefix:@"com.opa334."]) {
            return;
        }

        // 诊断日志：dylib 一旦被加载进任意进程就记录「真实」bundleID。
        // 必须用 PGAppBundleID()（_dyld 兜底），因为构造函数期 [NSBundle mainBundle]
        // bundleIdentifier 常返回 nil（App Store 应用尤甚），直接用会写成 "bundle=?" 且误判系统进程。
        // 查看路径：/var/mobile/Documents/PGNG_loadlog.txt
        @try {
            NSString *line = [NSString stringWithFormat:@"[%@] PGNG constructor ran (bundle=%@) | %@\n", [NSDate date], bid, PGDiagStatus()];
            // 多路径写入：沙盒 App Store 应用也能在 NSTemporaryDirectory 留痕，避免假阴性
            PGWriteDiagAll(@"PGNG_loadlog.txt", line);
        } @catch (NSException *e) {}

        // 不在构造函数期做「系统进程」提前返回：此时 [NSBundle mainBundle] 尚未就绪，
        // bundleID 为 nil 会被 PGIsSystemProcess 误判为系统进程 -> 整体失效（之前「完全没效果」的根因）。
        // 真正的系统进程防护放到 pg_install / pg_show / pg_reload（运行期，bundleID 已就绪）里做。
        // 先注册通知监听：这样在设置里勾选 App / 打开开关后能立刻生效，不用重启游戏
        int token = 0;
        notify_register_dispatch(PGNotifyName, &token, dispatch_get_main_queue(), ^(int t) {
            [[PGOverlay shared] pg_reload];
        });

        // roothide 通常在 didFinishLaunching 之后才注入 dylib，
        // 若只监听 DidFinishLaunching，通知早已发过 -> 永远错过 -> 窗口不创建 -> 下拉无反应。
        // 因此改为同时监听 DidBecomeActive（每次进入前台必触发）+ 2 秒兜底检测，确保必然安装。
        void (^tryInstall)(void) = ^{
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [[PGOverlay shared] pg_install];
                [[PGOverlay shared] pg_debugProve];
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
        // 兜底：dylib 在 App 已激活后才被注入的情况
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UIApplication *app = [UIApplication sharedApplication];
            if (app && app.applicationState == UIApplicationStateActive) {
                [[PGOverlay shared] pg_install];
                [[PGOverlay shared] pg_debugProve];
            }
        });
    }
}
