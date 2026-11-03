//go:build prod

// The release build sets -tags prod. Under that tag this file (amd64 by its name) is
// the only implementation, so the package is Shape C on arm64 - but only under the tag.
package fast

func F() int { return 1 }
