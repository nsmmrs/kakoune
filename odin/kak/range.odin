// Port of Kakoune's src/range.hh (the Range<T> half-open interval).
//
// Equality is the builtin == on structs. Hashing reuses the hash
// module: callers hash the endpoints first, exactly like the existing
// hash_values convention (see hash.odin).
package kak

// Range is a half-open [begin, end) interval over T (port of C++ Range<T>).
Range :: struct(T: typeid) {
	begin: T,
	end:   T,
}

// range_empty reports whether the interval is empty (begin == end).
range_empty :: proc(r: Range($T)) -> bool {
	return r.begin == r.end
}

// range_hash combines pre-hashed endpoints: the C++
// hash_values(begin, end) folds to combine(hash(end), hash(begin)).
range_hash :: proc(begin_hash, end_hash: uint) -> uint {
	return hash_values(begin_hash, end_hash)
}
