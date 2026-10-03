// Port of src/diff.hh: linear-space Myers O(ND) difference algorithm.
//
// Generic C++ iterators are specialized to builtin string (compared per
// byte, as the StringView UnitTests do); callbacks are plain proc values.
// Odin has no capturing closures, so the coalescing lambda of
// for_each_diff is an explicit Diff_Coalescer threaded through the
// recursion.
package kak

// Diff_Op mirrors Kakoune's DiffOp: the operation of one coalesced run.
Diff_Op :: enum {
	Keep,
	Add,
	Remove,
}

// Diff_Diff is one coalesced run: op repeated len times.
Diff_Diff :: struct {
	op:  Diff_Op,
	len: int,
}

// Diff_Snake_Op mirrors Kakoune's Snake::Op. Rev_Add/Rev_Del are edits
// found on the reverse path, applied after the diagonal.
Diff_Snake_Op :: enum {
	Add,
	Del,
	Rev_Add,
	Rev_Del,
}

// Diff_Snake is an edit followed by a (possibly empty) diagonal from
// (x, y) to (u, v).
Diff_Snake :: struct {
	x, y, u, v: int,
	op:         Diff_Snake_Op,
}

// Diff_Coalescer merges adjacent runs of the same op before forwarding
// them to outer, mirroring the last/on_diff lambda in for_each_diff.
Diff_Coalescer :: struct {
	last:  Diff_Diff,
	outer: proc(op: Diff_Op, len: int),
}

// diff_coalescer_emit feeds one run into the coalescer.
diff_coalescer_emit :: proc(c: ^Diff_Coalescer, op: Diff_Op, len: int) {
	if c.last.op == op {
		c.last.len += len
	} else {
		if c.last.len != 0 {
			c.outer(c.last.op, c.last.len)
		}
		c.last = Diff_Diff{op, len}
	}
}

// diff_end_snake ports find_end_snake_of_further_reaching_dpath: from the
// further-reaching of the two neighbor diagonals, take one edit step onto
// diagonal k, then follow the diagonal while bytes compare equal.
// v holds the furthest-reaching x per diagonal, indexed v[k + v_off].
// forward selects which end of a/b the walk starts from.
diff_end_snake :: proc(a, b: string, v: []int, v_off, d, k: int, forward: bool) -> Diff_Snake {
	n := len(a)
	m := len(b)

	add := k == -d || (k != d && v[k - 1 + v_off] < v[k + 1 + v_off])

	// By construction we sit on diagonal k, so y = x - k.
	x := v[k + 1 + v_off] if add else v[k - 1 + v_off] + 1
	y := x - k

	u, w := x, y
	for u < n && w < m {
		ca := a[u] if forward else a[n - 1 - u]
		cb := b[w] if forward else b[m - 1 - w]
		if ca != cb {
			break
		}
		u += 1
		w += 1
	}

	return Diff_Snake{x, y, u, w, .Add if add else .Del}
}

// diff_middle_snake ports find_middle_snake: bidirectional Myers search
// returning the middle snake of the shortest edit path, or the snake
// closest to (n, m) when the cost limit is exceeded. v1/v2 are scratch
// buffers shared with the recursion, indexed v[k + v_off].
diff_middle_snake :: proc(a, b: string, v1, v2: []int, v_off, cost_limit: int) -> Diff_Snake {
	n := len(a)
	m := len(b)
	delta := n - m
	v1[1 + v_off] = 0
	v2[1 + v_off] = 0

	max_d := min((m + n + 1) / 2 + 1, cost_limit)
	for d in 0 ..< max_d {
		for k1 := -d; k1 <= d; k1 += 2 {
			p := diff_end_snake(a, b, v1, v_off, d, k1, true)
			v1[k1 + v_off] = p.u

			k2 := -(k1 - delta)
			if delta % 2 != 0 && -(d - 1) <= k2 && k2 <= (d - 1) && v1[k1 + v_off] + v2[k2 + v_off] >= n {
				return p // last snake on forward path, len = 2 * d - 1
			}
		}

		for k2 := -d; k2 <= d; k2 += 2 {
			p := diff_end_snake(a, b, v2, v_off, d, k2, false)
			v2[k2 + v_off] = p.u

			k1 := -(k2 - delta)
			if delta % 2 == 0 && -d <= k1 && k1 <= d && v1[k1 + v_off] + v2[k2 + v_off] >= n {
				// last snake on reverse path, len = 2 * d
				op := Diff_Snake_Op.Rev_Add if p.op == .Add else .Rev_Del
				return Diff_Snake{n - p.u, m - p.v, n - p.x, m - p.y, op}
			}
		}
	}

	// No minimal path within max_d steps: one more pass keeping the snake
	// closest to (n, m).
	best := Diff_Snake{}
	for k1 := -max_d; k1 <= max_d; k1 += 2 {
		p := diff_end_snake(a, b, v1, v_off, max_d, k1, true)
		v1[k1 + v_off] = p.u
		if delta % 2 != 0 && p.u <= n && p.v <= m && p.u + p.v >= best.u + best.v {
			best = p
		}
	}
	for k2 := -max_d; k2 <= max_d; k2 += 2 {
		p := diff_end_snake(a, b, v2, v_off, max_d, k2, false)
		v2[k2 + v_off] = p.u
		if delta % 2 == 0 && p.u <= n && p.v <= m && p.u + p.v >= best.u + best.v {
			op := Diff_Snake_Op.Rev_Add if p.op == .Add else .Rev_Del
			best = Diff_Snake{p.x, p.y, p.u, p.v, op}
		}
	}

	if best.op == .Rev_Add || best.op == .Rev_Del {
		// Reverse the snake now, as we were comparing snake length.
		best = Diff_Snake{n - best.u, m - best.v, n - best.x, m - best.y, best.op}
	}
	return best
}

// diff_find_rec ports find_diff_rec: trim the common prefix/suffix, split
// at the middle snake, and report runs through the coalescer (never with
// len 0).
diff_find_rec :: proc(
	a: string,
	beg_a, end_a: int,
	b: string,
	beg_b, end_b: int,
	v1, v2: []int,
	v_off, cost_limit: int,
	coalescer: ^Diff_Coalescer,
) {
	lo_a, hi_a := beg_a, end_a
	lo_b, hi_b := beg_b, end_b

	prefix_len := 0
	for lo_a != hi_a && lo_b != hi_b && a[lo_a] == b[lo_b] {
		lo_a += 1
		lo_b += 1
		prefix_len += 1
	}

	suffix_len := 0
	for lo_a != hi_a && lo_b != hi_b && a[hi_a - 1] == b[hi_b - 1] {
		hi_a -= 1
		hi_b -= 1
		suffix_len += 1
	}

	if prefix_len != 0 {
		diff_coalescer_emit(coalescer, .Keep, prefix_len)
	}

	len_a := hi_a - lo_a
	len_b := hi_b - lo_b

	if len_a == 0 {
		if len_b != 0 {
			diff_coalescer_emit(coalescer, .Add, len_b)
		}
	} else if len_b == 0 {
		diff_coalescer_emit(coalescer, .Remove, len_a)
	} else {
		snake := diff_middle_snake(a[lo_a:hi_a], b[lo_b:hi_b], v1, v2, v_off, cost_limit)
		assert(snake.u <= len_a && snake.v <= len_b)

		del := 1 if snake.op == .Del else 0
		add := 1 if snake.op == .Add else 0
		diff_find_rec(
			a,
			lo_a,
			lo_a + snake.x - del,
			b,
			lo_b,
			lo_b + snake.y - add,
			v1,
			v2,
			v_off,
			cost_limit,
			coalescer,
		)

		if snake.op == .Add {
			diff_coalescer_emit(coalescer, .Add, 1)
		}
		if snake.op == .Del {
			diff_coalescer_emit(coalescer, .Remove, 1)
		}
		if snake.u - snake.x != 0 {
			diff_coalescer_emit(coalescer, .Keep, snake.u - snake.x)
		}
		if snake.op == .Rev_Add {
			diff_coalescer_emit(coalescer, .Add, 1)
		}
		if snake.op == .Rev_Del {
			diff_coalescer_emit(coalescer, .Remove, 1)
		}

		rev_del := 1 if snake.op == .Rev_Del else 0
		rev_add := 1 if snake.op == .Rev_Add else 0
		diff_find_rec(
			a,
			lo_a + snake.u + rev_del,
			hi_a,
			b,
			lo_b + snake.v + rev_add,
			hi_b,
			v1,
			v2,
			v_off,
			cost_limit,
			coalescer,
		)
	}

	if suffix_len != 0 {
		diff_coalescer_emit(coalescer, .Keep, suffix_len)
	}
}

// diff_for_each_diff ports for_each_diff: report the minimal (within the
// cost limit) edit script turning a into b, coalescing adjacent runs of
// the same op. The v scratch buffers are allocated with allocator and
// freed before return; on_diff is called synchronously.
diff_for_each_diff :: proc(a, b: string, on_diff: proc(op: Diff_Op, len: int), allocator := context.allocator) {
	// Cost limit mirrors the constexpr in diff.hh: bounds the Myers
	// D-steps before falling back to the closest snake.
	cost_limit := 1000

	// Diagonal k stays within +/-(max_d + 1), so centering v at
	// n + m + 1 (like &data[N+M] in diff.hh) keeps every access in bounds.
	v_off := len(a) + len(b) + 1
	v1 := make([]int, 2 * v_off + 1, allocator)
	defer delete(v1, allocator)
	v2 := make([]int, 2 * v_off + 1, allocator)
	defer delete(v2, allocator)

	coalescer := Diff_Coalescer{outer = on_diff}
	diff_find_rec(a, 0, len(a), b, 0, len(b), v1, v2, v_off, cost_limit, &coalescer)
	if coalescer.last.op != .Keep || coalescer.last.len != 0 {
		on_diff(coalescer.last.op, coalescer.last.len)
	}
}
