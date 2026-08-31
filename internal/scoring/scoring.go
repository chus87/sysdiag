package scoring

import (
	"sort"
	"strings"

	"github.com/chus87/sysdiag/internal/model"
)

type agg struct {
	score, maxImpact int
	domains          map[string]bool
}

// Rebuild is the single summary/scoring source of truth. Collector summaries
// are treated only as coverage hints and never survive into the final report.
func Rebuild(r *model.Report) {
	if len(r.Coverage) == 0 && len(r.Summary) > 0 {
		for _, s := range r.Summary {
			r.Coverage = append(r.Coverage, model.Coverage{Category: s.Category, Observed: true, Limited: strings.EqualFold(s.Status, "LIMITED")})
		}
	}
	m := map[string]*agg{}
	for _, f := range r.Findings {
		a := m[f.Category]
		if a == nil {
			a = &agg{domains: map[string]bool{}}
			m[f.Category] = a
		}
		a.score += f.Points
		a.domains[f.Domain] = true
		if v := impactValue(f.Impact); v > a.maxImpact {
			a.maxImpact = v
		}
	}
	cov := map[string]model.Coverage{}
	for _, c := range r.Coverage {
		x := cov[c.Category]
		x.Category = c.Category
		x.Observed = x.Observed || c.Observed
		x.Limited = x.Limited || c.Limited
		cov[c.Category] = x
	}
	r.Summary = nil
	seen := map[string]bool{}
	for _, cat := range categoryOrder {
		if _, ok := cov[cat]; ok || m[cat] != nil {
			r.Summary = append(r.Summary, build(cat, m[cat], cov[cat]))
			seen[cat] = true
		}
	}
	extra := []string{}
	for cat := range m {
		if !seen[cat] {
			extra = append(extra, cat)
		}
	}
	for cat := range cov {
		if !seen[cat] && m[cat] == nil {
			extra = append(extra, cat)
		}
	}
	sort.Strings(extra)
	for _, cat := range extra {
		r.Summary = append(r.Summary, build(cat, m[cat], cov[cat]))
	}
}
func build(cat string, a *agg, c model.Coverage) model.Summary {
	if a == nil {
		a = &agg{domains: map[string]bool{}}
	}
	s := model.Summary{Category: cat, Title: title(cat), Score: a.score, Signals: len(a.domains), Confidence: confidence(a.score, len(a.domains)), Impact: impactLabel(a.maxImpact)}
	s.Status = status(a.score, a.maxImpact)
	if c.Limited && s.Status == "OK" {
		s.Status = "LIMITED"
	}
	return s
}

var categoryOrder = []string{"cpu", "processes", "memory", "io", "filesystem", "network", "logging", "systemd", "boot", "containers", "kubernetes"}

func title(cat string) string {
	switch cat {
	case "cpu":
		return "CPU / planificación"
	case "processes":
		return "Procesos"
	case "memory":
		return "Memoria"
	case "io":
		return "I/O / almacenamiento / esperas kernel"
	case "filesystem":
		return "Filesystem / espacio / inodos"
	case "network":
		return "Red / TCP / sockets"
	case "logging":
		return "Logs / capacidad de diagnóstico"
	case "systemd":
		return "Systemd / servicios"
	case "boot":
		return "Boot / arranque"
	case "containers":
		return "Contenedores / runtime"
	case "kubernetes":
		return "Kubernetes / OpenShift"
	default:
		return cat
	}
}
func impactValue(s string) int {
	switch strings.ToUpper(strings.TrimSpace(s)) {
	case "BAJO", "LOW":
		return 1
	case "MEDIO", "MEDIUM":
		return 2
	case "ALTO", "HIGH":
		return 3
	case "CRÍTICO", "CRITICO", "CRITICAL":
		return 4
	}
	return 0
}
func impactLabel(v int) string {
	switch v {
	case 1:
		return "BAJO"
	case 2:
		return "MEDIO"
	case 3:
		return "ALTO"
	case 4:
		return "CRÍTICO"
	}
	return "SIN IMPACTO ESTIMADO"
}
func confidence(score, domains int) string {
	if score >= 8 || (score >= 6 && domains >= 3) {
		return "ALTA"
	}
	if score >= 4 || domains >= 2 {
		return "MEDIA"
	}
	if score >= 1 {
		return "BAJA"
	}
	return "SIN INDICIOS"
}
func status(score, impact int) string {
	if impact >= 4 {
		return "CRITICAL"
	}
	if score >= 4 || impact >= 3 {
		return "WARNING"
	}
	if score >= 1 {
		return "INFO"
	}
	return "OK"
}
