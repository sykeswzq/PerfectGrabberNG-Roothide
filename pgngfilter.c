// pgngfilter.c —— 极小的 setuid-root 帮助程序（roothide）
//
// 为什么需要它：substrate 的 filter plist 位于 <jbroot>/Library/MobileSubstrate/DynamicLibraries/，
// 属 root:wheel、权限 0644；设置面板跑在 Preferences 里，身份是 mobile，既改不了文件也进不去目录。
// 所以「在设置里勾选 App → 立刻改写 filter」这一步必须由 root 完成。
//
// 两种用法（最后一个参数永远是状态输出文件）：
//   1) pgngfilter <src> <dst> <status>
//        把 src 逐字节拷到 dst（src 是 mobile 可写的中转文件）
//   2) pgngfilter link <linkTarget> <dst> <status>
//        删掉 dst，改成指向 linkTarget 的软链。
//        一旦改造成功，之后每次勾选只需写中转文件（mobile 权限足够），
//        不再需要提权 —— 即使 setuid 在某些环境失效，后续使用也不受影响。
//
// 状态文件里会写 rc / uid / euid / errno，便于把「提权到底成没成」变成确定性信号。
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <sys/stat.h>
#include <sys/types.h>

static void write_status(const char *path, int rc, const char *extra) {
    if (!path) return;
    FILE *f = fopen(path, "wb");
    if (!f) return;
    fprintf(f, "rc=%d uid=%d euid=%d what=%s errno=%d(%s)\n",
            rc, (int)getuid(), (int)geteuid(),
            extra ? extra : "none", errno, strerror(errno));
    fclose(f);
    chmod(path, 0666);
}

int main(int argc, char **argv) {
    if (argc < 4) return 2;
    const char *status = argv[argc - 1];

    // ---- 模式 2：改成软链 ----
    if (strcmp(argv[1], "link") == 0) {
        if (argc < 5) return 2;
        const char *target = argv[2];
        const char *dst    = argv[3];
        struct stat st;
        if (stat(target, &st) != 0) { write_status(status, 10, "target-missing"); return 10; }
        unlink(dst);
        if (symlink(target, dst) != 0) { write_status(status, 11, "symlink-failed"); return 11; }
        write_status(status, 0, "linked");
        return 0;
    }

    // ---- 模式 1：拷贝 ----
    const char *src = argv[1];
    const char *dst = argv[2];

    FILE *sf = fopen(src, "rb");
    if (!sf) { write_status(status, 3, "open-src"); return 3; }
    if (fseek(sf, 0, SEEK_END) != 0) { fclose(sf); write_status(status, 4, "seek-src"); return 4; }
    long n = ftell(sf);
    if (n < 0) { fclose(sf); write_status(status, 4, "ftell-src"); return 4; }
    rewind(sf);

    char *buf = (char *)malloc((size_t)n + 1);
    if (!buf) { fclose(sf); write_status(status, 5, "malloc"); return 5; }
    size_t got = (n > 0) ? fread(buf, 1, (size_t)n, sf) : 0;
    fclose(sf);
    if (got != (size_t)n) { free(buf); write_status(status, 6, "read-src"); return 6; }

    FILE *df = fopen(dst, "wb");
    if (!df) { free(buf); write_status(status, 7, "open-dst"); return 7; }
    int rc = 0;
    if (n > 0 && fwrite(buf, 1, (size_t)n, df) != (size_t)n) rc = 8;
    if (fclose(df) != 0 && rc == 0) rc = 9;
    // 顺手放宽：万一哪次 helper 不可用，mobile 直接写也还有一线机会
    chmod(dst, 0666);
    free(buf);
    write_status(status, rc, rc == 0 ? "copied" : "write-dst");
    return rc;
}
