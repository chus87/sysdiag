package legacy

import (
	"context"
	"fmt"
	"sync"

	"github.com/chus87/sysdiag/internal/model"
)

type domainResult struct {
	name string
	rep  model.Report
	err  error
}

// JSONAll executes expensive layers as independent diagnostic transactions and
// merges only the metric keys owned by each layer. A collector cannot erase
// valid host metrics with null placeholders from another scope.
func (r Runner) JSONAll(ctx context.Context, args []string) model.Report {
	common, containerArgs, k8sArgs := splitArgs(args)
	jobs := []struct {
		name string
		args []string
	}{
		{"containers", append(append([]string{"--section", "containers"}, common...), containerArgs...)},
		{"kubernetes", append(append([]string{"--section", "kubernetes"}, common...), k8sArgs...)},
	}
	results := map[string]domainResult{}
	if expensiveMode(containerArgs, k8sArgs) {
		rep, err := r.JSON(ctx, append([]string{"--host-only"}, common...))
		results["host"] = domainResult{"host", rep, err}
		results = runJobs(ctx, r, jobs, results)
	} else {
		all := append([]struct {
			name string
			args []string
		}{{"host", append([]string{"--host-only"}, common...)}}, jobs...)
		results = runJobs(ctx, r, all, results)
	}
	out := model.NewReport()
	out.Scope = []string{"all"}
	out.Metrics = map[string]any{}
	for _, name := range []string{"host", "containers", "kubernetes"} {
		x, ok := results[name]
		if !ok {
			continue
		}
		out.Collectors = append(out.Collectors, x.rep.Collectors...)
		if x.err != nil {
			out.Limitations = append(out.Limitations, fmt.Sprintf("El collector %s no pudo completarse: %v. El informe es parcial.", name, x.err))
			addLimitedCoverage(&out, name)
			continue
		}
		mergeDomain(&out, x.rep, name)
	}
	model.HydrateTypedMetrics(&out)
	return out
}

func runJobs(ctx context.Context, r Runner, jobs []struct {
	name string
	args []string
}, results map[string]domainResult) map[string]domainResult {
	ch := make(chan domainResult, len(jobs))
	var wg sync.WaitGroup
	for _, j := range jobs {
		j := j
		wg.Add(1)
		go func() { defer wg.Done(); rep, err := r.JSON(ctx, j.args); ch <- domainResult{j.name, rep, err} }()
	}
	wg.Wait()
	close(ch)
	for x := range ch {
		results[x.name] = x
	}
	return results
}
func expensiveMode(c, k []string) bool {
	for _, x := range c {
		if x == "deep" {
			return true
		}
	}
	for _, x := range k {
		if x == "exhaustive" {
			return true
		}
	}
	return false
}

func addLimitedCoverage(r *model.Report, domain string) {
	if domain == "host" {
		for _, cat := range []string{"cpu", "processes", "memory", "io", "filesystem", "network", "logging", "systemd", "boot"} {
			r.Coverage = append(r.Coverage, model.Coverage{Category: cat, Observed: false, Limited: true})
		}
		return
	}
	r.Coverage = append(r.Coverage, model.Coverage{Category: domain, Observed: false, Limited: true})
}

func splitArgs(args []string) (common, containers, k8s []string) {
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch a {
		case "--all", "--summary", "--json", "--section":
			if a == "--section" && i+1 < len(args) {
				i++
			}
		case "--container-mode":
			if i+1 < len(args) {
				containers = append(containers, a, args[i+1])
				i++
			}
		case "--containers-deep":
			containers = append(containers, "--container-mode", "deep")
		case "--k8s-mode", "--k8s-node", "--k8s-namespace", "--k8s-pod", "--k8s-context", "--k8s-kubeconfig":
			if i+1 < len(args) {
				k8s = append(k8s, a, args[i+1])
				i++
			}
		case "--k8s-no-auth-prompt":
			k8s = append(k8s, a)
		default:
			common = append(common, a)
		}
	}
	return
}

var hostMetricKeys = []string{"system", "cpu", "processes", "memory", "io", "filesystem", "network", "logging", "recent_events", "systemd", "boot"}

func mergeDomain(dst *model.Report, src model.Report, domain string) {
	if dst.Host == "" && src.Host != "" {
		dst.Host = src.Host
	}
	dst.Findings = append(dst.Findings, src.Findings...)
	dst.Limitations = append(dst.Limitations, src.Limitations...)
	dst.NextSteps = append(dst.NextSteps, src.NextSteps...)
	dst.Coverage = append(dst.Coverage, src.Coverage...)
	switch domain {
	case "host":
		for _, k := range hostMetricKeys {
			if v, ok := src.Metrics[k]; ok {
				dst.Metrics[k] = v
			}
		}
	case "containers":
		if v, ok := src.Metrics["containers"]; ok {
			dst.Metrics["containers"] = v
		}
	case "kubernetes":
		if v, ok := src.Metrics["kubernetes"]; ok {
			dst.Metrics["kubernetes"] = v
		}
	}
	dst.Findings = dedupeFindings(dst.Findings)
	dst.Limitations = dedupeStrings(dst.Limitations)
	dst.NextSteps = dedupeSteps(dst.NextSteps)
	dst.Coverage = dedupeCoverage(dst.Coverage)
}
func dedupeFindings(in []model.Finding) []model.Finding {
	m := map[string]bool{}
	o := []model.Finding{}
	for _, x := range in {
		if !m[x.ID] {
			m[x.ID] = true
			o = append(o, x)
		}
	}
	return o
}
func dedupeStrings(in []string) []string {
	m := map[string]bool{}
	o := []string{}
	for _, x := range in {
		if x != "" && !m[x] {
			m[x] = true
			o = append(o, x)
		}
	}
	return o
}
func dedupeSteps(in []model.NextStep) []model.NextStep {
	m := map[string]bool{}
	o := []model.NextStep{}
	for _, x := range in {
		if !m[x.Description] {
			m[x.Description] = true
			o = append(o, x)
		}
	}
	return o
}
func dedupeCoverage(in []model.Coverage) []model.Coverage {
	m := map[string]int{}
	o := []model.Coverage{}
	for _, x := range in {
		if i, ok := m[x.Category]; ok {
			o[i].Observed = o[i].Observed || x.Observed
			o[i].Limited = o[i].Limited || x.Limited
			continue
		}
		m[x.Category] = len(o)
		o = append(o, x)
	}
	return o
}

// addLimitedSummary is kept for internal/test compatibility; Go consumes the
// resulting coverage and rebuilds the final summary centrally.
func addLimitedSummary(r *model.Report, domain string) {
	addLimitedCoverage(r, domain)
	if domain == "host" {
		for _, c := range r.Coverage {
			r.Summary = append(r.Summary, model.Summary{Category: c.Category, Title: titleFor(c.Category), Status: "LIMITED"})
		}
		return
	}
	r.Summary = append(r.Summary, model.Summary{Category: domain, Title: titleFor(domain), Status: "LIMITED"})
}
func titleFor(n string) string {
	switch n {
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
	}
	return n
}
