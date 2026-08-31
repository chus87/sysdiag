package executor

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestSafeEnvironmentDropsShellInjection(t *testing.T) {
	t.Setenv("BASH_ENV", "/tmp/evil")
	t.Setenv("ENV", "/tmp/evil2")
	t.Setenv("PATH", ".:/tmp:/usr/bin")
	env := SafeEnvironment()
	joined := strings.Join(env, "\n")
	if strings.Contains(joined, "BASH_ENV=") || strings.Contains(joined, "ENV=") {
		t.Fatal("se heredó entorno de inicialización de shell")
	}
	for _, e := range env {
		if strings.HasPrefix(e, "PATH=") && strings.Contains(e, "PATH=.") {
			t.Fatal("PATH relativo no saneado")
		}
	}
}

func TestSafeEnvironmentRejectsPathOverrides(t *testing.T) {
	t.Setenv("K8S_CLI_OVERRIDE", "/tmp/evil-kubectl")
	t.Setenv("SYSDIAG_TRUSTED_PATH", "/tmp:/usr/bin")
	env := strings.Join(SafeEnvironment(), "\n")
	if strings.Contains(env, "K8S_CLI_OVERRIDE=") {
		t.Fatal("se aceptó K8S_CLI_OVERRIDE con ruta")
	}
	if strings.Contains(env, "PATH=/tmp:") {
		t.Fatal("se aceptó un PATH confiable con directorio escribible")
	}
}

func TestSafeEnvironmentAcceptsCommandNameOverride(t *testing.T) {
	t.Setenv("K8S_CLI_OVERRIDE", "kubectl-test")
	env := strings.Join(SafeEnvironment(), "\n")
	if !strings.Contains(env, "K8S_CLI_OVERRIDE=kubectl-test") {
		t.Fatal("se rechazó un nombre de comando seguro")
	}
}

func TestRootDoesNotInheritUnsafeKubeconfig(t *testing.T) {
	if os.Geteuid() != 0 {
		t.Skip("la prueba requiere euid 0")
	}
	d := t.TempDir()
	k := filepath.Join(d, "config")
	if err := os.WriteFile(k, []byte("apiVersion: v1\n"), 0666); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(k, 0666); err != nil {
		t.Fatal(err)
	}
	t.Setenv("HOME", "/tmp/untrusted-home")
	t.Setenv("KUBECONFIG", k)
	env := strings.Join(SafeEnvironment(), "\n")
	if strings.Contains(env, "HOME=/tmp/untrusted-home") {
		t.Fatal("root heredó HOME del llamador")
	}
	if strings.Contains(env, "KUBECONFIG="+k) {
		t.Fatal("root heredó kubeconfig escribible")
	}
}

func TestCancellationKillsProcessGroup(t *testing.T) {
	d := t.TempDir()
	script := filepath.Join(d, "sysdiag-collector-test.sh")
	pidfile := filepath.Join(d, "child.pid")
	body := "#!/bin/bash\nsleep 30 &\necho $! > '" + pidfile + "'\nwait\n"
	if err := os.WriteFile(script, []byte(body), 0700); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 180*time.Millisecond)
	defer cancel()
	_, err := Run(ctx, Request{Mode: ModeCollector, Path: "/bin/bash", Args: []string{script}, Env: []string{"PATH=/usr/bin:/bin"}})
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("error inesperado: %v", err)
	}
	b, err := os.ReadFile(pidfile)
	if err != nil {
		t.Fatal(err)
	}
	pid, _ := strconv.Atoi(strings.TrimSpace(string(b)))
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		e := syscall.Kill(pid, 0)
		if errors.Is(e, syscall.ESRCH) {
			return
		}
		time.Sleep(25 * time.Millisecond)
	}
	t.Fatalf("el descendiente %d sigue vivo tras cancelar el collector", pid)
}

func TestExecutionPolicyIsMandatory(t *testing.T) {
	ctx := context.Background()
	_, err := Run(ctx, Request{Mode: ModeCollector, Path: "/usr/bin/env", Args: []string{"bash"}})
	if err == nil {
		t.Fatal("se ejecutó un intérprete no permitido")
	}
}
