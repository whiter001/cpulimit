// procinfo: 平台无关的进程信息接口。
// 由于 V 编译器对跨 $if 块的函数引用支持有限,这里采用 facade 模式:
// 每个 procinfo_open / procinfo_next / procinfo_close 把所有平台的实现内联在自己体内,
// 通过 $if 在编译期只保留当前平台那段。
module main

#include <signal.h>
#include <sys/types.h>

// 通过 -I 让 V 找到同目录的 .h 头文件,把 C 包装函数声明 include 进主 .c 文件。
#flag -I @VMODROOT

// 直接 include 头文件,把 C 函数原型带进主 .c 文件。
$if darwin {
#include "procinfo_darwin.h"
}
$if freebsd {
#include "procinfo_freebsd.h"
}

pub struct Process {
pub mut:
	pid       int
	ppid      int
	starttime int
	cputime   int    // 单位毫秒
	command   string
	cpu_usage f64   // 0..1,指数滑动平均,初始 -1
	prev_cpu  int
}

pub struct Filter {
pub:
	target_pid       int
	include_children bool
}

// 编译期常量,放在文件顶层以便各 $if 分支共享。
const darwin_max_pids = 8192
const darwin_max_comm = 64
const kinfo_proc_sz = 768

// C 函数声明放在顶层。#flag 也一样。
$if darwin {
#flag -lproc
#flag @VMODROOT/procinfo_darwin.c
fn C.vcpulimit_list_pids(&i32, i32) i32
fn C.vcpulimit_read_pid(i32, &i32, &i64, &i64, &i64, &u8, i32) i32
}
$if linux {
#include <dirent.h>
fn C.opendir(&u8) voidptr
fn C.readdir(voidptr) &C.dirent
fn C.closedir(voidptr) i32
}
$if freebsd {
#flag @VMODROOT/procinfo_freebsd.c
fn C.vcpulimit_kvm_open(&voidptr) i32
fn C.vcpulimit_kvm_procs(voidptr, &voidptr, &i32) i32
fn C.vcpulimit_kvm_one(voidptr, i32, voidptr) i32
fn C.vcpulimit_kvm_argv0(voidptr, voidptr, &u8, i32) i32
fn C.vcpulimit_kvm_close(voidptr)
}

// alive 检查 pid 是否存在(向其发送信号 0)。
fn proc_alive(pid int) bool {
	return C.kill(pid, 0) == 0
}

// basename 取路径末尾文件名。
fn proc_basename(path string) string {
	idx := path.last_index('/') or { return path }
	return path[idx + 1..]
}

// clone 用于在 process_group 里共享 CPU 使用率快照。
fn (p &Process) clone() Process {
	return Process{
		pid: p.pid
		ppid: p.ppid
		starttime: p.starttime
		cputime: p.cputime
		command: p.command
		cpu_usage: p.cpu_usage
		prev_cpu: p.prev_cpu
	}
}

// =============================================================================
// 平台无关的 Iterator。所有平台共用同一个 struct。
// =============================================================================
pub struct Iterator {
mut:
	tag        string
	pidlist    []i32
	idx        int
	count      int
	dir_handle voidptr
	kvm_handle voidptr
	procs      voidptr
	filter     Filter
}

// =============================================================================
// procinfo_open: 在编译期根据 OS 分支内联实现。
// =============================================================================
fn procinfo_open(filter Filter) !Iterator {
	mut it := Iterator{
		filter: filter
	}
	$if darwin {
		it.tag = 'darwin'
		mut buf := []i32{len: darwin_max_pids}
		n := unsafe { C.vcpulimit_list_pids(&buf[0], darwin_max_pids) }
		if n <= 0 {
			return error('vcpulimit_list_pids returned ${n}')
		}
		mut uniq := []i32{}
		for i in 0 .. n {
			pid := buf[i]
			if pid == 0 {
				continue
			}
			if pid in uniq {
				continue
			}
			uniq << pid
		}
		it.pidlist = uniq
	}
	$if linux {
		it.tag = 'linux'
		dip := unsafe { C.opendir('/proc'.str) }
		if dip == voidptr(0) {
			return error('opendir /proc failed')
		}
		it.dir_handle = dip
	}
	$if freebsd {
		it.tag = 'freebsd'
		mut kd := voidptr(0)
		if unsafe { C.vcpulimit_kvm_open(&kd) } != 0 {
			return error('kvm_open failed')
		}
		mut procs := voidptr(0)
		mut count := 0
		if unsafe { C.vcpulimit_kvm_procs(kd, &procs, &count) } != 0 {
			unsafe { C.vcpulimit_kvm_close(kd) }
			return error('kvm_getprocs failed')
		}
		it.kvm_handle = kd
		it.procs = procs
		it.count = count
	}
	return it
}

// =============================================================================
// procinfo_next: 每个平台的内联实现。
// =============================================================================
fn procinfo_next(mut it Iterator) !Process {
	mut p := Process{}
	$if darwin {
		// 平台特定的 fill helper(也内联)
		fill := fn (pid int, mut p Process) bool {
			mut ppid := i32(0)
			mut start := i64(0)
			mut user_ns := i64(0)
			mut sys_ns := i64(0)
			mut comm := []u8{len: darwin_max_comm, init: 0}
			rc := unsafe { C.vcpulimit_read_pid(pid, &ppid, &start, &user_ns, &sys_ns, &comm[0], comm.len) }
			if rc != 0 {
				return false
			}
			p.pid = pid
			p.ppid = int(ppid)
			p.starttime = int(start)
			p.cputime = int((user_ns + sys_ns) / 1_000_000)
			mut cmd := []u8{}
			for b in comm {
				if b == 0 {
					break
				}
				cmd << b
			}
			p.command = cmd.bytestr()
			return true
		}
		if it.filter.target_pid != 0 && !it.filter.include_children {
			// 单点查询模式:只在第一次返回目标,之后清空 pidlist 让迭代结束。
			if it.pidlist.len == 0 {
				return error('end')
			}
			pid := it.filter.target_pid
			if !fill(pid, mut p) {
				return error('pid ${pid} not found')
			}
			unsafe { it.pidlist.free() }
			it.pidlist = []
			return p
		}
		for it.idx < it.pidlist.len {
			pid := it.pidlist[it.idx]
			it.idx++
			if it.filter.target_pid != 0 && it.filter.include_children {
				if !fill(pid, mut p) {
					continue
				}
				if pid != it.filter.target_pid && p.ppid != it.filter.target_pid {
					continue
				}
				return p
			}
			if !fill(pid, mut p) {
				continue
			}
			return p
		}
		return error('end')
	}
	$if linux {
		fill_stat := fn (pid int, mut p Process) bool {
			path := '/proc/${pid}/stat'
			contents := os.read_file(path) or { return false }
			rp := contents.last_index(')') or { return false }
			rest := contents[rp + 1..].trim_space().split(' ')
			if rest.len < 22 {
				return false
			}
			p.ppid = rest[1].int()
			utime := rest[11].i64()
			stime := rest[12].i64()
			starttime := rest[21].i64()
			clk := unsafe { C.sysconf(C._SC_CLK_TCK) }
			p.cputime = int((utime + stime) * 1000 / clk)
			p.starttime = int(starttime / clk)
			return true
		}
		fill_cmd := fn (pid int, mut p Process) bool {
			raw := os.read_file('/proc/${pid}/cmdline') or { return false }
			mut first := []u8{}
			mut found := false
			for b in raw {
				if b == 0 {
					found = true
					break
				}
				first << b
			}
			if !found && raw.len > 0 {
				first = raw.bytes()
			}
			if first.len == 0 {
				return false
			}
			p.command = first.bytestr()
			return true
		}
		if it.filter.target_pid != 0 && !it.filter.include_children {
			// 单点查询:第一次返回目标,关闭 DIR 后使后续 next 立刻 end。
			if it.dir_handle == voidptr(0) {
				return error('end')
			}
			p.pid = it.filter.target_pid
			if !fill_stat(it.filter.target_pid, mut p) {
				return error('pid ${it.filter.target_pid} not found')
			}
			fill_cmd(it.filter.target_pid, mut p)
			unsafe { C.closedir(it.dir_handle) }
			it.dir_handle = voidptr(0)
			return p
		}
		for {
			dit := unsafe { C.readdir(it.dir_handle) }
			if dit == voidptr(0) {
				return error('end')
			}
			unsafe {
				mut pname := &u8(0)
				$if x64 {
					pname = &u8(voidptr(dit) + 19)
				}
				$else {
					pname = &u8(voidptr(dit) + 8)
				}
				mut bytes := []u8{}
				for {
					c := *pname
					if c == 0 {
						break
					}
					if !(c >= `0` && c <= `9`) {
						bytes = []
						break
					}
					bytes << c
					pname++
				}
				if bytes.len == 0 {
					continue
				}
				pid := bytes.bytestr().int()
				if !fill_stat(pid, mut p) {
					continue
				}
				fill_cmd(pid, mut p)
				p.pid = pid
				if it.filter.target_pid != 0 {
					if pid != it.filter.target_pid && p.ppid != it.filter.target_pid {
						continue
					}
				}
				return p
			}
		}
	}
	$if freebsd {
		read_field := fn (base voidptr, off int) int {
			unsafe {
				return *(&i32(base + off))
			}
		}
		read_i64 := fn (base voidptr, off int) i64 {
			unsafe {
				return *(&i64(base + off))
			}
		}
		fill_one := fn (kd voidptr, pid int, mut p Process) bool {
			mut kp_buf := []u8{len: kinfo_proc_sz}
			if unsafe { C.vcpulimit_kvm_one(kd, pid, voidptr(&kp_buf[0])) } != 0 {
				return false
			}
			base := voidptr(&kp_buf[0])
			p.pid = pid
			p.ppid = read_field(base, 4)
			p.starttime = int(read_i64(base, 0x68))
			p.cputime = int(read_i64(base, 0x88) / 1000)
			mut cmd := []u8{len: 1024}
			unsafe { C.vcpulimit_kvm_argv0(kd, base, &cmd[0], cmd.len) }
			mut bytes := []u8{}
			for b in cmd {
				if b == 0 {
					break
				}
				bytes << b
			}
			p.command = bytes.bytestr()
			return true
		}
		if it.filter.target_pid != 0 && !it.filter.include_children {
			if it.idx >= it.count {
				return error('end')
			}
			pid := it.filter.target_pid
			if !fill_one(it.kvm_handle, pid, mut p) {
				return error('pid ${pid} not found')
			}
			it.idx = it.count
			return p
		}
		for it.idx < it.count {
			kp_base := voidptr(it.procs) + kinfo_proc_sz * it.idx
			it.idx++
			pid := read_field(kp_base, 0)
			ppid := read_field(kp_base, 4)
			if pid <= 2 {
				continue
			}
			if it.filter.target_pid != 0 && it.filter.include_children {
				if pid != it.filter.target_pid && ppid != it.filter.target_pid {
					continue
				}
			}
			p.pid = pid
			p.ppid = ppid
			p.starttime = int(read_i64(kp_base, 0x68))
			p.cputime = int(read_i64(kp_base, 0x88) / 1000)
			mut cmd := []u8{len: 1024}
			unsafe { C.vcpulimit_kvm_argv0(it.kvm_handle, kp_base, &cmd[0], cmd.len) }
			mut bytes := []u8{}
			for b in cmd {
				if b == 0 {
					break
				}
				bytes << b
			}
			p.command = bytes.bytestr()
			return p
		}
		return error('end')
	}
	return error('procinfo not supported on this platform')
}

// =============================================================================
// procinfo_close: 内联每个平台的释放逻辑。
// =============================================================================
fn procinfo_close(mut it Iterator) {
	$if darwin {
		unsafe { it.pidlist.free() }
		it.idx = 0
	}
	$if linux {
		if it.dir_handle != voidptr(0) {
			unsafe { C.closedir(it.dir_handle) }
			it.dir_handle = voidptr(0)
		}
	}
	$if freebsd {
		if it.kvm_handle != voidptr(0) {
			unsafe { C.vcpulimit_kvm_close(it.kvm_handle) }
			it.kvm_handle = voidptr(0)
		}
	}
}
