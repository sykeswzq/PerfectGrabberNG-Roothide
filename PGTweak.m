// PGTweak.m —— V2.0.27：回归 V2.0.12 实机验证过的稳定方案
//
// 【历史教训（V2.0.20~V2.0.26 连续闪退的根因）】
//   roothide 时代连续 7 个版本在窗口代码上瞎改，把 V2.0.12 注释里明确记录的
//   「已知崩溃源」全部踩了一遍：
//     1. 枚举 connectedScenes（V2.0.11 移除：游戏 scene 状态机被 hook，枚举会 SIGSEGV）
//     2. windowLevel 用 Alert 级（V2.0.11 移除：触发 Metal 渲染同步崩溃，必须 Normal+1）
//     3. UIWindow 不设 rootViewController（UIKit 后台布局线程会拿到野指针）
//     4. 构造后 1 秒抢跑安装（App 还在启动中期，游戏引擎初始化中）
//   V2.0.27 = 完整回归 V2.0.12 的浮层实现（实机验证过的代码），
//            + 保留 V2.0.20+ 的 filter 基础设施（Bundles 白名单 + postinst chown）
//
// 与 V2.0.12 的唯一差异：
//   a) PGPassthroughView/strip/info/label 创建流程 100% 一致（含 AutoLayout）
//   b) 移除了 V2.0.12 的 PGDebugEnabled/PGKeyDebug（面板已不再提供该开关，避免编译错误）
//   c) 保留独立诊断日志 PGLog()（V2.0.26 的好东西，便于真机定位）
//   d) 安装时机：DidFinishLaunching + DidBecomeActive 双通知 + 2 秒兜底（V2.0.12 原样）
//   e) PGCommon.h 用 V2.0.26 版（三态判定 + filter 基础设施），不再依赖 PGKeyDebug

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <notify.h>
#import <string.h>
#import <mach-o/dyld.h>
#import "PGCommon.h"

#pragma mark - 诊断日志（V2.0.26 引入，保留）

static void PGLog(NSString *s) {
    @try {
        static NSString *path = nil;
        static BOOL tried = NO;
        if (!tried) {
            tried = YES;
            NSFileManager *fm = [NSFileManager defaultManager];
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
    if (!PGEnabled()) { PGLog(@"install: 总开关关闭"); return; }
    if (!PGCurrentAppSelected()) {
        PGLog([NSString stringWithFormat:@"install: 未勾选 bid=%@", PGAppBundleID()]);
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
      @try {
        if (_window) return;
        UIApplication *app = [UIApplication sharedApplication];
        if (app == nil) return;
        // ★ V2.0.11 教训：不检查 applicationState——原神启动期可能是 Background，
        //   过早 return 会导致窗口不创建；游戏进程通知时序特殊，任何检查都可能误判。

        UIWindow *w = nil;
        // ★ V2.0.11 教训：不枚举 connectedScenes（游戏 scene 状态机可能被 hook，枚举会 SIGSEGV）。
        //   改用 app.windows 第一个带 scene 的 window，取不到则 initWithFrame: 兜底
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
        // ★ V2.0.11 教训：windowLevel 必须 Normal+1(≈201)，Alert 级会触发 Metal 渲染同步崩溃
        w.windowLevel = UIWindowLevelNormal + 1.0;
        w.userInteractionEnabled = YES;

        // ★ V2.0.27 新增：rootViewController 必须设置（V2.0.25/26 缺失此步，UIKit 布局线程拿野指针）
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

        // 顶部触发条：高度 110（V2.0.12 原样，AutoLayout 锚点约束）
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

        // 显示胶囊（V2.0.12 原样：AutoLayout，居中）
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

        // 手势：下拉超过 16pt 触发（V2.0.12 原样）
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pg_handlePan:)];
        pan.cancelsTouchesInView = NO;
        [strip addGestureRecognizer:pan];

        // 长按兜底（V2.0.12 原样）
        UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(pg_handleLongPress:)];
        lp.minimumPressDuration = 0.3;
        lp.cancelsTouchesInView = NO;
        [strip addGestureRecognizer:lp];

        // ★ V2.0.11 教训：禁用电池监控 API 调用（游戏进程 hook 导致崩溃），pg_updateText 里同理
        // （电量从 batteryLevel 直接读，无需 monitoringEnabled；pg_show 里不再启用监控）

        PGLog(@"install: V2.0.27 窗口创建成功（V2.0.12 方案回归）");
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
    if (!PGEnabled()) return;
    if (!PGCurrentAppSelected()) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!_label) return;
        // ★ V2.0.11 教训：不碰电池监控 API（游戏 hook 下崩溃源）
        NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
        [fmt setDateFormat:@"HH:mm"];
        NSString *time = [fmt stringFromDate:[NSDate date]];
        int pct = (int)roundf([UIDevice currentDevice].batteryLevel * 100.0f);
        if (pct < 0) pct = 0;
        UIDeviceBatteryState st = [UIDevice currentDevice].batteryState;
        NSString *bolt = @"";
        if (st == UIDeviceBatteryStateCharging || st == UIDeviceBatteryStateFull) bolt = @"⚡";
        _label.text = [NSString stringWithFormat:@"%@   %@%d%%", time, bolt, pct];

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

- (void)pg_hide {
    if (!_infoView) return;
    _infoView.alpha = 0.0;
    _infoView.transform = CGAffineTransformIdentity;
}

@end

#pragma mark - 入口（V2.0.12 原样：双通知 + 兜底）

__attribute__((constructor))
static void PGInit(void) {
    // V2.0.28 修复：移除 _dyld_get_image_name(0) 遍历（游戏进程 hook 后枚举会 SIGSEGV）
    // 改用 NSProcessInfo 获取启动路径，纯 C 层快速过滤系统目录
    @autoreleasepool {
        // 快速 C 层白名单：避免不必要的 ObjC 开销
        const char *exe = [[[NSProcessInfo processInfo] arguments] firstObject] UTF8String];
        if (exe) {
            if (strncmp(exe, "/System", 7) == 0) return;
            if (strncmp(exe, "/usr", 4) == 0) return;
            if (strncmp(exe, "/bin", 4) == 0) return;
            if (strncmp(exe, "/sbin", 5) == 0) return;
            if (strncmp(exe, "/Library", 8) == 0) return;
            if (strstr(exe, "SpringBoard")) return;
            if (strstr(exe, "/var/jb")) return;
            if (strstr(exe, "/var/lib")) return;
            if (!strstr(exe, ".app/")) return;
        }

        if (PGIsSystemProcess()) return;
        if (PGIsJailbreakManager()) return;

        PGLog([NSString stringWithFormat:@"init: bid=%@", PGAppBundleID()]);

        int token = 0;
        notify_register_dispatch(PGNotifyName, &token, dispatch_get_main_queue(), ^(int t) {
            [[PGOverlay shared] pg_reload];
        });

        // V2.0.12 原样：双通知 + 2 秒兜底（不抢跑，等 App 就绪）
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
        // 兜底：dylib 在 App 已激活后才被注入的情况
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UIApplication *app = [UIApplication sharedApplication];
            if (app && app.applicationState == UIApplicationStateActive) {
                [[PGOverlay shared] pg_install];
            }
        });
    }
}
