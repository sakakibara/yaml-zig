// Writes tests/kyaml/*.kyaml and *.compact.kyaml by running
// sigs.k8s.io/yaml/kyaml v1.6.0 on the *.yaml inputs. Run from the repo root:
//
//	go run tools/kyaml-golden/main.go
//
// specials.yaml's nan and inf keys stay plain in this library. After a
// regenerate, unquote those two keys in both specials output files.
package main

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"sigs.k8s.io/yaml/kyaml"
)

func main() {
	dir := "tests/kyaml"
	if len(os.Args) > 1 {
		dir = os.Args[1]
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		fatal(err)
	}
	for _, e := range entries {
		name := e.Name()
		if !strings.HasSuffix(name, ".yaml") {
			continue
		}
		in, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil {
			fatal(err)
		}
		base := strings.TrimSuffix(name, ".yaml")
		if err := write(dir, base+".kyaml", in, false); err != nil {
			fatal(fmt.Errorf("%s: %w", name, err))
		}
		if err := write(dir, base+".compact.kyaml", in, true); err != nil {
			fatal(fmt.Errorf("%s compact: %w", name, err))
		}
	}
}

func write(dir, name string, in []byte, compact bool) error {
	var buf bytes.Buffer
	enc := kyaml.Encoder{Compact: compact}
	if err := enc.FromYAML(bytes.NewReader(in), &buf); err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(dir, name), buf.Bytes(), 0o644)
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, err)
	os.Exit(1)
}
