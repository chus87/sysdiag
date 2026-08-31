# Modelo de seguridad de SYSdiag

SYSdiag está diseñado como herramienta de diagnóstico **read-only**. Su objetivo es observar y correlacionar estado; nunca aplicar automáticamente una corrección sobre el host, runtime o cluster.

## Qué significa read-only

Durante un diagnóstico SYSdiag no debe ejecutar operaciones como:

- matar procesos o reiniciar/parar/iniciar servicios;
- montar/desmontar filesystems, cambiar `sysctl` o modificar firewall/rutas;
- crear, borrar, reiniciar o modificar contenedores/imágenes/volúmenes;
- ejecutar `prune`;
- crear, editar, parchear, borrar, escalar, drenar o depurar recursos Kubernetes/OpenShift;
- instalar paquetes.

Las recomendaciones pueden contener comandos mutantes para intervención manual. En la salida estructurada se clasifican como `mutating`; SYSdiag no los ejecuta.

## Fronteras de ejecución

El binario Go sólo ejecuta el collector Bash embebido mediante un gateway controlado. El backend:

1. se materializa en un directorio temporal privado;
2. se escribe con permisos restrictivos;
3. se verifica mediante SHA-256;
4. se ejecuta explícitamente con `/bin/bash`;
5. recibe un entorno saneado;
6. utiliza guards read-only para los wrappers de comandos externos y pipelines internas.

El binario no descubre ni ejecuta automáticamente un `sysdiag-legacy.sh` desde el directorio actual.

`SIGINT`, `SIGTERM` y los timeouts terminan el grupo de procesos del collector para evitar descendientes huérfanos.

## Ejecución con privilegios

Cuando SYSdiag corre con euid 0 utiliza un PATH fijo salvo un `SYSDIAG_TRUSTED_PATH` que cumpla las comprobaciones de propiedad/permisos. No hereda hooks como `BASH_ENV` o `ENV`, funciones de shell exportadas ni el HOME/XDG runtime de otro usuario.

Un `KUBECONFIG` heredado por entorno sólo se conserva con euid 0 si todos sus ficheros son regulares, pertenecen a root y no son escribibles por grupo/otros. Esto evita que una elevación mediante `sudo -E` convierta implícitamente un kubeconfig controlado por otro usuario en código ejecutable privilegiado.

Un fichero indicado explícitamente con `--k8s-kubeconfig` es una decisión del administrador. Debe considerarse **código/configuración de confianza**: Kubernetes permite mecanismos de autenticación `exec`, capaces de lanzar programas locales con los privilegios de SYSdiag. Si no se confía plenamente en ese kubeconfig, no debe usarse con SYSdiag ejecutándose como root.

## Credenciales Kubernetes/OpenShift

SYSdiag no modifica `~/.kube/config`. Los tokens introducidos interactivamente se almacenan sólo en un kubeconfig temporal `0600`, eliminado al finalizar. En OpenShift con usuario/contraseña, `oc` solicita la contraseña directamente; SYSdiag no la lee ni la coloca en `argv`.

La autenticación puede modificar únicamente ese material temporal local. No crea recursos en el cluster.

## Informes y logs

Los informes pueden contener información sensible operacional: hostnames, nombres de procesos/Pods, rutas, mensajes de error, topología y muestras de logs. Se crean con permisos `0600`, mediante escritura temporal y reemplazo atómico. Se rechazan destinos symlink y ficheros especiales.

El análisis profundo de logs redacta patrones frecuentes de credenciales (`password`, `token`, `Authorization/Bearer`, `api_key`, `secret`), pero la redacción automática no puede garantizar detectar todos los formatos posibles. Los informes deben protegerse como información técnica sensible.

## Coste de observación

Read-only no significa coste cero. Un diagnóstico exhaustivo puede realizar numerosas lecturas de API, filesystem y logs. SYSdiag limita concurrencia/timeouts y toma primero el baseline del host antes de operaciones costosas cuando éstas podrían contaminar la muestra, pero un análisis exhaustivo debe tratarse como una operación de observabilidad deliberada.

## Defensa en profundidad y validación

La garantía se protege mediante:

- política del gateway Go;
- guards read-only del collector Bash;
- tests unitarios de seguridad/cancelación;
- pruebas adversariales de CWD, entorno y PATH;
- mocks que fallan si se invocan familias mutantes;
- análisis estático/ShellCheck en CI;
- integridad del collector embebido y checksums de release;
- validación de paquetes ya extraídos.

Ninguna heurística sustituye una revisión de código. Cualquier nueva familia de comandos externos debe incorporarse explícitamente a estas barreras y a su regresión correspondiente.
