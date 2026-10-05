<?php
declare(strict_types=1);

require_once __DIR__ . '/coa.php';

/*
 * Túnel WireGuard para roteadores com IP dinâmico. Tudo que mexe no sistema passa pelo helper
 * bin/panel-wg-peer.sh (via sudo restrito); aqui só validação e chamada com argv (sem shell).
 * Só a chave PÚBLICA do roteador entra no painel.
 */

const WG_NAME_RE = '/^[A-Za-z0-9_][A-Za-z0-9_.-]{0,31}$/D';
const WG_KEY_RE  = '/^[A-Za-z0-9+\/]{42}[AEIMQUYcgkosw048]=$/D';
const WG_NET     = '10.99.0.';

function wg_valid_name(string $n): bool
{
    return (bool)preg_match(WG_NAME_RE, $n);
}

function wg_valid_key(string $k): bool
{
    return (bool)preg_match(WG_KEY_RE, $k);
}

/** IP interno de roteador (10.99.0.2 a 10.99.0.254). */
function wg_valid_ip(string $ip): bool
{
    return (bool)preg_match('/^10\.99\.0\.(?:[2-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-4])$/D', $ip);
}

/** Roda o helper. Retorna ['ok' => bool, 'lines' => string[], 'message' => primeira linha]. */
function wg_helper(array $args): array
{
    $helper = (string)cfg('wg_helper', '/opt/radpanel/bin/panel-wg-peer.sh');
    $sudo = (string)cfg('sudo_bin', '/usr/bin/sudo');
    if (!is_file($sudo) || !is_file($helper)) {
        throw new RuntimeException('Helper do WireGuard não instalado (rode o instalador de novo).');
    }
    $run = coa_run(array_merge([$sudo, '-n', $helper], $args), '', 30, 8000);
    if ($run['timed_out']) {
        return ['ok' => false, 'lines' => [], 'message' => 'O comando demorou demais.'];
    }
    $lines = array_values(array_filter(array_map('trim', explode("\n", $run['out'])), fn($l) => $l !== ''));
    if ($run['exit'] !== 0) {
        error_log('radpanel wg-helper rc=' . $run['exit'] . ': ' . mb_substr(trim($run['out'] . ' ' . $run['err']), 0, 300));
    }
    $msg = $lines[0] ?? ($run['exit'] === 0 ? '' : 'sem saída (código ' . $run['exit'] . ')');
    return ['ok' => $run['exit'] === 0, 'lines' => $lines, 'message' => mb_substr($msg, 0, 200)];
}

/** Chave pública do servidor, ou null se o túnel ainda não foi configurado. */
function wg_server_pubkey(): ?string
{
    $r = wg_helper(['pubkey']);
    $k = $r['lines'][0] ?? '';
    return ($r['ok'] && wg_valid_key($k)) ? $k : null;
}

/** [['name' => , 'ip' => , 'key' => ], ...] */
function wg_peers(): array
{
    $r = wg_helper(['list']);
    if (!$r['ok']) {
        throw new RuntimeException($r['message']);
    }
    $out = [];
    foreach ($r['lines'] as $l) {
        $p = explode(' ', $l);
        if (count($p) === 3 && wg_valid_name($p[0]) && wg_valid_ip($p[1]) && wg_valid_key($p[2])) {
            $out[] = ['name' => $p[0], 'ip' => $p[1], 'key' => $p[2]];
        }
    }
    return $out;
}

/** Adiciona (ou confirma) o roteador e devolve o IP do túnel. */
function wg_peer_add(string $name, string $key): string
{
    if (!wg_valid_name($name)) {
        throw new RuntimeException('Nome inválido (até 32: letras, números e _ . -).');
    }
    if (!wg_valid_key($key)) {
        throw new RuntimeException('Chave pública inválida: são 44 caracteres terminados em "=". Copie a chave PÚBLICA do MikroTik (não a privada).');
    }
    $r = wg_helper(['add', $name, $key]);
    if (!$r['ok'] || !preg_match('/^OK (10\.99\.0\.\d+)$/D', $r['lines'][0] ?? '', $m) || !wg_valid_ip($m[1])) {
        throw new RuntimeException($r['message'] !== '' ? $r['message'] : 'Falha ao adicionar o roteador.');
    }
    return $m[1];
}

function wg_peer_remove(string $name): void
{
    if (!wg_valid_name($name)) {
        throw new RuntimeException('Nome inválido.');
    }
    $r = wg_helper(['remove', $name]);
    if (!$r['ok']) {
        throw new RuntimeException($r['message']);
    }
}
