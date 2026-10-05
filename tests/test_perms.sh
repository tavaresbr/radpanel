#!/usr/bin/env bash
# Testa bin/raddb-access.sh numa árvore de brinquedo em /var/tmp (precisa de root, runuser, setfacl e dos usuários nobody/daemon).
# Uso: bash tests/test_perms.sh
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source tests/harness.sh   # ok/summary
S="$PWD/bin/raddb-access.sh"
if [ "$(id -u)" != 0 ] || ! command -v setfacl >/dev/null || ! id nobody >/dev/null 2>&1 || ! id daemon >/dev/null 2>&1; then
  echo "AVISO: precisa de root, setfacl, nobody e daemon; permissões NÃO testadas"; exit 0
fi
D=/var/tmp/radpanel-perms-test
cleanup() { rm -rf "$D"; }
trap cleanup EXIT
build() {
  rm -rf "$D"; mkdir -p "$D/raddb/clients.d" "$D/raddb/certs"
  echo "secret=x" >"$D/raddb/clients.conf"; echo "x" >"$D/raddb/radiusd.conf"; echo key >"$D/raddb/certs/k"
  chmod 640 "$D/raddb/clients.conf" "$D/raddb/radiusd.conf" "$D/raddb/certs/k"; chmod 750 "$D/raddb/certs"
  chown -R root:daemon "$D/raddb"; chmod 750 "$D/raddb"
  chown nobody:daemon "$D/raddb/clients.d"; chmod 2770 "$D/raddb/clients.d"; chmod 755 "$D"
}
AS() { runuser -u nobody -- "$@"; }

build
ok "antes: o erro do painel reproduz (nobody NÃO grava em clients.d)" "$(AS test -w "$D/raddb/clients.d" && echo grava || echo nao)" nao
out=$(bash "$S" "$D/raddb" nobody 2>&1); rc=$?
ok "script: rc 0" "$rc" 0
ok "  mensagem de sucesso" "$(echo "$out" | grep -c 'pode gravar')" 1
ok "depois: nobody grava em clients.d" "$(AS test -w "$D/raddb/clients.d" && echo grava || echo nao)" grava
AS sh -c "echo 'client X { ipaddr = 10.99.0.2 }' >'$D/raddb/clients.d/X.conf'"
ok "  arquivo criado" "$(test -f "$D/raddb/clients.d/X.conf" && echo sim)" sim
ok "  grupo do arquivo herdado (setgid) = daemon" "$(stat -c %G "$D/raddb/clients.d/X.conf")" daemon
ok "  o grupo do serviço lê o arquivo gravado" "$(runuser -u daemon -- cat "$D/raddb/clients.d/X.conf" 2>&1 | grep -c ipaddr)" 1
ok "nobody NÃO lista raddb" "$(AS ls "$D/raddb" >/dev/null 2>&1 && echo lista || echo nao)" nao
ok "nobody NÃO lê clients.conf" "$(AS cat "$D/raddb/clients.conf" >/dev/null 2>&1 && echo le || echo nao)" nao
ok "nobody NÃO lê radiusd.conf" "$(AS cat "$D/raddb/radiusd.conf" >/dev/null 2>&1 && echo le || echo nao)" nao
ok "nobody NÃO lê certs/k" "$(AS cat "$D/raddb/certs/k" >/dev/null 2>&1 && echo le || echo nao)" nao
ok "nobody NÃO entra em certs" "$(AS ls "$D/raddb/certs" >/dev/null 2>&1 && echo entra || echo nao)" nao
ok "ACL só tem o usuário pedido, com --x" "$(getfacl -p "$D/raddb" 2>/dev/null | grep -c '^user:nobody:--x$')$(getfacl -p "$D/raddb" 2>/dev/null | grep -c '^user:[^:]\+:')" 11
ok "modo base de raddb não foi aberto a 'outros'" "$(getfacl -p "$D/raddb" 2>/dev/null | grep '^other::')" "other::---"
out=$(bash "$S" "$D/raddb" nobody 2>&1); ok "idempotente (rc 0)" "$?" 0

# falhas
build; rmdir "$D/raddb/clients.d"
out=$(bash "$S" "$D/raddb" nobody 2>&1); ok "sem clients.d: rc 1 e explica" "$?$(echo "$out" | grep -c 'clients.d não existe')" 11
build
out=$(bash "$S" "$D/raddb" usuario-que-nao-existe 2>&1); ok "usuário inexistente: rc 1" "$?$(echo "$out" | grep -c 'não existe')" 11
out=$(bash "$S" /nao/existe nobody 2>&1); ok "pasta inexistente: rc 1" "$?$(echo "$out" | grep -c 'não existe')" 11
build; chgrp nogroup "$D/raddb"   # o usuário do Apache já pertence ao grupo dono de raddb (como se www-data estivesse no grupo freerad)
out=$(bash "$S" "$D/raddb" nobody 2>&1); rc=$?
ok "Apache já no grupo dono de raddb: a ACL de passagem prevalece (rc 0)" "$rc" 0
ok "  e ele continua sem listar raddb" "$(AS ls "$D/raddb" >/dev/null 2>&1 && echo lista || echo nao)" nao
build; chmod 644 "$D/raddb/clients.conf"; chmod 751 "$D/raddb"   # clients.conf legível por outros
out=$(bash "$S" "$D/raddb" nobody 2>&1); ok "clients.conf legível: recusa (rc 1) e avisa" "$?$(echo "$out" | grep -c 'LER')" 11
build; chmod 700 "$D/raddb/clients.d"; chown root:root "$D/raddb/clients.d"  # sem escrita possível
out=$(bash "$S" "$D/raddb" nobody 2>&1); ok "clients.d sem escrita: rc 1 e orienta (namei)" "$?$(echo "$out" | grep -c 'namei')" 11
if [ "$(id -u)" != 0 ]; then :; else
  out=$(runuser -u nobody -- bash "$S" "$D/raddb" nobody 2>&1); ok "sem root: recusa" "$?$(echo "$out" | grep -c 'como root')" 11
fi
# o instalador chama o script e aborta se ele falhar
ok "install-panel.sh chama raddb-access.sh e aborta se falhar" "$(grep -c 'bash "\$SRC/bin/raddb-access.sh".*|| {.*exit 1; }' install-panel.sh)" 1
ok "install-panel.sh instala o pacote acl" "$(grep -c 'sudo acl$' install-panel.sh)" 1
summary
