package model

import "testing"

func TestHydrateTypedMetrics(t *testing.T) {
	r := Report{Metrics: map[string]any{"kubernetes": map[string]any{"nodes_detail": []any{map[string]any{"name": "w1", "memory_pressure": "True"}}, "pod_issues": []any{map[string]any{"namespace": "n", "name": "p", "node": "w1", "restarts": 2.0}}}, "memory": map[string]any{"available_kb": 1234.0}}}
	HydrateTypedMetrics(&r)
	if r.Typed == nil || len(r.Typed.Kubernetes.Nodes) != 1 || !r.Typed.Kubernetes.Nodes[0].MemoryPressure {
		t.Fatal("tipado k8s falló")
	}
	if r.Typed.Host.MemoryAvailableKB == nil || *r.Typed.Host.MemoryAvailableKB != 1234 {
		t.Fatal("tipado host falló")
	}
}
