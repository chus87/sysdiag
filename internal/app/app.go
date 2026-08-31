package app

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/chus87/sysdiag/internal/correlation"
	"github.com/chus87/sysdiag/internal/legacy"
	"github.com/chus87/sysdiag/internal/model"
	"github.com/chus87/sysdiag/internal/render"
	"github.com/chus87/sysdiag/internal/scoring"
	"github.com/chus87/sysdiag/internal/security"
	"github.com/chus87/sysdiag/internal/version"
)

type Options struct {
	JSON, Summary, Verbose, Explain bool
	Guide                           bool
	Color                           bool
	Report                          string
	LegacyArgs                      []string
}

type App struct{}

func (App) Run(ctx context.Context, o Options) error {
	r := legacy.Runner{Interactive: !o.JSON}
	if o.Guide {
		return r.Text(ctx, []string{"--guide", "--no-color"}, os.Stdout, os.Stderr)
	}
	started := time.Now().UTC()
	var rep model.Report
	var err error
	if requestsAll(o.LegacyArgs) {
		rep = r.JSONAll(ctx, o.LegacyArgs)
	} else {
		rep, err = r.JSON(ctx, o.LegacyArgs)
		if err != nil {
			return err
		}
	}
	finalize(&rep, started)
	if o.JSON {
		if o.Report != "" {
			if err := writeJSON(resolveReport(o.Report, rep, "json"), rep); err != nil {
				return err
			}
		}
		return render.JSON(os.Stdout, rep)
	}
	render.Full(os.Stdout, rep, render.Options{Color: o.Color, SummaryOnly: o.Summary, Verbose: o.Verbose, Explain: o.Explain})
	if o.Report != "" {
		path := resolveReport(o.Report, rep, "txt")
		return writeText(path, func(f *os.File) {
			render.Full(f, rep, render.Options{Color: false, SummaryOnly: o.Summary, Verbose: o.Verbose, Explain: o.Explain})
		})
	}
	return nil
}

func finalize(r *model.Report, started time.Time) {
	r.SysdiagVersion = version.Version
	r.Engine = version.Engine
	r.SchemaVersion = version.SchemaVersion
	r.ReadOnly = true
	r.Build = version.BuildInfo()
	if r.GeneratedAt == "" {
		r.GeneratedAt = time.Now().UTC().Format(time.RFC3339)
	}
	r.StartedAt = started.Format(time.RFC3339)
	completed := time.Now().UTC()
	r.CompletedAt = completed.Format(time.RFC3339)
	r.DurationMS = completed.Sub(started).Milliseconds()
	model.HydrateTypedMetrics(r)
	// Collector summaries are not trusted as final analysis. Coverage was copied
	// separately by the legacy adapter; Go owns the canonical summary.
	r.Summary = nil
	scoring.Rebuild(r)
	correlation.Correlate(r)
	decorateNextSteps(r)
}

func decorateNextSteps(r *model.Report) {
	for i := range r.NextSteps {
		r.NextSteps[i].Actions = nil
		for _, c := range r.NextSteps[i].Commands {
			r.NextSteps[i].Actions = append(r.NextSteps[i].Actions, model.ManualAction{Command: c, Safety: security.ClassifyManualCommand(c), RequiresPrivilege: requiresPrivilege(c)})
		}
	}
}
func requiresPrivilege(c string) bool {
	c = strings.TrimSpace(strings.ToLower(c))
	return strings.HasPrefix(c, "sudo ") || strings.Contains(c, " journalctl") || strings.HasPrefix(c, "journalctl") || strings.Contains(c, "/proc/") || strings.Contains(c, "/sys/")
}

func writeJSON(path string, r model.Report) error {
	return writeSecure(path, func(f *os.File) error { return render.JSON(f, r) })
}
func writeText(path string, fn func(*os.File)) error {
	return writeSecure(path, func(f *os.File) error { fn(f); return nil })
}
func writeSecure(path string, fn func(*os.File) error) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0700); err != nil && dir != "." {
		return err
	}
	if err := validateReportTarget(path); err != nil {
		return err
	}
	f, err := os.CreateTemp(dir, ".sysdiag-report-*")
	if err != nil {
		return err
	}
	tmp := f.Name()
	cleanup := func() { _ = os.Remove(tmp) }
	defer cleanup()
	if err := f.Chmod(0600); err != nil {
		_ = f.Close()
		return err
	}
	if err := fn(f); err != nil {
		_ = f.Close()
		return err
	}
	if err := f.Sync(); err != nil {
		_ = f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	// Recheck immediately before the atomic replace. rename(2) replaces a final
	// symlink rather than following it, but we still reject it for a clear contract.
	if err := validateReportTarget(path); err != nil {
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		return err
	}
	if err := os.Chmod(path, 0600); err != nil {
		return err
	}
	return nil
}

func validateReportTarget(path string) error {
	st, err := os.Lstat(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	if st.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("el destino del informe es un enlace simbólico; se rechaza por seguridad")
	}
	if !st.Mode().IsRegular() {
		return fmt.Errorf("el destino del informe no es un fichero regular; se rechaza por seguridad")
	}
	return nil
}
func resolveReport(path string, r model.Report, ext string) string {
	if path != "AUTO" && path != "" {
		return path
	}
	h := sanitize(r.Host)
	if h == "" {
		h = "host"
	}
	return fmt.Sprintf("./sysdiag-%s-%s.%s", h, time.Now().UTC().Format("20060102-150405Z"), ext)
}
func sanitize(s string) string {
	var b strings.Builder
	lastSep := false
	for _, r := range strings.TrimSpace(s) {
		ok := (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') || r == '.' || r == '-'
		if ok {
			b.WriteRune(r)
			lastSep = false
		} else if !lastSep && b.Len() > 0 {
			b.WriteByte('_')
			lastSep = true
		}
		if b.Len() >= 80 {
			break
		}
	}
	return strings.Trim(b.String(), "._-")
}
func requestsAll(args []string) bool {
	for _, a := range args {
		if a == "--all" || a == "--summary" {
			return true
		}
	}
	return false
}
