// Tests for the hashing primitives ported from src/hash.cc.
//
// The first three procs port test_murmur_hash 1:1. All golden values were
// produced by compiling and running the real src/hash.cc (see task report),
// whose own anchors (0xf816f95b, 3551113186, 2572747774) matched first.
package kak

import "core:testing"

// ported: murmur3("Hello, World!") == 0xf816f95b
@(test)
hash_test_murmur_hello_world :: proc(t: ^testing.T) {
	testing.expect_value(t, hash_murmur3("Hello, World!"), uint(0xf816f95b))
}

// ported: murmur3(28 x's) == 3551113186
@(test)
hash_test_murmur_xes :: proc(t: ^testing.T) {
	input := "xxxxxxxxxxxxxxxxxxxxxxxxxxxx"
	testing.expect_value(t, len(input), 28)
	testing.expect_value(t, hash_murmur3(input), uint(3551113186))
}

// ported: murmur3("", 0) == 2572747774
@(test)
hash_test_murmur_empty :: proc(t: ^testing.T) {
	testing.expect_value(t, hash_murmur3(""), uint(2572747774))
}

// tail-word sweep: len&3 covers 1, 2, 3, 0(block-aligned), 1, 0
@(test)
hash_test_murmur_tail_lengths :: proc(t: ^testing.T) {
	testing.expect_value(t, hash_murmur3("a"), uint(19364162))
	testing.expect_value(t, hash_murmur3("ab"), uint(4103593485))
	testing.expect_value(t, hash_murmur3("abc"), uint(3916666175))
	testing.expect_value(t, hash_murmur3("abcd"), uint(2751631130))
	testing.expect_value(t, hash_murmur3("abcde"), uint(3155786720))
	testing.expect_value(t, hash_murmur3("abcdefgh"), uint(3636383867))
}

// high-bit bytes must hash as unsigned (no sign extension in murmur3)
@(test)
hash_test_murmur_binary :: proc(t: ^testing.T) {
	testing.expect_value(t, hash_murmur3("\x00\xff\x80\x01\xfeA\x7f"), uint(2097130635))
	testing.expect_value(t, hash_murmur3("\xff\xfe\xfd\xfc\xfb"), uint(864960512))
}

// multi-block input: 64 bytes of cycling 'A'..'Z'
@(test)
hash_test_murmur_long :: proc(t: ^testing.T) {
	buf: [64]byte
	for i in 0 ..< 64 {
		buf[i] = u8(65 + (i % 26))
	}
	testing.expect_value(t, hash_murmur3(string(buf[:])), uint(381236982))
}

// fnv1a goldens, including the signed-char path on high-bit bytes
@(test)
hash_test_fnv1a :: proc(t: ^testing.T) {
	testing.expect_value(t, hash_fnv1a(""), uint(2166136261))
	testing.expect_value(t, hash_fnv1a("a"), uint(3826002220))
	testing.expect_value(t, hash_fnv1a("Hello, World!"), uint(1525479220))
	testing.expect_value(t, hash_fnv1a("\x00\xff\x80\x01\xfeA\x7f"), uint(1824609671))
	testing.expect_value(t, hash_fnv1a("\xff\xfe\xfd\xfc\xfb"), uint(971460542))
}

@(test)
hash_test_combine :: proc(t: ^testing.T) {
	testing.expect_value(t, hash_combine(0, 0), uint(2654435769))
	testing.expect_value(t, hash_combine(1, 2), uint(2654435834))
	testing.expect_value(t, hash_combine(0xf816f95b, 28), uint(266722965424))
}

@(test)
hash_test_values :: proc(t: ^testing.T) {
	testing.expect_value(t, hash_values(42), uint(42))
	testing.expect_value(t, hash_values(1, 2, 3), uint(175247756320))
	// order matters: pairs fold as combine(second, first)
	testing.expect_value(t, hash_values(7, 9), hash_combine(9, 7))
	testing.expect(t, hash_values(7, 9) != hash_values(9, 7))
}

hash_Test_Code :: enum {
	Ok    = 0,
	Retry = 7,
	Fail  = -5,
}

@(test)
hash_test_value_int_and_enum :: proc(t: ^testing.T) {
	testing.expect_value(t, hash_value(0), uint(0))
	testing.expect_value(t, hash_value(12345), uint(12345))
	testing.expect_value(t, hash_value(u32(0xdeadbeef)), uint(0xdeadbeef))
	// negative values wrap modulo 2^64, like the C++ (size_t) cast
	testing.expect_value(t, hash_value(i64(-1)), max(uint))
	testing.expect_value(t, hash_value(-5), max(uint) - 4)
	testing.expect_value(t, hash_value(hash_Test_Code.Ok), uint(0))
	testing.expect_value(t, hash_value(hash_Test_Code.Retry), uint(7))
	testing.expect_value(t, hash_value(hash_Test_Code.Fail), max(uint) - 4)
}
