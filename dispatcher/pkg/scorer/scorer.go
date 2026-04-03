package scorer

import (
	"fmt"
	"math"
	"sort"

	"github.com/kubecon-fleets-demo/least-disruption-dispatcher/pkg/inflight"
)

// ClusterPriorityLabel is the label on MultiKueueCluster resources that
// sets the cluster's scheduling priority. Higher value = preferred when
// eviction scores are equal.
const ClusterPriorityLabel = "dispatcher.kueue.x-k8s.io/priority"

// ClusterState represents the GPU capacity and workload state of a single
// worker cluster, read from the informer cache.
type ClusterState struct {
	ClusterName      string
	ClusterPriority  int32 // from label; higher = preferred as tiebreaker
	NominalQuota     int32 // total GPUs in the ClusterQueue flavor
	UsedGPUs         int32 // currently used GPUs (from ClusterQueue status)
	Workloads        []WorkloadInfo
	InFlight         []inflight.Entry // in-flight dispatches targeting this cluster
}

// WorkloadInfo represents an admitted workload on a worker cluster.
type WorkloadInfo struct {
	Name     string
	Priority int32
	GPUs     int32
	Running  bool // true if pods are Running, false if still Pending
}

// Config holds the scoring configuration loaded from a ConfigMap.
type Config struct {
	PriorityWeights map[string]int // priority class name -> weight
	ResourceName    string         // e.g. "nvidia.com/gpu"
	FlavorName      string         // e.g. "rtx-pro-6000"
}

// Result holds the scoring output for a single cluster.
type Result struct {
	ClusterName     string
	ClusterPriority int32 // from label; higher = preferred as tiebreaker
	Score           int64
	FreeGPUs        int32 // free GPUs after accounting for in-flight
	Feasible        bool  // whether the workload can fit at all
}

// ScoreCluster calculates the eviction cost of placing a workload on the
// given cluster. Lower score = less disruption. Returns math.MaxInt64 if
// the workload cannot fit even after all possible evictions.
func ScoreCluster(state ClusterState, gpuRequest int32, incomingPriority int32, cfg Config) Result {
	// Account for in-flight dispatches
	inFlightGPUs := int32(0)
	for _, e := range state.InFlight {
		inFlightGPUs += e.GPUs
	}

	freeGPUs := state.NominalQuota - state.UsedGPUs - inFlightGPUs
	if freeGPUs < 0 {
		freeGPUs = 0
	}

	needed := gpuRequest - freeGPUs

	// No eviction needed — best possible outcome
	if needed <= 0 {
		return Result{
			ClusterName:     state.ClusterName,
			ClusterPriority: state.ClusterPriority,
			Score:           0,
			FreeGPUs:        freeGPUs,
			Feasible:        true,
		}
	}

	// Sort workloads by priority ascending (cheapest to evict first)
	sorted := make([]WorkloadInfo, len(state.Workloads))
	copy(sorted, state.Workloads)
	sort.Slice(sorted, func(i, j int) bool {
		return sorted[i].Priority < sorted[j].Priority
	})

	var score int64
	freed := int32(0)

	for _, wl := range sorted {
		if wl.Priority >= incomingPriority {
			break // can't preempt same or higher priority
		}

		weight := priorityWeight(wl.Priority, cfg)

		// Running workloads are more expensive to preempt than pending
		multiplier := 1.0
		if wl.Running {
			multiplier = 2.0
		}

		score += int64(float64(int64(wl.GPUs)*int64(weight)) * multiplier)
		freed += wl.GPUs

		if freed >= needed {
			return Result{
				ClusterName:     state.ClusterName,
				ClusterPriority: state.ClusterPriority,
				Score:           score,
				FreeGPUs:        freeGPUs,
				Feasible:        true,
			}
		}
	}

	// Can't fit even after all possible evictions
	return Result{
		ClusterName:     state.ClusterName,
		ClusterPriority: state.ClusterPriority,
		Score:           math.MaxInt64,
		FreeGPUs:        freeGPUs,
		Feasible:        false,
	}
}

// SelectBest picks the cluster with the lowest eviction cost.
// Tiebreaker order:
//  1. Lowest eviction score
//  2. Highest cluster priority (from dispatcher.kueue.x-k8s.io/priority label)
//  3. Most free GPUs
//
// Returns the cluster name and a human-readable reason for the decision.
// Returns empty string if no cluster is feasible.
func SelectBest(results []Result) (string, string) {
	feasibleCount := 0
	var best *Result
	for i := range results {
		r := &results[i]
		if !r.Feasible {
			continue
		}
		feasibleCount++
		if best == nil {
			best = r
			continue
		}
		if r.Score < best.Score {
			best = r
		} else if r.Score == best.Score {
			if r.ClusterPriority > best.ClusterPriority {
				best = r
			} else if r.ClusterPriority == best.ClusterPriority && r.FreeGPUs > best.FreeGPUs {
				best = r
			}
		}
	}
	if best == nil {
		return "", "no feasible cluster"
	}

	// Determine the reason
	if feasibleCount == 1 {
		return best.ClusterName, "only feasible cluster"
	}
	// Check what decided it among feasible clusters
	for i := range results {
		r := &results[i]
		if !r.Feasible || r.ClusterName == best.ClusterName {
			continue
		}
		if best.Score < r.Score {
			return best.ClusterName, fmt.Sprintf("lowest eviction score (%d vs %d)", best.Score, r.Score)
		}
		if best.Score == r.Score && best.ClusterPriority > r.ClusterPriority {
			return best.ClusterName, fmt.Sprintf("higher cluster priority (%d vs %d), scores tied at %d", best.ClusterPriority, r.ClusterPriority, best.Score)
		}
		if best.Score == r.Score && best.ClusterPriority == r.ClusterPriority && best.FreeGPUs > r.FreeGPUs {
			return best.ClusterName, fmt.Sprintf("more free GPUs (%d vs %d), scores and priorities tied", best.FreeGPUs, r.FreeGPUs)
		}
	}
	return best.ClusterName, "first feasible (all tied)"
}

func priorityWeight(priority int32, cfg Config) int {
	// Walk config to find matching weight by priority value.
	// The config maps priority class names to weights, but we receive
	// the numeric priority value. For simplicity, use value ranges.
	// In production, you'd resolve the WorkloadPriorityClass name.
	if priority <= 100 {
		return lookupWeight("training-low", cfg, 1)
	}
	if priority <= 1000 {
		return lookupWeight("inference-high", cfg, 10)
	}
	return lookupWeight("training-critical", cfg, 1000)
}

func lookupWeight(name string, cfg Config, fallback int) int {
	if w, ok := cfg.PriorityWeights[name]; ok {
		return w
	}
	return fallback
}
