#ifndef VCPULIMIT_PROCINFO_DARWIN_H
#define VCPULIMIT_PROCINFO_DARWIN_H

#include <libproc.h>
#include <sys/sysctl.h>
#include <string.h>

int vcpulimit_list_pids(int *out, int cap);
int vcpulimit_read_pid(int pid, int *out_ppid, long long *out_start_sec,
                       long long *out_user_ns, long long *out_sys_ns,
                       char *out_comm, int comm_cap);

#endif
