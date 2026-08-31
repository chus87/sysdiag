package scoring

import (
	"testing"

	"github.com/chus87/sysdiag/internal/model"
)

func TestRebuild(t *testing.T) {
	r := model.Report{
		Summary: []model.Summary{{Category: "memory", Title: "Memoria", Status: "OK"}},
		Findings: []model.Finding{
			{ID: "a", Category: "memory", Domain: "available", Points: 3, Impact: "MEDIO"},
			{ID: "b", Category: "memory", Domain: "psi", Points: 3, Impact: "ALTO"},
		},
	}
	Rebuild(&r)
	s := r.Summary[0]
	if s.Score != 6 || s.Signals != 2 || s.Confidence != "MEDIA" || s.Status != "WARNING" || s.Impact != "ALTO" {
		t.Fatalf("summary inesperado: %#v", s)
	}
}

func TestLimitedWithoutFindingsIsPreserved(t *testing.T) {
	r := model.Report{Summary: []model.Summary{{Category: "io", Status: "LIMITED"}}}
	Rebuild(&r)
	if r.Summary[0].Status != "LIMITED" {
		t.Fatalf("LIMITED perdido: %#v", r.Summary[0])
	}
}

func TestCrossDomainFindingAddsMissingSummaryCategory(t *testing.T) {
	r := model.Report{
		Summary:  []model.Summary{{Category: "cpu", Title: "CPU / planificación", Status: "OK"}},
		Findings: []model.Finding{{ID: "IO_CROSS", Category: "io", Domain: "cross_correlation", Points: 3, Impact: "ALTO"}},
	}
	Rebuild(&r)
	var found *model.Summary
	for i := range r.Summary {
		if r.Summary[i].Category == "io" {
			found = &r.Summary[i]
		}
	}
	if found == nil {
		t.Fatal("falta summary para categoría cross-domain con findings")
	}
	if found.Score != 3 || found.Status != "WARNING" || found.Title == "" {
		t.Fatalf("summary cross-domain inesperado: %#v", found)
	}
}

func TestUnknownFindingCategoryIsNotDropped(t *testing.T) {
	r := model.Report{Findings: []model.Finding{{ID: "X", Category: "plugin-x", Domain: "signal", Points: 1, Impact: "BAJO"}}}
	Rebuild(&r)
	if len(r.Summary) != 1 || r.Summary[0].Category != "plugin-x" {
		t.Fatalf("categoría desconocida perdida: %#v", r.Summary)
	}
}
