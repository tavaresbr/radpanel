<?php
declare(strict_types=1);

/*
 * Gerador de script RouterOS (MikroTik) para apontar o equipamento ao RADIUS.
 *
 * Funções puras (sem banco, sem sessão): validam TODO campo com lista de caracteres permitidos
 * (nunca "escape e torça") e só então montam o texto. Alvo: RouterOS v7 (sintaxe 7.1 ou mais nova;
 * em v6 os comandos /radius, /ip hotspot profile e /ppp aaa são os mesmos, mas "/radius incoming"
 * e o "radius-interim-update" têm pequenas diferenças). NÃO validado em equipamento real.
 *
 * O segredo é aceito só se pertencer a um conjunto seguro de caracteres e vai entre aspas duplas:
 * sem aspas, \ $ [ ] ; ? ` ' ( ) { } | & < > espaço ou quebra de linha, de modo que o RouterOS
 * não tem como interpretar nada como comando ou substituição.
 */

const MT_VERSION = 2;
const MT_SERVICES = ['hotspot', 'ppp'];
const MT_SECRET_RE = '/^[A-Za-z0-9._,:@#%^*+=~\/!-]{8,64}$/D';

/** IPv4, IPv6 ou nome de host (DNS). */
function mt_valid_host(string $h): bool
{
    if ($h === '' || strlen($h) > 253) {
        return false;
    }
    if (filter_var($h, FILTER_VALIDATE_IP) !== false) {
        return true;
    }
    if (str_contains($h, ':')) {
        return false;
    }
    return (bool)preg_match('/^(?=.{1,253}$)([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$/D', $h);
}

function mt_valid_port(string $p): ?int
{
    if (!preg_match('/^[0-9]{1,5}$/D', $p)) {
        return null;
    }
    $n = (int)$p;
    return ($n >= 1 && $n <= 65535) ? $n : null;
}

/**
 * Valida e normaliza os campos. Lança RuntimeException (mensagem em português) se algo for inválido.
 * Campos: server_ip, secret, name, services (array), auth_port, acct_port, accounting (bool),
 * interim (minutos 1..60), incoming (bool), coa_port, hotspot_profile ('' = perfil padrão),
 * src_address ('' = sem túnel), firewall (bool; padrão sim quando incoming: regra UDP do CoA só do servidor).
 */
function mikrotik_validate(array $in): array
{
    $str = static function ($v): string {
        if (!is_string($v)) {
            throw new RuntimeException('Campo inválido.');
        }
        return $v;
    };
    $out = [];

    $host = trim($str($in['server_ip'] ?? ''));
    if (!mt_valid_host($host)) {
        throw new RuntimeException('IP/host do servidor RADIUS inválido.');
    }
    $out['server_ip'] = $host;

    $secret = $str($in['secret'] ?? '');
    if (!preg_match(MT_SECRET_RE, $secret)) {
        throw new RuntimeException('Segredo inválido: 8 a 64 caracteres entre letras, números e . _ , : @ # % ^ * + = ~ / ! - '
            . '(sem espaço, aspas, ;, $, [, ], \\ ou quebra de linha).');
    }
    $out['secret'] = $secret;

    $name = trim($str($in['name'] ?? ''));
    if ($name === '') {
        $name = 'radpanel';
    }
    if (!preg_match('/^[A-Za-z0-9_.-]{1,32}$/D', $name)) {
        throw new RuntimeException('Nome inválido (até 32: letras, números e _ . -).');
    }
    $out['name'] = $name;

    $services = $in['services'] ?? [];
    if (!is_array($services)) {
        throw new RuntimeException('Serviços inválidos.');
    }
    $sel = [];
    foreach ($services as $s) {
        if (!is_string($s) || !in_array($s, MT_SERVICES, true)) {
            throw new RuntimeException('Serviço inválido.');
        }
        $sel[$s] = true;
    }
    if (!$sel) {
        throw new RuntimeException('Escolha ao menos um serviço (hotspot e/ou ppp).');
    }
    $out['services'] = array_values(array_filter(MT_SERVICES, fn($s) => isset($sel[$s])));

    foreach (['auth_port' => ['1812', 'Porta de autenticação'], 'acct_port' => ['1813', 'Porta de contabilidade'],
              'coa_port' => ['3799', 'Porta CoA']] as $k => [$def, $label]) {
        $raw = trim($str($in[$k] ?? ''));
        $port = mt_valid_port($raw === '' ? $def : $raw);
        if ($port === null) {
            throw new RuntimeException($label . ' inválida (1 a 65535).');
        }
        $out[$k] = $port;
    }

    $out['accounting'] = !empty($in['accounting']);
    $out['incoming']   = !empty($in['incoming']);
    $out['firewall']   = array_key_exists('firewall', $in) ? !empty($in['firewall']) : true;

    $interim = trim($str($in['interim'] ?? '5'));
    if (!preg_match('/^[0-9]{1,2}$/D', $interim) || (int)$interim < 1 || (int)$interim > 60) {
        throw new RuntimeException('Interim-update inválido (1 a 60 minutos).');
    }
    $out['interim'] = (int)$interim;

    $src = trim($str($in['src_address'] ?? ''));
    if ($src !== '' && filter_var($src, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4) === false) {
        throw new RuntimeException('IP de origem (túnel) inválido: use um IPv4, por exemplo 10.99.0.2.');
    }
    $out['src_address'] = $src;

    $prof = trim($str($in['hotspot_profile'] ?? ''));
    if ($prof !== '' && !preg_match('/^[A-Za-z0-9_.-]{1,32}$/D', $prof)) {
        throw new RuntimeException('Nome do perfil de hotspot inválido (até 32: letras, números e _ . -).');
    }
    $out['hotspot_profile'] = $prof;

    return $out;
}

/** Gera o script (texto puro, linhas terminadas em \n). Lança RuntimeException se a entrada for inválida. */
function mikrotik_script(array $in): string
{
    $v = mikrotik_validate($in);
    $acct = $v['accounting'] ? 'yes' : 'no';
    $hotspot = in_array('hotspot', $v['services'], true);
    $ppp = in_array('ppp', $v['services'], true);

    $tag = 'RadPanel-' . $v['name'];
    $hsSel = $v['hotspot_profile'] === '' ? 'default=yes' : 'name="' . $v['hotspot_profile'] . '"';
    $fwIp = filter_var($v['server_ip'], FILTER_VALIDATE_IP, FILTER_FLAG_IPV4) !== false;

    $l = [];
    $l[] = '# RadPanel - script para RouterOS v7 (cole no terminal ou importe com /import)';
    $l[] = '# Revise antes de aplicar. O servidor precisa ter este equipamento cadastrado como cliente RADIUS.';
    $l[] = sprintf('# Gerador v%d, %s UTC. Pode ser colado de novo: as entradas "%s" são recriadas, não duplicadas.', MT_VERSION, gmdate('Y-m-d H:i'), $tag);
    // Idempotente: remove a entrada anterior deste painel (identificada pelo comentário) antes de criar.
    $l[] = sprintf('/radius remove [ find comment="%s" ]', $tag);
    $l[] = sprintf(
        '/radius add service=%s address=%s%s secret="%s" authentication-port=%d accounting-port=%d timeout=3s called-id=%s comment="%s"',
        implode(',', $v['services']),
        $v['server_ip'],
        $v['src_address'] === '' ? '' : ' src-address=' . $v['src_address'],
        $v['secret'],
        $v['auth_port'],
        $v['acct_port'],
        $v['name'],
        $tag
    );
    if ($v['incoming']) {
        $l[] = sprintf('/radius incoming set accept=yes port=%d', $v['coa_port']);
        if ($v['firewall'] && $fwIp) {
            $fwc = $tag . ' coa';
            $l[] = sprintf('/ip firewall filter remove [ find comment="%s" ]', $fwc);
            $rule = sprintf('/ip firewall filter add chain=input protocol=udp src-address=%s dst-port=%d action=accept comment="%s"', $v['server_ip'], $v['coa_port'], $fwc);
            // place-before=0 falha se a lista estiver vazia; nesse caso adiciona sem posição.
            $l[] = ':do { ' . $rule . ' place-before=0 } on-error={ ' . $rule . ' }';
        } else {
            $l[] = sprintf('# CoA/Disconnect: libere UDP %d vindo de %s no firewall do equipamento.', $v['coa_port'], $v['server_ip']);
        }
    }
    if ($hotspot) {
        // O painel guarda o MAC como AA-BB-CC-DD-EE-FF; o padrão do MikroTik (XX:XX:...) não casaria.
        $l[] = sprintf(
            '/ip hotspot profile set [ find %s ] use-radius=yes radius-accounting=%s radius-interim-update=%dm radius-mac-format=XX-XX-XX-XX-XX-XX',
            $hsSel,
            $acct,
            $v['interim']
        );
    }
    if ($ppp) {
        $l[] = sprintf('/ppp aaa set use-radius=yes accounting=%s interim-update=%dm', $acct, $v['interim']);
    }
    $l[] = sprintf(':log info "%s aplicado"', $tag);
    $l[] = '# --- Desfazer (rollback): tire o "#" das linhas abaixo e cole ---';
    $l[] = sprintf('# /radius remove [ find comment="%s" ]', $tag);
    if ($v['incoming']) {
        $l[] = '# /radius incoming set accept=no';
        if ($v['firewall'] && $fwIp) {
            $l[] = sprintf('# /ip firewall filter remove [ find comment="%s coa" ]', $tag);
        }
    }
    if ($hotspot) {
        $l[] = sprintf('# /ip hotspot profile set [ find %s ] use-radius=no', $hsSel);
    }
    if ($ppp) {
        $l[] = '# /ppp aaa set use-radius=no';
    }
    return implode("\n", $l) . "\n";
}

/**
 * Script RouterOS v7 do túnel WireGuard até o servidor. Campos: server_ip (IP/host público do servidor),
 * server_pub (chave pública do servidor), address (10.99.0.N do roteador), name, wg_port (padrão 51820).
 * A chave privada é criada pelo próprio RouterOS ao criar a interface e nunca sai dele.
 */
function mikrotik_wg_script(array $in): string
{
    $str = static fn($v): string => is_string($v) ? trim($v) : throw new RuntimeException('Campo inválido.');
    $host = $str($in['server_ip'] ?? '');
    if (!mt_valid_host($host)) {
        throw new RuntimeException('IP/host do servidor inválido.');
    }
    $pub = $str($in['server_pub'] ?? '');
    if (!preg_match('/^[A-Za-z0-9+\/]{42}[AEIMQUYcgkosw048]=$/D', $pub)) {
        throw new RuntimeException('Chave pública do servidor inválida.');
    }
    $addr = $str($in['address'] ?? '');
    if (!preg_match('/^10\.99\.0\.(?:[2-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-4])$/D', $addr)) {
        throw new RuntimeException('IP do túnel inválido (10.99.0.2 a 10.99.0.254).');
    }
    $name = $str($in['name'] ?? '');
    if ($name === '') {
        $name = 'radpanel';
    }
    if (!preg_match('/^[A-Za-z0-9_.-]{1,32}$/D', $name)) {
        throw new RuntimeException('Nome inválido (até 32: letras, números e _ . -).');
    }
    $rawPort = $str($in['wg_port'] ?? '');
    $port = mt_valid_port($rawPort === '' ? '51820' : $rawPort);
    if ($port === null) {
        throw new RuntimeException('Porta WireGuard inválida (1 a 65535).');
    }

    $l = [];
    $l[] = '# RadPanel - túnel WireGuard (RouterOS v7.1 ou mais novo). Cole no terminal do MikroTik.';
    $l[] = ':if ([:len [/interface wireguard find name=wg-radius]] = 0) do={ /interface wireguard add name=wg-radius listen-port=13231 comment="RadPanel-' . $name . '" }';
    $l[] = ':if ([:len [/interface wireguard peers find interface=wg-radius]] = 0) do={ ' . sprintf(
        '/interface wireguard peers add interface=wg-radius public-key="%s" endpoint-address=%s endpoint-port=%d allowed-address=10.99.0.1/32 persistent-keepalive=25s comment="RadPanel servidor"',
        $pub,
        $host,
        $port
    ) . ' }';
    $l[] = sprintf(':if ([:len [/ip address find address="%s/24"]] = 0) do={ /ip address add address=%s/24 interface=wg-radius comment="RadPanel tunel" }', $addr, $addr);
    $l[] = '# Se o firewall do roteador bloqueia entrada (chain=input), permita o servidor (necessário para derrubar sessões):';
    $l[] = '# /ip firewall filter add chain=input in-interface=wg-radius src-address=10.99.0.1 action=accept place-before=0';
    $l[] = '# Chave pública DESTE roteador (a mesma que você colou no painel):';
    $l[] = ':put [/interface wireguard get wg-radius public-key]';
    return implode("\n", $l) . "\n";
}
