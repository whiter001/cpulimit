#include <libproc.h>
#include <sys/sysctl.h>
#include <string.h>

int vcpulimit_list_pids(int *out, int cap) {
    int needed = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
    if (needed <= 0) return 0;
    if (needed > cap) needed = cap;
    int n = proc_listpids(PROC_ALL_PIDS, 0, out, needed * (int)sizeof(int));
    if (n <= 0) return 0;
    return n / (int)sizeof(int);
}

int vcpulimit_read_pid(int pid, int *out_ppid, long long *out_start_sec,
                       long long *out_user_ns, long long *out_sys_ns,
                       char *out_comm, int comm_cap) {
    struct proc_taskallinfo ti;
    int bytes = proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &ti, sizeof(ti));
    if (bytes <= 0) return -1;
    if (out_ppid)      *out_ppid      = (int)ti.pbsd.pbi_ppid;
    if (out_start_sec) *out_start_sec = (long long)ti.pbsd.pbi_start_tvsec;
    if (out_user_ns)   *out_user_ns   = (long long)ti.ptinfo.pti_total_user;
    if (out_sys_ns)    *out_sys_ns    = (long long)ti.ptinfo.pti_total_system;
    if (out_comm && comm_cap > 0) {
        size_t n = strnlen(ti.pbsd.pbi_comm, sizeof(ti.pbsd.pbi_comm));
        if ((int)n >= comm_cap) n = (size_t)(comm_cap - 1);
        memcpy(out_comm, ti.pbsd.pbi_comm, n);
        out_comm[n] = '\0';
    }
    return 0;
}
