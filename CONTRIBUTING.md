# Contribuir a SYSdiag

Gracias por contribuir a SYSdiag.

## Principios no negociables

- SYSdiag es read-only.
- Dato, interpretación, hipótesis y evidencia deben mantenerse separados.
- Un síntoma no debe convertirse en causa sin pruebas discriminantes.
- Las capas Host Linux → runtime → contenedor → Kubernetes/OpenShift → aplicación se mantienen separadas.
- La ausencia de datos no equivale a estado saludable.
- Todo cambio funcional debe añadir o actualizar regresiones.

## Preparar el entorno

Consulta `COMPILACION.md` y usa exactamente la versión indicada en `.go-version`.

```bash
make test-go
make lint
make release-check
```

## Pull requests

Incluye:

1. Problema que resuelve el cambio.
2. Evidencia o caso reproducible.
3. Impacto en read-only/seguridad.
4. Tests añadidos o modificados.
5. Compatibilidad con JSON/schema cuando aplique.

No incluyas credenciales, logs privados, kubeconfigs reales ni datos identificativos en tests o issues.
