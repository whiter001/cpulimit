module main

#include <sys/sysctl.h>
#include <sys/resource.h>

fn C.getpriority(i32, i32) i32
fn C.setpriority(i32, i32, i32) i32

const time_slot_us = 100_000 // 100 ms 一个调度时隙
const alfa = 0.08            // 指数滑动平均权重 (同 C 版本)
const min_dt_ms = 20         // 两次采样最少间隔
const max_priority = -10

// get_ncpu 取本机逻辑 CPU 数 (macOS / Linux / FreeBSD 都有 sysconf / sysctl 路径)。
fn get_ncpu() int {
	$if darwin {
		mut n := 0
		mut mib := [C.CTL_HW, C.HW_NCPU]!
		mut sz := sizeof(int)
		unsafe {
			C.sysctl(&mib[0], 2, &n, &sz, 0, 0)
		}
		if n <= 0 {
			n = 1
		}
		return n
	}
	$if linux || freebsd {
		return unsafe { C.sysconf(C._SC_NPROCESSORS_ONLN) }
	}
	return 1
}

// get_pid_max 返回内核允许的最大 pid 值。
fn get_pid_max() int {
	$if linux {
		contents := os.read_file('/proc/sys/kernel/pid_max') or { return 32768 }
		return contents.trim_space().int()
	}
	return 99998
}

// increase_priority 提高 cpulimit 自身的调度优先级(越低越好),
// 以确保我们发送的 SIGSTOP/SIGCONT 能尽快被调度。
fn increase_priority(verbose bool) {
	old := unsafe { C.getpriority(C.PRIO_PROCESS, 0) }
	mut prio := old
	for unsafe { C.setpriority(C.PRIO_PROCESS, 0, prio - 1) } == 0 && prio > max_priority {
		prio--
	}
	if prio != old {
		if verbose {
			println('Priority changed to ${prio}')
		}
	} else if verbose {
		println('Warning: Cannot change priority. Run as root or renice for best results.')
	}
}
