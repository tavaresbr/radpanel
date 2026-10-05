#!/bin/bash
# Gerencia os roteadores (peers) do túnel WireGuard do RadPanel.
# Chamado pelo painel via sudo -n (sudoers restrito, ver server-config/sudoers.radpanel):
#   panel-wg-peer.sh add NOME CHAVE_PUBLICA   -> "OK 10.99.0.N" (idempotente se NOME+chave já existem)
#   panel-wg-peer.sh remove NOME              -> "OK"
#   panel-wg-peer.sh list                     -> uma linha por peer: "NOME IP CHAVE_PUBLICA"
#   panel-wg-peer.sh pubkey                   -> chave pública do servidor
#   panel-wg-peer.sh status                   -> uma linha por peer: "NOME IP EPOCH_DO_ULTIMO_HANDSHAKE" (0 = nunca conectou)
# Só a chave PÚBLICA do roteador passa por aqui; a privada nunca sai do MikroTik.
# Estado: /etc/wireguard/peers.d/NOME.conf (um bloco [Peer] cada) + wg0.base (bloco [Interface]).
# wg0.conf é regenerado (base + peers) e aplicado com "wg syncconf", sem derrubar quem já está conectado.
# Variáveis WG_DIR/WG_BIN/WG_QUICK/WG_IFACE só valem com RADPANEL_TEST=1 (produção ignora o ambiente).
# Saída: exit 0 = ok; 1 = pedido recusado/erro (mensagem em português na primeira linha); 64 = uso/ambiente.
set -u
umask 077
if [ "${RADPANEL_TEST:-}" = "1" ]; then
  WG_DIR="${WG_DIR:-/etc/wireguard}"; WG_BIN="${WG_BIN:-/usr/bin/wg}"; WG_QUICK="${WG_QUICK:-/usr/bin/wg-quick}"
  WG_IFACE="${WG_IFACE:-wg0}"
else
  WG_DIR=/etc/wireguard; WG_BIN=/usr/bin/wg; WG_QUICK=/usr/bin/wg-quick; WG_IFACE=wg0
  [ "$(id -u)" = "0" ] || { echo "precisa rodar como root (via sudo)"; exit 64; }
fi
NET=10.99.0
PEERS="$WG_DIR/peers.d"
BASE="$WG_DIR/$WG_IFACE.base"
CONF="$WG_DIR/$WG_IFACE.conf"
NAME_RE='^[A-Za-z0-9_][A-Za-z0-9_.-]{0,31}$'
KEY_RE='^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$'

[ -f "$BASE" ] || { echo "WireGuard não está configurado no servidor (rode: sudo bash bin/wg-setup.sh)"; exit 1; }
mkdir -p "$PEERS"
exec 9>"$WG_DIR/.peers.lock"
flock -w 10 9 || { echo "outra alteração em andamento; tente de novo"; exit 1; }

peer_ip()  { sed -n 's/^AllowedIPs = \([0-9.]*\)\/32$/\1/p' "$1" | head -n1; }
peer_key() { sed -n 's/^PublicKey = \(.*\)$/\1/p' "$1" | head -n1; }

rebuild() {
  local tmp f
  tmp=$(mktemp "$WG_DIR/.conf.XXXXXX") || return 1
  { cat "$BASE"; for f in "$PEERS"/*.conf; do [ -f "$f" ] && { echo; cat "$f"; }; done; } >"$tmp"
  chmod 600 "$tmp"; mv -f "$tmp" "$CONF" || return 1
  # Aplica sem derrubar o túnel. Se a interface não estiver ativa, o arquivo já vale no próximo "wg-quick up".
  if [ -x "$WG_BIN" ] && "$WG_BIN" show "$WG_IFACE" >/dev/null 2>&1; then
    local stripped
    stripped=$("$WG_QUICK" strip "$CONF" 2>&1) || { echo "wg-quick strip falhou: $(printf '%s' "$stripped" | head -c 160)"; return 1; }
    printf '%s\n' "$stripped" | "$WG_BIN" syncconf "$WG_IFACE" /dev/stdin 2>&1 | head -c 200 || true
  fi
  return 0
}

cmd="${1:-}"
case "$cmd" in
  add)
    [ $# -eq 3 ] || { echo "uso: add NOME CHAVE_PUBLICA"; exit 64; }
    name=$2; key=$3
    [[ "$name" =~ $NAME_RE ]] || { echo "Nome inválido (até 32: letras, números e _ . -)."; exit 1; }
    [[ "$key" =~ $KEY_RE ]] || { echo "Chave pública inválida (44 caracteres terminados em =)."; exit 1; }
    f="$PEERS/$name.conf"
    if [ -f "$f" ]; then
      if [ "$(peer_key "$f")" = "$key" ]; then echo "OK $(peer_ip "$f")"; exit 0; fi
      echo "Já existe um roteador com o nome '$name' e outra chave."; exit 1
    fi
    for o in "$PEERS"/*.conf; do
      [ -f "$o" ] || continue
      [ "$(peer_key "$o")" = "$key" ] && { echo "Essa chave já está em uso por '$(basename "$o" .conf)'."; exit 1; }
    done
    used=" "
    for o in "$PEERS"/*.conf; do [ -f "$o" ] && used="$used$(peer_ip "$o") "; done
    ip=""
    for n in $(seq 2 254); do
      case "$used" in *" $NET.$n "*) ;; *) ip="$NET.$n"; break ;; esac
    done
    [ -n "$ip" ] || { echo "Sem IP livre no túnel (máximo 253 roteadores)."; exit 1; }
    printf '[Peer]\n# %s\nPublicKey = %s\nAllowedIPs = %s/32\n' "$name" "$key" "$ip" >"$f.tmp" && mv -f "$f.tmp" "$f"
    if ! msg=$(rebuild); then rm -f "$f"; rebuild >/dev/null 2>&1; echo "Falha ao aplicar: $msg"; exit 1; fi
    echo "OK $ip"
    ;;
  remove)
    [ $# -eq 2 ] || { echo "uso: remove NOME"; exit 64; }
    name=$2
    [[ "$name" =~ $NAME_RE ]] || { echo "Nome inválido."; exit 1; }
    [ -f "$PEERS/$name.conf" ] || { echo "Roteador '$name' não encontrado."; exit 1; }
    rm -f "$PEERS/$name.conf"
    msg=$(rebuild) || { echo "Removido, mas falhou ao aplicar: $msg"; exit 1; }
    echo "OK"
    ;;
  list)
    [ $# -eq 1 ] || { echo "uso: list"; exit 64; }
    for o in "$PEERS"/*.conf; do
      [ -f "$o" ] && echo "$(basename "$o" .conf) $(peer_ip "$o") $(peer_key "$o")"
    done
    exit 0
    ;;
  status)
    [ $# -eq 1 ] || { echo "uso: status"; exit 64; }
    hs=""
    if [ -x "$WG_BIN" ]; then hs=$("$WG_BIN" show "$WG_IFACE" latest-handshakes 2>/dev/null || true); fi
    for o in "$PEERS"/*.conf; do
      [ -f "$o" ] || continue
      k=$(peer_key "$o")
      t=$(printf '%s\n' "$hs" | awk -v k="$k" '$1 == k { print $2; exit }')
      echo "$(basename "$o" .conf) $(peer_ip "$o") ${t:-0}"
    done
    exit 0
    ;;
  pubkey)
    [ $# -eq 1 ] || { echo "uso: pubkey"; exit 64; }
    [ -s "$WG_DIR/server.pub" ] || { echo "server.pub ausente"; exit 1; }
    head -n1 "$WG_DIR/server.pub"
    ;;
  *) echo "uso: add NOME CHAVE | remove NOME | list | pubkey | status"; exit 64 ;;
esac
