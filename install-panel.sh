#!/usr/bin/env bash
# Instala (ou atualiza) o RadPanel em /opt/radpanel. Ubuntu 24.04. Rode: sudo bash install-panel.sh
#
# Pode ser executado de novo: mantém /etc/radpanel/config.php e a senha do banco, recria arquivos do
# painel, aplica o SQL idempotente e só cria o administrador se ainda não houver nenhum.
#
# Variáveis opcionais (para uso sem perguntas):
#   PANEL_DOMAIN, PANEL_EMAIL, PORTAL_DOMAIN, ADMIN_USER, ASSUME_YES=1
#   DB_NAME (radius)  RADIUS_USER_GROUP (freerad)  RADIUS_ETC (/opt/freeradius/etc/raddb)
#   SKIP_APT=1 (não instala pacotes)  SKIP_FIREWALL=1  SKIP_CERTBOT=1
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Rode com sudo." >&2
  exit 1
fi

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST=/opt/radpanel
CONF_DIR=/etc/radpanel
DB_NAME="${DB_NAME:-radius}"
PANEL_DB_USER=radpanel
PORTAL_DB_USER=radportal
RADIUS_USER_GROUP="${RADIUS_USER_GROUP:-freerad}"
RADIUS_ETC="${RADIUS_ETC:-/opt/freeradius/etc/raddb}"
WEB_USER=www-data

for f in public/login.php lib/core.php sql/panel.sql bin/create-admin.php portal/public/login.php; do
  [[ -f "$SRC/$f" ]] || { echo "Arquivo ausente: $SRC/$f (rode a partir da pasta radpanel descompactada)." >&2; exit 1; }
done
[[ "$DB_NAME" =~ ^[A-Za-z0-9_]{1,64}$ ]] || { echo "DB_NAME inválido." >&2; exit 1; }

ask() { # variável, pergunta
  local var=$1 prompt=$2
  if [[ -z "${!var:-}" && "${ASSUME_YES:-0}" != "1" ]]; then
    read -rp "$prompt" "$var" || true
  fi
}

ask PANEL_DOMAIN "Domínio do painel (ex.: radius.seudominio.com) ou vazio para acesso só local por túnel SSH: "
PANEL_DOMAIN="${PANEL_DOMAIN:-}"
PORTAL_DOMAIN="${PORTAL_DOMAIN:-}"
EMAIL="${PANEL_EMAIL:-}"
if [[ -n "$PANEL_DOMAIN" ]]; then
  [[ "$PANEL_DOMAIN" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || { echo "Domínio inválido." >&2; exit 1; }
  ask PORTAL_DOMAIN "Domínio do PORTAL DO CLIENTE (outro nome, também apontando para este servidor) ou vazio para não instalar o portal: "
  if [[ -n "$PORTAL_DOMAIN" ]]; then
    [[ "$PORTAL_DOMAIN" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || { echo "Domínio do portal inválido." >&2; exit 1; }
    [[ "$PORTAL_DOMAIN" != "$PANEL_DOMAIN" ]] || { echo "O portal precisa de um domínio diferente do painel." >&2; exit 1; }
  fi
  ask EMAIL "E-mail para o certificado Let's Encrypt: "
  [[ "$EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+$ ]] || { echo "E-mail inválido." >&2; exit 1; }
  echo "Confirme que $PANEL_DOMAIN ${PORTAL_DOMAIN:+e $PORTAL_DOMAIN }já apontam (registro A) para o IP público deste servidor."
  if [[ "${ASSUME_YES:-0}" != "1" ]]; then
    read -rp "Continuar? [s/N] " okc
    [[ "$okc" == "s" || "$okc" == "S" ]] || exit 1
  fi
fi

if [[ "${SKIP_APT:-0}" != "1" ]]; then
  echo "==> Pacotes"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y apache2 php libapache2-mod-php php-mysql mariadb-client openssl sudo
  [[ -n "$PANEL_DOMAIN" && "${SKIP_CERTBOT:-0}" != "1" ]] && apt-get install -y certbot python3-certbot-apache
fi

command -v mysql >/dev/null || { echo "Cliente mysql/mariadb não encontrado." >&2; exit 1; }
mysql -e "SELECT 1" >/dev/null 2>&1 || { echo "Não consegui falar com o MariaDB como root (socket). O servidor de banco está rodando?" >&2; exit 1; }
mysql -e "USE \`$DB_NAME\`" 2>/dev/null || { echo "Banco '$DB_NAME' não existe. Carregue o esquema do FreeRADIUS primeiro." >&2; exit 1; }

echo "==> Arquivos em $DEST"
install -d -m 755 -o root -g root "$DEST"
for d in lib public portal bin sql server-config; do
  rm -rf "${DEST:?}/$d"
  cp -r "$SRC/$d" "$DEST/$d"
done
chown -R root:root "$DEST"
find "$DEST" -type d -exec chmod 755 {} +
find "$DEST" -type f -exec chmod 644 {} +
find "$DEST/bin" -type f -name '*.sh' -exec chmod 755 {} +
find "$DEST/server-config" -type f -name '*.sh' -exec chmod 755 {} +

echo "==> Configuração e banco"
install -d -m 750 -o root -g "$WEB_USER" "$CONF_DIR"
php_get() { php -r '$c = require $argv[1]; echo $c[$argv[2]] ?? "";' "$1" "$2"; }

if [[ -f "$CONF_DIR/config.php" ]]; then
  echo "    config.php já existe: mantendo (e a senha do banco do painel)."
  DB_PASS="$(php_get "$CONF_DIR/config.php" db_pass)"
  [[ -n "$DB_PASS" ]] || { echo "config.php sem db_pass." >&2; exit 1; }
else
  DB_PASS="$(openssl rand -hex 24)"
  umask 077
  cat > "$CONF_DIR/config.php" <<PHP
<?php
return [
    'db_host' => 'localhost',
    'db_name' => '${DB_NAME}',
    'db_user' => '${PANEL_DB_USER}',
    'db_pass' => '${DB_PASS}',
    'timezone' => '$(cat /etc/timezone 2>/dev/null || echo America/Sao_Paulo)',
    'radius_etc' => '${RADIUS_ETC}',
    'clients_d_group' => '${RADIUS_USER_GROUP}',
    'radclient' => '/opt/freeradius/bin/radclient',
    'restart_helper' => '${DEST}/bin/panel-restart-radius.sh',
    'server_ip' => '$(curl -s --max-time 4 https://api.ipify.org 2>/dev/null || true)',
    'trusted_proxies' => ['127.0.0.1', '::1'],
];
PHP
  umask 022
fi
chown root:"$WEB_USER" "$CONF_DIR/config.php"
chmod 640 "$CONF_DIR/config.php"

# Usuário MySQL do painel (a senha vem do config.php, então re-executar não a troca).
mysql <<SQL
CREATE USER IF NOT EXISTS '${PANEL_DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
ALTER USER '${PANEL_DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
SQL

# SQL do painel: panel.sql primeiro, depois os demais módulos (idempotentes).
mysql "$DB_NAME" < "$DEST/sql/panel.sql"
for f in "$DEST"/sql/*.sql; do
  b="$(basename "$f")"
  case "$b" in panel.sql|grants.*) continue ;; esac
  mysql "$DB_NAME" < "$f"
done
for f in "$DEST"/sql/grants.*.sql; do
  sed "s/{{DB_NAME}}/${DB_NAME}/g; s/{{DB_USER}}/${PANEL_DB_USER}/g" "$f" | mysql
done
mysql -e "FLUSH PRIVILEGES"

echo "==> PHP"
for d in /etc/php/*/apache2/conf.d; do
  [[ -d "$d" ]] || continue
  cat > "$d/99-radpanel.ini" <<'INI'
expose_php = Off
display_errors = Off
log_errors = On
session.cookie_httponly = 1
session.use_strict_mode = 1
INI
done

echo "==> Administrador"
HAS_ADMIN="$(mysql -N "$DB_NAME" -e 'SELECT COUNT(*) FROM panel_admins')"
if [[ "$HAS_ADMIN" == "0" ]]; then
  ask ADMIN_USER "Nome do administrador do painel (3-64: letras, números e _ . @ -): "
  [[ "${ADMIN_USER:-}" =~ ^[A-Za-z0-9_.@-]{3,64}$ ]] || { echo "Nome de administrador inválido." >&2; exit 1; }
  php "$DEST/bin/create-admin.php" "$ADMIN_USER" admin
else
  echo "    já existe administrador: nada a criar (para outro: bin/create-admin.php USUARIO papel)."
fi

if [[ -n "$PORTAL_DOMAIN" ]]; then
  echo "==> Portal do cliente (usuário MySQL separado, privilégio mínimo)"
  if [[ -f "$CONF_DIR/portal-config.php" ]]; then
    PORTAL_DB_PASS="$(php_get "$CONF_DIR/portal-config.php" db_pass)"
  else
    PORTAL_DB_PASS="$(openssl rand -hex 24)"
  fi
  mysql <<SQL
CREATE USER IF NOT EXISTS '${PORTAL_DB_USER}'@'localhost' IDENTIFIED BY '${PORTAL_DB_PASS}';
ALTER USER '${PORTAL_DB_USER}'@'localhost' IDENTIFIED BY '${PORTAL_DB_PASS}';
SQL
  sed "s/{{DB_NAME}}/${DB_NAME}/g; s/{{PORTAL_DB_USER}}/${PORTAL_DB_USER}/g" \
    "$DEST/portal/grants-portal-user.sql.example" | grep -v '^--' | mysql
  mysql -e "FLUSH PRIVILEGES"
  umask 077
  cat > "$CONF_DIR/portal-config.php" <<PHP
<?php
return [
    'db_host' => 'localhost',
    'db_name' => '${DB_NAME}',
    'db_user' => '${PORTAL_DB_USER}',
    'db_pass' => '${PORTAL_DB_PASS}',
    'timezone' => '$(php_get "$CONF_DIR/config.php" timezone)',
    'trusted_proxies' => ['127.0.0.1', '::1'],
];
PHP
  umask 022
  chown root:"$WEB_USER" "$CONF_DIR/portal-config.php"
  chmod 640 "$CONF_DIR/portal-config.php"
fi

echo "==> Reinício do FreeRADIUS pelo painel (sudoers restrito) e pasta clients.d"
install -m 0440 -o root -g root "$DEST/server-config/sudoers.radpanel" /etc/sudoers.d/radpanel
visudo -cf /etc/sudoers.d/radpanel >/dev/null || { rm -f /etc/sudoers.d/radpanel; echo "sudoers inválido; removido." >&2; exit 1; }
if [[ -d "$RADIUS_ETC" ]]; then
  if getent group "$RADIUS_USER_GROUP" >/dev/null; then
    install -d -m 2770 -o "$WEB_USER" -g "$RADIUS_USER_GROUP" "$RADIUS_ETC/clients.d"
  else
    echo "    AVISO: grupo '$RADIUS_USER_GROUP' não existe; criando clients.d só para $WEB_USER."
    install -d -m 2770 -o "$WEB_USER" -g "$WEB_USER" "$RADIUS_ETC/clients.d"
  fi
  if ! grep -q '^\$INCLUDE clients.d/' "$RADIUS_ETC/clients.conf" 2>/dev/null; then
    cp -a "$RADIUS_ETC/clients.conf" "$RADIUS_ETC/clients.conf.bak.radpanel.$(date +%Y%m%d-%H%M%S)"
    printf '\n$INCLUDE clients.d/\n' >> "$RADIUS_ETC/clients.conf"
    echo "    adicionado '\$INCLUDE clients.d/' ao clients.conf (backup ao lado)."
  fi
else
  echo "    AVISO: $RADIUS_ETC não existe: pulei clients.d. Ajuste RADIUS_ETC e rode de novo."
fi

echo "==> Apache"
a2enmod headers rewrite ssl >/dev/null
a2dissite 000-default >/dev/null 2>&1 || true
vhost_dir() {
  cat <<CONF
    <Directory ${1}>
        Options -Indexes -FollowSymLinks -MultiViews
        AllowOverride None
        Require all granted
        DirectoryIndex index.php
    </Directory>
    ServerSignature Off
    ErrorLog \${APACHE_LOG_DIR}/${2}-error.log
    CustomLog \${APACHE_LOG_DIR}/${2}-access.log combined
CONF
}
if [[ -n "$PANEL_DOMAIN" ]]; then
  cat > /etc/apache2/sites-available/radpanel.conf <<CONF
<VirtualHost *:80>
    ServerName ${PANEL_DOMAIN}
    DocumentRoot ${DEST}/public
$(vhost_dir "$DEST/public" radpanel)
</VirtualHost>
CONF
else
  grep -q '^Listen 127.0.0.1:8080' /etc/apache2/ports.conf || echo 'Listen 127.0.0.1:8080' >> /etc/apache2/ports.conf
  cat > /etc/apache2/sites-available/radpanel.conf <<CONF
<VirtualHost 127.0.0.1:8080>
    DocumentRoot ${DEST}/public
$(vhost_dir "$DEST/public" radpanel)
</VirtualHost>
CONF
fi
a2ensite radpanel >/dev/null
if [[ -n "$PORTAL_DOMAIN" ]]; then
  cat > /etc/apache2/sites-available/radportal.conf <<CONF
<VirtualHost *:80>
    ServerName ${PORTAL_DOMAIN}
    DocumentRoot ${DEST}/portal/public
    SetEnv RADPANEL_CONFIG ${CONF_DIR}/portal-config.php
$(vhost_dir "$DEST/portal/public" radportal)
</VirtualHost>
CONF
  a2ensite radportal >/dev/null
fi
sed -i 's/^ServerTokens .*/ServerTokens Prod/' /etc/apache2/conf-available/security.conf
apache2ctl configtest
systemctl enable apache2 >/dev/null 2>&1 || true
systemctl restart apache2 || service apache2 restart || true

if [[ -n "$PANEL_DOMAIN" ]]; then
  if [[ "${SKIP_FIREWALL:-0}" != "1" ]] && command -v iptables >/dev/null; then
    echo "==> Firewall (TCP 80/443)"
    for p in 80 443; do
      iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || iptables -I INPUT 5 -p tcp --dport "$p" -j ACCEPT
    done
    command -v netfilter-persistent >/dev/null && netfilter-persistent save || true
  fi
  if [[ "${SKIP_CERTBOT:-0}" != "1" ]]; then
    echo "==> Certificado HTTPS"
    certbot --apache -d "$PANEL_DOMAIN" ${PORTAL_DOMAIN:+-d "$PORTAL_DOMAIN"} -m "$EMAIL" --agree-tos --no-eff-email --redirect --non-interactive
  fi
fi

echo "==> Backup diário"
if [[ "${ASSUME_YES:-0}" == "1" ]]; then BK=s; else read -rp "Instalar o backup diário do banco (cron 03:17)? [S/n] " BK || true; fi
if [[ "${BK:-s}" != "n" && "${BK:-s}" != "N" ]]; then
  DB_NAME="$DB_NAME" bash "$DEST/bin/install-backup.sh" --create-db-user
fi

cat <<MSG

==================================================================
RadPanel instalado em $DEST
MSG
if [[ -n "$PANEL_DOMAIN" ]]; then
  echo "  Painel : https://${PANEL_DOMAIN}/"
  [[ -n "$PORTAL_DOMAIN" ]] && echo "  Portal : https://${PORTAL_DOMAIN}/"
  echo "  Libere TCP 80 e 443 na Security List da Oracle."
else
  echo "  Acesso local. No seu PC: ssh -L 8080:127.0.0.1:8080 -i SUA_CHAVE ubuntu@IP_DO_SERVIDOR"
  echo "  e abra http://127.0.0.1:8080/"
fi
cat <<MSG

  PRÓXIMOS PASSOS (veja LEIA-ME.md):
  1) Limites de uso (franquia, tempo, MAC, simultâneas) só funcionam depois de:
       sudo SERVICE=freeradius $DEST/bin/apply-server-config.sh --restart
     SEM isso, não grave limites: o servidor rejeita o usuário que tiver um limite que ele não conhece.
  2) Validade de usuários (Expiration) exige o servidor corrigido: veja LEIA-ME.md, seção "Bug do fork".
  3) Apague o usuário 'teste' e troque o segredo 'testing123' do clients.conf antes de produção.
==================================================================
MSG
