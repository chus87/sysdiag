package app

import (
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"

	"github.com/chus87/sysdiag/internal/model"
)

func TestWriteSecureCreates0600AndReplacesAtomically(t *testing.T) {
	d := t.TempDir()
	p := filepath.Join(d, "report.txt")
	if err := os.WriteFile(p, []byte("old"), 0644); err != nil {
		t.Fatal(err)
	}
	err := writeSecure(p, func(f *os.File) error {
		_, e := f.WriteString("new report\n")
		return e
	})
	if err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(p)
	if string(b) != "new report\n" {
		t.Fatalf("contenido inesperado: %q", b)
	}
	st, err := os.Stat(p)
	if err != nil {
		t.Fatal(err)
	}
	if st.Mode().Perm() != 0600 {
		t.Fatalf("modo inseguro: %o", st.Mode().Perm())
	}
	matches, _ := filepath.Glob(filepath.Join(d, ".sysdiag-report-*"))
	if len(matches) != 0 {
		t.Fatalf("temporales no limpiados: %v", matches)
	}
}

func TestWriteSecureRejectsSymlinkAndFIFO(t *testing.T) {
	d := t.TempDir()
	target := filepath.Join(d, "target")
	link := filepath.Join(d, "link")
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}
	if err := writeSecure(link, func(*os.File) error { return nil }); err == nil || !strings.Contains(err.Error(), "enlace simbólico") {
		t.Fatalf("symlink no rechazado: %v", err)
	}
	fifo := filepath.Join(d, "fifo")
	if err := syscall.Mkfifo(fifo, 0600); err != nil {
		t.Fatal(err)
	}
	if err := writeSecure(fifo, func(*os.File) error { return nil }); err == nil || !strings.Contains(err.Error(), "fichero regular") {
		t.Fatalf("FIFO no rechazado: %v", err)
	}
}

func TestResolveReportSanitizesHost(t *testing.T) {
	r := model.Report{Host: "../worker/03 test\n\x1b[31m"}
	p := resolveReport("AUTO", r, "json")
	if strings.Contains(p, "worker/03") || !strings.Contains(p, "worker_03_test_31m") {
		t.Fatalf("nombre no saneado: %s", p)
	}
}

func TestRequestsAll(t *testing.T) {
	if !requestsAll([]string{"--all"}) || !requestsAll([]string{"--summary"}) || requestsAll([]string{"--section", "memory"}) {
		t.Fatal("detección all incorrecta")
	}
}
