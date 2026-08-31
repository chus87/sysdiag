package render

import (
	"bytes"
	"strings"
	"testing"

	"github.com/chus87/sysdiag/internal/model"
)

func sampleReport() model.Report {
	return model.Report{
		SysdiagVersion: "0.14.2", Engine: "go-core", Host: "worker-01", Scope: []string{"all"}, DurationMS: 1250,
		Summary: []model.Summary{
			{Category: "memory", Title: "Memoria", Status: "OK", Confidence: "ALTA", Impact: "BAJO"},
			{Category: "kubernetes", Title: "Kubernetes / OpenShift", Status: "CRITICAL", Confidence: "ALTA", Impact: "CRÍTICO"},
		},
		Findings:    []model.Finding{{ID: "x", Category: "kubernetes", Domain: "d", Impact: "CRÍTICO", Message: "Node NotReady observado."}},
		Limitations: []string{"Métricas no disponibles."}, Metrics: map[string]any{},
	}
}

func TestFullColorContract(t *testing.T) {
	var plain, colored bytes.Buffer
	Full(&plain, sampleReport(), Options{Color: false})
	Full(&colored, sampleReport(), Options{Color: true})
	if strings.Contains(plain.String(), "\x1b[") {
		t.Fatal("salida sin color contiene ANSI")
	}
	if !strings.Contains(colored.String(), "\x1b[") {
		t.Fatal("salida con color no contiene ANSI")
	}
	if strings.Index(plain.String(), "CRITICAL") > strings.Index(plain.String(), "OK") {
		t.Fatal("resumen no está priorizado por severidad")
	}
}

func TestSummaryOnlyOmitsMetricsAndFindings(t *testing.T) {
	var b bytes.Buffer
	Full(&b, sampleReport(), Options{SummaryOnly: true})
	s := b.String()
	if strings.Contains(s, "DATOS RELEVANTES") || strings.Contains(s, "HALLAZGOS") {
		t.Fatal("summary-only mostró detalle")
	}
}

func TestHelpers(t *testing.T) {
	if got := truncate("abcdef", 4); got != "abc…" {
		t.Fatalf("truncate: %q", got)
	}
	if got := labelize("available_kb"); got != "Available kb" {
		t.Fatalf("labelize: %q", got)
	}
	if got := formatDuration(1250); got != "1.25s" {
		t.Fatalf("duration: %q", got)
	}
}

func TestFormatMetricValueHumanReadable(t *testing.T) {
	if got := formatMetricValue("available_kb", float64(5569076)); got != "5.31 GiB (5569076 KiB)" {
		t.Fatalf("unexpected KiB formatting: %q", got)
	}
	if got := formatMetricValue("rx_bytes", float64(1048576)); got != "1.00 MiB (1048576 B)" {
		t.Fatalf("unexpected bytes formatting: %q", got)
	}
	if got := formatMetricValue("usage_pct", float64(12.345)); got != "12.3%" {
		t.Fatalf("unexpected percent formatting: %q", got)
	}
}
