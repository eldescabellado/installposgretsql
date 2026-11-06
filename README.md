# Instalador de PostgreSQL 18 para CentOS Stream 10 / RHEL 10

Script único `install-postgres18.sh`. Instalación nativa (dnf + systemd), sin Docker ni Podman.
Pensado para servidores donde **ya corre otro sistema**: no borra ni sobrescribe nada existente.

Incluye (opcional): observabilidad (postgres_exporter + Prometheus + Grafana) y pgAdmin 4 web.
Apertura de puertos del firewall configurable.

## Requisitos
- Ejecutar como root (`sudo`).
- **Conexión a internet** en el servidor: usa los repositorios de PostgreSQL (PGDG), Grafana y
  GitHub (exporter y Prometheus). No funciona sin conexión.

## Uso desde una memoria USB

1. Conecte la USB y ubíquela:
   ```bash
   lsblk -f
   ```
2. Móntela (si el sistema no la montó solo; ajuste `sdb1` a lo que muestre `lsblk`):
   ```bash
   sudo mkdir -p /mnt/usb
   sudo mount /dev/sdb1 /mnt/usb
   ```
3. Ejecute **con `bash`** (las USB en FAT32/exFAT no guardan el permiso de ejecución
   y a veces se montan con `noexec`, así que `./script` fallaría):
   ```bash
   sudo bash /mnt/usb/postgres18-installer/install-postgres18.sh --dry-run   # simulacion
   sudo bash /mnt/usb/postgres18-installer/install-postgres18.sh --all --open-all
   ```
   Si prefiere copiarlo al servidor:
   ```bash
   sudo cp /mnt/usb/postgres18-installer/install-postgres18.sh /root/
   sudo bash /root/install-postgres18.sh --help
   ```
4. Al terminar: `sudo umount /mnt/usb`

### Si da el error `$'\r': command not found`
El archivo se guardó con saltos de línea de Windows. Corrija con:
```bash
sed 's/\r$//' /mnt/usb/postgres18-installer/install-postgres18.sh > /root/install-postgres18.sh
sudo bash /root/install-postgres18.sh --help
```

## Clave de administración
Por defecto es `Jema2026#` (postgres si el cluster es nuevo, pgAdmin y Grafana si se instalan nuevos).
- En una terminal interactiva el script **pregunta**: Enter = clave por defecto, o escriba otra (mínimo 8 caracteres).
- Sin preguntas: `--yes` (usa la por defecto) o `--password 'OtraClave'`.
- Sin dejarla en el historial del shell: `sudo ADMIN_PASSWORD='OtraClave' bash install-postgres18.sh ...`

Las claves quedan guardadas en `/root/.postgres18-credentials` (solo root). Si el cluster
ya existía, **no se cambia** la clave de `postgres`.

## Ejemplos
```bash
# Solo PostgreSQL, local
sudo bash install-postgres18.sh

# Todo, puerto 5433, acceso remoto solo desde la red local, puertos abiertos en firewall
sudo bash install-postgres18.sh --all --pg-port 5433 --listen '*' \
     --allow-cidr 192.168.1.0/24 --open-all

# Puertos adicionales
sudo bash install-postgres18.sh --extra-ports 8080,9000
```
Todas las opciones: `bash install-postgres18.sh --help`

## Verificación
```bash
systemctl status postgresql-18
sudo -u postgres /usr/pgsql-18/bin/psql -p 5432 -c "select version();"
# Grafana:  http://IP:3000      pgAdmin: http://IP:5050/pgadmin4
```

## Registro y respaldo
- Log: `/var/log/install-postgres18-*.log`
- Estado previo del servidor: `/root/preinstall-snapshot-*`
- Respaldos de cada archivo de configuración modificado: `*.bak-<fecha>`

## En el repositorio
`.gitattributes` fuerza finales de línea LF para evitar el problema de `\r`.
Para que el repo conserve el permiso de ejecución:
```bash
git add --chmod=+x install-postgres18.sh
```
