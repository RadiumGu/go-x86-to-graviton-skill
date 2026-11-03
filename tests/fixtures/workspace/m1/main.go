// Fixture: a go.work root with no go.mod of its own. `go list ./...` at the root fails
// with "directory prefix . does not contain modules listed in go.work".
package main

import _ "example.com/m1/simd"

func main() {}
