// Hashing primitives ported from src/hash.hh and src/hash.cc.
//
// hash_murmur3 must produce bit-identical output to the C++ murmur3;
// its goldens in hash_test.odin come from compiling the real src/hash.cc.
//
// The C++ Hash functor and HashCompatible traits have no equivalent here:
// callers use builtin map[K]V (see odin/CONVENTIONS.md).
package kak

import "base:intrinsics"

// hash_rotl rotates the 32-bit value x left by r bits.
@(private = "file")
hash_rotl :: proc(x: u32, r: uint) -> u32 {
	return (x << r) | (x >> (32 - r))
}

// hash_fmix is the MurmurHash3 finalizer: avalanches all input bits.
@(private = "file")
hash_fmix :: proc(h: u32) -> u32 {
	h := h
	h ~= h >> 16
	h *= 0x85ebca6b
	h ~= h >> 13
	h *= 0xc2b2ae35
	h ~= h >> 16
	return h
}

// hash_fnv1a hashes data with FNV-1a (32-bit, returned widened to uint).
//
// Faithful quirk: the C++ xors each signed char into the state, so bytes
// >= 0x80 are sign-extended to 32 bits before the xor. Byte-identical input
// therefore hashes identically to the C++ version, including non-ASCII data.
hash_fnv1a :: proc(data: string) -> uint {
	fnv_prime: u32 = 16777619
	offset_basis: u32 = 2166136261

	hash: u32 = offset_basis
	for i := 0; i < len(data); i += 1 {
		hash = (hash ~ u32(i8(data[i]))) * fnv_prime
	}
	return uint(hash)
}

// hash_murmur3 hashes data with a seeded 32-bit MurmurHash3 variant
// (seed 0x1235678, little-endian block loads), returned widened to uint.
hash_murmur3 :: proc(input: string) -> uint {
	c1: u32 = 0xcc9e2d51
	c2: u32 = 0x1b873593

	hash: u32 = 0x1235678
	nblocks := len(input) / 4

	for i := 0; i < nblocks; i += 1 {
		key := u32(input[4 * i + 3]) << 24 |
			u32(input[4 * i + 2]) << 16 |
			u32(input[4 * i + 1]) << 8 |
			u32(input[4 * i])
		key *= c1
		key = hash_rotl(key, 15)
		key *= c2

		hash ~= key
		hash = hash_rotl(hash, 13)
		hash = hash * 5 + 0xe6546b64
	}

	tail := nblocks * 4
	key: u32 = 0
	switch len(input) & 3 {
	case 3:
		key ~= u32(input[tail + 2]) << 16
		fallthrough
	case 2:
		key ~= u32(input[tail + 1]) << 8
		fallthrough
	case 1:
		key ~= u32(input[tail + 0])
		key *= c1
		key = hash_rotl(key, 15)
		key *= c2
		hash ~= key
	case 0:
	// no tail bytes
	}

	hash ~= u32(len(input))
	hash = hash_fmix(hash)

	return uint(hash)
}

// hash_combine mixes rhs into the lhs seed (boost::hash_combine formula).
// Arithmetic is full-width uint, matching the C++ size_t behavior.
hash_combine :: proc(lhs, rhs: uint) -> uint {
	return lhs ~ (rhs + 0x9e3779b9 + (lhs << 6) + (lhs >> 2))
}

// hash_value_int hashes an integer by widening, like C++ hash_value:
// out-of-range values wrap modulo 2^64 (64-bit uint).
hash_value_int :: proc(val: $T) -> uint where intrinsics.type_is_integer(T) {
	return uint(val)
}

// hash_value_enum hashes an enum through its underlying value.
// Values must fit in int, which holds for every Kakoune enum ported so far.
hash_value_enum :: proc(val: $T) -> uint where intrinsics.type_is_enum(T) {
	return uint(int(val))
}

// hash_value hashes a single integer or enum value.
hash_value :: proc {
	hash_value_int,
	hash_value_enum,
}

// hash_values folds pre-hashed values right-to-left exactly like the C++
// variadic hash_values: hash_values(a, b, c) == combine(combine(c, b), a).
// Callers hash each element first, e.g. hash_values(hash_value(a), hash_value(b)).
hash_values :: proc(first: uint, rest: ..uint) -> uint {
	if len(rest) == 0 {
		return first
	}
	seed := rest[len(rest) - 1]
	for i := len(rest) - 2; i >= 0; i -= 1 {
		seed = hash_combine(seed, rest[i])
	}
	return hash_combine(seed, first)
}
