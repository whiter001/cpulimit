#ifndef VCPULIMIT_PROCINFO_FREEBSD_H
#define VCPULIMIT_PROCINFO_FREEBSD_H

#include <kvm.h>
#include <fcntl.h>
#include <paths.h>
#include <sys/param.h>
#include <sys/sysctl.h>
#include <sys/user.h>
#include <stdlib.h>
#include <string.h>

int vcpulimit_kvm_open(void **out_kd);
int vcpulimit_kvm_procs(void *kd, void **out_procs, int *out_count);
int vcpulimit_kvm_one(void *kd, int pid, void *out_kp);
int vcpulimit_kvm_argv0(void *kd, void *kp_in, char *out, int cap);
void vcpulimit_kvm_close(void *kd);

#endif
