// A nested module. `go list ./...` from the parent module does not see it at all.
package main

import _ "example.com/layout/svc/simd"

func main() {}
