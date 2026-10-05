#!/bin/bash
# Configura o servidor WireGuard do RadPanel (uma vez; pode repetir sem trocar a chave nem apagar peers).
# Uso: sudo bash bin/wg-setup.sh        Opções: SKIP_FIREWALL=1  SKIP_APT=1  WG_PORT=51820
# Túnel 10.99.0.0/24: servidor 10.99.0.1; cada roteador recebe 10.99.0.N pelo painel (menu VPN WireGuard).
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Rode com sudo: sudo bash bin/wg-setup.sh" >&2; exit 1; }
WG_PORT="${WG_PORT:-51820}"
WG_DIR=/etc/wireguard
IFACE=wg0
WEB_GROUP="${WEB_GROUP:-www-data}"

if [[ "${SKIP_APT:-0}" != "1" ]]; then
  echo "==> Instalando wireguard-tools"
  DEBIAN_FRONTEND=noninteractive apt-get install -y wireguard-tools iptables
fi
command -v wg >/dev/null || { echo "Comando 'wg' não encontrado (instale wireguard-tools)." >&2; exit 1; }

install -d -m 700 "$WG_DIR" "$WG_DIR/peers.d"
if [[ ! -s "$WG_DIR/server.key" ]]; then
  echo "==> Gerando chave do servidor"
  ( umask 077; wg genkey > "$WG_DIR/server.key" )
fi
wg pubkey < "$WG_DIR/server.key" > "$WG_DIR/server.pub"
chmod 600 "$WG_DIR/server.key"
chmod 644 "$WG_DIR/server.pub"
# O diretório é 700 (root): o painel lê a chave pública pelo helper (sudo), não direto.

if [[ ! -f "$WG_DIR/$IFACE.base" ]]; then
  ( umask 077; cat > "$WG_DIR/$IFACE.base" <<BASE
[Interface]
Address = 10.99.0.1/24
ListenPort = ${WG_PORT}
PrivateKey = $(cat "$WG_DIR/server.key")
BASE
  )
fi
# wg0.conf = base + peers (o helper regenera o mesmo arquivo a cada alteração).
if [[ ! -f "$WG_DIR/$IFACE.conf" ]]; then
  ( umask 077; cat "$WG_DIR/$IFACE.base" > "$WG_DIR/$IFACE.conf" )
fi

if [[ "${SKIP_FIREWALL:-0}" != "1" ]] && command -v iptables >/dev/null; then
  echo "==> Firewall: UDP ${WG_PORT} (túnel); RADIUS 1812/1813 só dentro do túnel (wg0)"
  iptables -C INPUT -p udp --dport "$WG_PORT" -j ACCEPT 2>/dev/null || iptables -I INPUT 5 -p udp --dport "$WG_PORT" -j ACCEPT
  for p in 1812 1813; do
    iptables -C INPUT -i "$IFACE" -p udp --dport "$p" -j ACCEPT 2>/dev/null || iptables -I INPUT 5 -i "$IFACE" -p udp --dport "$p" -j ACCEPT
  done
  command -v netfilter-persistent >/dev/null && netfilter-persistent save || \
    echo "    AVISO: sem netfilter-persistent; as regras somem no reboot (apt install iptables-persistent e rode de novo)."
fi

echo "==> Ligando o túnel"
systemctl enable "wg-quick@$IFACE" >/dev/null
if wg show "$IFACE" >/dev/null 2>&1; then
  wg syncconf "$IFACE" <(wg-quick strip "$WG_DIR/$IFACE.conf")
else
  systemctl start "wg-quick@$IFACE"
fi
wg show "$IFACE" | head -n 4
echo
echo "Pronto. Chave pública do servidor: $(cat "$WG_DIR/server.pub")"
echo "Libere UDP ${WG_PORT} na Security List da Oracle e use o menu 'VPN WireGuard' do painel."
