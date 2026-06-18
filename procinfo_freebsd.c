/*
 * FreeBSD 进程枚举的 C 包装层。
 * 通过 kvm_getprocs / kvm_getargv 读取进程元数据。
 */
#include <kvm.h>
#include <fcntl.h>
#include <paths.h>
#include <sys/param.h>
#include <sys/sysctl.h>
#include <sys/user.h>
#include <stdlib.h>
#include <string.h>

int vcpulimit_kvm_open(void **out_kd) {
    char errbuf[_POSIX2_LINE_MAX];
    kvm_t *kd = kvm_openfiles(NULL, _PATH_DEVNULL, NULL, O_RDONLY, errbuf);
    if (!kd) return -1;
    *out_kd = (void *)kd;
    return 0;
}

int vcpulimit_kvm_procs(void *kd, void **out_procs, int *out_count) {
    struct kinfo_proc *kp = kvm_getprocs((kvm_t *)kd, KERN_PROC_PROC, 0, out_count);
    if (!kp) return -1;
    *out_procs = (void *)kp;
    return 0;
}

int vcpulimit_kvm_one(void *kd, int pid, void *out_kp) {
    int count = 0;
    struct kinfo_proc *kp = kvm_getprocs((kvm_t *)kd, KERN_PROC_PID, pid, &count);
    if (!kp || count == 0) return -1;
    memcpy(out_kp, kp, sizeof(struct kinfo_proc));
    return 0;
}

int vcpulimit_kvm_argv0(void *kd, void *kp_in, char *out, int cap) {
    struct kinfo_proc *kp = (struct kinfo_proc *)kp_in;
    char **args = kvm_getargv((kvm_t *)kd, kp, 0);
    if (!args || !args[0]) {
        out[0] = '\0';
        return -1;
    }
    size_t n = strnlen(args[0], (size_t)cap - 1);
    memcpy(out, args[0], n);
    out[n] = '\0';
    return 0;
}

void vcpulimit_kvm_close(void *kd) {
    if (kd) kvm_close((kvm_t *)kd);
}
