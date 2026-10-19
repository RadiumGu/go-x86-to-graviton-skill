// Package cache is a realistic shape: a lazily-built lookup table published to
// readers through a plain bool flag. The build and the publish are not ordered
// by any synchronization primitive, so a reader can observe ready==true while
// table is still nil (nil map read is harmless) or, worse, while the slice
// header is visible but its backing array is not yet.
package cache

type Cache struct {
	ready bool
	table []int
}

func (c *Cache) Warm(n int) {
	t := make([]int, n)
	for i := range t {
		t[i] = i * i
	}
	c.table = t   // publish the slice
	c.ready = true // then the flag - no ordering between the two
}

// Lookup returns the cached value and whether the cache was warm.
func (c *Cache) Lookup(i int) (int, bool) {
	if !c.ready {
		return 0, false
	}
	t := c.table
	if i < len(t) {
		return t[i], true
	}
	return 0, true
}
