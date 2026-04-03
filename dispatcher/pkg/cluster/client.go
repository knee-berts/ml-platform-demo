package cluster

import (
	"context"
	"fmt"

	"strconv"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"
	"sigs.k8s.io/controller-runtime/pkg/client"
	ctrlcluster "sigs.k8s.io/controller-runtime/pkg/cluster"
	"sigs.k8s.io/controller-runtime/pkg/log"

	kueuev1beta1 "sigs.k8s.io/kueue/apis/kueue/v1beta1"
)

// WorkerCluster holds the cluster.Cluster instance, its name, and priority.
type WorkerCluster struct {
	Name     string
	Priority int32 // from dispatcher.kueue.x-k8s.io/priority label
	Cluster  ctrlcluster.Cluster
}

// DiscoverWorkerClusters reads MultiKueueCluster resources from the management
// cluster and builds controller-runtime Cluster instances for each worker.
//
// For GKE fleet clusters, authentication uses the ClusterProfile reference
// and the gcp-auth-plugin exec credential provider (same mechanism as
// Kueue's built-in MultiKueue controller).
func DiscoverWorkerClusters(
	ctx context.Context,
	mgmtClient client.Client,
	scheme *runtime.Scheme,
) ([]WorkerCluster, error) {
	logger := log.FromContext(ctx)

	var mkClusters kueuev1beta1.MultiKueueClusterList
	if err := mgmtClient.List(ctx, &mkClusters); err != nil {
		return nil, fmt.Errorf("list MultiKueueClusters: %w", err)
	}

	var workers []WorkerCluster
	for _, mkc := range mkClusters.Items {
		// Check if the cluster is active
		active := false
		for _, c := range mkc.Status.Conditions {
			if c.Type == "Active" && c.Status == "True" {
				active = true
				break
			}
		}
		if !active {
			logger.Info("skipping inactive MultiKueueCluster", "cluster", mkc.Name)
			continue
		}

		cfg, err := buildRestConfig(ctx, mgmtClient, &mkc)
		if err != nil {
			logger.Error(err, "failed to build REST config", "cluster", mkc.Name)
			continue
		}

		cluster, err := ctrlcluster.New(cfg, func(o *ctrlcluster.Options) {
			o.Scheme = scheme
		})
		if err != nil {
			logger.Error(err, "failed to create cluster", "cluster", mkc.Name)
			continue
		}

		// Read cluster priority from label
		var priority int32
		if v, ok := mkc.Labels["dispatcher.kueue.x-k8s.io/priority"]; ok {
			if p, err := strconv.ParseInt(v, 10, 32); err == nil {
				priority = int32(p)
			}
		}

		workers = append(workers, WorkerCluster{
			Name:     mkc.Name,
			Priority: priority,
			Cluster:  cluster,
		})

		logger.Info("discovered worker cluster", "cluster", mkc.Name, "priority", priority)
	}

	return workers, nil
}

// buildRestConfig creates a rest.Config for a worker cluster using the
// GKE fleet ClusterProfile mechanism.
//
// The MultiKueueCluster spec references a ClusterProfile, which contains
// the cluster's connection details. For GKE, we use the Connect Gateway
// endpoint with the gcp-auth-plugin for authentication.
func buildRestConfig(
	ctx context.Context,
	mgmtClient client.Client,
	mkc *kueuev1beta1.MultiKueueCluster,
) (*rest.Config, error) {
	// Read kubeconfig from the secret named <cluster>-kubeconfig.
	// GKE fleet clusters store kubeconfigs in secrets with the
	// gcp-auth-plugin exec credential provider for authentication.
	return buildRestConfigFromSecret(ctx, mgmtClient, mkc)
}

// buildRestConfigFromSecret attempts to read a kubeconfig Secret for the
// worker cluster. The secret name follows Kueue's convention.
func buildRestConfigFromSecret(
	ctx context.Context,
	mgmtClient client.Client,
	mkc *kueuev1beta1.MultiKueueCluster,
) (*rest.Config, error) {
	// Kubeconfig secrets follow the naming convention: <base-name>-kubeconfig
	// where base-name is the MultiKueueCluster name with "-cluster" suffix removed.
	// e.g., "worker-east1-cluster" -> "worker-east1-kubeconfig"
	baseName := mkc.Name
	if len(baseName) > 8 && baseName[len(baseName)-8:] == "-cluster" {
		baseName = baseName[:len(baseName)-8]
	}
	secretName := baseName + "-kubeconfig"
	var secret corev1.Secret
	key := types.NamespacedName{
		Namespace: "kueue-system",
		Name:      secretName,
	}
	if err := mgmtClient.Get(ctx, key, &secret); err != nil {
		return nil, fmt.Errorf("get kubeconfig secret %s: %w", secretName, err)
	}

	kubeconfigBytes, ok := secret.Data["kubeconfig"]
	if !ok {
		return nil, fmt.Errorf("secret %s has no 'kubeconfig' key", secretName)
	}

	cfg, err := clientcmd.RESTConfigFromKubeConfig(kubeconfigBytes)
	if err != nil {
		return nil, fmt.Errorf("parse kubeconfig from secret %s: %w", secretName, err)
	}

	return cfg, nil
}

