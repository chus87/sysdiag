# Integración en VMs systemd

Esta matriz valida SYSdiag sobre **systemd real como PID 1**, separada de los tests rápidos con mocks.

Requisitos del host: Vagrant, libvirt/KVM y el plugin `vagrant-libvirt`.

```bash
cd tests/vm
vagrant up ubuntu2404 --provider=libvirt
vagrant ssh ubuntu2404 -c 'sudo /opt/sysdiag/tests/integration/systemd_live.sh /opt/sysdiag'
vagrant destroy -f ubuntu2404
```

VMs definidas: `ubuntu2404`, `debian12`, `rocky9`, `alma9`. Los boxes pueden sobrescribirse con `SYSDIAG_BOX_UBUNTU`, `SYSDIAG_BOX_DEBIAN`, `SYSDIAG_BOX_ROCKY` y `SYSDIAG_BOX_ALMA`.

El test live crea **solo dentro de la VM desechable** dos units temporales para comprobar `failed`/restart-loop, ejecuta SYSdiag y las elimina mediante `trap`. SYSdiag en sí sigue siendo read-only.
