module main

import os
import time

// Cli 收集命令行解析后的所有状态。
struct Cli {
mut:
	exe              string
	perclimit        int
	exe_ok           bool
	pid_ok           bool
	limit_ok         bool
	pid              int
	include_children bool
	verbose          bool
	lazy             bool
	ncpu             int
}

// 全局退出标志,由 C 信号回调设置。
__global g_should_exit = false

fn C.signal(i32, voidptr) voidptr

// quit_handler 是 C 信号处理回调,只设置全局标志。
fn quit_handler(_signal i32) {
	unsafe {
		*(&g_should_exit) = true
	}
	print('\r')
	os.flush()
}

fn print_usage(program_name string, ncpu int) string {
	mut s := ''
	s += 'Usage: ${program_name} [OPTIONS...] TARGET\n'
	s += '   OPTIONS\n'
	s += '      -l, --limit=N          percentage of cpu allowed from 0 to ${ncpu * 100} (required)\n'
	s += '      -v, --verbose          show control statistics\n'
	s += '      -z, --lazy             exit if if no target process, or if it dies\n'
	s += '      -i, --include-children limit also the children processes\n'
	s += '      -h, --help             display this help and exit\n'
	s += '   TARGET must be exactly one of these:\n'
	s += '      -p, --pid=N            pid of the process (implies -z)\n'
	s += '      -e, --exe=FILE         name of the executable program file or path name\n'
	s += '      -COMMAND [ARGS]        run this command and limit it (implies -z)\n'
	s += '\n'
	return s
}

fn find_process_by_name(name string) int {
	mut it := procinfo_open(Filter{}) or { return 0 }
	defer { procinfo_close(mut it) }
	for {
		p := procinfo_next(mut it) or { break }
		bn := proc_basename(p.command)
		if bn == name || p.command == name || p.command.ends_with('/${name}') {
			return p.pid
		}
	}
	return 0
}

fn main() {
	program_name := os.args[0]
	mut cli := Cli{
		ncpu: get_ncpu()
	}

	// 手动解析参数(避开 getopt_long 在 V 里的 binding 复杂性)。
	mut i := 1
	mut command_mode := false
	mut command_start := 0
	for i < os.args.len {
		arg := os.args[i]
		match arg {
			'-h', '--help' {
				print(print_usage(program_name, cli.ncpu))
				return
			}
			'-v', '--verbose' {
				cli.verbose = true
			}
			'-z', '--lazy' {
				cli.lazy = true
			}
			'-i', '--include-children' {
				cli.include_children = true
			}
			else {
				if arg.starts_with('--pid=') {
					cli.pid = arg['--pid='.len..].int()
					cli.pid_ok = true
				} else if arg == '--pid' {
					i++
					if i >= os.args.len {
						eprintln('--pid requires an argument')
						exit(1)
					}
					cli.pid = os.args[i].int()
					cli.pid_ok = true
				} else if arg.starts_with('-p=') {
					cli.pid = arg['-p='.len..].int()
					cli.pid_ok = true
				} else if arg == '-p' {
					i++
					if i >= os.args.len {
						eprintln('-p requires an argument')
						exit(1)
					}
					cli.pid = os.args[i].int()
					cli.pid_ok = true
				} else if arg.starts_with('-p') && arg.len > 2 {
					cli.pid = arg[2..].int()
					cli.pid_ok = true
				} else if arg.starts_with('--exe=') {
					cli.exe = arg['--exe='.len..]
					cli.exe_ok = true
				} else if arg == '--exe' {
					i++
					if i >= os.args.len {
						eprintln('--exe requires an argument')
						exit(1)
					}
					cli.exe = os.args[i]
					cli.exe_ok = true
				} else if arg.starts_with('-e=') {
					cli.exe = arg['-e='.len..]
					cli.exe_ok = true
				} else if arg == '-e' {
					i++
					if i >= os.args.len {
						eprintln('-e requires an argument')
						exit(1)
					}
					cli.exe = os.args[i]
					cli.exe_ok = true
				} else if arg.starts_with('-e') && arg.len > 2 {
					cli.exe = arg[2..]
					cli.exe_ok = true
				} else if arg.starts_with('--limit=') {
					cli.perclimit = arg['--limit='.len..].int()
					cli.limit_ok = true
				} else if arg == '--limit' {
					i++
					if i >= os.args.len {
						eprintln('--limit requires an argument')
						exit(1)
					}
					cli.perclimit = os.args[i].int()
					cli.limit_ok = true
				} else if arg.starts_with('-l=') {
					cli.perclimit = arg['-l='.len..].int()
					cli.limit_ok = true
				} else if arg == '-l' {
					i++
					if i >= os.args.len {
						eprintln('-l requires an argument')
						exit(1)
					}
					cli.perclimit = os.args[i].int()
					cli.limit_ok = true
				} else if arg.starts_with('-l') && arg.len > 2 {
					cli.perclimit = arg[2..].int()
					cli.limit_ok = true
				} else if arg == '--' {
					command_mode = true
					command_start = i + 1
					break
				} else if !arg.starts_with('-') {
					// 命令模式:剩下都是要 fork + exec 的命令行
					command_mode = true
					command_start = i
					break
				} else {
					eprintln('Unknown option: ${arg}')
					eprint(print_usage(program_name, cli.ncpu))
					exit(1)
				}
			}
		}
		i++
	}

	// 参数校验
	if cli.pid_ok && (cli.pid <= 1 || cli.pid >= get_pid_max()) {
		eprintln('Error: Invalid value for argument PID')
		eprint(print_usage(program_name, cli.ncpu))
		exit(1)
	}
	if cli.pid != 0 {
		cli.lazy = true
	}
	if !cli.limit_ok {
		eprintln('Error: You must specify a cpu limit percentage')
		eprint(print_usage(program_name, cli.ncpu))
		exit(1)
	}
	limit := f64(cli.perclimit) / 100.0
	if limit < 0.0 || limit > f64(cli.ncpu) {
		eprintln('Error: limit must be in the range 0-${cli.ncpu * 100}')
		eprint(print_usage(program_name, cli.ncpu))
		exit(1)
	}
	mode_count := (if cli.exe_ok { 1 } else { 0 }) + (if cli.pid_ok { 1 } else { 0 }) + (if command_mode { 1 } else { 0 })
	if mode_count == 0 {
		eprintln('Error: You must specify one target process, either by name, pid, or command line')
		eprint(print_usage(program_name, cli.ncpu))
		exit(1)
	}
	if mode_count > 1 {
		eprintln('Error: You must specify exactly one target process, either by name, pid, or command line')
		eprint(print_usage(program_name, cli.ncpu))
		exit(1)
	}

	// 安装 SIGINT / SIGTERM 处理器 (走 C signal 直接注册)。
	unsafe {
		C.signal(C.SIGINT, voidptr(quit_handler))
		C.signal(C.SIGTERM, voidptr(quit_handler))
	}

	if cli.verbose {
		println('${cli.ncpu} cpu detected')
	}

	if command_mode {
		run_command_mode(command_start, limit, cli.include_children, cli.verbose)
		return
	}

	run_target_mode(cli, limit)
}

fn run_target_mode(cli Cli, limit f64) {
	mut pid := cli.pid
	for {
		if unsafe { g_should_exit } {
			print('\r')
			os.flush()
			exit(0)
		}
		mut ret := 0
		if cli.pid_ok {
			ret = pid
			if !proc_alive(ret) {
				println('No process found')
				ret = 0
			}
		} else {
			ret = find_process_by_name(cli.exe)
			if ret == 0 {
				println('No process found')
			} else {
				pid = ret
			}
		}
		if ret > 0 {
			own := os.getpid()
			if ret == own {
				println('Target process ${ret} is cpulimit itself! Aborting because it makes no sense')
				exit(1)
			}
			println('Process ${pid} found')
			limit_process(pid, limit, cli.include_children, cli.verbose)
		}
		if cli.lazy {
			break
		}
		for _ in 0 .. 4 {
			if unsafe { g_should_exit } {
				print('\r')
				os.flush()
				exit(0)
			}
			time.sleep(500 * time.millisecond)
		}
	}
}

fn run_command_mode(command_start int, limit f64, include_children bool, verbose bool) {
	if command_start >= os.args.len {
		eprintln('No command specified')
		exit(1)
	}
	cmd := os.args[command_start]
	cmd_args := os.args[command_start..].clone()
	if verbose {
		println("Running command: '${cmd_args.join(' ')}'")
	}

	cpid := os.fork()
	if cpid < 0 {
		exit(1)
	}
	if cpid == 0 {
		os.execvp(cmd, cmd_args) or { eprintln('execvp failed: ${err}') }
		exit(127)
	}
	limiter := os.fork()
	if limiter < 0 {
		exit(1)
	}
	if limiter > 0 {
		os.wait()
		os.wait()
		exit(0)
	}
	if verbose {
		println('Limiting process ${cpid}')
	}
	limit_process(cpid, limit, include_children, verbose)
	exit(0)
}
