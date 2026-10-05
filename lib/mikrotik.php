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
 * interim (minutos 1..60), incoming (bool), coa_port, hotspot_profile ('' = perfil padrão).
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

    $interim = trim($str($in['interim'] ?? '5'));
    if (!preg_match('/^[0-9]{1,2}$/D', $interim) || (int)$interim < 1 || (int)$interim > 60) {
        throw new RuntimeException('Interim-update inválido (1 a 60 minutos).');
    }
    $out['interim'] = (int)$interim;

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

    $l = [];
    $l[] = '# RadPanel - script para RouterOS v7 (cole no terminal ou importe com /import)';
    $l[] = '# Revise antes de aplicar. O servidor precisa ter este equipamento cadastrado como cliente RADIUS.';
    $l[] = sprintf(
        '/radius add service=%s address=%s secret="%s" authentication-port=%d accounting-port=%d timeout=3s comment="RadPanel-%s"',
        implode(',', $v['services']),
        $v['server_ip'],
        $v['secret'],
        $v['auth_port'],
        $v['acct_port'],
        $v['name']
    );
    if ($v['incoming']) {
        $l[] = sprintf('/radius incoming set accept=yes port=%d', $v['coa_port']);
        $l[] = sprintf('# CoA/Disconnect: libere UDP %d vindo de %s no firewall do equipamento.', $v['coa_port'], $v['server_ip']);
    }
    if ($hotspot) {
        $sel = $v['hotspot_profile'] === '' ? 'default=yes' : 'name="' . $v['hotspot_profile'] . '"';
        $l[] = sprintf(
            '/ip hotspot profile set [ find %s ] use-radius=yes radius-accounting=%s radius-interim-update=%dm',
            $sel,
            $acct,
            $v['interim']
        );
    }
    if ($ppp) {
        $l[] = sprintf('/ppp aaa set use-radius=yes accounting=%s interim-update=%dm', $acct, $v['interim']);
    }
    return implode("\n", $l) . "\n";
}
