module main

import time

// pid_hashfn 与 C 版本一致:把 pid 右移 8 位再与低 8 位异或后做桶索引。
fn pid_hashfn(pid int) int {
	return ((pid >> 8) ^ pid) & (pid_hash_sz - 1)
}

const pid_hash_sz = 1024

// ProcessGroup 管理一组被控进程。每个桶是一个 list-style slice,
// 保存从外部 iterator 拉到的进程快照,本周期用于发送信号。
struct ProcessGroup {
mut:
	buckets         [][]Process // 哈希桶,按 pid 索引历史快照
	target_pid      int
	include_children bool
	last_update     time.Time
	// 当前周期拉到的进程列表(便于迭代发送信号)
	current         []Process
}

// new_process_group 创建并初始化哈希桶。
fn new_process_group(target_pid int, include_children bool) ProcessGroup {
	mut buckets := [][]Process{len: pid_hash_sz, init: []Process{}}
	return ProcessGroup{
		buckets: buckets
		target_pid: target_pid
		include_children: include_children
	}
}

// add_or_update 把 iterator 拉到的进程合并进桶,并计算指数滑动平均 cpu_usage。
fn (mut pg ProcessGroup) add_or_update(now time.Time, snap Process) {
	h := pid_hashfn(snap.pid)
	if pg.buckets[h].len == 0 {
		mut copy := snap
		copy.cpu_usage = -1.0
		copy.prev_cpu = snap.cputime
		pg.buckets[h] = [copy]
		pg.current << copy
		return
	}
	mut found_idx := -1
	for i, existing in pg.buckets[h] {
		if existing.pid == snap.pid && existing.starttime == snap.starttime {
			found_idx = i
			break
		}
	}
	if found_idx < 0 {
		mut copy := snap
		copy.cpu_usage = -1.0
		copy.prev_cpu = snap.cputime
		pg.buckets[h] << copy
		pg.current << copy
		return
	}
	mut existing := &pg.buckets[h][found_idx]
	dt_ms := int(now.unix_milli() - pg.last_update.unix_milli())
	if dt_ms > 0 {
		sample := f64(snap.cputime - existing.prev_cpu) / f64(dt_ms)
		if existing.cpu_usage < 0 {
			existing.cpu_usage = sample
		} else {
			existing.cpu_usage = (1 - alfa) * existing.cpu_usage + alfa * sample
		}
	}
	existing.prev_cpu = snap.cputime
	pg.current << existing.clone()
}

// refresh 重新扫描进程并更新桶、计算 cpu_usage。
fn (mut pg ProcessGroup) refresh() ! {
	pg.current = []
	now := time.now()
	mut it := procinfo_open(Filter{
		target_pid: pg.target_pid
		include_children: pg.include_children
	})!
	defer { procinfo_close(mut it) }
	for {
		p := procinfo_next(mut it) or { break }
		pg.add_or_update(now, p)
	}
	if int(now.unix_milli() - pg.last_update.unix_milli()) >= min_dt_ms {
		pg.last_update = now
	}
}

// sum_cpu_usage 汇总当前周期内进程的实测 CPU 使用率。
fn (pg &ProcessGroup) sum_cpu_usage() f64 {
	mut total := -1.0
	for p in pg.current {
		if p.cpu_usage < 0 {
			continue
		}
		if total < 0 {
			total = 0
		}
		total += p.cpu_usage
	}
	return total
}

// remove 从哈希桶里删除进程(pid 已经被 kill 失败或已退出)。
fn (mut pg ProcessGroup) remove(pid int) {
	h := pid_hashfn(pid)
	mut i := 0
	for pg.buckets[h].len > 0 && i < pg.buckets[h].len {
		if pg.buckets[h][i].pid == pid {
			pg.buckets[h].delete(i)
			return
		}
		i++
	}
}
