package main

import (
	"bufio"
	"context"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/chus87/sysdiag/internal/app"
	"github.com/chus87/sysdiag/internal/version"
)

func main() {
	raw := normalizeArgs(os.Args[1:])
	fs := flag.NewFlagSet(programName(), flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	var jsonOut, summary, verbose, explain, all, ver, menu, noColor, noAuth bool
	var section, containerMode, k8sMode, k8sNode, k8sNS, k8sPod, k8sCtx, kubeconfig, report, colorMode string
	var sample int
	var timeout time.Duration
	fs.BoolVar(&jsonOut, "json", false, "")
	fs.BoolVar(&summary, "summary", false, "")
	fs.BoolVar(&verbose, "verbose", false, "")
	fs.BoolVar(&explain, "explain", false, "")
	fs.BoolVar(&all, "all", false, "")
	fs.BoolVar(&menu, "menu", false, "")
	fs.BoolVar(&noColor, "no-color", false, "")
	fs.BoolVar(&ver, "version", false, "")
	fs.StringVar(&section, "section", "", "")
	fs.StringVar(&containerMode, "container-mode", "", "")
	fs.StringVar(&k8sMode, "k8s-mode", "", "")
	fs.StringVar(&k8sNode, "k8s-node", "", "")
	fs.StringVar(&k8sNS, "k8s-namespace", "", "")
	fs.StringVar(&k8sPod, "k8s-pod", "", "")
	fs.StringVar(&k8sCtx, "k8s-context", "", "")
	fs.StringVar(&kubeconfig, "k8s-kubeconfig", "", "")
	fs.StringVar(&report, "report", "", "")
	fs.StringVar(&colorMode, "color", "auto", "")
	fs.IntVar(&sample, "sample", 1, "")
	fs.BoolVar(&noAuth, "k8s-no-auth-prompt", false, "")
	fs.DurationVar(&timeout, "timeout", 30*time.Minute, "")
	containersDeep := fs.Bool("containers-deep", false, "")
	recent := fs.Bool("recent-errors", false, "")
	guide := fs.Bool("guide", false, "")
	fs.Usage = usage
	if err := fs.Parse(raw); err != nil {
		if err == flag.ErrHelp {
			return
		}
		os.Exit(2)
	}
	if ver {
		printVersion()
		return
	}
	if timeout < time.Second || timeout > 24*time.Hour {
		fatal2("--timeout debe estar entre 1s y 24h")
	}
	if noColor {
		colorMode = "never"
	}
	if colorMode != "auto" && colorMode != "always" && colorMode != "never" {
		fatal2("--color admite auto, always o never")
	}
	if jsonOut && (*guide || section == "guide") {
		fatal2("la guía no es compatible con --json")
	}
	if jsonOut && menu {
		fatal2("--menu no es compatible con --json")
	}
	if section == "guide" {
		*guide = true
	}

	interactive := menu || (len(os.Args) == 1 && isTTY(os.Stdin) && isTTY(os.Stdout))
	args := []string{}
	if interactive {
		choice, cm, g, err := showMenu(colorEnabled(colorMode, false))
		if err != nil {
			fmt.Fprintln(os.Stderr, "ERROR:", err)
			os.Exit(1)
		}
		if choice == "exit" {
			return
		}
		if g {
			*guide = true
		} else if choice == "summary" {
			summary = true
			args = append(args, "--all")
		} else if choice == "all" {
			args = append(args, "--all")
		} else {
			args = append(args, "--internal-sections", choice)
		}
		if cm != "" {
			containerMode = cm
		}
	} else if summary {
		args = append(args, "--all")
	} else if *guide {
	} else if *recent {
		args = append(args, "--section", "recent")
	} else if *containersDeep {
		args = append(args, "--section", "containers")
		containerMode = "deep"
	} else if all || section == "" || section == "all" {
		args = append(args, "--all")
	} else {
		args = append(args, "--section", section)
	}
	if containerMode != "" {
		if containerMode != "normal" && containerMode != "deep" {
			fatal2("--container-mode admite normal o deep")
		}
		args = append(args, "--container-mode", containerMode)
	}
	if k8sMode != "" {
		if k8sMode != "quick" && k8sMode != "deep" && k8sMode != "exhaustive" {
			fatal2("--k8s-mode admite quick, deep o exhaustive")
		}
		args = append(args, "--k8s-mode", k8sMode)
	}
	if k8sNode != "" {
		args = append(args, "--k8s-node", k8sNode)
	}
	if k8sNS != "" {
		args = append(args, "--k8s-namespace", k8sNS)
	}
	if k8sPod != "" {
		if !strings.Contains(k8sPod, "/") {
			fatal2("--k8s-pod requiere namespace/pod")
		}
		args = append(args, "--k8s-pod", k8sPod)
	}
	if k8sCtx != "" {
		args = append(args, "--k8s-context", k8sCtx)
	}
	if kubeconfig != "" {
		args = append(args, "--k8s-kubeconfig", kubeconfig)
	}
	if noAuth {
		args = append(args, "--k8s-no-auth-prompt")
	}
	if sample < 1 || sample > 30 {
		fatal2("--sample debe estar entre 1 y 30")
	}
	if sample != 1 {
		args = append(args, "--sample", strconv.Itoa(sample))
	}
	if verbose {
		args = append(args, "--verbose")
	}
	if explain {
		args = append(args, "--explain")
	}
	if *guide {
		args = nil
	}

	baseCtx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	ctx, cancel := context.WithTimeout(baseCtx, timeout)
	defer cancel()
	color := colorEnabled(colorMode, jsonOut)
	err := app.App{}.Run(ctx, app.Options{JSON: jsonOut, Summary: summary, Verbose: verbose, Explain: explain, Guide: *guide, Color: color, Report: report, LegacyArgs: args})
	if err != nil {
		if ctx.Err() != nil {
			fmt.Fprintln(os.Stderr, "ERROR: diagnóstico cancelado:", ctx.Err())
			os.Exit(130)
		}
		fmt.Fprintln(os.Stderr, "ERROR:", err)
		os.Exit(1)
	}
}

func showMenu(color bool) (choice, containerMode string, guide bool, err error) {
	cyan, bold, reset := "", "", ""
	if color {
		cyan = "\x1b[36m"
		bold = "\x1b[1m"
		reset = "\x1b[0m"
	}
	r := bufio.NewReader(os.Stdin)
	for {
		fmt.Printf("\n%s%sSYSdiag — ¿Qué quieres analizar?%s\n\n", bold, cyan, reset)
		fmt.Print("  1) Resumen general\n  2) CPU y procesos\n  3) Memoria\n  4) I/O y almacenamiento\n  5) Filesystems\n  6) Red\n  7) Logs / journald\n  8) Warnings y errores recientes\n  9) Systemd / servicios\n 10) Boot / arranque\n 11) Contenedores / runtime\n 12) Kubernetes / OpenShift\n 13) Guía de diagnóstico y comandos\n 14) Diagnóstico completo\n\n  0/q) Salir\n\nPuedes combinar secciones, por ejemplo: 4,6,8\nTambién puedes salir con q, quit, salir o exit.\nSelecciona una opción: ")
		line, e := r.ReadString('\n')
		if e != nil && strings.TrimSpace(line) == "" {
			return "", "", false, e
		}
		parts := strings.Fields(strings.ReplaceAll(strings.TrimSpace(line), ",", " "))
		if len(parts) == 0 {
			continue
		}
		selected := map[string]bool{}
		special := ""
		valid := true
		for _, rawPart := range parts {
			x := strings.ToLower(rawPart)
			switch x {
			case "0", "q", "quit", "salir", "exit":
				special = "exit"
			case "1":
				special = "summary"
			case "2":
				selected["cpu"] = true
				selected["processes"] = true
			case "3":
				selected["memory"] = true
			case "4":
				selected["io"] = true
			case "5":
				selected["filesystem"] = true
			case "6":
				selected["network"] = true
			case "7":
				selected["logging"] = true
			case "8":
				selected["recent"] = true
			case "9":
				selected["systemd"] = true
			case "10":
				selected["boot"] = true
			case "11":
				selected["containers"] = true
			case "12":
				selected["kubernetes"] = true
			case "13":
				special = "guide"
			case "14":
				special = "all"
			default:
				valid = false
			}
		}
		if !valid {
			fmt.Println("Selección no válida.")
			continue
		}
		if special != "" && len(parts) != 1 {
			fmt.Println("Las opciones de salida, 1, 13 y 14 deben elegirse solas.")
			continue
		}
		if special == "exit" || special == "summary" || special == "all" {
			return special, "", false, nil
		}
		if special == "guide" {
			return "", "", true, nil
		}
		order := []string{"cpu", "processes", "memory", "io", "filesystem", "network", "logging", "recent", "systemd", "boot", "containers", "kubernetes"}
		out := []string{}
		for _, x := range order {
			if selected[x] {
				out = append(out, x)
			}
		}
		if len(out) == 0 {
			continue
		}
		cm := ""
		if selected["containers"] {
			fmt.Print("\nModo de contenedores: 1) Normal  2) Profundo [1]: ")
			v, _ := r.ReadString('\n')
			if strings.TrimSpace(v) == "2" {
				cm = "deep"
			} else {
				cm = "normal"
			}
		}
		return strings.Join(out, ","), cm, false, nil
	}
}

func colorEnabled(mode string, jsonOut bool) bool {
	if jsonOut || os.Getenv("NO_COLOR") != "" || mode == "never" {
		return false
	}
	if mode == "always" {
		return true
	}
	return isTTY(os.Stdout)
}
func printVersion() {
	b := version.BuildInfo()
	fmt.Printf("SYSdiag %s\nAutor: %s\nLicencia: %s\nEngine: %s\nSchema: %s\nGo: %s\nTarget: %s\nCommit: %s\nTag: %s\nBuild date: %s\nCollector SHA256: %s\n", version.Version, version.Author, version.License, version.Engine, version.SchemaVersion, b.GoVersion, b.Target, b.Commit, b.Tag, b.BuildDate, b.CollectorSHA256)
}
func normalizeArgs(in []string) []string {
	out := make([]string, 0, len(in)+1)
	for i := 0; i < len(in); i++ {
		if in[i] == "--report" && (i+1 == len(in) || strings.HasPrefix(in[i+1], "--")) {
			out = append(out, "--report=AUTO")
			continue
		}
		out = append(out, in[i])
	}
	return out
}
func isTTY(f *os.File) bool {
	st, err := f.Stat()
	return err == nil && st.Mode()&os.ModeCharDevice != 0
}
func fatal2(s string) { fmt.Fprintln(os.Stderr, "ERROR:", s); os.Exit(2) }
func programName() string {
	name := filepath.Base(os.Args[0])
	if name == "" || name == "." || name == string(filepath.Separator) {
		return "sysdiag"
	}
	return name
}
func usage() {
	fmt.Printf(`SYSdiag %s — diagnóstico read-only con núcleo Go
Autor: Chus (GitHub: chus87)

Uso:
  %s [opciones]

Opciones:
  --summary                     Resumen priorizado del diagnóstico completo.
  --all                         Diagnóstico completo sin menú.
  --section <nombre>            system, cpu, processes, memory, io, filesystem,
                                network, logging, recent, systemd, boot,
                                containers, kubernetes, guide, all.
  --verbose                     Añade IDs, dominios y metadata de collectors.
  --explain                     Muestra evidencia y verificaciones discriminantes.
  --container-mode normal|deep  Análisis normal o profundo de contenedores/logs.
  --containers-deep             Atajo para contenedores en modo deep.
  --k8s-mode quick|deep|exhaustive
  --k8s-node <nodo> | --k8s-namespace <ns> | --k8s-pod <ns/pod>
  --k8s-context <ctx> | --k8s-kubeconfig <f> | --k8s-no-auth-prompt
  --recent-errors               Warnings/errores recientes.
  --guide                       Guía técnica read-only.
  --json                        JSON estructurado schema %s.
  --report [fichero]            Guarda informe 0600 sin ANSI.
  --sample <1-30>               Ventana de muestreo base.
  --timeout <duración>          Límite global (defecto 30m).
  --color auto|always|never     Color semántico (defecto auto).
  --no-color                    Alias de --color never.
  --menu                        Menú interactivo.
  --version                     Build/provenance de SYSdiag.
  -h, --help                    Ayuda.

Seguridad:
  El núcleo Go sólo ejecuta el collector Bash embebido y auditado, mediante
  /bin/bash, entorno saneado, política read-only y grupo de procesos aislado.
`, version.Version, programName(), version.SchemaVersion)
}
