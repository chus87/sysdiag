package render

import (
	"encoding/json"
	"fmt"
	"io"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/chus87/sysdiag/internal/model"
)

type Options struct {
	Color       bool
	SummaryOnly bool
	Verbose     bool
	Explain     bool
}

type palette struct{ reset, bold, dim, cyan, green, yellow, red, blue string }

func colors(on bool) palette {
	if !on {
		return palette{}
	}
	return palette{reset: "\x1b[0m", bold: "\x1b[1m", dim: "\x1b[2m", cyan: "\x1b[36m", green: "\x1b[32m", yellow: "\x1b[33m", red: "\x1b[31m", blue: "\x1b[34m"}
}

func JSON(w io.Writer, r model.Report) error {
	e := json.NewEncoder(w)
	e.SetIndent("", "  ")
	return e.Encode(r)
}

func Full(w io.Writer, r model.Report, o Options) {
	p := colors(o.Color)
	fmt.Fprintf(w, "%s%sSYSdiag %s%s %s— diagnóstico read-only%s\n", p.bold, p.cyan, r.SysdiagVersion, p.reset, p.dim, p.reset)
	fmt.Fprintf(w, "%s%s%s\n", p.dim, strings.Repeat("─", 84), p.reset)
	meta := []string{}
	if r.Host != "" {
		meta = append(meta, "Host: "+r.Host)
	}
	if r.DurationMS > 0 {
		meta = append(meta, fmt.Sprintf("Duración: %s", formatDuration(r.DurationMS)))
	}
	if len(r.Scope) > 0 {
		meta = append(meta, "Ámbito: "+strings.Join(r.Scope, ","))
	}
	meta = append(meta, "Motor: "+r.Engine)
	author := r.Build.Author
	if author == "" {
		author = "Chus (GitHub: chus87)"
	}
	meta = append(meta, "Autor: "+author)
	fmt.Fprintf(w, "%s%s%s\n", p.dim, strings.Join(meta, "  ·  "), p.reset)
	printSummary(w, r, p)
	if o.SummaryOnly {
		printConclusions(w, r, p, o)
		printLimitations(w, r, p)
		printCollectors(w, r, p, false)
		return
	}
	printKeyMetrics(w, r, p, o)
	printFindings(w, r, p, o)
	printConclusions(w, r, p, o)
	printLimitations(w, r, p)
	printNextSteps(w, r, p)
	printCollectors(w, r, p, o.Verbose)
	if o.Explain {
		printEvidence(w, r, p)
	}
}

func printSummary(w io.Writer, r model.Report, p palette) {
	fmt.Fprintf(w, "\n%s%sRESUMEN PRIORIZADO%s\n", p.bold, p.cyan, p.reset)
	if len(r.Summary) == 0 {
		fmt.Fprintln(w, "  Sin categorías diagnósticas observables.")
		return
	}
	ss := append([]model.Summary(nil), r.Summary...)
	sort.SliceStable(ss, func(i, j int) bool { return rank(ss[i].Status) > rank(ss[j].Status) })
	for _, s := range ss {
		label, color, bold := statusLabel(s.Status, p)
		fmt.Fprintf(w, "  %s%s%-11s%s %-43s  conf=%-12s impacto=%s\n", color, bold, label, p.reset, truncate(s.Title, 43), s.Confidence, s.Impact)
	}
}

func printKeyMetrics(w io.Writer, r model.Report, p palette, o Options) {
	if r.Typed == nil {
		model.HydrateTypedMetrics(&r)
	}
	fmt.Fprintf(w, "\n%s%sDATOS RELEVANTES%s\n", p.bold, p.cyan, p.reset)
	printed := false
	if m, ok := r.Metrics["system"].(map[string]any); ok && scopeAllows(r, "system") {
		printed = true
		fmt.Fprintf(w, "  %sHost Linux%s\n", p.bold, p.reset)
		for _, k := range []string{"os", "kernel", "uptime", "virtualization", "cpu_logical", "cpu_physical_cores"} {
			if v, ok := m[k]; ok {
				fmt.Fprintf(w, "    %-22s %v\n", labelize(k)+":", v)
			}
		}
	}
	if r.Typed != nil && scopeAllows(r, "containers") {
		c := r.Typed.Containers
		if c.Runtime != "" || c.Running+c.Exited+c.Restarting+c.Unhealthy+c.OOMKilled > 0 {
			printed = true
			fmt.Fprintf(w, "  %sContenedores%s\n", p.bold, p.reset)
			fmt.Fprintf(w, "    Runtime=%s  Running=%d  Exited=%d  Restarting=%d  Unhealthy=%d  OOMKilled=%d\n", nz(c.Runtime, "n/d"), c.Running, c.Exited, c.Restarting, c.Unhealthy, c.OOMKilled)
			if c.DeepScanned > 0 {
				fmt.Fprintf(w, "    Deep scan: %d contenedores · %d patrones relevantes\n", c.DeepScanned, c.DeepPatternMatches)
			}
		}
	}
	if r.Typed != nil && scopeAllows(r, "kubernetes") {
		k := r.Typed.Kubernetes
		if k.Access != "" {
			printed = true
			fmt.Fprintf(w, "  %sKubernetes / OpenShift%s\n", p.bold, p.reset)
			fmt.Fprintf(w, "    Acceso=%s  cliente=%s  modo=%s  nodos=%d  NotReady=%d  MemoryPressure=%d  DiskPressure=%d\n", nz(k.Access, "n/d"), nz(k.Client, "n/d"), nz(k.Mode, "n/d"), len(k.Nodes), k.NodesNotReady, k.MemoryPressureNodes, k.DiskPressureNodes)
			fmt.Fprintf(w, "    FailedScheduling=%d  FailedAttach=%d  FailedMount=%d  RBAC denied=%d\n", k.FailedScheduling, k.FailedAttach, k.FailedMount, k.PermissionDenied)
		}
	}
	// For a specific section, expose its scalar raw metrics without dumping large arrays.
	if len(r.Scope) == 1 && r.Scope[0] != "all" {
		if m, ok := r.Metrics[r.Scope[0]].(map[string]any); ok {
			printed = true
			printScalarMetricMap(w, m, "  ", o.Verbose)
		}
	}
	if !printed {
		fmt.Fprintln(w, "  No hay métricas adicionales útiles para este ámbito.")
	}
}

func printFindings(w io.Writer, r model.Report, p palette, o Options) {
	fmt.Fprintf(w, "\n%s%sHALLAZGOS%s\n", p.bold, p.cyan, p.reset)
	if len(r.Findings) == 0 {
		fmt.Fprintf(w, "  %sNo se han detectado señales anómalas con la evidencia disponible.%s\n", p.green, p.reset)
		return
	}
	fs := append([]model.Finding(nil), r.Findings...)
	sort.SliceStable(fs, func(i, j int) bool {
		if fs[i].Points == fs[j].Points {
			return fs[i].Category < fs[j].Category
		}
		return fs[i].Points > fs[j].Points
	})
	for _, f := range fs {
		sev := findingColor(f, p)
		fmt.Fprintf(w, "  %s●%s %s\n", sev, p.reset, f.Message)
		if o.Verbose {
			fmt.Fprintf(w, "    %sID=%s · categoría=%s · dominio=%s · puntos=%d · impacto=%s%s\n", p.dim, f.ID, f.Category, f.Domain, f.Points, f.Impact, p.reset)
		}
	}
}

func printConclusions(w io.Writer, r model.Report, p palette, o Options) {
	if len(r.Conclusions) == 0 {
		return
	}
	fmt.Fprintf(w, "\n%s%sCORRELACIÓN Y DIAGNÓSTICO%s\n", p.bold, p.cyan, p.reset)
	for _, c := range r.Conclusions {
		mark := p.yellow
		if strings.EqualFold(c.Confidence, "ALTA") {
			mark = p.red
		}
		if !c.RootCause && strings.EqualFold(c.Confidence, "MEDIA") {
			mark = p.cyan
		}
		root := ""
		if c.RootCause {
			root = " · candidato a causa raíz"
		}
		fmt.Fprintf(w, "  %s◆ [%s]%s %s%s\n", mark, c.Confidence, p.reset, c.Title, root)
		fmt.Fprintf(w, "    %s\n", c.Interpretation)
		if o.Explain && len(c.ManualChecks) > 0 {
			fmt.Fprintln(w, "    Verificación manual:")
			for _, x := range c.ManualChecks {
				fmt.Fprintf(w, "      $ %s\n", x)
			}
		}
	}
	fmt.Fprintf(w, "  %sLas correlaciones expresan hipótesis apoyadas por evidencia; no sustituyen la validación del administrador.%s\n", p.dim, p.reset)
}
func printLimitations(w io.Writer, r model.Report, p palette) {
	if len(r.Limitations) == 0 {
		return
	}
	fmt.Fprintf(w, "\n%s%sLIMITACIONES DE COBERTURA%s\n", p.bold, p.blue, p.reset)
	for _, x := range r.Limitations {
		fmt.Fprintf(w, "  %s○%s %s\n", p.blue, p.reset, x)
	}
}
func printNextSteps(w io.Writer, r model.Report, p palette) {
	if len(r.NextSteps) == 0 {
		return
	}
	fmt.Fprintf(w, "\n%s%sSIGUIENTES COMPROBACIONES MANUALES%s\n", p.bold, p.cyan, p.reset)
	for _, s := range r.NextSteps {
		fmt.Fprintf(w, "  %s\n", s.Description)
		if len(s.Actions) > 0 {
			for _, a := range s.Actions {
				tag := a.Safety
				if tag == "mutating" {
					tag = "MUTANTE"
				} else if tag == "read_only" {
					tag = "READ-ONLY"
				} else {
					tag = "REVISAR"
				}
				fmt.Fprintf(w, "    [%s] $ %s\n", tag, a.Command)
			}
		} else {
			for _, c := range s.Commands {
				fmt.Fprintf(w, "    $ %s\n", c)
			}
		}
	}
}
func printCollectors(w io.Writer, r model.Report, p palette, force bool) {
	show := force
	for _, c := range r.Collectors {
		if c.Status != "ok" {
			show = true
		}
	}
	if !show || len(r.Collectors) == 0 {
		return
	}
	fmt.Fprintf(w, "\n%s%sCOBERTURA DE COLLECTORS%s\n", p.bold, p.cyan, p.reset)
	for _, c := range r.Collectors {
		col := p.green
		if c.Status == "limited" {
			col = p.blue
		} else if c.Status == "failed" {
			col = p.red
		}
		fmt.Fprintf(w, "  %s%-8s%s %-14s %8s", col, strings.ToUpper(c.Status), p.reset, c.Name, formatDuration(c.DurationMS))
		if c.Error != "" {
			fmt.Fprintf(w, "  %s", truncate(c.Error, 70))
		}
		fmt.Fprintln(w)
	}
}
func printEvidence(w io.Writer, r model.Report, p palette) {
	if len(r.Evidence) == 0 {
		return
	}
	fmt.Fprintf(w, "\n%s%sEVIDENCIA ESTRUCTURADA%s\n", p.bold, p.cyan, p.reset)
	for _, e := range r.Evidence {
		state := e.TemporalState
		if state == "" {
			state = model.TemporalUnknown
		}
		fmt.Fprintf(w, "  - %-18s %-12s %-18s %s\n", e.Layer, state, truncate(e.Resource, 18), e.Message)
	}
}

func printScalarMetricMap(w io.Writer, m map[string]any, indent string, verbose bool) {
	keys := make([]string, 0, len(m))
	for k, v := range m {
		switch v.(type) {
		case map[string]any, []any:
			if !verbose {
				continue
			}
		}
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		v := m[k]
		switch x := v.(type) {
		case []any:
			fmt.Fprintf(w, "%s%-28s %d elementos\n", indent, labelize(k)+":", len(x))
		case map[string]any:
			fmt.Fprintf(w, "%s%-28s %d campos\n", indent, labelize(k)+":", len(x))
		default:
			fmt.Fprintf(w, "%s%-28s %s\n", indent, labelize(k)+":", formatMetricValue(k, v))
		}
	}
}

func scopeAllows(r model.Report, cat string) bool {
	if len(r.Scope) == 0 {
		return true
	}
	for _, s := range r.Scope {
		if s == "all" || s == cat {
			return true
		}
	}
	return false
}
func statusLabel(s string, p palette) (label, color, emphasis string) {
	switch strings.ToUpper(s) {
	case "OK":
		return "OK", p.green, ""
	case "INFO":
		return "INFO", p.cyan, ""
	case "LIMITED":
		return "LIMITADO", p.blue, ""
	case "WARNING":
		return "WARNING", p.yellow, ""
	case "CRITICAL":
		return "CRITICAL", p.red, p.bold
	}
	return s, "", ""
}
func findingColor(f model.Finding, p palette) string {
	switch strings.ToUpper(f.Impact) {
	case "CRÍTICO", "CRITICO", "CRITICAL":
		return p.red
	case "ALTO", "HIGH":
		return p.yellow
	case "MEDIO", "MEDIUM":
		return p.cyan
	default:
		return p.blue
	}
}
func rank(s string) int {
	switch s {
	case "CRITICAL":
		return 5
	case "WARNING":
		return 4
	case "INFO":
		return 3
	case "LIMITED":
		return 2
	case "OK":
		return 1
	}
	return 0
}
func truncate(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	if n < 2 {
		return string(r[:n])
	}
	return string(r[:n-1]) + "…"
}
func labelize(s string) string {
	s = strings.ReplaceAll(s, "_", " ")
	if s == "" {
		return s
	}
	r := []rune(s)
	r[0] = []rune(strings.ToUpper(string(r[0])))[0]
	return string(r)
}
func nz(s, d string) string {
	if strings.TrimSpace(s) == "" {
		return d
	}
	return s
}
func formatDuration(ms int64) string {
	if ms <= 0 {
		return "0ms"
	}
	d := time.Duration(ms) * time.Millisecond
	if d < time.Second {
		return d.String()
	}
	return d.Round(10 * time.Millisecond).String()
}

func formatMetricValue(key string, value any) string {
	v, ok := metricFloat(value)
	if strings.HasSuffix(key, "_kb") && ok {
		raw := strconv.FormatFloat(v, 'f', -1, 64)
		if v >= 1024*1024 {
			return fmt.Sprintf("%.2f GiB (%s KiB)", v/(1024*1024), raw)
		}
		if v >= 1024 {
			return fmt.Sprintf("%.2f MiB (%s KiB)", v/1024, raw)
		}
		return raw + " KiB"
	}
	if (strings.HasSuffix(key, "_bytes") || strings.HasSuffix(key, "_byte")) && ok {
		raw := strconv.FormatFloat(v, 'f', -1, 64)
		if v >= 1024*1024*1024 {
			return fmt.Sprintf("%.2f GiB (%s B)", v/(1024*1024*1024), raw)
		}
		if v >= 1024*1024 {
			return fmt.Sprintf("%.2f MiB (%s B)", v/(1024*1024), raw)
		}
		if v >= 1024 {
			return fmt.Sprintf("%.2f KiB (%s B)", v/1024, raw)
		}
		return raw + " B"
	}
	if (strings.HasSuffix(key, "_pct") || strings.HasSuffix(key, "_percent")) && ok {
		return fmt.Sprintf("%.1f%%", v)
	}
	switch x := value.(type) {
	case float64:
		return strconv.FormatFloat(x, 'f', -1, 64)
	case float32:
		return strconv.FormatFloat(float64(x), 'f', -1, 32)
	default:
		return fmt.Sprint(value)
	}
}

func metricFloat(value any) (float64, bool) {
	switch v := value.(type) {
	case float64:
		return v, true
	case float32:
		return float64(v), true
	case int:
		return float64(v), true
	case int64:
		return float64(v), true
	case json.Number:
		f, err := v.Float64()
		return f, err == nil
	case string:
		f, err := strconv.ParseFloat(v, 64)
		return f, err == nil
	default:
		return 0, false
	}
}
