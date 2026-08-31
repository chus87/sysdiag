## Qué cambia

Describe el cambio y su motivo.

## Evidencia / troubleshooting

Explica qué dato nuevo se recoge, cómo se interpreta y qué hipótesis puede discriminar.

## Seguridad read-only

- [ ] No ejecuta acciones correctivas ni mutantes.
- [ ] No introduce credenciales en argv/logs/informes.
- [ ] La ausencia de información no se presenta como estado saludable.
- [ ] Se mantienen separadas las capas Linux → runtime → contenedor → Kubernetes/OpenShift → aplicación.

## Validación

- [ ] `make test`
- [ ] `make test-race`
- [ ] `make lint`
- [ ] `make vuln-check`
- [ ] `make release-check` (cuando aplique)
- [ ] Tests nuevos o regresiones para el cambio.
