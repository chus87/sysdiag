package legacy

import (
	"github.com/chus87/sysdiag/internal/model"
	"testing"
)

func TestMergeDomainDoesNotOverwriteOtherLayers(t *testing.T) {
	dst := model.NewReport()
	host := model.NewReport()
	host.Metrics = map[string]any{"memory": map[string]any{"available_kb": 123.0}, "containers": map[string]any{"total": nil}}
	mergeDomain(&dst, host, "host")
	c := model.NewReport()
	c.Metrics = map[string]any{"memory": map[string]any{"available_kb": nil}, "containers": map[string]any{"total": 3.0}}
	mergeDomain(&dst, c, "containers")
	mem := dst.Metrics["memory"].(map[string]any)
	if mem["available_kb"] != 123.0 {
		t.Fatalf("memory sobrescrita: %#v", mem)
	}
	cont := dst.Metrics["containers"].(map[string]any)
	if cont["total"] != 3.0 {
		t.Fatalf("containers no fusionado: %#v", cont)
	}
}
func TestSplitArgs(t *testing.T) {
	c, co, k := splitArgs([]string{"--all", "--sample", "5", "--container-mode", "deep", "--k8s-mode", "exhaustive", "--k8s-node", "w1", "--no-color"})
	if len(co) != 2 || co[1] != "deep" {
		t.Fatal(co)
	}
	if len(k) != 4 {
		t.Fatal(k)
	}
	if len(c) != 3 {
		t.Fatal(c)
	}
}

func TestExpensiveMode(t *testing.T) {
	if !expensiveMode([]string{"--container-mode", "deep"}, nil) {
		t.Fatal("deep debe ser costoso")
	}
	if !expensiveMode(nil, []string{"--k8s-mode", "exhaustive"}) {
		t.Fatal("exhaustive debe ser costoso")
	}
	if expensiveMode([]string{"--container-mode", "normal"}, []string{"--k8s-mode", "deep"}) {
		t.Fatal("modo normal/deep k8s puede paralelizar")
	}
}
func TestHostFailureCreatesLimitedCoverage(t *testing.T) {
	r := model.NewReport()
	addLimitedSummary(&r, "host")
	if len(r.Summary) != 9 {
		t.Fatalf("faltan categorías host: %d", len(r.Summary))
	}
	for _, s := range r.Summary {
		if s.Status != "LIMITED" {
			t.Fatal(s)
		}
	}
}
