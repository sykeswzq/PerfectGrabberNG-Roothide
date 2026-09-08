// PGCommon.h —— tweak(dylib) 与 设置面板(bundle) 共用的偏好读写
// 注意：两个模块分别编译，函数用 static inline 各存一份，互不影响。
#import <Foundation/Foundation.h>
#import <notify.h>

#define PGDomain        @"com.sykes.perfectgrabberng"
#define PGKeyEnabled    @"enabled"
#define PGKeyApps       @"apps"
#define PGKeyDuration   @"duration"
#define PGNotifyName    "com.sykes.perfectgrabberng.reload"

NS_INLINE NSString *PGPrefsFileName(void) {
    return @"com.sykes.perfectgrabberng.plist";
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

// 读取路径：第一个真实存在的
NS_INLINE NSString *PGPrefsReadPath(void) {
    NSString *file = PGPrefsFileName();
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *r in PGPrefsRoots()) {
        NSString *p = [NSString stringWithFormat:@"%@/var/mobile/Library/Preferences/%@", r, file];
        if ([fm fileExistsAtPath:p]) return p;
    }
    return [@"/var/mobile/Library/Preferences" stringByAppendingPathComponent:file];
}

// 写入路径：第一个父目录可写的
NS_INLINE NSString *PGPrefsWritePath(void) {
    NSString *file = PGPrefsFileName();
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *r in PGPrefsRoots()) {
        NSString *p = [NSString stringWithFormat:@"%@/var/mobile/Library/Preferences/%@", r, file];
        NSString *dir = [p stringByDeletingLastPathComponent];
        if ([fm fileExistsAtPath:dir] && [fm isWritableFileAtPath:dir]) return p;
    }
    // 都没准备好就返回标准路径，写入失败也不影响插件运行
    return [@"/var/mobile/Library/Preferences" stringByAppendingPathComponent:file];
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

NS_INLINE BOOL PGCurrentAppSelected(void) {
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    if (bid.length == 0) return NO;
    NSArray *apps = PGValue(PGKeyApps);
    // 列表为空 = 开箱即用，对所有已注入的 App 生效；
    // 一旦勾选了 App，就转为白名单（仅勾选的生效）。
    if (![apps isKindOfClass:[NSArray class]] || apps.count == 0) return YES;
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
