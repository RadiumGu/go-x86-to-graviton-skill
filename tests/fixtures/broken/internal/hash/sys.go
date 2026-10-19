package hash

import "syscall"

const pageSize = 4096

func f() { _ = syscall.SYS_READ; _ = pageSize }
