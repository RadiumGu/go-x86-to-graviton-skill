// Fixture: a single-module repo laid out the way real Go projects are, with every
// directory the go command does NOT build (testdata/, _scratch/, .cache/), a package
// whose Shape C only appears under the deployment's build tag, a nested module, and a
// Makefile that runs the race detector through gotestsum. See tests/run_tests.sh.
package main

import "example.com/layout/internal/fast"

func main() { _ = fast.F() }
