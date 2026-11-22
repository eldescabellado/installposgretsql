# Instalador de PostgreSQL 18 (CentOS/RHEL 10 y Ubuntu/Debian)

| Sistema | Script | Instalación |
|---|---|---|
| CentOS Stream 10 / RHEL 10 / Rocky / Alma 10 | `install-postgres18.sh` | dnf + systemd |
| Ubuntu 22.04 / 24.04 / 26.04, Debian 12 / 13 | `install-postgres18-ubuntu.sh` | apt + systemd |

Los dos instalan lo mismo y aceptan **las mismas opciones**. Instalación nativa, sin Docker ni Podman.
Pensado para servidores donde **ya corre otro sistema**: no borra ni sobrescribe nada existente.

Configura en un solo paso: **puerto**, **acceso remoto** (listen_addresses, pg_hba.conf con SSL y
firewall), **rendimiento** según la RAM y CPU del servidor, y el **usuario `jema`** para la aplicación
con permisos sobre sus bases (nuevas o ya existentes).
Opcional: observabilidad (postgres_exporter + Prometheus + Grafana) y pgAdmin 4 web.

## Requisitos
- Ejecutar como root (`sudo`).
- **Conexión a internet** en el servidor: usa los repositorios de PostgreSQL (PGDG), Grafana y
  GitHub (exporter y Prometheus). No funciona sin conexión.

## Instalar clonando el repositorio

**Ubuntu / Debian**
```bash
sudo apt-get update && sudo apt-get install -y git
git clone https://github.com/eldescabellado/installposgretsql.git
cd installposgretsql
sudo bash install-postgres18-ubuntu.sh
```

**CentOS / RHEL / Rocky / Alma 10**
```bash
sudo dnf install -y git
git clone https://github.com/eldescabellado/installposgretsql.git
cd installposgretsql
sudo bash install-postgres18.sh
```

Sin opciones, el instalador **pregunta**: puerto, si permite conexiones remotas, qué IPs, las bases
del usuario `jema` y la clave.
Para actualizar el repositorio más adelante: `cd installposgretsql && git pull`.

## Instalación con un solo comando (sin clonar)

Detecta si el servidor es Ubuntu/Debian o CentOS/RHEL, descarga el script que corresponde y lo ejecuta:
```bash
curl -fsSL https://raw.githubusercontent.com/eldescabellado/installposgretsql/main/instalar.sh | sudo bash
```
Con opciones (todo lo que va después de `bash -s --` se pasa al instalador):
```bash
curl -fsSL https://raw.githubusercontent.com/eldescabellado/installposgretsql/main/instalar.sh | sudo bash -s -- --all --open-all
```
Para revisar el script antes de ejecutarlo (lo deja en `/root`):
```bash
curl -fsSL https://raw.githubusercontent.com/eldescabellado/installposgretsql/main/instalar.sh | sudo bash -s -- --solo-descargar
```
- La pregunta de la clave funciona igual: se lee del teclado aunque el script venga por `curl |`.
- `--ref RAMA_O_TAG` usa otra rama o versión del repositorio (por defecto `main`).
- Si no hay `curl` usa `wget`: `wget -qO- .../instalar.sh | sudo bash`

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

## Puerto y acceso remoto a la base de datos

`--remote` hace todo lo necesario para conectarse desde otras PC o servidores:
- `listen_addresses = '*'` (en `conf.d/91-escucha.conf`).
- Reglas en `pg_hba.conf` dentro de un bloque propio `BEGIN/END install-postgres18`, que se
  reemplaza completo al reconfigurar. Exigen **SSL** (`hostssl`) y clave (`scram-sha-256`).
- **SSL**: Ubuntu ya lo trae activo; en CentOS se genera un certificado autofirmado.
- Apertura del puerto en el firewall (ufw o firewalld), solo para las IPs permitidas.

```bash
# Puerto 5433, acceso solo desde dos origenes, usuario jema con la base del ERP
sudo bash install-postgres18-ubuntu.sh --pg-port 5433 --remote --allow-cidr 190.1.2.3,10.0.0.0/24 \
     --app-db erp_db_biovenezuela --block-postgres-remote

# Desde cualquier IP (se recomienda una clave propia: la por defecto es publica)
sudo ADMIN_PASSWORD='ClaveLarga2026!' bash install-postgres18.sh --remote
```

| Opción | Qué hace |
|---|---|
| `--pg-port N` | Puerto de PostgreSQL (def. 5432) |
| `--remote` | Activa el acceso remoto completo |
| `--allow-cidr LISTA` | IPs o redes permitidas, separadas por coma. Sin lista: cualquier IP |
| `--no-ssl-required` | Permite conexiones remotas sin cifrar (`host` en vez de `hostssl`) |
| `--block-postgres-remote` | El superusuario `postgres` solo entra desde el propio servidor |
| `--enable-firewall` | Si ufw/firewalld está inactivo, lo activa (permitiendo antes SSH) |
| `--local-only` | Solo conexiones locales, sin preguntar |

Al final, el resumen muestra la cadena de conexión para su aplicación
(`host=... port=... dbname=... user=... sslmode=require`).

> Si su proveedor de VPS tiene un firewall propio en su panel web, abra también allí el puerto.

### Servidor que ya tiene PostgreSQL instalado
Si el cluster ya existe, el instalador **no lo toca** salvo que use `--configure-existing`
(o responda "s" cuando pregunta). En ese caso:
1. Respalda cada archivo que cambia (`*.bak-<fecha>`).
2. Escribe los ajustes en `conf.d/` y en el bloque propio de `pg_hba.conf`.
3. Reinicia PostgreSQL. **Si no arranca, revierte todo solo** y lo deja como estaba.

```bash
sudo bash install-postgres18-ubuntu.sh --configure-existing --remote --allow-cidr 190.1.2.3
sudo bash install-postgres18-ubuntu.sh --configure-existing --pg-port 5433     # cambiar el puerto
```
Al reconfigurar, el bloque de `pg_hba.conf` se genera de nuevo con las opciones de **esa**
ejecución: repita `--allow-cidr` y `--block-postgres-remote` si los usaba.

## Usuario de la aplicación (`jema`)
El instalador siempre crea el usuario **`jema`** con la **clave de administración** (`Jema2026#` si no
la cambia), para que la aplicación no use el superusuario `postgres`. Los nombres van siempre en
minúsculas: si escribe `JEMA` o `ERP_DB`, se pasan a minúsculas.

| Opción | Qué hace |
|---|---|
| `--app-db LISTA` | Bases del usuario, separadas por coma (def. `jema`; si no se indica, pregunta) |
| `--app-owner` | En bases existentes, además le traspasa la propiedad (base, esquemas, tablas, vistas, secuencias, funciones y tipos) |
| `--app-user NOMBRE` | Otro nombre de usuario en vez de `jema` |
| `--app-password CLAVE` | Otra clave para el usuario (o variable `APP_PASSWORD`) |
| `--no-app-user` | No crea el usuario |

- **Base nueva**: se crea con `jema` como dueño.
- **Base existente** (por ejemplo la de su ERP): `jema` recibe permisos completos en todos los esquemas
  sobre tablas, secuencias y funciones, también sobre las que se creen después. Con eso puede leer,
  insertar, modificar y crear tablas. Para **modificar la estructura de las tablas existentes**
  (`ALTER TABLE`, por ejemplo al actualizar el ERP) use `--app-owner`.
- Si `jema` ya existe, se conserva su clave salvo que indique `--app-password`.

```bash
# Servidor que ya tiene la base del ERP
sudo bash install-postgres18-ubuntu.sh --configure-existing --app-db erp_db_biovenezuela --app-owner
```

En la aplicación: `User_Name=jema`, `Password=` la clave de administración (está en
`/root/.postgres18-credentials`).

## Rendimiento
En un cluster nuevo se ajustan memoria y paralelismo según la RAM y los CPU
(`conf.d/80-rendimiento.conf`): `shared_buffers` 25 % de la RAM, `effective_cache_size` 75 %,
`work_mem`, `maintenance_work_mem`, parámetros de WAL y valores para discos SSD.

| Opción | Qué hace |
|---|---|
| `--no-tune` | No ajusta nada |
| `--tune` | Ajusta también un cluster existente (con `--configure-existing`) |
| `--max-connections N` | Conexiones máximas (def. 100) |
| `--ram-mb N` | RAM a considerar, si el servidor la comparte con otro sistema |
| `--no-pg-stat-statements` | No activa las estadísticas de consultas |

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
sudo bash install-postgres18.sh --all --pg-port 5433 --remote \
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
