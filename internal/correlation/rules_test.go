package correlation

import (
	"testing"

	"github.com/chus87/sysdiag/internal/model"
)

func finding(id, domain, msg string) model.Finding {
	return model.Finding{ID: id, Category: "kubernetes", Domain: domain, Points: 4, Impact: "ALTO", Message: msg}
}

func hasConclusion(r model.Report, prefix string) bool {
	for _, c := range r.Conclusions {
		if len(c.ID) >= len(prefix) && c.ID[:len(prefix)] == prefix {
			return true
		}
	}
	return false
}

func TestRulesDoNotDependOnHumanWording(t *testing.T) {
	r := model.NewReport()
	r.Findings = []model.Finding{
		finding("K8S_LIVENESS_KILL_ns-Pod-api", "liveness_restart", "texto completamente distinto"),
		finding("K8S_LIVENESS_ns-Pod-api", "liveness", "otro texto"),
		finding("K8S_POD_RESTARTS_ns-api", "restart_history", "sin palabras clave"),
	}
	Correlate(&r)
	if !hasConclusion(r, "corr-liveness-restarts-") {
		t.Fatal("la correlación debe basarse en IDs, no en texto")
	}
}

func TestStorageClassPendingCorrelation(t *testing.T) {
	r := model.NewReport()
	r.Findings = []model.Finding{
		finding("K8S_PVC_SC_ns-db", "storage_config", "x"),
		finding("K8S_PVC_PENDING_ns-db", "storage_provision", "y"),
	}
	Correlate(&r)
	if !hasConclusion(r, "corr-k8s-storageclass-pvc-") {
		t.Fatal("se esperaba correlación StorageClass/PVC")
	}
	for _, c := range r.Conclusions {
		if c.ID == "corr-k8s-storageclass-pvc-ns-db" && (!c.RootCause || c.Confidence != "ALTA") {
			t.Fatalf("conclusión inesperada: %#v", c)
		}
	}
}

func TestOOMWithoutNodeMemoryPressure(t *testing.T) {
	r := model.NewReport()
	r.Findings = []model.Finding{finding("K8S_POD_OOM_ns-api", "cgroup_memory", "x")}
	r.Metrics = map[string]any{"kubernetes": map[string]any{
		"nodes_detail": []any{map[string]any{"name": "worker-1", "memory_pressure": "False"}},
		"pod_issues":   []any{map[string]any{"namespace": "ns", "name": "api", "node": "worker-1", "last_reason": "OOMKilled", "status_reason": "n/d"}},
	}}
	Correlate(&r)
	if !hasConclusion(r, "corr-k8s-cgroup-oom-") {
		t.Fatal("se esperaba OOM de cgroup sin MemoryPressure")
	}
}

func TestEvictionWithMemoryPressureSameNode(t *testing.T) {
	r := model.NewReport()
	r.Findings = []model.Finding{
		finding("K8S_POD_EVICTED_ns-api", "eviction", "x"),
		finding("K8S_NODE_MEMORY_worker-1", "node_pressure", "y"),
	}
	r.Metrics = map[string]any{"kubernetes": map[string]any{
		"nodes_detail": []any{map[string]any{"name": "worker-1", "memory_pressure": "True"}},
		"pod_issues":   []any{map[string]any{"namespace": "ns", "name": "api", "node": "worker-1", "last_reason": "n/d", "status_reason": "Evicted"}},
	}}
	Correlate(&r)
	if !hasConclusion(r, "corr-node-pressure-eviction-") {
		t.Fatal("se esperaba node-pressure eviction")
	}
}

func TestEvictionDoesNotCorrelateAcrossDifferentNode(t *testing.T) {
	r := model.NewReport()
	r.Findings = []model.Finding{
		finding("K8S_POD_EVICTED_ns-api", "eviction", "x"),
		finding("K8S_NODE_MEMORY_worker-2", "node_pressure", "y"),
	}
	r.Metrics = map[string]any{"kubernetes": map[string]any{
		"nodes_detail": []any{
			map[string]any{"name": "worker-1", "memory_pressure": "False"},
			map[string]any{"name": "worker-2", "memory_pressure": "True"},
		},
		"pod_issues": []any{map[string]any{"namespace": "ns", "name": "api", "node": "worker-1", "status_reason": "Evicted"}},
	}}
	Correlate(&r)
	if hasConclusion(r, "corr-node-pressure-eviction-") {
		t.Fatal("no debe correlacionar presión de otro nodo")
	}
}

func TestServiceSelectorDoesNotNeedTextMatching(t *testing.T) {
	r := model.NewReport()
	r.Findings = []model.Finding{finding("K8S_SVC_SELECTOR_ns-api", "service_selector", "redacción arbitraria")}
	Correlate(&r)
	if !hasConclusion(r, "corr-service-selector-") {
		t.Fatal("se esperaba correlación de selector")
	}
}

func TestNoFalseCorrelationFromWordsOnly(t *testing.T) {
	r := model.NewReport()
	r.Findings = []model.Finding{
		finding("RANDOM_A", "random", "liveness"),
		finding("RANDOM_B", "random", "reinicios"),
		finding("RANDOM_C", "random", "storageclass pvc sin endpoints selector"),
	}
	Correlate(&r)
	if len(r.Conclusions) != 0 {
		t.Fatalf("el texto no debe disparar reglas: %#v", r.Conclusions)
	}
}

func TestMetricEvidenceIDDoesNotDependOnMessage(t *testing.T) {
	r := model.NewReport()
	id1 := addMetricEvidence(&r, "kubernetes", "node_condition", "worker-1", "primera redacción", map[string]any{"memory_pressure": false})
	id2 := addMetricEvidence(&r, "kubernetes", "node_condition", "worker-1", "texto completamente distinto", map[string]any{"memory_pressure": false})
	if id1 != id2 {
		t.Fatalf("el ID de evidencia métrica debe ser estable: %q != %q", id1, id2)
	}
	if len(r.Evidence) != 1 {
		t.Fatalf("la misma evidencia estructurada no debe duplicarse: %d", len(r.Evidence))
	}
}

func TestLivenessCorrelationIncludesPodRestartEvidence(t *testing.T) {
	r := model.NewReport()
	r.Findings = []model.Finding{
		finding("K8S_LIVENESS_KILL_ns-Pod-api", "liveness_restart", "x"),
		finding("K8S_LIVENESS_ns-Pod-api", "liveness", "y"),
		finding("K8S_POD_RESTARTS_ns-api", "restart_history", "z"),
	}
	Correlate(&r)
	for _, c := range r.Conclusions {
		if c.ID != "corr-liveness-restarts-ns-Pod-api" {
			continue
		}
		want := map[string]bool{
			"ev-K8S_LIVENESS_KILL_ns-Pod-api": false,
			"ev-K8S_LIVENESS_ns-Pod-api":      false,
			"ev-K8S_POD_RESTARTS_ns-api":      false,
		}
		for _, id := range c.EvidenceIDs {
			if _, ok := want[id]; ok {
				want[id] = true
			}
		}
		for id, ok := range want {
			if !ok {
				t.Fatalf("falta evidencia %s en %#v", id, c.EvidenceIDs)
			}
		}
		return
	}
	t.Fatal("no se encontró la conclusión de liveness")
}
