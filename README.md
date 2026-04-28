# Supabase self-hosted installer (Ubuntu)

Script de un solo paso para levantar [Supabase](https://supabase.com) self-hosted en Ubuntu 22.04 o 24.04. Usa el `docker-compose.yml` oficial del repo `supabase/supabase`, genera todos los secretos automáticamente y configura un reverse proxy con SSL si le pasas un dominio.

**Repo:** https://github.com/doothemes/supabase-setup

---

## Instalación en una línea

Descarga, revisa y ejecuta:

```bash
curl -fsSL https://raw.githubusercontent.com/doothemes/supabase-setup/main/setup.sh -o setup.sh
chmod +x setup.sh
sudo ./setup.sh --domain supabase.midominio.com --email admin@midominio.com -y
```

O si confías ciegamente (pipe-to-bash, no recomendado en producción):

```bash
curl -fsSL https://raw.githubusercontent.com/doothemes/supabase-setup/main/setup.sh \
    | sudo bash -s -- --domain supabase.midominio.com --email admin@midominio.com -y
```

Para lab/sin dominio:

```bash
curl -fsSL https://raw.githubusercontent.com/doothemes/supabase-setup/main/setup.sh -o setup.sh
chmod +x setup.sh
sudo ./setup.sh --no-tls -y
```

[Ver `setup.sh` en el repo](https://github.com/doothemes/supabase-setup/blob/main/setup.sh) · [Reportar issue](https://github.com/doothemes/supabase-setup/issues)

---

## Tabla de contenidos

1. [Arquitectura del stack](#arquitectura-del-stack)
2. [Requisitos](#requisitos)
3. [Uso rápido](#uso-rápido)
4. [Flags del instalador](#flags-del-instalador)
5. [Qué hace el script paso a paso](#qué-hace-el-script-paso-a-paso)
6. [Archivos generados](#archivos-generados)
7. [Secretos generados — qué hace cada uno](#secretos-generados--qué-hace-cada-uno)
8. [Modelo de red y seguridad](#modelo-de-red-y-seguridad)
9. [Endpoints expuestos](#endpoints-expuestos)
10. [Operación día a día](#operación-día-a-día)
11. [Backup y restore](#backup-y-restore)
12. [Configurar SMTP para emails de Auth](#configurar-smtp-para-emails-de-auth)
13. [Acceso directo a Postgres](#acceso-directo-a-postgres)
14. [Actualizar Supabase](#actualizar-supabase)
15. [Troubleshooting](#troubleshooting)
16. [Desinstalación](#desinstalación)
17. [Limitaciones](#limitaciones)

---

## Arquitectura del stack

Supabase no es un único servicio — es una colección de microservicios open-source orquestados con Docker Compose alrededor de Postgres. El instalador levanta todos los siguientes contenedores:

| Servicio | Imagen | Rol |
|----------|--------|-----|
| **db** | `supabase/postgres` | Postgres extendido con `pgsodium`, `pg_graphql`, `pg_jsonschema`, `wrappers`, `pg_cron`, `pgvector`, etc. Es el corazón del stack — todos los demás servicios son fachadas sobre él. |
| **kong** | `kong` | API gateway. Único punto de entrada HTTP para los servicios. Aplica routing por path (`/auth/*`, `/rest/*`, ...) y valida el `apikey` (`anon` o `service_role`). |
| **auth** | `supabase/gotrue` | Servidor de autenticación (signup, login, OAuth, magic links, JWTs). Conocido upstream como GoTrue. |
| **rest** | `postgrest/postgrest` | PostgREST — convierte Postgres en una API REST automáticamente a partir de schemas y RLS. |
| **realtime** | `supabase/realtime` | Servidor Elixir de WebSockets que escucha el WAL (logical replication) de Postgres y empuja cambios en vivo a clientes suscritos. |
| **storage** | `supabase/storage-api` | API tipo S3 para archivos. Metadata en Postgres, bytes en disco (`volumes/storage/`). |
| **imgproxy** | `darthsim/imgproxy` | Transformación de imágenes on-the-fly (resize, crop) que Storage delega. |
| **studio** | `supabase/studio` | Dashboard web (Next.js). Es lo que ves en el navegador al entrar al dominio. |
| **meta** | `supabase/postgres-meta` | API REST para metadata de Postgres (tablas, columnas, roles). La consume Studio. |
| **functions** | `supabase/edge-runtime` | Runtime Deno para Edge Functions definidas en `volumes/functions/`. |
| **analytics** | `supabase/logflare` | Pipeline de logs (estructura los logs de cada servicio). |
| **vector** | `timberio/vector` | Recolector que envía logs de los contenedores a `analytics`. |
| **supavisor** | `supabase/supavisor` | Connection pooler para Postgres (transaction y session pooling, multi-tenant). Expuesto en `:6543`. |

Todo corre en una única red Docker bridge interna. Solo `kong` (HTTP API) y `studio` (dashboard) publican puertos al host. Postgres y los demás solo son accesibles por la red interna del stack.

```
                 ┌──────────────────────────────────────────────────────────────────┐
                 │                    docker network: supabase_default              │
                 │                                                                  │
   internet      │   ┌────────────┐  ┌──────────────┐  ┌────────────┐               │
   :443 ──→ Caddy │──→│   studio   │  │     kong     │←─│ rest, auth │               │
   (host)        │   │   :3000    │  │    :8000     │  │ realtime,  │               │
                 │   └────────────┘  └──────────────┘  │ storage,   │               │
                 │                          │          │ functions, │               │
                 │                          ↓          │ meta       │               │
                 │                   ┌────────────┐    └─────┬──────┘               │
                 │                   │     db     │←─────────┘                      │
                 │                   │  (postgres)│                                 │
                 │                   └─────┬──────┘                                 │
                 │                         │                                        │
                 │                   ┌─────┴──────┐  ┌────────────┐                 │
                 │                   │ supavisor  │  │  analytics │  vector ──┐     │
                 │                   │ pooler     │  │  logflare  │           │     │
                 │                   └────────────┘  └────────────┘ ←─────────┘     │
                 └──────────────────────────────────────────────────────────────────┘
```

---

## Requisitos

| Item | Mínimo | Recomendado |
|------|--------|-------------|
| Distribución | Ubuntu 22.04 o 24.04 | Ubuntu 24.04 LTS |
| RAM | 4 GB | 8 GB |
| vCPU | 2 | 4 |
| Disco | 20 GB | 40+ GB SSD |
| Acceso | root o sudo | — |
| Red | puertos 80 + 443 abiertos (con TLS); o 8000 + 3000 (sin TLS) + 22 SSH | — |
| DNS | registro `A` apuntando al servidor **antes** de correr el script (solo modo TLS) | — |

> El stack idle ya consume ~1.5 GB de RAM. Con tráfico real y Realtime activo, los 8 GB son la línea cómoda.

---

## Uso rápido

### Opción A — descarga remota (recomendada)

```bash
curl -fsSL https://raw.githubusercontent.com/doothemes/supabase-setup/main/setup.sh -o setup.sh
chmod +x setup.sh
sudo ./setup.sh --domain supabase.midominio.com --email admin@midominio.com -y
```

### Opción B — clonar el repo

```bash
git clone https://github.com/doothemes/supabase-setup.git
cd supabase-setup
chmod +x setup.sh
sudo ./setup.sh --domain supabase.midominio.com --email admin@midominio.com -y
```

### Opción C — lab interno, sin dominio

```bash
curl -fsSL https://raw.githubusercontent.com/doothemes/supabase-setup/main/setup.sh -o setup.sh
chmod +x setup.sh
sudo ./setup.sh --no-tls -y
```

Cuando termina muestra la URL del Studio, el usuario `admin` y la contraseña generada. La copia completa queda en `/opt/supabase/credentials.txt` (chmod 600).

---

## Flags del instalador

| Flag | Default | Descripción |
|------|---------|-------------|
| `--domain DOMINIO` | — | Dominio público para Caddy + Let's Encrypt. Activa modo TLS. |
| `--email EMAIL` | — | Email para registro Let's Encrypt. Requerido con `--domain`. |
| `--no-tls` | off | No instalar Caddy. Expone Kong (`:8000`) y Studio (`:3000`) directamente sobre la IP. |
| `--no-ufw` | off | No tocar el firewall (UFW). |
| `--dir RUTA` | `/opt/supabase` | Directorio de instalación. |
| `--force` | off | **Destructivo.** `docker compose down -v` y `rm -rf` la instalación previa antes de instalar. |
| `-y`, `--yes` | off | No preguntar confirmaciones. |
| `-h`, `--help` | — | Ayuda. |

---

## Qué hace el script paso a paso

### 1. Pre-flight

- Verifica `EUID == 0` (root).
- Verifica `ID=ubuntu` y `VERSION_ID` ∈ {22.04, 24.04}. Aborta en cualquier otra distro o versión.
- Si vas en modo TLS, valida formato de dominio y email con regex.
- Si ya existe `$INSTALL_DIR/.env`, aborta a menos que pasaras `--force`.

### 2. Dependencias del sistema

`apt-get install` de: `curl ca-certificates gnupg lsb-release git openssl jq ufw apt-transport-https debian-keyring debian-archive-keyring dnsutils`. `dnsutils` se usa para validar DNS antes de Let's Encrypt; el resto son utilidades estándar.

### 3. Docker Engine + plugin compose

Si `docker` ya está instalado, lo deja. Si no:

- Añade la GPG key oficial de Docker en `/etc/apt/keyrings/docker.gpg`.
- Añade el repo de Docker para tu codename de Ubuntu en `/etc/apt/sources.list.d/docker.list`.
- Instala `docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin`.
- `systemctl enable --now docker`.

### 4. Verificación de DNS (solo modo TLS)

Antes de instalar Caddy, hace `dig +short A $DOMAIN` y compara con la IP local (`hostname -I`). Si no resuelve o apunta a otra IP, te avisa y te pregunta si quieres continuar (Let's Encrypt fallará hasta que el DNS apunte bien, pero Caddy reintentará automáticamente).

### 5. Clonado del stack

- `git clone --depth 1 https://github.com/supabase/supabase` a un directorio temporal.
- Copia `supabase/docker/.` a `$INSTALL_DIR/` (incluye `docker-compose.yml`, `volumes/`, configs de Kong, Vector, Logflare).
- Copia `supabase/docker/.env.example` a `$INSTALL_DIR/.env`.
- Borra el clon temporal.

### 6. Generación de secretos en `.env`

Usa la función `set_env` (un `awk` que reemplaza la línea o la añade al final) para escribir cada valor sin riesgo de problemas de escape con `sed`. Ver [Secretos generados](#secretos-generados--qué-hace-cada-uno) para el detalle de cada uno.

`chmod 600 .env`.

### 7. `docker-compose.override.yml` (solo modo TLS)

Docker manipula `iptables` directamente y se **salta UFW** por defecto. Si publicáramos Kong en `0.0.0.0:8000`, quedaría expuesto al mundo aunque UFW dijera "deny 8000". El override re-bindea Kong y Studio a `127.0.0.1` para que solo Caddy (que corre en el host) pueda llegar:

```yaml
services:
    kong:
        ports:
            - "127.0.0.1:8000:8000/tcp"
            - "127.0.0.1:8443:8443/tcp"
    studio:
        ports:
            - "127.0.0.1:3000:3000/tcp"
```

### 8. Caddy + Let's Encrypt (solo modo TLS)

- Instala Caddy desde el repo oficial de Cloudsmith (firmado).
- Escribe `/etc/caddy/Caddyfile` con:
    - Bloque global `email` para registro Let's Encrypt.
    - Site bloque `$DOMAIN { ... }`.
    - Routing por path: `/auth/*`, `/rest/*`, `/realtime/*`, `/storage/*`, `/functions/*`, `/pg/*`, `/graphql/v1*` → `127.0.0.1:8000` (Kong).
    - Todo lo demás → `127.0.0.1:3000` (Studio).
    - `encode zstd gzip` para compresión.
- `systemctl enable && restart caddy`.

Caddy obtiene el certificado al primer request HTTPS — automatic HTTPS, sin certbot, sin renovación manual.

### 9. UFW

Si no estaba activo, setea defaults `deny incoming` / `allow outgoing`. Permite SSH (`22`) siempre, y según modo:

- **TLS**: `80/tcp` y `443/tcp`.
- **No-TLS**: `8000/tcp` y `3000/tcp`.

Luego `ufw --force enable`.

### 10. Levantar el stack

```bash
docker compose pull   # descarga ~10 imágenes (~3-5 GB)
docker compose up -d  # arranca todo en background
```

Espera 20s y muestra `docker compose ps`.

### 11. Guardar credenciales

Escribe `/opt/supabase/credentials.txt` con todo lo generado, `chmod 600`. Imprime un resumen en pantalla con la URL, usuario y password.

---

## Archivos generados

Después de ejecutar el script tendrás esto en `/opt/supabase`:

```
/opt/supabase/
├── .env                          ← secretos (chmod 600)
├── credentials.txt               ← resumen legible (chmod 600)
├── docker-compose.yml            ← oficial, sin tocar
├── docker-compose.override.yml   ← solo si --domain (bind a 127.0.0.1)
├── volumes/
│   ├── api/kong.yml              ← config de Kong (rutas, plugins)
│   ├── db/                       ← scripts SQL de inicialización
│   ├── functions/                ← edge functions (mete tus .ts aquí)
│   ├── logs/vector.yml           ← config de Vector
│   ├── pooler/pooler.exs         ← config de Supavisor
│   └── storage/                  ← bytes de los archivos subidos (¡respaldar!)
└── reset.sh                      ← script auxiliar de Supabase (resetea DB)
```

Plus, fuera del directorio del proyecto:

| Archivo | Propósito |
|---------|-----------|
| `/etc/caddy/Caddyfile` | Config de Caddy (solo modo TLS) |
| `/etc/apt/keyrings/docker.gpg` | GPG key del repo Docker |
| `/etc/apt/sources.list.d/docker.list` | Repo Docker |
| `/etc/apt/sources.list.d/caddy-stable.list` | Repo Caddy |
| `/usr/share/keyrings/caddy-stable-archive-keyring.gpg` | GPG key del repo Caddy |

---

## Secretos generados — qué hace cada uno

Todos los valores se escriben en `/opt/supabase/.env`.

| Variable | Longitud | Función |
|----------|----------|---------|
| `POSTGRES_PASSWORD` | 32 chars alfanuméricos | Password del usuario `postgres` (superuser). Lo usan internamente todos los servicios y es necesario para `psql` directo. |
| `JWT_SECRET` | 48 chars | Clave HS256 con la que se firman **todos** los JWTs de la plataforma. Con ella se firman `ANON_KEY` y `SERVICE_ROLE_KEY` y los tokens de sesión que emite Auth. **Si la rotas, todos los tokens y claves quedan inválidos** — tendrías que regenerar `ANON_KEY`/`SERVICE_ROLE_KEY` y forzar relogin a todos los usuarios. |
| `ANON_KEY` | JWT firmado | Clave pública para clientes anónimos (frontend, mobile). Se manda en el header `apikey: ...` con todas las requests. PostgREST y Auth la decodifican para saber el `role` (anon) y aplicar RLS. **No es secreta** — va embebida en el JS del cliente. Expira en 10 años. |
| `SERVICE_ROLE_KEY` | JWT firmado | Clave de servicio que **bypasa RLS**. Solo para backends de confianza (cron jobs, jobs server-side). **Mantenla secreta.** Expira en 10 años. |
| `DASHBOARD_USERNAME` | `admin` | Usuario para entrar a Studio. Fijo a `admin` por el script. |
| `DASHBOARD_PASSWORD` | 24 chars | Password de Studio. Kong la usa con basic auth para proteger el dashboard. |
| `SECRET_KEY_BASE` | 64 hex chars | Clave de Realtime (Phoenix/Elixir). Firma cookies y tokens internos del servidor de WebSockets. |
| `VAULT_ENC_KEY` | 32 chars | Clave de cifrado del Vault de Postgres (extensión `pgsodium`). Cifra columnas marcadas como secretas (`secret` o `encrypted`). **Si la pierdes, no puedes desencriptar esos datos.** Respáldala. |
| `POOLER_TENANT_ID` | 12 chars (lowercase) | Identificador del tenant del Supavisor (pooler). El connection string del pooler lo incluye: `postgres://USER.TENANT_ID:PASS@HOST:6543/postgres`. |

### URLs

- `API_EXTERNAL_URL` y `SUPABASE_PUBLIC_URL`: la URL pública por la que los clientes llegan a la API. Con TLS = `https://$DOMAIN`. Sin TLS = `http://IP:8000`.
- `SITE_URL`: URL del frontend para flujos de Auth (links de magic-link, password reset). Por defecto la fijo igual a la del Studio. Si tienes un frontend separado, edítalo después.

---

## Modelo de red y seguridad

### Con `--domain` (modo TLS — recomendado para producción)

```
                          ┌─── 80/443 ──── Caddy ──── 127.0.0.1:3000 (studio)
internet ──── ufw ────────┤                    └────  127.0.0.1:8000 (kong)
                          └─── 22 ───── ssh
```

- Solo 22, 80, 443 expuestos públicamente.
- Kong y Studio bindeados a `127.0.0.1` — **inaccesibles desde fuera**, solo Caddy llega.
- Caddy maneja TLS termination y forward al servicio correcto por path.
- Postgres (`5432`) y el pooler (`6543`) **no se publican**. Solo accesibles desde dentro de la red Docker.

### Sin `--no-tls`

```
                          ┌─── 8000 ──── kong (api)
internet ──── ufw ────────┤   3000 ──── studio (dashboard, sin auth web)
                          └─── 22 ───── ssh
```

- Studio queda expuesto sobre HTTP plano.
- **No usar en internet abierto.** Es para LANs, VPNs, o pruebas locales.

### Capas de auth en la API

1. **Kong** valida que el header `apikey` matchee `ANON_KEY` o `SERVICE_ROLE_KEY`. Sin apikey válida, 401.
2. **PostgREST/Auth** decodifican el JWT (`Authorization: Bearer ...` o el mismo apikey) y setean el `role` Postgres correspondiente.
3. **Postgres** aplica las políticas de RLS (Row Level Security) sobre cada query según ese `role` y `auth.uid()`.

`SERVICE_ROLE_KEY` salta el paso 3 (RLS) — por eso es crítico mantenerla solo en backends.

---

## Endpoints expuestos

Con `--domain supabase.midominio.com`:

| URL | Servicio | Para qué |
|-----|----------|----------|
| `https://supabase.midominio.com/` | Studio | Dashboard web (login con admin/password) |
| `https://supabase.midominio.com/rest/v1/{tabla}` | PostgREST | CRUD sobre tablas con RLS |
| `https://supabase.midominio.com/auth/v1/signup` | Auth | Signup |
| `https://supabase.midominio.com/auth/v1/token` | Auth | Login / refresh |
| `https://supabase.midominio.com/auth/v1/user` | Auth | Datos del usuario actual |
| `https://supabase.midominio.com/realtime/v1/websocket` | Realtime | WebSocket para suscripciones |
| `https://supabase.midominio.com/storage/v1/object/{bucket}/{path}` | Storage | Upload/download de archivos |
| `https://supabase.midominio.com/functions/v1/{name}` | Functions | Ejecutar Edge Function |
| `https://supabase.midominio.com/graphql/v1` | pg_graphql | API GraphQL auto-generada |
| `https://supabase.midominio.com/pg/*` | pg-meta | Metadata Postgres (lo consume Studio internamente) |

### Conectar tus apps cliente

Configuración mínima de un cliente JS:

```js
import { createClient } from '@supabase/supabase-js'

const supabase = createClient(
    'https://supabase.midominio.com',
    'TU_ANON_KEY_DE_credentials.txt'
)
```

`SERVICE_ROLE_KEY` solo en servidores, nunca en código que llegue al navegador.

---

## Operación día a día

Todos los comandos se corren dentro del directorio de instalación:

```bash
cd /opt/supabase
```

| Comando | Qué hace |
|---------|----------|
| `docker compose ps` | Estado de cada servicio (Up / Restarting / Exited) |
| `docker compose logs -f` | Tail de **todos** los logs |
| `docker compose logs -f kong` | Logs de un servicio específico |
| `docker compose logs --tail=200 auth` | Últimas 200 líneas de auth |
| `docker compose restart` | Reinicia todo el stack |
| `docker compose restart auth realtime` | Reinicia servicios concretos |
| `docker compose stop` | Detiene contenedores (conserva volúmenes) |
| `docker compose start` | Vuelve a arrancar |
| `docker compose down` | Detiene **y borra** contenedores (conserva volúmenes) |
| `docker compose down -v` | **Destructivo.** Borra contenedores **y volúmenes** (perdés todos los datos) |
| `docker compose exec db psql -U postgres` | Shell `psql` en el container de Postgres |
| `docker stats` | Uso de CPU/RAM por contenedor en vivo |

### Ver logs solo de una sesión problemática

```bash
docker compose logs --since=10m auth | less
```

### Reiniciar un servicio sin afectar a los demás

```bash
docker compose up -d --force-recreate --no-deps auth
```

---

## Backup y restore

### Lo que hay que respaldar

| Item | Cómo |
|------|------|
| Datos de Postgres | `pg_dumpall` (recomendado) o snapshot del volumen Docker |
| Archivos de Storage | `volumes/storage/` |
| Configuración | `.env` y `docker-compose.override.yml` |
| **Vault encryption key** | El valor de `VAULT_ENC_KEY` — sin él, datos cifrados son irrecuperables |

### Backup manual

```bash
cd /opt/supabase

# Dump lógico (incluye auth, storage, schemas custom)
docker compose exec -T db pg_dumpall -U postgres -c \
    | gzip > "backup-db-$(date +%F).sql.gz"

# Archivos
tar czf "backup-storage-$(date +%F).tar.gz" volumes/storage/

# Config
cp .env "backup-env-$(date +%F).txt"
```

### Crontab (backup diario 3 AM, retención 14 días)

```bash
sudo mkdir -p /var/backups/supabase
sudo crontab -e
```

Añade:

```cron
0 3 * * * cd /opt/supabase && docker compose exec -T db pg_dumpall -U postgres -c | gzip > /var/backups/supabase/db-$(date +\%F).sql.gz && find /var/backups/supabase/ -name 'db-*.sql.gz' -mtime +14 -delete
15 3 * * * tar czf /var/backups/supabase/storage-$(date +\%F).tar.gz -C /opt/supabase volumes/storage/ && find /var/backups/supabase/ -name 'storage-*.tar.gz' -mtime +14 -delete
```

### Restore

> **Antes de restaurar**, asegúrate de tener un `.env` con el mismo `JWT_SECRET` y `VAULT_ENC_KEY` que tenía la instalación original — si no, los JWTs y datos cifrados quedarán inválidos.

```bash
cd /opt/supabase
docker compose down
# Restaurar archivos primero (con stack apagado)
tar xzf backup-storage-2026-04-28.tar.gz

# Levantar solo db
docker compose up -d db
sleep 10

# Aplicar el dump (asume DB virgen — usa --force al instalar para empezar limpio)
gunzip -c backup-db-2026-04-28.sql.gz | docker compose exec -T db psql -U postgres

# Levantar el resto
docker compose up -d
```

---

## Configurar SMTP para emails de Auth

Sin SMTP los emails caen al **inbucket interno** del stack (no llegan al usuario). Para producción edita `.env`:

```ini
SMTP_HOST=smtp.tuproveedor.com
SMTP_PORT=587
SMTP_USER=usuario
SMTP_PASS=password-de-aplicacion
SMTP_SENDER_NAME=Supabase
SMTP_ADMIN_EMAIL=admin@midominio.com
```

Y reinicia auth:

```bash
docker compose restart auth
```

Proveedores comunes que funcionan: SendGrid, Mailgun, Amazon SES, Postmark, Brevo. **Gmail/Workspace no es buena idea** para producción (rate limits y deliverability mediocre).

---

## Acceso directo a Postgres

El instalador **no expone** Postgres al exterior por seguridad. Tus opciones:

### Opción 1: SSH tunnel (recomendada)

```bash
# desde tu máquina local
ssh -L 5432:localhost:5432 user@servidor

# en otra terminal local
psql -h localhost -U postgres
# password: el de POSTGRES_PASSWORD
```

Pero ese `localhost:5432` dentro del servidor no está publicado tampoco. Tendrías que agregar al `docker-compose.override.yml`:

```yaml
services:
    db:
        ports:
            - "127.0.0.1:5432:5432"
```

Luego `docker compose up -d` y ya el SSH tunnel funciona.

### Opción 2: Pooler (Supavisor) público

Para conexiones desde apps externas (mejor que abrir Postgres directo):

```yaml
services:
    supavisor:
        ports:
            - "0.0.0.0:6543:6543"
```

Y abre 6543 en UFW. Connection string:

```
postgres://postgres.TENANT_ID:POSTGRES_PASSWORD@servidor:6543/postgres
```

(`TENANT_ID` es `POOLER_TENANT_ID` de tu `.env`)

### Opción 3: shell interactiva en el container

```bash
cd /opt/supabase
docker compose exec db psql -U postgres
```

---

## Actualizar Supabase

```bash
cd /opt/supabase

# 1. Backup primero
docker compose exec -T db pg_dumpall -U postgres -c | gzip > "pre-update-$(date +%F).sql.gz"

# 2. Actualizar imágenes
docker compose pull
docker compose up -d

# 3. Revisar logs
docker compose logs -f --tail=100
```

> Si Supabase upstream añade nuevos servicios o variables al `docker-compose.yml`, esto **no las trae**. Para sincronizar con el repo upstream, lo más limpio es: respaldar `.env` + `volumes/storage/`, correr `setup.sh --force` (que vuelve a clonar), y luego copiar manualmente los valores de tu `.env` viejo al nuevo (cuidando de mantener `JWT_SECRET`, `VAULT_ENC_KEY`, `POSTGRES_PASSWORD` y `POOLER_TENANT_ID` idénticos).

---

## Troubleshooting

### Caddy no obtiene certificado

```bash
sudo journalctl -u caddy -n 200 --no-pager
```

Causas comunes:

- DNS no apunta al servidor todavía (espera propagación, suele ser 1-30 min).
- Puerto 80 o 443 bloqueado por UFW o firewall del proveedor (DigitalOcean, AWS SG, etc.).
- Otro proceso usa el 80/443 (Apache, nginx). `sudo ss -ltnp | grep -E ':(80|443) '` para revisar.
- Rate limit de Let's Encrypt si has reintentado mucho. Esperar 1h.

### Un contenedor está en `Restarting` infinito

```bash
docker compose ps
docker compose logs --tail=200 NOMBRE_SERVICIO
```

Patrones comunes:

- **db** muere al inicio: probablemente el volumen `volumes/db/data/` quedó corrupto de una instalación previa. Si es lab, `docker compose down -v` y reinstalar.
- **auth** o **realtime** dice "JWT_SECRET must be at least 32 characters": el `.env` no tiene el secreto bien escrito. Revisa que `JWT_SECRET=...` esté sin espacios y sin comillas.
- **storage** falla: chequea permisos de `volumes/storage/`.

### Studio carga pero muestra "Failed to fetch"

Studio habla con la API pasando por Kong. Verifica que `kong` esté `Up` (`docker compose ps`). Si lo está, mira sus logs por mensajes 500 — usualmente es Postgres no listo (espera 30s y reintenta).

### Olvidé la password de Studio

```bash
grep DASHBOARD_PASSWORD /opt/supabase/.env
# o
sudo cat /opt/supabase/credentials.txt
```

### Quiero rotar `JWT_SECRET`

Esto invalida **todas** las sesiones y las claves `anon`/`service_role`. Tendrás que:

1. Editar `JWT_SECRET` en `.env`.
2. Regenerar `ANON_KEY` y `SERVICE_ROLE_KEY` con un script que firme `{"role":"anon",...}` y `{"role":"service_role",...}` con el nuevo secreto. (El `setup.sh` original tiene la función `gen_jwt`.)
3. Actualizar `.env` con las nuevas claves.
4. `docker compose restart` — todos los usuarios deberán volver a loguearse, todas las apps cliente necesitan la nueva `ANON_KEY`.

### El servidor se quedó sin disco

Los logs de Docker pueden crecer mucho. Limita en `/etc/docker/daemon.json`:

```json
{
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "50m",
        "max-file": "3"
    }
}
```

Y `sudo systemctl restart docker`.

---

## Desinstalación

El repo incluye `uninstall.sh` que limpia todo lo que `setup.sh` puso. Por defecto detiene el stack, borra los volúmenes Docker (¡pierdes todos los datos!) y elimina `/opt/supabase`. **No** toca Caddy, Docker ni UFW salvo que lo pidas explícitamente.

### Borrar solo Supabase (conservar Caddy y Docker)

```bash
curl -fsSL https://raw.githubusercontent.com/doothemes/supabase-setup/main/uninstall.sh -o uninstall.sh
chmod +x uninstall.sh
sudo ./uninstall.sh -y
```

### Borrar todo lo que el instalador puso

```bash
sudo ./uninstall.sh --purge-caddy --purge-docker --reset-ufw -y
```

> `--purge-docker` desinstala Docker entero — afecta a **todos** los contenedores e imágenes del servidor, no solo los de Supabase. El script te pide confirmación extra antes de hacerlo.

### Reinstalar conservando los datos

```bash
sudo ./uninstall.sh --keep-volumes -y
sudo ./setup.sh --domain ... --email ... -y
```

### Flags de uninstall.sh

| Flag | Descripción |
|------|-------------|
| `--dir RUTA` | Directorio a desinstalar (default: `/opt/supabase`) |
| `--keep-volumes` | NO borrar los volúmenes Docker (conserva Postgres + Storage) |
| `--purge-caddy` | Desinstalar Caddy + borrar `/etc/caddy` y su repo apt |
| `--purge-docker` | Desinstalar Docker + borrar `/var/lib/docker` (afecta a todo Docker) |
| `--reset-ufw` | Quitar reglas UFW que añadió `setup.sh` (no desactiva UFW entero) |
| `-y`, `--yes` | No preguntar confirmación |
| `-h`, `--help` | Ayuda |

[Ver `uninstall.sh` en el repo](https://github.com/doothemes/supabase-setup/blob/main/uninstall.sh)

---

## Limitaciones

- **Single-node.** No hay alta disponibilidad ni replicación. Si el servidor cae, el servicio cae. Para HA real, considera Supabase Cloud o un setup manual con Patroni/replicación lógica.
- **Edge Functions** corren en el runtime oficial pero no se hot-reload — para añadir funciones, mete `.ts` en `volumes/functions/` y reinicia el container `functions`.
- **No incluye SMTP configurado.** Auth funcionará para signup pero los correos quedan atrapados en el inbucket interno hasta que edites las vars `SMTP_*`.
- **No publica Postgres.** Hay que añadirlo manualmente al override si lo necesitas (y tomarte en serio la seguridad — password fuerte, IP allowlist, etc.).
- **No es push automático de updates.** Las imágenes Docker tienen tag fijo en el `docker-compose.yml` upstream — `docker compose pull` trae minor versions del mismo tag, pero un upgrade mayor (ej. `studio:20240101` → `studio:20250101`) requiere reclonar el repo o editar el compose.
- **Logs en disco** crecen sin límite por defecto. Configura `daemon.json` (ver troubleshooting).

---

## Licencia

`setup.sh` y este README son libres de copiar y modificar. Las imágenes Docker que descarga siguen sus licencias respectivas (Supabase es Apache 2.0 / PostgreSQL License según el componente).

---

## Enlaces

- **Repo:** https://github.com/doothemes/supabase-setup
- **Issues:** https://github.com/doothemes/supabase-setup/issues
- **`setup.sh` (raw):** https://raw.githubusercontent.com/doothemes/supabase-setup/main/setup.sh
- **`uninstall.sh` (raw):** https://raw.githubusercontent.com/doothemes/supabase-setup/main/uninstall.sh
- **Supabase upstream:** https://github.com/supabase/supabase
- **Docs Supabase self-hosting:** https://supabase.com/docs/guides/self-hosting/docker
