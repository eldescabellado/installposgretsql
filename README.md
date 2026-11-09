# Instalador de PostgreSQL 18 (CentOS/RHEL 10 y Ubuntu/Debian)

| Sistema | Script | Instalación |
|---|---|---|
| CentOS Stream 10 / RHEL 10 / Rocky / Alma 10 | `install-postgres18.sh` | dnf + systemd |
| Ubuntu 22.04 / 24.04 / 26.04, Debian 12 / 13 | `install-postgres18-ubuntu.sh` | apt + systemd |

Los dos instalan lo mismo y aceptan **las mismas opciones**. Instalación nativa, sin Docker ni Podman.
Pensado para servidores donde **ya corre otro sistema**: no borra ni sobrescribe nada existente.

Incluye (opcional): observabilidad (postgres_exporter + Prometheus + Grafana) y pgAdmin 4 web.
Apertura de puertos del firewall configurable.

## Requisitos
- Ejecutar como root (`sudo`).
- **Conexión a internet** en el servidor: usa los repositorios de PostgreSQL (PGDG), Grafana y
  GitHub (exporter y Prometheus). No funciona sin conexión.

## Diferencias en Ubuntu / Debian

| | CentOS / RHEL | Ubuntu / Debian |
|---|---|---|
| Repositorio PostgreSQL | PGDG yum | `apt.postgresql.org` (llave de `postgresql-common`) |
| Datos | `/var/lib/pgsql/18/data` | `/var/lib/postgresql/18/main` |
| Configuración | `/var/lib/pgsql/18/data` | `/etc/postgresql/18/main` (+ `conf.d/90-install-script.conf`) |
| Binarios | `/usr/pgsql-18/bin` | `/usr/lib/postgresql/18/bin` |
| Servicio | `postgresql-18` | `postgresql@18-main` |
| Firewall | firewalld | ufw (o firewalld si es el que está activo) |
| pgAdmin web | httpd | apache2 |
| Grafana | repo rpm.grafana.com | repo apt.grafana.com |

Detalles propios del script de Ubuntu:
- Si el cluster `18/main` **no existía**, el paquete crea uno automático (puerto libre y locale del
  entorno, que puede quedar en `SQL_ASCII`); el script lo reemplaza por uno vacío con el puerto
  indicado, `UTF8`, checksums y `scram-sha-256`. Locale: el del sistema si es UTF-8, si no `C.UTF-8`
  (cámbielo con `--locale es_VE.UTF-8`, por ejemplo). Si el cluster **ya existía**, no se toca.
- Si un repositorio apt nuevo (PGDG, Grafana, pgAdmin) falla en `apt-get update`, se retira solo,
  para no dejar roto el `apt` del servidor.
- ufw: solo agrega reglas si está **activo**; nunca lo activa (podría cortar su SSH).

```bash
sudo bash install-postgres18-ubuntu.sh --dry-run
sudo bash install-postgres18-ubuntu.sh --all --open-all
```

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
   # En Ubuntu / Debian:
   sudo bash /mnt/usb/postgres18-installer/install-postgres18-ubuntu.sh --all --open-all
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
# CentOS / RHEL
systemctl status postgresql-18
sudo -u postgres /usr/pgsql-18/bin/psql -p 5432 -c "select version();"
# Ubuntu / Debian
systemctl status postgresql@18-main
pg_lsclusters
sudo -u postgres psql -p 5432 -c "select version();"
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
git add --chmod=+x install-postgres18.sh install-postgres18-ubuntu.sh
```
