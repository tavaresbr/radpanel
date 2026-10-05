#!/usr/bin/env bash
# Aplica server-config/ ao FreeRADIUS 4.0 (executar como root no servidor).
#
#   bin/apply-server-config.sh [--restart]
#
# Variáveis:
#   RADDB        diretório raddb (padrão /opt/freeradius/etc/raddb)
#   RADIUSD      binário para validar (padrão /opt/freeradius/sbin/radiusd)
#   SERVICE      serviço systemd a reiniciar com --restart (padrão radiusd)
#   BACKUP_ROOT  onde guardar os backups datados (padrão "$RADDB/../radpanel-backups")
#
# Faz: backup datado -> copia arquivos -> link em mods-enabled -> insere (idempotente) as chamadas no
# "recv Access-Request" do site default entre "# BEGIN radpanel" / "# END radpanel" -> valida com
# "radiusd -CX" -> se falhar, RESTAURA o backup.  Só reinicia o serviço com --restart.
set -euo pipefail

RESTART=0
for a in "$@"; do
  case "$a" in
    --restart) RESTART=1 ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "argumento desconhecido: $a" >&2; exit 2 ;;
  esac
done

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../server-config" && pwd)"
RADDB="${RADDB:-/opt/freeradius/etc/raddb}"
RADIUSD="${RADIUSD:-/opt/freeradius/sbin/radiusd}"
SERVICE="${SERVICE:-radiusd}"
RADDB="$(cd "$RADDB" && pwd)"
BACKUP_ROOT="${BACKUP_ROOT:-$RADDB/../radpanel-backups}"
STAMP="$(date +%Y%m%d-%H%M%S)"
BK="$BACKUP_ROOT/$STAMP"

[ -d "$RADDB/sites-available" ] || { echo "RADDB inválido: $RADDB" >&2; exit 1; }
[ -x "$RADIUSD" ] || { echo "radiusd não encontrado/executável: $RADIUSD" >&2; exit 1; }

SITE_LINK="$RADDB/sites-enabled/default"
if [ -e "$SITE_LINK" ]; then SITE="$(readlink -f "$SITE_LINK")"; else SITE="$RADDB/sites-available/default"; fi
[ -f "$SITE" ] || { echo "site default não encontrado" >&2; exit 1; }

# Arquivos copiados (relativos a server-config/ e a $RADDB)
FILES=(
  mods-available/panel_counters
  policy.d/panel_limits
  mods-config/sql/counter/mysql/panel_daily.conf
  mods-config/sql/counter/mysql/panel_monthly.conf
  mods-config/sql/counter/mysql/panel_total.conf
  mods-config/sql/counter/mysql/panel_quota_day.conf
  mods-config/sql/counter/mysql/panel_quota_month.conf
  mods-config/sql/counter/mysql/panel_quota_total.conf
)
for f in "${FILES[@]}"; do [ -f "$SRC/$f" ] || { echo "faltando $SRC/$f" >&2; exit 1; }; done

# Os backups podem conter senhas (ex.: mods-available/sql): só o root lê. (O umask NÃO é alterado de forma
# global porque os arquivos copiados para o raddb precisam continuar legíveis pelo usuário do serviço.)
mkdir -p "$BK/files"
chmod 700 "$BACKUP_ROOT" "$BK" "$BK/files"
MANIFEST="$BK/manifest"   # linhas: "keep<TAB>caminho" (existia, está no backup) ou "new<TAB>caminho"
: > "$MANIFEST"
backup_one() {  # caminho absoluto
  local p="$1" rel="${1#/}"
  if [ -e "$p" ] || [ -L "$p" ]; then
    mkdir -p "$BK/files/$(dirname "$rel")"
    chmod 700 "$BK/files/$(dirname "$rel")" 2>/dev/null || true
    cp -a "$p" "$BK/files/$rel"
    printf 'keep\t%s\n' "$p" >> "$MANIFEST"
  else
    printf 'new\t%s\n' "$p" >> "$MANIFEST"
  fi
}
for f in "${FILES[@]}"; do backup_one "$RADDB/$f"; done
backup_one "$RADDB/mods-enabled/panel_counters"
backup_one "$SITE"
echo "backup em $BK"

restore() {
  echo "RESTAURANDO backup $BK" >&2
  local kind p
  while IFS=$'\t' read -r kind p; do
    if [ "$kind" = keep ]; then
      rm -rf "$p"; cp -a "$BK/files/${p#/}" "$p"
    else
      rm -rf "$p"
    fi
  done < "$MANIFEST"
}
fail() { echo "ERRO: $1" >&2; restore; exit 1; }

# 1. copia
for f in "${FILES[@]}"; do
  mkdir -p "$RADDB/$(dirname "$f")"
  install -m 0640 "$SRC/$f" "$RADDB/$f"
  # mesmo dono do diretório pai (ex.: radiusd:radiusd)
  chown --reference="$RADDB/$(dirname "$f")" "$RADDB/$f" 2>/dev/null || true
done

# 2. habilita o módulo
mkdir -p "$RADDB/mods-enabled"
ln -sfn ../mods-available/panel_counters "$RADDB/mods-enabled/panel_counters"

# 3. insere as chamadas no recv Access-Request do site default (idempotente)
if grep -q '# BEGIN radpanel' "$SITE"; then
  echo "site default já contém o bloco radpanel (nada a inserir)"
else
  TMP="$(mktemp)"
  if ! awk '
    function indent(l,   m) { match(l, /^[ \t]*/); return substr(l, 1, RLENGTH) }
    BEGIN { insec = 0; depth = 0; pre = 0; main = 0 }
    {
      line = $0
      if (!insec && line ~ /^[ \t]*recv[ \t]+Access-Request[ \t]*\{/) { insec = 1; depth = 0 }
      if (insec) {
        if (!pre && line ~ /^[ \t]*-?sql[ \t]*$/) {
          i = indent(line)
          print i "# BEGIN radpanel (prepare)"
          print i "panel_limits_prepare"
          print i "# END radpanel"
          pre = 1
        }
        if (!main && line ~ /^[ \t]*pap[ \t]*$/) {
          i = indent(line)
          print i "# BEGIN radpanel"
          print i "panel_limits"
          print i "# END radpanel"
          main = 1
        }
        n = gsub(/\{/, "{", line); m = gsub(/\}/, "}", line)
        depth += n - m
        if (depth <= 0 && (n + m) > 0 && line !~ /recv[ \t]+Access-Request/) insec = 0
      }
      print $0
    }
    END { if (!pre || !main) exit 3 }
  ' "$SITE" > "$TMP"; then
    rm -f "$TMP"
    fail "não achei 'sql' e 'pap' dentro de 'recv Access-Request' em $SITE (insira manualmente, veja server-config/README-insercao.txt)"
  fi
  cat "$TMP" > "$SITE"   # preserva dono/permissão/link do arquivo
  rm -f "$TMP"
  echo "chamadas inseridas em $SITE"
fi

# 4. valida
if ! "$RADIUSD" -CX -d "$RADDB" > "$BK/radiusd-check.log" 2>&1; then
  tail -n 25 "$BK/radiusd-check.log" >&2
  fail "radiusd -CX falhou (log completo em $BK/radiusd-check.log)"
fi
echo "configuração validada (radiusd -CX)"

# 5. reinicia só se pedido
if [ "$RESTART" -eq 1 ]; then
  systemctl restart "$SERVICE" || fail "falha ao reiniciar $SERVICE"
  echo "serviço $SERVICE reiniciado"
else
  echo "NÃO reiniciado: rode 'systemctl restart $SERVICE' (ou use --restart)."
fi
