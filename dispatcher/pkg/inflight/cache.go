package inflight

import (
	"sync"
	"time"

	"k8s.io/apimachinery/pkg/types"
)

// Entry represents an in-flight dispatch decision that hasn't been
// confirmed by Kueue yet (status.clusterName not set).
type Entry struct {
	ClusterName  string
	GPUs         int32
	Priority     int32
	DispatchedAt time.Time
}

// Cache tracks in-flight workload dispatches to prevent the thundering
// herd problem where multiple workloads are scored against stale cluster
// state and all get sent to the same cluster.
type Cache struct {
	mu      sync.RWMutex
	entries map[types.UID]*Entry
}

// New creates a new in-flight cache.
func New() *Cache {
	return &Cache{
		entries: make(map[types.UID]*Entry),
	}
}

// Record adds an in-flight dispatch entry.
func (c *Cache) Record(uid types.UID, clusterName string, gpus, priority int32) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.entries[uid] = &Entry{
		ClusterName:  clusterName,
		GPUs:         gpus,
		Priority:     priority,
		DispatchedAt: time.Now(),
	}
}

// Remove clears an entry when the workload is fully dispatched
// (status.clusterName is set).
func (c *Cache) Remove(uid types.UID) {
	c.mu.Lock()
	defer c.mu.Unlock()
	delete(c.entries, uid)
}

// Has returns true if a workload UID is already tracked as in-flight.
func (c *Cache) Has(uid types.UID) bool {
	c.mu.RLock()
	defer c.mu.RUnlock()
	_, ok := c.entries[uid]
	return ok
}

// ForCluster returns all in-flight entries targeting the given cluster.
func (c *Cache) ForCluster(clusterName string) []Entry {
	c.mu.RLock()
	defer c.mu.RUnlock()
	var result []Entry
	for _, e := range c.entries {
		if e.ClusterName == clusterName {
			result = append(result, *e)
		}
	}
	return result
}

// Cleanup removes entries older than the given TTL.
func (c *Cache) Cleanup(ttl time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	cutoff := time.Now().Add(-ttl)
	for uid, e := range c.entries {
		if e.DispatchedAt.Before(cutoff) {
			delete(c.entries, uid)
		}
	}
}
