#!/bin/bash
# Dá ao usuário do Apache só a PASSAGEM (x) na pasta raddb do FreeRADIUS, por ACL, para o painel gravar em raddb/clients.d.
# Sem isso o painel não alcança clients.d (raddb é root:freerad, modo 750) e Equipamentos falha ("clients.d não é gravável").
# Não dá leitura nem listagem: chaves de certificado, clients.conf e mods-enabled/sql continuam ilegíveis ao Apache.
# Uso (root): raddb-access.sh [RADIUS_ETC [USUARIO_WEB]]      Padrão: /opt/freeradius/etc/raddb  www-data
# Sai com 0 só se o usuário consegue gravar em clients.d E NÃO consegue listar/ler o resto de raddb.
set -u
ETC="${1:-/opt/freeradius/etc/raddb}"
WEB="${2:-www-data}"
die() { echo "ERRO: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "rode como root (sudo)."
[[ -d "$ETC" ]] || die "pasta $ETC não existe."
[[ -d "$ETC/clients.d" ]] || die "pasta $ETC/clients.d não existe (o instalador a cria antes de chamar este script)."
id "$WEB" >/dev/null 2>&1 || die "usuário '$WEB' não existe."
command -v setfacl >/dev/null || die "falta o comando setfacl. Instale: sudo apt install -y acl"
command -v runuser >/dev/null || die "falta o runuser."

setfacl -m "u:$WEB:--x" "$ETC" 2>/dev/null \
  || die "não consegui aplicar ACL em $ETC (o sistema de arquivos não suporta ACL?). Não vou abrir a pasta para todos os usuários."

# 1) tem que conseguir gravar em clients.d
runuser -u "$WEB" -- test -w "$ETC/clients.d" \
  || die "mesmo com a ACL, '$WEB' não consegue gravar em $ETC/clients.d (confira dono/modo da pasta e as pastas acima dela: namei -l $ETC/clients.d)."
# 2) não pode listar nem ler o resto (a ACL deu só passagem)
if runuser -u "$WEB" -- ls "$ETC" >/dev/null 2>&1; then
  die "'$WEB' consegue LISTAR $ETC: a permissão ficou larga demais. Revise as permissões antes de continuar."
fi
for f in clients.conf radiusd.conf; do
  if [[ -e "$ETC/$f" ]] && runuser -u "$WEB" -- test -r "$ETC/$f"; then
    die "'$WEB' consegue LER $ETC/$f: a permissão ficou larga demais. Revise as permissões antes de continuar."
  fi
done
echo "    '$WEB' pode gravar em $ETC/clients.d e não lê o restante de $ETC (ACL só de passagem)."
