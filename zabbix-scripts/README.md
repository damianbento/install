# Despliegue remoto de Zabbix Agent 2

Ejecutar desde el servidor Zabbix.

```bash
chmod +x deploy-zabbix-agent2.sh
sudo ./deploy-zabbix-agent2.sh \
  --hosts ubuntu-hosts.txt \
  --user dami \
  --identity /root/.ssh/id_ed25519
```

Requisitos remotos: Ubuntu 20.04/22.04/24.04/26.04, acceso SSH por clave, usuario root o sudo sin contraseña, salida HTTPS hacia repo.zabbix.com y conexión TCP al ServerActive configurado.
