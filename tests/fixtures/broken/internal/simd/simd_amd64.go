//go:build amd64

package simd

// Shape C: no arm64 and no generic sibling.
func Sum(xs []float64) float64 { return 0 }
