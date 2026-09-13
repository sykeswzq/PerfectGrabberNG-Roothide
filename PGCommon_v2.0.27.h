// PGCommon.h —— V2 tweak(dylib) 与 设置面板(bundle) 共用的偏好读写 + 进程判定
// 两个模块分别编译，函数用 NS_INLINE 各存一份，互不影响。
// 设计目标：精简、干净、在 roothide(rootless-compat) 下稳定运行，构造函数期不崩。
#import <Foundation/Foundation.h>
#import <notify.h>
#import <mach-o/dyld.h>
#import <spawn.h>
#import <sys/wait.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>
#import <string.h>
#import <crt_externs.h>

#define PGDomain     @"com.sykes.perfectgrabberng"
#define PGKeyEnabled @"enabled"
#define PGKeyApps    @"apps"
#define PGKeyDuration @"duration"
#define PGKeyKeepOn  @"keepOn"
#define PGNotifyName "com.sykes.perfectgrabberng.reload"

// ---- jbroot 解析：优先 JBROOT 环境变量，其次 /var/jb 软链，兜底 /var/jb ----
NS_INLINE NSString *PGJbRoot(void) {
    const char *e = getenv("JBROOT");
    if (e && e[0]) return [NSString stringWithUTF8String:e];
    NSString *dest = [[NSFileManager defaultManager] destinationOfSymbolicLinkAtPath:@"/var/jb" error:NULL];
    if (dest.length) return dest;
    return @"/var/jb";
}

NS_INLINE NSString *PGPrefsReadPath(void) {
    NSString *file = @"com.sykes.perfectgrabberng.plist";
    NSFileManager *fm = [NSFileManager defaultManager];
    // 标准世界可读路径优先（沙盒 App 也读得到），其次 jbroot 前缀
    NSString *plain = [@"/var/mobile/Library/Preferences" stringByAppendingPathComponent:file];
    if ([fm fileExistsAtPath:plain]) return plain;
    NSString *jb = [PGJbRoot() stringByAppendingPathComponent:@"var/mobile/Library/Preferences/"];
    NSString *p = [jb stringByAppendingPathComponent:file];
    if ([fm fileExistsAtPath:p]) return p;
    return plain;
}

NS_INLINE NSString *PGPrefsWritePath(void) {
    NSString *file = @"com.sykes.perfectgrabberng.plist";
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *plain = [@"/var/mobile/Library/Preferences" stringByAppendingPathComponent:file];
    NSString *dir = [plain stringByDeletingLastPathComponent];
    if ([fm isWritableFileAtPath:dir]) return plain;
    NSString *jbroot = PGJbRoot();
    NSString *jbdir = [jbroot stringByAppendingPathComponent:@"var/mobile/Library/Preferences"];
    if ([fm fileExistsAtPath:jbdir] && [fm isWritableFileAtPath:jbdir])
        return [jbdir stringByAppendingPathComponent:file];
    return plain;
}

NS_INLINE NSDictionary *PGPrefs(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:PGPrefsReadPath()];
    return d ?: @{};
}

NS_INLINE id PGValue(NSString *key) {
    id v = nil;
    @try { v = PGPrefs()[key]; } @catch (NSException *e) {}
    if (v) return v;
    CFTypeRef c = CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)PGDomain);
    if (c) return CFBridgingRelease(c);
    return nil;
}

NS_INLINE void PGSetValue(NSString *key, id value) {
    @try {
        NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary:PGPrefs()];
        if (value) d[key] = value; else [d removeObjectForKey:key];
        [d writeToFile:PGPrefsWritePath() atomically:YES];
    } @catch (NSException *e) {}
    @try {
        if (value) CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value, (__bridge CFStringRef)PGDomain);
        else CFPreferencesSetAppValue((__bridge CFStringRef)key, NULL, (__bridge CFStringRef)PGDomain);
        CFPreferencesAppSynchronize((__bridge CFStringRef)PGDomain);
    } @catch (NSException *e) {}
    notify_post(PGNotifyName);
}

NS_INLINE BOOL PGEnabled(void) {
    id v = PGValue(PGKeyEnabled);
    if (v == nil) return YES;
    if ([v respondsToSelector:@selector(boolValue)]) return [v boolValue];
    return YES;
}

// 可靠取 bundleID：mainBundle 取不到时用 _dyld_get_image_name(0) 回退解析 .app/Info.plist。
// 关键：构造函数期 mainBundle 常未就绪（返回 nil），不能拿它当"系统进程"判断。
NS_INLINE NSString *PGAppBundleID(void) {
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    if (bid.length > 0) return bid;
    @try {
        NSString *exe = nil;
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

// 系统/关键进程判定：拿不到 bid(="?") 不再武断当系统进程；apple 前缀一律排除。
NS_INLINE BOOL PGIsSystemProcess(void) {
    NSString *bid = PGAppBundleID();
    if ([bid isEqualToString:@"?"]) return NO;
    if ([bid isEqualToString:@"com.apple.springboard"]) return YES;
    if ([bid hasPrefix:@"com.apple."]) return YES;
    return NO;
}

// 越狱管理类 App 黑名单：这些 App 的 window 结构特殊，注入浮层易崩。
NS_INLINE BOOL PGIsJailbreakManager(void) {
    NSString *bid = PGAppBundleID();
    NSArray *bl = @[@"org.coolstar.SileoStore", @"com.coolstar.SileoStore",
                    @"com.rile.ios.Sileo", @"com.tigisoftware.Filza",
                    @"com.saurik.Cydia", @"com.zebra.renati",
                    @"com.opa334.root-hiding"];
    for (NSString *b in bl) if ([bid isEqualToString:b]) return YES;
    if ([bid hasPrefix:@"com.opa334."]) return YES;
    return NO;
}

// 生效判定：默认【不注入任何 App】（全关），只在设置里勾选了「注入 App 列表」白名单后才命中勾选的 App。
// （选哪个注哪个：未勾选 → 全机零注入 → 无闪退/无安全模式；勾选某 App 才注入该 App。）
// 系统进程/越狱管理器始终不注入。
NS_INLINE BOOL PGCurrentAppSelected(void) {
    if (PGIsSystemProcess()) return NO;
    if (PGIsJailbreakManager()) return NO;
    NSString *bid = PGAppBundleID();
    if ([bid isEqualToString:@"?"]) return NO;
    id apps = PGValue(PGKeyApps);
    if ([apps isKindOfClass:[NSArray class]]) {
        NSArray *list = (NSArray *)apps;
        if (list.count == 0) return NO;              // 明确「全关」
        return [list containsObject:bid];
    }
    // 读不到偏好（第三方 App 有沙盒，读 /var/mobile/Library/Preferences 常被拒）→
    // 但本 dylib 已经被加载，这本身就说明 filter 白名单放行了本 App，
    // 而 filter 里只写「用户勾选过的 App」→ 判定为已勾选，避免出现"勾选了却没反应"。
    return YES;
}

#pragma mark - 注入 filter 同步（根治安全模式的根本手段）

// 从"自己被加载出来的真实路径"反推 jbroot：roothide 的 jbroot 是随机路径，写死 /var/jb
// 不可靠；但 PreferenceBundle / dylib 自身的 image path 一定带着真实 jbroot 前缀。
NS_INLINE NSString *PGJbRootFromSelf(void) {
    @try {
        uint32_t n = _dyld_image_count();
        for (uint32_t i = 0; i < n; i++) {
            const char *p = _dyld_get_image_name(i);
            if (!p || !p[0]) continue;
            NSString *s = [NSString stringWithUTF8String:p];
            NSRange r = [s rangeOfString:@"/Library/PreferenceBundles/PerfectGrabberNG.bundle"];
            if (r.location == NSNotFound)
                r = [s rangeOfString:@"/Library/MobileSubstrate/DynamicLibraries/PerfectGrabberNG.dylib"];
            if (r.location != NSNotFound) return [s substringToIndex:r.location];
        }
    } @catch (NSException *e) {}
    return nil;
}

// jbroot 候选（多来源并集）。
// 2.0.8 关键修正：本机的 jbroot 是 /var/containers/Bundle/Application/.jbroot-XXXX，
// 而 /var/jb 软链与 /var/jbroot 【根本不存在】—— 旧版候选里有一半是死路，
// 且失败原因会被后面的候选覆盖，于是只能看到「目录不存在」这种误导信息。
// 这里增加对 roothide 特征目录的直接扫描，不依赖软链，推断必定命中。
NS_INLINE NSArray<NSString *> *PGJbRootCandidates(void) {
    NSMutableArray *out = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    void (^add)(NSString *) = ^(NSString *r) {
        if (![r isKindOfClass:[NSString class]] || r.length == 0) return;
        if ([seen containsObject:r]) return;
        [seen addObject:r];
        [out addObject:r];
    };
    const char *e = getenv("JBROOT");
    if (e && e[0]) add([NSString stringWithUTF8String:e]);
    add(PGJbRootFromSelf());
    NSString *dest = [[NSFileManager defaultManager] destinationOfSymbolicLinkAtPath:@"/var/jb" error:NULL];
    if (dest.length) add(dest);
    @try {
        // roothide 特征：jbroot 就挂在 Bundle 目录下，名字以 .jbroot- 开头
        NSArray *names = [[NSFileManager defaultManager]
                          contentsOfDirectoryAtPath:@"/var/containers/Bundle/Application" error:NULL];
        for (NSString *n in names) {
            if ([n hasPrefix:@".jbroot-"])
                add([@"/var/containers/Bundle/Application" stringByAppendingPathComponent:n]);
        }
    } @catch (NSException *ex) {}
    add(@"/var/jb");
    add(@"/var/jbroot");
    return out;
}

#define PGFilterRelPath    @"Library/MobileSubstrate/DynamicLibraries/PerfectGrabberNG.plist"
#define PGHelperRelPath    @"usr/bin/pgngfilter"
// 中转文件：/var/mobile/Library/Preferences 是 mobile 可写目录（偏好本身就写这里，已验证）。
// 期望内容先落到这里，再由 root helper 搬进 filter 位置（或直接软链过去）。
#define PGFilterStagePath  @"/var/mobile/Library/Preferences/PGNG.filter.plist"
#define PGFilterStatusPath @"/var/mobile/Library/Preferences/PGNG.filter.status"

NS_INLINE NSArray<NSString *> *PGFilterPlistCandidates(void) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *r in PGJbRootCandidates()) {
        NSString *p = [r stringByAppendingPathComponent:PGFilterRelPath];
        if (![out containsObject:p]) [out addObject:p];
    }
    return out;
}

NS_INLINE NSArray<NSString *> *PGHelperCandidates(void) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *r in PGJbRootCandidates()) {
        NSString *p = [r stringByAppendingPathComponent:PGHelperRelPath];
        if (![out containsObject:p]) [out addObject:p];
    }
    return out;
}

// dylib 旁的注入 filter plist 路径（优先返回真实存在的那个）
NS_INLINE NSString *PGFilterPlistPath(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *p in PGFilterPlistCandidates()) {
        if ([fm fileExistsAtPath:p]) return p;
    }
    return PGFilterPlistCandidates().firstObject ?: @"";
}

NS_INLINE NSString *PGErrText(int err, NSString *what) {
    return [NSString stringWithFormat:@"%@ errno=%d(%s)", what, err, strerror(err)];
}

// 真实写一次（不预检：沙盒下 fileExists / isWritable 会说谎，只有真写才知道）
NS_INLINE BOOL PGRawWrite(NSData *data, NSString *path, NSString **errOut) {
    @try {
        int fd = open([path fileSystemRepresentation], O_WRONLY | O_CREAT | O_TRUNC, 0666);
        if (fd < 0) { if (errOut) *errOut = PGErrText(errno, @"open"); return NO; }
        ssize_t w = write(fd, [data bytes], [data length]);
        BOOL ok = (w == (ssize_t)[data length]);
        if (!ok && errOut) *errOut = PGErrText(errno, @"write");
        close(fd);
        return ok;
    } @catch (NSException *e) { if (errOut) *errOut = @"exception"; }
    return NO;
}

// 调 setuid root helper；返回进程退出码（0=成功），并把 helper 写下的状态串出来
NS_INLINE int PGRunHelper(NSArray<NSString *> *args, NSString **statusOut) {
    @try {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *helper = nil;
        for (NSString *h in PGHelperCandidates()) {
            if ([fm isExecutableFileAtPath:h]) { helper = h; break; }
        }
        if (!helper) { if (statusOut) *statusOut = @"helper未找到"; return -1; }

        [fm removeItemAtPath:PGFilterStatusPath error:NULL];
        const char *cargs[8] = {0};
        NSUInteger n = 0;
        cargs[n++] = [helper fileSystemRepresentation];
        for (NSString *a in args) { if (n < 6) cargs[n++] = [a fileSystemRepresentation]; }
        cargs[n] = NULL;

        pid_t pid = 0;
        char **envp = *_NSGetEnviron();
        int rc = posix_spawn(&pid, cargs[0], NULL, NULL, (char *const *)cargs, envp);
        if (rc != 0) { if (statusOut) *statusOut = PGErrText(rc, @"spawn"); return -2; }
        int st = 0;
        if (waitpid(pid, &st, 0) < 0) { if (statusOut) *statusOut = @"waitpid失败"; return -3; }
        int code = WIFEXITED(st) ? WEXITSTATUS(st) : -4;
        NSString *s = [NSString stringWithContentsOfFile:PGFilterStatusPath
                                                encoding:NSUTF8StringEncoding error:NULL];
        if (statusOut) *statusOut = [NSString stringWithFormat:@"%@ exit=%d",
                                     s.length ? s : @"(无状态文件)", code];
        return code;
    } @catch (NSException *e) { if (statusOut) *statusOut = @"exception"; }
    return -5;
}

// 读回某个 filter plist 里当前生效的 Bundles（用于写入后校验）
NS_INLINE NSArray *PGBundlesAtPath(NSString *path) {
    @try {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:path];
        id b = [[d objectForKey:@"Filter"] objectForKey:@"Bundles"];
        if ([b isKindOfClass:[NSArray class]]) return (NSArray *)b;
    } @catch (NSException *e) {}
    return nil;
}

// 诊断信息：把「filter 到底写没写成功、写到哪、为什么失败」回写到偏好里，
// 这样设置面板能直接显示原因，用户不用猜、也不用开 Filza。
#define PGKeyFilterDiag @"filterDiag"
NS_INLINE void PGSetDiag(NSString *s) {
    @try {
        NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary:PGPrefs()];
        d[PGKeyFilterDiag] = s ?: @"";
        [d writeToFile:PGPrefsWritePath() atomically:YES];
    } @catch (NSException *e) {}
}
NS_INLINE NSString *PGDiag(void) {
    id v = PGValue(PGKeyFilterDiag);
    return [v isKindOfClass:[NSString class]] ? (NSString *)v : @"";
}

// 把「注入 App 列表」写进 filter plist 的 Filter.Bundles。
// 与旧版"注进所有进程再运行时 return"的本质区别：filter 里没有的进程
// （SpringBoard / Sileo / 系统 App）压根不会被 dyld 加载 dylib —— 这才是根治。
NS_INLINE BOOL PGSyncFilterPlist(void) {
    NSMutableString *log = [NSMutableString string];
    @try {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSArray<NSString *> *cs = PGFilterPlistCandidates();
        if (cs.count == 0) { PGSetDiag(@"无法推断 jbroot"); return NO; }
        [log appendFormat:@"uid=%d euid=%d | 候选%lu", getuid(), geteuid(), (unsigned long)cs.count];
        if (cs.count) [log appendFormat:@" | 首选=%@", cs.firstObject];

        NSMutableArray *bundles = [NSMutableArray array];
        id apps = PGValue(PGKeyApps);
        if ([apps isKindOfClass:[NSArray class]]) {
            for (id b in (NSArray *)apps) {
                if (![b isKindOfClass:[NSString class]]) continue;
                NSString *bid = (NSString *)b;
                if (!bid.length) continue;
                if ([bid isEqualToString:@"com.apple.springboard"]) continue;
                if ([bid hasPrefix:@"com.apple."]) continue;   // 系统 App 永不注入
                [bundles addObject:bid];
            }
        }
        // 全关：写占位 bid，保证不匹配任何进程
        if (bundles.count == 0) bundles = [@[@"com.sykes.pgng.disabled"] mutableCopy];

        NSError *serErr = nil;
        NSData *data = [NSPropertyListSerialization
                        dataWithPropertyList:@{@"Filter": @{@"Bundles": bundles}}
                                      format:NSPropertyListXMLFormat_v1_0
                                     options:0 error:&serErr];
        if (!data.length) { PGSetDiag([log stringByAppendingString:@" | 序列化失败"]); return NO; }

        NSString *stage = PGFilterStagePath;

        // —— 第 0 层：filter 已经是软链且指向中转文件 → 只写中转就等于写 filter（免提权稳态）
        for (NSString *dst in cs) {
            NSString *link = [fm destinationOfSymbolicLinkAtPath:dst error:NULL];
            if (link.length && [link isEqualToString:stage]) {
                NSString *err = nil;
                if (PGRawWrite(data, stage, &err) && [PGBundlesAtPath(dst) isEqualToArray:bundles]) {
                    [log appendString:@" | 软链直写=成功"];
                    PGSetDiag(log);
                    return YES;
                }
                [log appendFormat:@" | 软链直写失败(%@)", err ?: @"回读校验不符"];
                break;
            }
        }

        // 期望内容先落到中转文件（mobile 可写）
        NSString *serr = nil;
        BOOL stageOK = PGRawWrite(data, stage, &serr);
        [log appendFormat:@" | 中转=%@", stageOK ? @"OK" : [@"失败" stringByAppendingString:(serr ?: @"")]];

        // —— 第 1 层：mobile 直接写 filter（权限多半不够，但先试，成本为零）
        if (stageOK && cs.count) {
            NSString *dst = cs.firstObject;
            NSString *err = nil;
            if (PGRawWrite(data, dst, &err) && [PGBundlesAtPath(dst) isEqualToArray:bundles]) {
                [log appendString:@" | 直写=成功"];
                PGSetDiag(log);
                return YES;
            }
            [log appendFormat:@" | 直写失败(%@)", err ?: @"回读校验不符"];
        }

        // —— 第 2 层：setuid root helper 搬运（真正的解法）
        if (stageOK && cs.count) {
            NSString *dst = cs.firstObject;
            NSString *st = nil;
            int rc = PGRunHelper(@[stage, dst, PGFilterStatusPath], &st);
            [log appendFormat:@" | helper%@", st ?: @"=?"];
            if (rc == 0 && [PGBundlesAtPath(dst) isEqualToArray:bundles]) {
                // —— 第 3 层：一次性把 filter 改造成软链，之后永远不必再提权
                NSString *st2 = nil;
                int rc2 = PGRunHelper(@[@"link", stage, dst, PGFilterStatusPath], &st2);
                [log appendFormat:@" | 软链改造=%@", (rc2 == 0) ? @"成功(以后免提权)" : (st2 ?: @"失败")];
                [log appendString:@" | 结果=成功"];
                PGSetDiag(log);
                return YES;
            }
        }

        [log appendString:@" | 结果=失败"];
        PGSetDiag(log);
        return NO;
    } @catch (NSException *e) {
        [log appendString:@" | 异常"];
        PGSetDiag(log);
    }
    return NO;
}

// 读回当前 filter plist 里实际生效的 Bundles（供设置面板显示诊断信息，
// 这样用户不用 Filza 也能一眼确认「勾选有没有真的写进 filter」）
NS_INLINE NSArray *PGFilterBundles(void) {
    @try {
        // 逐个候选读，第一个能解析出 Bundles 的即当前生效值
        for (NSString *p in PGFilterPlistCandidates()) {
            NSArray *b = PGBundlesAtPath(p);
            if (b.count) return b;
        }
    } @catch (NSException *e) {}
    return nil;
}

NS_INLINE NSTimeInterval PGDuration(void) {
    id v = PGValue(PGKeyDuration);
    if (v && [v respondsToSelector:@selector(doubleValue)]) {
        double d = [v doubleValue];
        if (d >= 0.5) return d;
    }
    return 2.0;
}

// 常驻显示：开启后时间电量一直挂在顶部，不依赖下拉手势（游戏中手势不灵时的保底方案）
NS_INLINE BOOL PGKeepOn(void) {
    id v = PGValue(PGKeyKeepOn);
    if (v == nil) return NO;
    if ([v respondsToSelector:@selector(boolValue)]) return [v boolValue];
    return NO;
}
