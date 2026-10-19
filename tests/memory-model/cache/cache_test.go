package cache

import (
	"sync"
	"testing"
)

// TestConcurrentWarm is the shape `go test -race` exists to catch: one goroutine
// warms the cache while others read it, with no synchronization anywhere.
func TestConcurrentWarm(t *testing.T) {
	for round := 0; round < 200; round++ {
		c := &Cache{}
		var wg sync.WaitGroup
		wg.Add(5)
		go func() { defer wg.Done(); c.Warm(4096) }()
		for r := 0; r < 4; r++ {
			go func() {
				defer wg.Done()
				for i := 0; i < 4096; i++ {
					if v, ok := c.Lookup(i); ok && v != i*i {
						t.Errorf("stale value at %d: got %d want %d", i, v, i*i)
						return
					}
				}
			}()
		}
		wg.Wait()
	}
}
