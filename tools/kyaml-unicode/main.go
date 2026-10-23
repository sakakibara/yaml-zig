// Generates src/kyaml_unicode.zig from the Go unicode tables the KYAML
// encoder uses (unicode.IsLetter, IsNumber, IsPrint, IsSpace).
package main

import (
	"fmt"
	"os"
	"unicode"
)

func main() {
	out := os.Stdout
	if len(os.Args) > 1 {
		f, err := os.Create(os.Args[1])
		if err != nil {
			panic(err)
		}
		defer f.Close()
		out = f
	}
	fmt.Fprint(out, `//! Unicode classes for KYAML key quoting and string escaping.
//! Generated from Go's unicode tables. Regenerate with:
//!
//!     go run tools/kyaml-unicode/main.go src/kyaml_unicode.zig

const Range = struct { lo: u21, hi: u21 };

fn inRanges(r: u21, ranges: []const Range) bool {
    var lo: usize = 0;
    var hi = ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const span = ranges[mid];
        if (r < span.lo) {
            hi = mid;
        } else if (r > span.hi) {
            lo = mid + 1;
        } else return true;
    }
    return false;
}

pub fn isLetter(r: u21) bool {
    return inRanges(r, &letters);
}

pub fn isNumber(r: u21) bool {
    return inRanges(r, &numbers);
}

pub fn isPrint(r: u21) bool {
    return inRanges(r, &print);
}

pub fn isSpace(r: u21) bool {
    return inRanges(r, &spaces);
}

`)
	write(out, "letters", unicode.IsLetter)
	write(out, "numbers", unicode.IsNumber)
	write(out, "print", unicode.IsPrint)
	write(out, "spaces", unicode.IsSpace)
}

func write(out *os.File, name string, pred func(rune) bool) {
	fmt.Fprintf(out, "const %s = [_]Range{\n", name)
	var lo rune = -1
	var prev rune
	flush := func(hi rune) {
		if lo < 0 {
			return
		}
		fmt.Fprintf(out, "    .{ .lo = 0x%X, .hi = 0x%X },\n", lo, hi)
		lo = -1
	}
	for r := rune(0); r <= unicode.MaxRune; r++ {
		if pred(r) {
			if lo < 0 {
				lo = r
			}
			prev = r
		} else if lo >= 0 {
			flush(prev)
		}
	}
	flush(prev)
	fmt.Fprint(out, "};\n\n")
}
