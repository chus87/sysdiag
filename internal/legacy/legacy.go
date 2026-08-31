package legacy

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/chus87/sysdiag/internal/assets"
	"github.com/chus87/sysdiag/internal/executor"
	"github.com/chus87/sysdiag/internal/model"
)

type Runner struct{ Interactive bool }

func (Runner) script() (string, func(), error) {
	dir, err := os.MkdirTemp("", "sysdiag-collector-*")
	if err != nil {
		return "", func() {}, err
	}
	cleanup := func() { _ = os.RemoveAll(dir) }
	if err := os.Chmod(dir, 0700); err != nil {
		cleanup()
		return "", func() {}, err
	}
	p := filepath.Join(dir, "sysdiag-collector-backend.sh")
	f, err := os.OpenFile(p, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0400)
	if err != nil {
		cleanup()
		return "", func() {}, err
	}
	if _, err := f.Write(assets.LegacyStandalone); err != nil {
		_ = f.Close()
		cleanup()
		return "", func() {}, err
	}
	if err := f.Sync(); err != nil {
		_ = f.Close()
		cleanup()
		return "", func() {}, err
	}
	if err := f.Close(); err != nil {
		cleanup()
		return "", func() {}, err
	}
	b, err := os.ReadFile(p)
	if err != nil {
		cleanup()
		return "", func() {}, err
	}
	sum := sha256.Sum256(b)
	if hex.EncodeToString(sum[:]) != assets.CollectorSHA256() {
		cleanup()
		return "", func() {}, fmt.Errorf("integridad del collector embebido no válida")
	}
	return p, cleanup, nil
}

func (r Runner) JSON(ctx context.Context, args []string) (model.Report, error) {
	var rep model.Report
	script, cleanup, err := r.script()
	if err != nil {
		return rep, err
	}
	defer cleanup()
	cmdArgs := append([]string{script}, args...)
	cmdArgs = append(cmdArgs, "--json", "--no-color")
	started := time.Now().UTC()
	env := executor.SafeEnvironment()
	var outBuf, errBuf bytes.Buffer
	stderr := io.Writer(&errBuf)
	stdin := io.Reader(nil)
	if r.Interactive && isTTY(os.Stdin) {
		env = append(env, "SYSDIAG_MACHINE_INTERACTIVE=1")
		stdin = os.Stdin
		stderr = io.MultiWriter(&errBuf, os.Stderr)
	}
	res, err := executor.Run(ctx, executor.Request{Mode: executor.ModeCollector, Path: "/bin/bash", Args: cmdArgs, Env: env, Stdin: stdin, Stdout: &outBuf, Stderr: stderr})
	out := outBuf.Bytes()
	if err != nil && errBuf.Len() > 0 {
		err = fmt.Errorf("%w: %s", err, errBuf.String())
	}
	cr := collectorRun(nameForArgs(args), started, res.Duration, err)
	rep.Collectors = []model.CollectorRun{cr}
	if err != nil {
		return rep, fmt.Errorf("collector Bash: %w", err)
	}
	if err := json.Unmarshal(out, &rep); err != nil {
		return rep, fmt.Errorf("JSON del collector no válido: %w", err)
	}
	cov := collectorCoverage(rep)
	rep.Coverage = cov
	for _, c := range cov {
		if c.Limited && cr.Status == "ok" {
			cr.Status = "limited"
			break
		}
	}
	rep.Collectors = []model.CollectorRun{cr}
	model.HydrateTypedMetrics(&rep)
	return rep, nil
}

func (r Runner) Text(ctx context.Context, args []string, stdout, stderr io.Writer) error {
	script, cleanup, err := r.script()
	if err != nil {
		return err
	}
	defer cleanup()
	cmdArgs := append([]string{script}, args...)
	_, err = executor.Run(ctx, executor.Request{Mode: executor.ModeCollector, Path: "/bin/bash", Args: cmdArgs, Env: executor.SafeEnvironment(), Stdin: os.Stdin, Stdout: stdout, Stderr: stderr})
	if err != nil {
		return fmt.Errorf("collector Bash: %w", err)
	}
	return nil
}

func collectorRun(name string, started time.Time, d time.Duration, err error) model.CollectorRun {
	status := "ok"
	msg := ""
	if err != nil {
		status = "failed"
		msg = err.Error()
	}
	return model.CollectorRun{Name: name, Status: status, StartedAt: started.Format(time.RFC3339), CompletedAt: started.Add(d).Format(time.RFC3339), DurationMS: d.Milliseconds(), Error: msg}
}

func nameForArgs(args []string) string {
	for i, a := range args {
		if a == "--host-only" {
			return "host"
		}
		if a == "--section" && i+1 < len(args) {
			return args[i+1]
		}
	}
	return "diagnostic"
}

func inferScope(args []string) []string {
	for i, a := range args {
		if a == "--host-only" {
			return []string{"cpu", "processes", "memory", "io", "filesystem", "network", "logging", "systemd", "boot"}
		}
		if a == "--section" && i+1 < len(args) {
			return []string{args[i+1]}
		}
	}
	for _, a := range args {
		if a == "--all" || a == "--summary" {
			return []string{"all"}
		}
	}
	return []string{"all"}
}

func collectorCoverage(rep model.Report) []model.Coverage {
	out := []model.Coverage{}
	seen := map[string]bool{}
	for _, s := range rep.Summary {
		if s.Category == "" || seen[s.Category] {
			continue
		}
		seen[s.Category] = true
		out = append(out, model.Coverage{Category: s.Category, Observed: true, Limited: strings.EqualFold(s.Status, "LIMITED")})
	}
	return out
}

func isTTY(f *os.File) bool {
	st, err := f.Stat()
	return err == nil && st.Mode()&os.ModeCharDevice != 0
}
