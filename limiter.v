module main

import math
import time

// kill_pid 封装的 C.kill 包装,确保返回值被检查并转换成 bool。
fn kill_pid(pid int, sig i32) bool {
	return unsafe { C.kill(pid, sig) } == 0
}

// limit_process 是 cpulimit 的核心:在每个 100ms 时隙里先 SIGCONT 让目标进程跑一段,
// 再 SIGSTOP 让它停一段。workingrate 按上一周期实测 vs. 目标 limit 收敛。
fn limit_process(pid int, limit f64, include_children bool, verbose bool) {
	increase_priority(verbose)

	mut pg := new_process_group(pid, include_children)

	pg.refresh() or {}
	if verbose {
		println('Members in the process group owned by ${pid}: ${pg.current.len}')
	}

	mut workingrate := -1.0
	mut cycle := 0
	for {
		pg.refresh() or {}
		if pg.current.len == 0 {
			if verbose {
				println('No more processes.')
			}
			break
		}

		mut pcpu := pg.sum_cpu_usage()
		mut twork_ns := i64(0)
		if pcpu < 0 {
			// 第一周期,没采样数据,用 limit 初始化
			pcpu = limit
			workingrate = limit
			twork_ns = i64(time_slot_us) * i64(limit * 1000.0)
		} else {
			workingrate = math.min(workingrate / pcpu * limit, 1.0)
			twork_ns = i64(time_slot_us) * i64(workingrate * 1000.0)
		}
		tsleep_ns := i64(time_slot_us) * 1000 - twork_ns

		if verbose {
			if cycle % 200 == 0 {
				println('\n%CPU\twork quantum\tsleep quantum\tactive rate')
			}
			if cycle % 10 == 0 && cycle > 0 {
				println('${pcpu * 100:5.2f}%\t${twork_ns / 1000:6d} us\t${tsleep_ns / 1000:6d} us\t${workingrate * 100:5.2f}%')
			}
		}

		// 唤醒所有目标进程,记录本周期唤醒失败者以便下一轮移除
		mut dead := []int{}
		for p in pg.current {
			if !kill_pid(p.pid, C.SIGCONT) {
				if verbose {
					eprintln('SIGCONT failed. Process ${p.pid} dead!')
				}
				dead << p.pid
			}
		}
		for d in dead {
			pg.remove(d)
		}

		// 工作阶段
		start := time.now()
		sleep_ns(twork_ns)
		elapsed := time.now().unix_nano() - start.unix_nano()

		if tsleep_ns > 0 {
			mut dead2 := []int{}
			for p in pg.current {
				if !kill_pid(p.pid, C.SIGSTOP) {
					if verbose {
						eprintln('SIGSTOP failed. Process ${p.pid} dead!')
					}
					dead2 << p.pid
				}
			}
			for d in dead2 {
				pg.remove(d)
			}
			sleep_ns(tsleep_ns)
		}

		// 长时间漂移提示(供 verbose 调优,这里静默)
		_ = elapsed
		cycle++
	}
}

// sleep_ns 用 V time.sleep 提供纳秒级 sleep,跨平台安全。
fn sleep_ns(ns i64) {
	if ns <= 0 {
		return
	}
	mut ms := int(ns / 1_000_000)
	if ms <= 0 {
		ms = 1
	}
	time.sleep(ms * time.millisecond)
}
