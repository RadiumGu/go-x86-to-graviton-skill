// Memory-ordering litmus test: message passing (MP) without synchronization.
//
// Writer:  store(&sh.data, i); store(&sh.flg, i)   -- in that program order
// Reader:  f := load(&sh.flg); d := load(&sh.data) -- in that program order
//
// f > d means the reader observed the flag AHEAD of the data, which requires
// store-store reordering in the writer or load-load reordering in the reader.
// x86-64 is Total Store Order and permits NEITHER. AArch64 permits BOTH.
//
// Two design points, both learned the hard way:
//   - the two variables MUST sit on different cache lines. Adjacent int64 globals
//     share a line, and cache coherence then orders the two stores for free: a
//     first version with `var data, flg int64` measured 0 violations in 1.9e8
//     samples on a c7g.2xlarge purely because of this.
//   - the accesses go through //go:noinline helpers. Go's compiler may assume the
//     program is race-free and keep a global in a register across the loop, so
//     without the call there is nothing left to reorder.
package main

import (
	"flag"
	"fmt"
	"runtime"
	"sync/atomic"
)

const lineSep = 256 // > any plausible cache line, Graviton included

type shared struct {
	data int64
	_    [lineSep - 8]byte
	flg  int64
	_    [lineSep - 8]byte
}

var sh = new(shared)
var stop int32

//go:noinline
func store(p *int64, v int64) { *p = v }

//go:noinline
func load(p *int64) int64 { return *p }

func main() {
	iters := flag.Int64("iters", 300_000_000, "writer iterations")
	flag.Parse()
	runtime.GOMAXPROCS(runtime.NumCPU())

	fmt.Printf("addr(data)=%p addr(flg)=%p delta=%d bytes\n",
		&sh.data, &sh.flg, uintptr(unsafe_offset()))

	var violations, samples uint64
	done := make(chan struct{})
	readerDone := make(chan struct{})

	go func() {
		for i := int64(1); i <= *iters; i++ {
			store(&sh.data, i)
			store(&sh.flg, i)
		}
		atomic.StoreInt32(&stop, 1)
		close(done)
	}()

	go func() {
		defer close(readerDone)
		for {
			f := load(&sh.flg)
			d := load(&sh.data)
			samples++
			if f > d {
				violations++
			}
			if samples&0xFFFF == 0 && atomic.LoadInt32(&stop) == 1 {
				return
			}
		}
	}()

	<-done
	<-readerDone

	fmt.Printf("GOARCH=%s NumCPU=%d GoVer=%s\n", runtime.GOARCH, runtime.NumCPU(), runtime.Version())
	fmt.Printf("samples=%d  flag-ahead-of-data=%d  rate=%.3e\n",
		samples, violations, float64(violations)/float64(samples))
	if violations > 0 {
		fmt.Println("RESULT: reordering OBSERVED")
	} else {
		fmt.Println("RESULT: no reordering observed in this run")
	}
}

//go:noinline
func unsafe_offset() int { return int(uintptr(lineSep)) }
