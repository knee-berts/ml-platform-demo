package dispatcher

import (
	"context"
	"fmt"
	"time"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	"k8s.io/apimachinery/pkg/types"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log"

	kueuev1beta1 "sigs.k8s.io/kueue/apis/kueue/v1beta1"

	"github.com/kubecon-fleets-demo/least-disruption-dispatcher/pkg/inflight"
	"github.com/kubecon-fleets-demo/least-disruption-dispatcher/pkg/scorer"
)

const fieldManager = "kueue-admission"

// Reconciler watches Workloads on the management cluster and sets
// status.nominatedClusterNames to the cluster with the lowest eviction cost.
type Reconciler struct {
	// mgmtClient is the client for the management cluster
	mgmtClient client.Client

	// workerClients maps cluster name -> client for that worker cluster.
	// These clients read from local informer caches set up by controller-runtime.
	workerClients map[string]client.Reader

	// clusterPriorities maps cluster name -> priority from the
	// dispatcher.kueue.x-k8s.io/priority label on MultiKueueCluster.
	// Higher value = preferred when eviction scores are equal.
	clusterPriorities map[string]int32

	// inFlight tracks dispatches that haven't been confirmed yet
	inFlight *inflight.Cache

	// config holds scoring parameters
	config scorer.Config

	// clusterQueueName is the name of the ClusterQueue on worker clusters
	clusterQueueName string

	// Timing parameters (loaded from ConfigMap / env vars)
	nominationTimeout time.Duration
	inFlightTTL       time.Duration
	requeueDelay      time.Duration
	cleanupPeriod     time.Duration
}

// TimingConfig holds the tunable timing parameters for the dispatcher.
type TimingConfig struct {
	NominationTimeout time.Duration
	InFlightTTL       time.Duration
	RequeueDelay      time.Duration
	CleanupPeriod     time.Duration
}

// NewReconciler creates a new dispatcher reconciler.
func NewReconciler(
	mgmtClient client.Client,
	workerClients map[string]client.Reader,
	clusterPriorities map[string]int32,
	inFlightCache *inflight.Cache,
	cfg scorer.Config,
	clusterQueueName string,
	timing TimingConfig,
) *Reconciler {
	return &Reconciler{
		mgmtClient:        mgmtClient,
		workerClients:     workerClients,
		clusterPriorities: clusterPriorities,
		inFlight:          inFlightCache,
		config:            cfg,
		clusterQueueName:  clusterQueueName,
		nominationTimeout: timing.NominationTimeout,
		inFlightTTL:       timing.InFlightTTL,
		requeueDelay:      timing.RequeueDelay,
		cleanupPeriod:     timing.CleanupPeriod,
	}
}

// SetupWithManager registers the reconciler with the controller-runtime manager.
func (r *Reconciler) SetupWithManager(mgr ctrl.Manager) error {
	// Start background in-flight cache cleanup
	go func() {
		ticker := time.NewTicker(r.cleanupPeriod)
		defer ticker.Stop()
		for range ticker.C {
			r.inFlight.Cleanup(r.inFlightTTL)
		}
	}()

	return ctrl.NewControllerManagedBy(mgr).
		For(&kueuev1beta1.Workload{}).
		Complete(r)
}

// Reconcile is the main reconciliation loop. It is called for every Workload
// event on the management cluster.
func (r *Reconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	logger := log.FromContext(ctx).WithValues("workload", req.NamespacedName)

	var wl kueuev1beta1.Workload
	if err := r.mgmtClient.Get(ctx, req.NamespacedName, &wl); err != nil {
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}

	// If clusterName is set, the workload is fully dispatched — clear in-flight
	if wl.Status.ClusterName != nil && *wl.Status.ClusterName != "" {
		if r.inFlight.Has(wl.UID) {
			logger.V(1).Info("workload dispatched, clearing in-flight",
				"cluster", *wl.Status.ClusterName)
			r.inFlight.Remove(wl.UID)
		}
		return ctrl.Result{}, nil
	}

	// Only act on workloads that have quota reserved but no nomination yet
	if wl.Status.Admission == nil {
		return ctrl.Result{}, nil // not yet admitted
	}
	if len(wl.Status.NominatedClusterNames) > 0 {
		// Check if the nomination is stale — Kueue should set clusterName
		// within a reasonable window. If not, clear the nomination so we
		// can re-score and potentially pick a different cluster.
		nominated := wl.Status.NominatedClusterNames[0]
		age := time.Since(wl.CreationTimestamp.Time)
		var lastTransition time.Time
		for _, c := range wl.Status.Conditions {
			if c.LastTransitionTime.After(lastTransition) {
				lastTransition = c.LastTransitionTime.Time
			}
		}
		sinceLastChange := time.Since(lastTransition)

		if sinceLastChange < r.nominationTimeout && age < r.nominationTimeout {
			return ctrl.Result{RequeueAfter: r.requeueDelay}, nil // give Kueue time to fulfill
		}

		// Nomination is stale — clear it so we can re-score
		logger.Info("clearing stale nomination",
			"nominated", nominated,
			"age", age.Round(time.Second),
			"sinceLastChange", sinceLastChange.Round(time.Second))

		patch := client.MergeFrom(wl.DeepCopy())
		wl.Status.NominatedClusterNames = nil
		if err := r.mgmtClient.Status().Patch(ctx, &wl, patch, client.FieldOwner(fieldManager)); err != nil {
			logger.Error(err, "failed to clear stale nomination")
			return ctrl.Result{}, err
		}
		r.inFlight.Remove(wl.UID)
		// Requeue rather than immediately re-scoring — this lets the
		// in-flight cache drain so the next cycle sees accurate free GPUs.
		return ctrl.Result{RequeueAfter: r.requeueDelay}, nil
	}
	if r.inFlight.Has(wl.UID) {
		return ctrl.Result{}, nil // we already dispatched this, waiting for confirmation
	}

	// Extract GPU request
	gpuRequest := extractGPURequest(&wl, r.config.ResourceName)
	if gpuRequest <= 0 {
		logger.V(1).Info("workload has no GPU request, skipping")
		return ctrl.Result{}, nil
	}

	priority := wl.Spec.Priority
	if priority == nil {
		zero := int32(0)
		priority = &zero
	}

	logger.Info("scoring clusters for workload",
		"gpus", gpuRequest, "priority", *priority)

	// Score each worker cluster
	var results []scorer.Result
	for clusterName, clusterClient := range r.workerClients {
		state, err := r.buildClusterState(ctx, clusterName, clusterClient)
		if err != nil {
			logger.Error(err, "failed to read cluster state", "cluster", clusterName)
			continue
		}

		result := scorer.ScoreCluster(state, gpuRequest, *priority, r.config)
		results = append(results, result)

		inFlightGPUs := int32(0)
		for _, e := range state.InFlight {
			inFlightGPUs += e.GPUs
		}

		logger.Info("cluster scored",
			"cluster", clusterName,
			"clusterPriority", state.ClusterPriority,
			"score", result.Score,
			"feasible", result.Feasible,
			"quotaTotal", state.NominalQuota,
			"quotaUsed", state.UsedGPUs,
			"inFlightGPUs", inFlightGPUs,
			"freeGPUs", result.FreeGPUs,
			"admittedWorkloads", len(state.Workloads))
	}

	// Select the best cluster
	best, reason := scorer.SelectBest(results)
	if best == "" {
		logger.Info("no feasible cluster found, requeueing",
			"clusterCount", len(results))
		return ctrl.Result{RequeueAfter: r.requeueDelay}, nil
	}

	logger.Info("nominating cluster",
		"cluster", best,
		"reason", reason,
		"workload", wl.Name)

	// Set status.nominatedClusterNames
	patch := client.MergeFrom(wl.DeepCopy())
	wl.Status.NominatedClusterNames = []string{best}
	if err := r.mgmtClient.Status().Patch(ctx, &wl, patch, client.FieldOwner(fieldManager)); err != nil {
		logger.Error(err, "failed to patch nominatedClusterNames")
		return ctrl.Result{}, err
	}

	// Record in-flight
	r.inFlight.Record(wl.UID, best, gpuRequest, *priority)

	return ctrl.Result{}, nil
}

// buildClusterState reads ClusterQueue and Workload state from the worker
// cluster's local informer cache.
func (r *Reconciler) buildClusterState(
	ctx context.Context,
	clusterName string,
	clusterClient client.Reader,
) (scorer.ClusterState, error) {
	state := scorer.ClusterState{
		ClusterName:     clusterName,
		ClusterPriority: r.clusterPriorities[clusterName],
		InFlight:        r.inFlight.ForCluster(clusterName),
	}

	// Read ClusterQueue
	var cq kueuev1beta1.ClusterQueue
	if err := clusterClient.Get(ctx, types.NamespacedName{Name: r.clusterQueueName}, &cq); err != nil {
		return state, fmt.Errorf("get ClusterQueue %s: %w", r.clusterQueueName, err)
	}

	// Extract quota and usage for our flavor/resource
	for _, rg := range cq.Spec.ResourceGroups {
		for _, f := range rg.Flavors {
			if f.Name != kueuev1beta1.ResourceFlavorReference(r.config.FlavorName) {
				continue
			}
			for _, res := range f.Resources {
				if string(res.Name) == r.config.ResourceName {
					state.NominalQuota = int32(res.NominalQuota.Value())
				}
			}
		}
	}

	// Extract usage from status
	for _, fu := range cq.Status.FlavorsUsage {
		if string(fu.Name) == r.config.FlavorName {
			for _, res := range fu.Resources {
				if string(res.Name) == r.config.ResourceName {
					state.UsedGPUs = int32(res.Total.Value())
				}
			}
		}
	}

	// List admitted workloads on this cluster
	var workloads kueuev1beta1.WorkloadList
	if err := clusterClient.List(ctx, &workloads); err != nil {
		return state, fmt.Errorf("list Workloads: %w", err)
	}

	for _, wl := range workloads.Items {
		if wl.Status.Admission == nil {
			continue // not admitted
		}

		gpus := extractGPURequest(&wl, r.config.ResourceName)
		if gpus <= 0 {
			continue // no GPU request in our resource
		}

		priority := int32(0)
		if wl.Spec.Priority != nil {
			priority = *wl.Spec.Priority
		}

		// Check if workload has running pods (by checking conditions)
		running := isWorkloadRunning(&wl)

		state.Workloads = append(state.Workloads, scorer.WorkloadInfo{
			Name:     wl.Name,
			Priority: priority,
			GPUs:     gpus,
			Running:  running,
		})
	}

	return state, nil
}

// extractGPURequest sums the GPU requests across all podSets in a workload.
func extractGPURequest(wl *kueuev1beta1.Workload, resourceName string) int32 {
	var total int32
	resName := corev1.ResourceName(resourceName)

	for _, ps := range wl.Spec.PodSets {
		count := int32(1)
		if ps.Count > 0 {
			count = ps.Count
		}

		for _, c := range ps.Template.Spec.Containers {
			if q, ok := c.Resources.Requests[resName]; ok {
				total += count * int32(q.Value())
			}
		}

		// Also check resource claims for DRA (future-proofing)
		// For now, DRA workloads won't have nvidia.com/gpu in requests,
		// but when deviceClassMappings is configured, Kueue maps claims
		// back to the logical resource. The workload's podSets will
		// reflect the mapped resource count.
	}

	return total
}

// isWorkloadRunning checks if the workload's pods are in Running state.
// We use the "Started" condition as a heuristic.
func isWorkloadRunning(wl *kueuev1beta1.Workload) bool {
	for _, c := range wl.Status.Conditions {
		if c.Type == "Started" && c.Status == "True" {
			return true
		}
	}
	// Fallback: if admitted and no "Started" condition, assume pending
	return false
}

// extractGPUQuantity is a helper to get an int32 from a resource.Quantity.
func extractGPUQuantity(q resource.Quantity) int32 {
	return int32(q.Value())
}
