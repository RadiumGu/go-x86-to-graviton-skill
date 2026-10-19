//go:build !amd64

package compress

// A stub, not an implementation: the pattern that passes the build and
// returns wrong answers on Graviton.
func Z() { panic("unsupported architecture") }
