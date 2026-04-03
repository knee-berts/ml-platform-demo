package main

import (
	"context"
	"os"

	"k8s.io/apimachinery/pkg/runtime"
	utilruntime "k8s.io/apimachinery/pkg/util/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/healthz"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"

	kueuev1beta1 "sigs.k8s.io/kueue/apis/kueue/v1beta1"

	"github.com/kubecon-fleets-demo/least-disruption-dispatcher/pkg/cluster"
	"github.com/kubecon-fleets-demo/least-disruption-dispatcher/pkg/config"
	"github.com/kubecon-fleets-demo/least-disruption-dispatcher/pkg/dispatcher"
	"github.com/kubecon-fleets-demo/least-disruption-dispatcher/pkg/inflight"
)

var scheme = runtime.NewScheme()

func init() {
	utilruntime.Must(clientgoscheme.AddToScheme(scheme))
	utilruntime.Must(kueuev1beta1.AddToScheme(scheme))
}

func main() {
	opts := zap.Options{Development: true}
	ctrl.SetLogger(zap.New(zap.UseFlagOptions(&opts)))
	logger := ctrl.Log.WithName("least-disruption-dispatcher")

	ctx := context.Background()

	// Create the manager for the management cluster
	mgr, err := ctrl.NewManager(ctrl.GetConfigOrDie(), ctrl.Options{
		Scheme:                 scheme,
		HealthProbeBindAddress: ":8081",
		LeaderElection:         true,
		LeaderElectionID:       "least-disruption-dispatcher.kueue.x-k8s.io",
	})
	if err != nil {
		logger.Error(err, "unable to create manager")
		os.Exit(1)
	}

	// Health checks
	if err := mgr.AddHealthzCheck("healthz", healthz.Ping); err != nil {
		logger.Error(err, "unable to set up health check")
		os.Exit(1)
	}
	if err := mgr.AddReadyzCheck("readyz", healthz.Ping); err != nil {
		logger.Error(err, "unable to set up ready check")
		os.Exit(1)
	}

	// Discover worker clusters using MultiKueueCluster resources
	// We need a client that can read before the manager starts, so use a
	// direct client from the manager's config.
	directClient, err := client.New(mgr.GetConfig(), client.Options{Scheme: scheme})
	if err != nil {
		logger.Error(err, "unable to create direct client")
		os.Exit(1)
	}

	workers, err := cluster.DiscoverWorkerClusters(ctx, directClient, scheme)
	if err != nil {
		logger.Error(err, "unable to discover worker clusters")
		os.Exit(1)
	}

	if len(workers) == 0 {
		logger.Error(nil, "no active worker clusters found")
		os.Exit(1)
	}

	// Register worker clusters with the manager and build client/priority maps
	workerClients := make(map[string]client.Reader)
	clusterPriorities := make(map[string]int32)
	for _, w := range workers {
		if err := mgr.Add(w.Cluster); err != nil {
			logger.Error(err, "unable to add worker cluster to manager", "cluster", w.Name)
			os.Exit(1)
		}
		workerClients[w.Name] = w.Cluster.GetCache()
		clusterPriorities[w.Name] = w.Priority
		logger.Info("registered worker cluster", "cluster", w.Name, "priority", w.Priority)
	}

	// Load config from ConfigMap file (mounted at /config/config.yaml),
	// with env var overrides for timing parameters.
	configPath := os.Getenv("DISPATCHER_CONFIG_PATH")
	if configPath == "" {
		configPath = "/config/config.yaml"
	}
	cfg, err := config.LoadFromFile(configPath)
	if err != nil {
		logger.Error(err, "unable to load config", "path", configPath)
		os.Exit(1)
	}

	// Create the in-flight cache
	inFlightCache := inflight.New()

	// Set up the reconciler
	reconciler := dispatcher.NewReconciler(
		mgr.GetClient(),
		workerClients,
		clusterPriorities,
		inFlightCache,
		cfg.Scorer,
		cfg.ClusterQueueName,
		dispatcher.TimingConfig{
			NominationTimeout: cfg.NominationTimeout,
			InFlightTTL:       cfg.InFlightTTL,
			RequeueDelay:      cfg.RequeueDelay,
			CleanupPeriod:     cfg.CleanupPeriod,
		},
	)
	if err := reconciler.SetupWithManager(mgr); err != nil {
		logger.Error(err, "unable to set up dispatcher reconciler")
		os.Exit(1)
	}

	logger.Info("starting least-disruption dispatcher",
		"workers", len(workerClients),
		"resourceName", cfg.Scorer.ResourceName,
		"flavorName", cfg.Scorer.FlavorName,
		"clusterQueue", cfg.ClusterQueueName,
		"nominationTimeout", cfg.NominationTimeout,
		"inFlightTTL", cfg.InFlightTTL,
		"requeueDelay", cfg.RequeueDelay,
		"cleanupPeriod", cfg.CleanupPeriod)

	if err := mgr.Start(ctrl.SetupSignalHandler()); err != nil {
		logger.Error(err, "manager exited with error")
		os.Exit(1)
	}
}
