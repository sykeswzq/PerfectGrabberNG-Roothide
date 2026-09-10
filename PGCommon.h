// PGCommon.h —— tweak(dylib) 与 设置面板(bundle) 共用的偏好读写
// 注意：两个模块分别编译，函数用 static inline 各存一份，互不影响。
#import <Foundation/Foundation.h>
#import <notify.h>
#import <mach-o/dyld.h>

#define PGDomain        @"com.sykes.perfectgrabberng"
#define PGKeyEnabled    @"enabled"
#define PGKeyApps       @"apps"
#define PGKeyDuration   @"duration"
#define PGKeyDebug      @"debug"
#define PGNotifyName    "com.sykes.perfectgrabberng.reload"

NS_INLINE NSString *PGPrefsFileName(void) {
    return @"com.sykes.perfectgrabberng.plist";
}

// roothide jbroot 内可写临时目录：注入后的 App Store 应用（沙盒）能写这里，
// 而 /var/mobile/Documents 写不进。诊断日志统一放这里，避免「假阴性」。
NS_INLINE NSString *PGJbTmp(void) {
    NSString *jb = nil;
    const char *e = getenv("JBROOT");
    if (e && e[0]) jb = [NSString stringWithUTF8String:e];
    if (!jb) {
        NSString *dest = [[NSFileManager defaultManager] destinationOfSymbolicLinkAtPath:@"/var/jb" error:NULL];
        if (dest.length > 0) jb = dest;
    }
    if (!jb) jb = @"/var/jb";
    NSString *dir = [jb stringByAppendingPathComponent:@"tmp"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                               withIntermediateDirectories:YES
                                                attributes:nil
                                                     error:NULL];
    return dir;
}

// 诊断日志落盘路径：优先 /var/mobile/Documents（roothide 下实测可写、用户易找），
// 回退 /var/jb/tmp，再回退 /tmp。返回具体文件全路径。
NS_INLINE NSString *PGDiagPath(NSString *name) {
    NSArray *dirs = @[@"/var/mobile/Documents", @"/var/jb/tmp", @"/tmp"];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *d in dirs) {
        if ([fm isWritableFileAtPath:d]) return [d stringByAppendingPathComponent:name];
    }
    return [@"/var/mobile/Documents" stringByAppendingPathComponent:name];
}

// 多路径诊断写入：沙盒 App Store 应用写 /var/mobile/Documents 会静默失败（沙盒外不可写），
// 造成「无日志」假阴性，让我们一直误判「dylib 没加载」。这里同时尝试多个候选目录
// （含沙盒内 NSTemporaryDirectory，App Store 应用一定能写），任一可写即留痕，
// 确保「到底有没有加载」变成确定性信号。返回成功写入的路径数组。
NS_INLINE NSArray<NSString *> *PGWriteDiagAll(NSString *name, NSString *content) {
    NSMutableArray *ok = [NSMutableArray array];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *dirs = [NSMutableArray array];
    @try {
        NSString *nt = NSTemporaryDirectory();   // 沙盒内 tmp，App Store 应用必可写
        if (nt.length) [dirs addObject:nt];
    } @catch (NSException *e) {}
    @try {
        // 沙盒 Documents：App Store 应用可写，且不会被系统清理，Filza 进沙盒一步可找
        NSArray *docPaths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        if (docPaths.count) { NSString *dd = docPaths[0]; if (dd.length) [dirs addObject:dd]; }
    } @catch (NSException *e) {}
    [dirs addObjectsFromArray:@[@"/var/jb/tmp", @"/var/mobile/Documents", @"/tmp"]];
    for (NSString *d in dirs) {
        @try {
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:d isDirectory:&isDir] || !isDir) continue;
            if (![fm isWritableFileAtPath:d]) continue;
            NSString *p = [d stringByAppendingPathComponent:name];
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:p];
            if (fh) { [fh seekToEndOfFile]; [fh writeData:[content dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
            else { [content writeToFile:p atomically:YES]; }
            [ok addObject:p];
        } @catch (NSException *e) {}
    }
    return ok;
}

// roothide / rootless 下偏好文件的候选根目录：优先真实 jbroot，其次 /var/jb 软链，最后兜底
NS_INLINE NSArray<NSString *> *PGPrefsRoots(void) {
    NSMutableArray *roots = [NSMutableArray array];
    const char *env = getenv("JBROOT");
    if (env && env[0]) [roots addObject:[NSString stringWithUTF8String:env]];
    NSString *dest = [[NSFileManager defaultManager] destinationOfSymbolicLinkAtPath:@"/var/jb" error:NULL];
    if (dest.length > 0) [roots addObject:dest];
    [roots addObjectsFromArray:@[@"/var/jb", @"/var/roothide", @""]];
    return roots;
}

// 读取路径：优先「标准世界可读路径」/var/mobile/Library/Preferences/<file>。
// 关键：沙盒 App Store 应用（微信等）读不到 jbroot 前缀路径（/var/jb/...），
// 而标准路径是 world-readable，所有 App 都能读。之前只读 jbroot 前缀导致
// 沙盒 App 偏好全为默认（调试模式/启用/App列表都读不到）→ 浮层永不出现。
// 这里标准路径优先，找不到再回退 jbroot（越狱 App/设置面板写的位置）。
NS_INLINE NSString *PGPrefsReadPath(void) {
    NSString *file = PGPrefsFileName();
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *plain = [@"/var/mobile/Library/Preferences" stringByAppendingPathComponent:file];
    if ([fm fileExistsAtPath:plain]) return plain;
    for (NSString *r in PGPrefsRoots()) {
        NSString *p = [NSString stringWithFormat:@"%@/var/mobile/Library/Preferences/%@", r, file];
        if ([fm fileExistsAtPath:p]) return p;
    }
    return plain;
}

// 写入路径：优先「标准世界可读路径」/var/mobile/Library/Preferences/<file>。
// 沙盒 App Store 应用只能读这个标准路径（读不到 jbroot 前缀），所以偏好必须写这里
// 才能让微信等沙盒 App 看到「调试模式/启用/App列表」。找不到可写标准目录才回退 jbroot。
NS_INLINE NSString *PGPrefsWritePath(void) {
    NSString *file = PGPrefsFileName();
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *plain = [@"/var/mobile/Library/Preferences" stringByAppendingPathComponent:file];
    NSString *plainDir = [plain stringByDeletingLastPathComponent];
    if ([fm fileExistsAtPath:plainDir] && [fm isWritableFileAtPath:plainDir]) return plain;
    for (NSString *r in PGPrefsRoots()) {
        NSString *p = [NSString stringWithFormat:@"%@/var/mobile/Library/Preferences/%@", r, file];
        NSString *dir = [p stringByDeletingLastPathComponent];
        if ([fm fileExistsAtPath:dir] && [fm isWritableFileAtPath:dir]) return p;
    }
    return plain;
}

NS_INLINE NSDictionary *PGPrefs(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:PGPrefsReadPath()];
    return d ?: @{};
}

// 读取：文件通道优先，读不到再走 CFPreferences
// （Root.plist 里 defaults 域的开关是 Preferences 框架直接写 CFPreferences 的）
NS_INLINE id PGValue(NSString *key) {
    id v = nil;
    @try { v = PGPrefs()[key]; } @catch (NSException *e) {}
    if (v) return v;
    CFTypeRef c = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                            (__bridge CFStringRef)PGDomain);
    if (c) return CFBridgingRelease(c);
    return nil;
}

// 写入：两条通道都写，保证设置面板和插件进程都能读到
NS_INLINE void PGSetValue(NSString *key, id value) {
    @try {
        NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary:PGPrefs()];
        if (value) d[key] = value;
        else [d removeObjectForKey:key];
        [d writeToFile:PGPrefsWritePath() atomically:YES];
    }
    @catch (NSException *e) {}
    @try {
        if (value) {
            CFPreferencesSetAppValue((__bridge CFStringRef)key,
                                     (__bridge CFPropertyListRef)value,
                                     (__bridge CFStringRef)PGDomain);
        } else {
            CFPreferencesSetAppValue((__bridge CFStringRef)key, NULL,
                                     (__bridge CFStringRef)PGDomain);
        }
        CFPreferencesAppSynchronize((__bridge CFStringRef)PGDomain);
    }
    @catch (NSException *e) {}
    notify_post(PGNotifyName);
}

NS_INLINE BOOL PGEnabled(void) {
    id v = PGValue(PGKeyEnabled);
    if (v == nil) return YES;          // 默认开启
    if ([v respondsToSelector:@selector(boolValue)]) return [v boolValue];
    return YES;
}

NS_INLINE BOOL PGDebugEnabled(void) {
    id v = PGValue(PGKeyDebug);
    if (v && [v respondsToSelector:@selector(boolValue)]) return [v boolValue];
    return NO;
}

// 可靠的 bundle ID 获取。
// 关键坑：dylib 在「构造函数（加载期）」运行时 [NSBundle mainBundle] bundleIdentifier
// 经常尚未初始化 -> 返回 nil（App Store 应用尤甚），导致被误判为系统进程而整体失效。
// 这里在 mainBundle 取不到时，用 _dyld_get_image_name(0)（构造函数期一定可用）
// 拿到主可执行文件路径，向上回退找 .app/Info.plist 解析 CFBundleIdentifier。
NS_INLINE NSString *PGAppBundleID(void) {
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    if (bid.length > 0) return bid;
    @try {
        NSString *exe = nil;
        // 启动路径（NSProcessInfo.arguments[0]）在构造函数期一定可用，优先于 _dyld
        NSArray *args = [[NSProcessInfo processInfo] arguments];
        if (args.count) exe = args[0];
        if (!exe.length) {
            const char *m = _dyld_get_image_name(0);
            if (m && m[0]) exe = [NSString stringWithUTF8String:m];
        }
        if (exe.length) {
            NSString *dir = [exe stringByDeletingLastPathComponent];
            for (int i = 0; i < 8 && dir.length; i++) {
                NSString *plist = [dir stringByAppendingPathComponent:@"Info.plist"];
                if ([[NSFileManager defaultManager] fileExistsAtPath:plist]) {
                    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:plist];
                    NSString *b = info[@"CFBundleIdentifier"];
                    if (b.length) return b;
                }
                if ([[dir pathExtension] isEqualToString:@"app"]) break;
                dir = [dir stringByDeletingLastPathComponent];
            }
        }
    } @catch (NSException *e) {}
    return @"?";
}

NS_INLINE BOOL PGIsSystemProcess(void) {
    // 只服务用户 App；系统进程（含 SpringBoard / 后台 daemon）一律排除，
    // 从根上避免 tweak 在系统进程里创建浮层导致卡死或界面冲突。
    // 注意：取不到 bundleID(=@"?")时不再武断判为系统进程，否则会误杀所有
    // 在构造函数期 mainBundle 未就绪的 App Store 应用（这正是之前「完全没效果」的根因）。
    NSString *bid = PGAppBundleID();
    if ([bid isEqualToString:@"?"]) return NO;
    if ([bid isEqualToString:@"com.apple.springboard"]) return YES;
    if ([bid isEqualToString:@"com.apple.backboardd"]) return YES;
    if ([bid hasPrefix:@"com.apple."]) return YES;         // 所有系统 App
    return NO;
}

NS_INLINE BOOL PGCurrentAppSelected(void) {
    // 默认不注入任何 App；只有在设置列表里勾选的 App 才生效（白名单模式）。
    if (PGIsSystemProcess()) return NO;          // 系统进程永不注入，避免卡死
    // 注意：调试模式不再「强制所有用户 App 注入浮层」。旧逻辑会让 Sileo/Filza 等
    // 越狱管理 App 也创建浮层+弹窗，这些 App 的 window 结构特殊，浮层创建易触发
    // bad-access（@try/@catch 抓不住）-> 进程闪退。调试模式现在只用于：
    // ① 绕过总「启用」开关；② 浮层标签显示调试信息；③ 在「已勾选」App 弹确认窗。
    NSString *bid = PGAppBundleID();
    if ([bid isEqualToString:@"?"]) return NO;
    NSArray *apps = PGValue(PGKeyApps);
    if (![apps isKindOfClass:[NSArray class]] || apps.count == 0) return NO;
    return [apps containsObject:bid];
}

NS_INLINE NSTimeInterval PGDuration(void) {
    id v = PGValue(PGKeyDuration);
    if (v && [v respondsToSelector:@selector(doubleValue)]) {
        double d = [v doubleValue];
        if (d >= 0.5) return d;
    }
    return 2.0;                        // 默认 2 秒
}
