package config

import (
	"os"
	"strconv"
	"time"

	"gopkg.in/yaml.v3"

	"github.com/kubecon-fleets-demo/least-disruption-dispatcher/pkg/scorer"
)

// Config holds all dispatcher configuration, loaded from a ConfigMap file
// with optional env var overrides.
type Config struct {
	Scorer           scorer.Config
	ClusterQueueName string
	NominationTimeout time.Duration
	InFlightTTL       time.Duration
	RequeueDelay      time.Duration
	CleanupPeriod     time.Duration
}

// configFile mirrors the YAML structure of the ConfigMap.
type configFile struct {
	PriorityWeights          map[string]int `yaml:"priorityWeights"`
	ResourceName             string         `yaml:"resourceName"`
	FlavorName               string         `yaml:"flavorName"`
	ClusterQueueName         string         `yaml:"clusterQueueName"`
	NominationTimeoutSeconds int            `yaml:"nominationTimeoutSeconds"`
	InFlightTTLSeconds       int            `yaml:"inFlightTTLSeconds"`
	RequeueDelaySeconds      int            `yaml:"requeueDelaySeconds"`
	CleanupPeriodSeconds     int            `yaml:"cleanupPeriodSeconds"`
}

// Defaults returns a Config with sensible defaults.
func Defaults() Config {
	return Config{
		Scorer: scorer.Config{
			PriorityWeights: map[string]int{
				"training-low":      1,
				"inference-high":    10,
				"training-critical": 1000,
			},
			ResourceName: "nvidia.com/gpu",
			FlavorName:   "rtx-pro-6000",
		},
		ClusterQueueName:  "gpu-cluster-queue",
		NominationTimeout: 30 * time.Second,
		InFlightTTL:       60 * time.Second,
		RequeueDelay:      5 * time.Second,
		CleanupPeriod:     30 * time.Second,
	}
}

// LoadFromFile reads a YAML config file (typically mounted from a ConfigMap)
// and applies env var overrides on top.
func LoadFromFile(path string) (Config, error) {
	cfg := Defaults()

	data, err := os.ReadFile(path)
	if err != nil {
		// If the file doesn't exist, fall back to defaults + env vars
		if os.IsNotExist(err) {
			applyEnvOverrides(&cfg)
			return cfg, nil
		}
		return cfg, err
	}

	var f configFile
	if err := yaml.Unmarshal(data, &f); err != nil {
		return cfg, err
	}

	if len(f.PriorityWeights) > 0 {
		cfg.Scorer.PriorityWeights = f.PriorityWeights
	}
	if f.ResourceName != "" {
		cfg.Scorer.ResourceName = f.ResourceName
	}
	if f.FlavorName != "" {
		cfg.Scorer.FlavorName = f.FlavorName
	}
	if f.ClusterQueueName != "" {
		cfg.ClusterQueueName = f.ClusterQueueName
	}
	if f.NominationTimeoutSeconds > 0 {
		cfg.NominationTimeout = time.Duration(f.NominationTimeoutSeconds) * time.Second
	}
	if f.InFlightTTLSeconds > 0 {
		cfg.InFlightTTL = time.Duration(f.InFlightTTLSeconds) * time.Second
	}
	if f.RequeueDelaySeconds > 0 {
		cfg.RequeueDelay = time.Duration(f.RequeueDelaySeconds) * time.Second
	}
	if f.CleanupPeriodSeconds > 0 {
		cfg.CleanupPeriod = time.Duration(f.CleanupPeriodSeconds) * time.Second
	}

	applyEnvOverrides(&cfg)
	return cfg, nil
}

// applyEnvOverrides lets env vars take precedence over file values.
// Env vars: DISPATCHER_NOMINATION_TIMEOUT_SECONDS, DISPATCHER_INFLIGHT_TTL_SECONDS,
// DISPATCHER_REQUEUE_DELAY_SECONDS, DISPATCHER_CLEANUP_PERIOD_SECONDS.
func applyEnvOverrides(cfg *Config) {
	if v := envInt("DISPATCHER_NOMINATION_TIMEOUT_SECONDS"); v > 0 {
		cfg.NominationTimeout = time.Duration(v) * time.Second
	}
	if v := envInt("DISPATCHER_INFLIGHT_TTL_SECONDS"); v > 0 {
		cfg.InFlightTTL = time.Duration(v) * time.Second
	}
	if v := envInt("DISPATCHER_REQUEUE_DELAY_SECONDS"); v > 0 {
		cfg.RequeueDelay = time.Duration(v) * time.Second
	}
	if v := envInt("DISPATCHER_CLEANUP_PERIOD_SECONDS"); v > 0 {
		cfg.CleanupPeriod = time.Duration(v) * time.Second
	}
}

func envInt(key string) int {
	s := os.Getenv(key)
	if s == "" {
		return 0
	}
	v, err := strconv.Atoi(s)
	if err != nil {
		return 0
	}
	return v
}
