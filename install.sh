#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  exec sudo bash "$0" "$@"
fi

clear
echo "=== INSTALADOR DE PAINEL + CLOUDFLARE TUNNEL ==="
echo

read -rp "Dominio principal (ex: grythprogress.com.br): " DOMAIN
read -rp "Subdominio (ex: tvexpress): " SUBDOMAIN
read -rp "Nome do tunnel (ex: tvexpress-local): " TUNNEL_NAME
read -rp "Porta local do Apache (ex: 80): " LOCAL_PORT
read -rp "Diretorio do site (ENTER para /var/www/html): " WEBROOT
WEBROOT="${WEBROOT:-/var/www/html}"

if [[ -z "${DOMAIN}" || -z "${SUBDOMAIN}" || -z "${TUNNEL_NAME}" || -z "${LOCAL_PORT}" ]]; then
  echo "Erro: preencha dominio, subdominio, tunnel e porta."
  exit 1
fi

HOSTNAME="${SUBDOMAIN}.${DOMAIN}"
DATADIR="${WEBROOT}/data"
DBFILE="${DATADIR}/ltapp.db"
CF_DIR="/etc/cloudflared"

echo "[1/10] Instalando pacotes..."
apt update
apt install -y curl gpg lsb-release apt-transport-https apache2 php libapache2-mod-php php-sqlite3 sqlite3

echo "[2/10] Habilitando Apache..."
systemctl enable --now apache2

echo "[3/10] Preparando hospedagem..."
mkdir -p "${WEBROOT}"
mkdir -p "${DATADIR}"
chown -R www-data:www-data "${WEBROOT}"
chmod 755 "${WEBROOT}"
chmod 750 "${DATADIR}"

if [[ ! -f "${WEBROOT}/index.php" ]]; then
  cat > "${WEBROOT}/index.php" <<'EOF'
<?php
session_start();
if (isset($_SESSION['username'])) {
    header('Location: dashboard.php');
    exit();
}
header('Location: login.php');
exit();
EOF
fi

if [[ ! -f "${WEBROOT}/login.php" ]]; then
  cat > "${WEBROOT}/login.php" <<'EOF'
<?php
session_start();
if (isset($_SESSION['username'])) {
    header('Location: dashboard.php');
    exit();
}
echo "login.php pronto";
EOF
fi

if [[ ! -f "${DBFILE}" ]]; then
  sqlite3 "${DBFILE}" "CREATE TABLE IF NOT EXISTS install_test(id INTEGER PRIMARY KEY AUTOINCREMENT, created_at TEXT DEFAULT CURRENT_TIMESTAMP);"
fi

chown -R www-data:www-data "${DATADIR}"
chmod 660 "${DBFILE}"

echo "[4/10] Criando VirtualHost..."
VHOST_FILE="/etc/apache2/sites-available/${SUBDOMAIN}.conf"
cat > "${VHOST_FILE}" <<EOF
<VirtualHost *:${LOCAL_PORT}>
    ServerName ${HOSTNAME}
    ServerAlias www.${HOSTNAME}
    DocumentRoot ${WEBROOT}

    <Directory ${WEBROOT}>
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/${SUBDOMAIN}_error.log
    CustomLog \${APACHE_LOG_DIR}/${SUBDOMAIN}_access.log combined
</VirtualHost>
EOF

a2ensite "${SUBDOMAIN}.conf" >/dev/null
a2dissite 000-default.conf >/dev/null 2>&1 || true

if ! grep -q "^ServerName localhost" /etc/apache2/apache2.conf; then
  echo "ServerName localhost" >> /etc/apache2/apache2.conf
fi

systemctl reload apache2

echo "[5/10] Instalando cloudflared..."
if ! command -v cloudflared >/dev/null 2>&1; then
  curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | gpg --dearmor -o /usr/share/keyrings/cloudflare-main.gpg
  echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared $(lsb_release -cs) main" > /etc/apt/sources.list.d/cloudflared.list
  apt update
  apt install -y cloudflared
fi

echo "[6/10] Login Cloudflare..."
if [[ ! -f /root/.cloudflared/cert.pem ]]; then
  cloudflared tunnel login
fi

echo "[7/10] Criando/validando tunnel..."
if ! cloudflared tunnel list | awk 'NR>2{print $2}' | grep -qx "${TUNNEL_NAME}"; then
  cloudflared tunnel create "${TUNNEL_NAME}"
fi

TUNNEL_ID="$(cloudflared tunnel list | awk -v n="${TUNNEL_NAME}" 'NR>2 && $2==n {print $1; exit}')"
if [[ -z "${TUNNEL_ID}" ]]; then
  echo "Nao foi possivel obter o UUID do tunnel."
  exit 1
fi

echo "[8/10] Gerando config.yml..."
mkdir -p "${CF_DIR}"
cat > "${CF_DIR}/config.yml" <<EOF
tunnel: ${TUNNEL_ID}
credentials-file: /root/.cloudflared/${TUNNEL_ID}.json

ingress:
  - hostname: ${HOSTNAME}
    service: http://127.0.0.1:${LOCAL_PORT}
  - service: http_status:404
EOF

echo "[9/10] Criando DNS da rota..."
cloudflared tunnel route dns "${TUNNEL_NAME}" "${HOSTNAME}"

echo "[10/10] Ativando servico..."
cloudflared service install
systemctl enable --now cloudflared
systemctl restart cloudflared
systemctl restart apache2

sudo chown -R www-data:www-data /var/www/html
sudo find /var/www/html -type d -exec chmod 755 {} \;
sudo find /var/www/html -type f -exec chmod 644 {} \;
sudo systemctl restart apache2

echo
echo "Concluido:"
echo "Painel: https://${HOSTNAME}/"
echo "API:    https://${HOSTNAME}/api/"
echo "Final:  https://${HOSTNAME}/api/api.php"
