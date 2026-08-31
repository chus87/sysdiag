package executor

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/chus87/sysdiag/internal/security"
)

type Mode string

const ModeCollector Mode = "collector"

type Request struct {
	Mode   Mode
	Path   string
	Args   []string
	Dir    string
	Env    []string
	Stdin  io.Reader
	Stdout io.Writer
	Stderr io.Writer
}

type Result struct{ Duration time.Duration }

// Run is the mandatory external-process gateway for the Go core. A child gets
// its own process group so cancellation cannot leave kubectl/docker/journalctl
// descendants behind after SYSdiag exits.
func Run(ctx context.Context, req Request) (Result, error) {
	if req.Mode != ModeCollector {
		return Result{}, fmt.Errorf("modo de ejecución externo no autorizado: %s", req.Mode)
	}
	if err := security.ValidateCollectorExecution(req.Path, req.Args); err != nil {
		return Result{}, err
	}
	cmd := exec.Command(req.Path, req.Args...)
	cmd.Dir, cmd.Env, cmd.Stdin = req.Dir, req.Env, req.Stdin
	cmd.Stdout, cmd.Stderr = req.Stdout, req.Stderr
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	start := time.Now()
	if err := cmd.Start(); err != nil {
		return Result{}, err
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	select {
	case err := <-done:
		return Result{Duration: time.Since(start)}, err
	case <-ctx.Done():
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM)
		select {
		case <-done:
		case <-time.After(750 * time.Millisecond):
			_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
			<-done
		}
		return Result{Duration: time.Since(start)}, ctx.Err()
	}
}

func Capture(ctx context.Context, req Request) ([]byte, []byte, Result, error) {
	var out, er bytes.Buffer
	req.Stdout, req.Stderr = &out, &er
	res, err := Run(ctx, req)
	if err != nil && len(er.Bytes()) > 0 {
		err = fmt.Errorf("%w: %s", err, er.String())
	}
	return out.Bytes(), er.Bytes(), res, err
}

func IsCancellation(err error) bool {
	return errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded)
}

func SafeEnvironment() []string {
	// Deliberately exclude shell startup hooks and function exports. When SYSdiag
	// runs as root we also refuse to inherit identity/runtime paths from a caller:
	// HOME, XDG_RUNTIME_DIR and an environment KUBECONFIG can indirectly cause
	// privileged code execution (for example through kubeconfig exec plugins).
	euid := os.Geteuid()
	path := "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
	if v := os.Getenv("SYSDIAG_TRUSTED_PATH"); v != "" && trustedPath(v, euid) {
		path = v
	} else if euid != 0 {
		if v := sanitizedPath(os.Getenv("PATH"), euid); v != "" {
			path = v
		}
	}
	env := []string{"PATH=" + path}

	// Locale/terminal settings are data-only and safe to inherit.
	copyKeys(&env, "LANG", "LC_ALL", "LC_CTYPE", "TERM", "NO_COLOR", "DOCKER_HOST", "CONTAINER_HOST", "CONTAINER_DEEP_LOG_TIMEOUT_SECONDS", "SYSDIAG_MACHINE_INTERACTIVE")

	if euid == 0 {
		home := "/root"
		if u, err := user.LookupId("0"); err == nil && filepath.IsAbs(u.HomeDir) {
			home = u.HomeDir
		}
		env = append(env, "HOME="+home, "USER=root", "LOGNAME=root")
		// An inherited kubeconfig is accepted for root only if every listed file is
		// root-owned, regular and not writable by group/others. An explicitly
		// requested --k8s-kubeconfig remains an administrator decision and travels
		// as a collector argument, not as inherited environment.
		if v := os.Getenv("KUBECONFIG"); v != "" && trustedFileList(v, 0) {
			env = append(env, "KUBECONFIG="+v)
		}
	} else {
		copyKeys(&env, "HOME", "USER", "LOGNAME", "TMPDIR", "KUBECONFIG", "XDG_RUNTIME_DIR")
	}

	// Test/development override accepts only a command name, never a path. PATH
	// validation above therefore remains the trust boundary.
	if v := os.Getenv("K8S_CLI_OVERRIDE"); safeCommandName(v) {
		env = append(env, "K8S_CLI_OVERRIDE="+v)
	}
	return env
}

func copyKeys(env *[]string, keys ...string) {
	for _, k := range keys {
		if v, ok := os.LookupEnv(k); ok {
			*env = append(*env, k+"="+v)
		}
	}
}

func sanitizedPath(v string, euid int) string {
	out := []string{}
	for _, d := range filepath.SplitList(v) {
		if d == "" || !filepath.IsAbs(d) || !trustedDir(d, euid, false) {
			continue
		}
		out = append(out, d)
	}
	return strings.Join(out, string(os.PathListSeparator))
}

func trustedPath(v string, euid int) bool {
	parts := filepath.SplitList(v)
	if len(parts) == 0 {
		return false
	}
	for _, d := range parts {
		if d == "" || !filepath.IsAbs(d) || !trustedDir(d, euid, true) {
			return false
		}
	}
	return true
}

func trustedDir(d string, euid int, requireOwner bool) bool {
	st, err := os.Stat(d)
	if err != nil || !st.IsDir() || st.Mode().Perm()&0022 != 0 {
		return false
	}
	stat, ok := st.Sys().(*syscall.Stat_t)
	if !ok {
		return false
	}
	uid := int(stat.Uid)
	if requireOwner {
		return uid == euid
	}
	return uid == 0 || uid == euid
}

func trustedFileList(v string, owner int) bool {
	for _, f := range filepath.SplitList(v) {
		if f == "" || !filepath.IsAbs(f) {
			return false
		}
		st, err := os.Lstat(f)
		if err != nil || !st.Mode().IsRegular() || st.Mode().Perm()&0022 != 0 {
			return false
		}
		stat, ok := st.Sys().(*syscall.Stat_t)
		if !ok || int(stat.Uid) != owner {
			return false
		}
	}
	return true
}

func safeCommandName(v string) bool {
	if v == "" || strings.ContainsAny(v, `/\`) {
		return false
	}
	for _, r := range v {
		if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') || strings.ContainsRune("._-", r) {
			continue
		}
		return false
	}
	return true
}
