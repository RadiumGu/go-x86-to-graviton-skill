// Every file in this package is a cgo file. With CGO_ENABLED=0 the package emits
// "build constraints exclude all Go files" - verbatim the Shape C message - and the
// fix is Phase 2.1 (cgo), not Phase 2.2 (constraints). Measured on go1.27.2.
package purecgo

/*
#include <stdlib.h>
*/
import "C"

// Alloc exists only so the cgo import is load-bearing.
func Alloc() { C.free(C.malloc(1)) }
