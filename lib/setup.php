<?php
declare(strict_types=1);

require_once __DIR__ . '/nas.php';
require_once __DIR__ . '/wireguard.php';

/*
 * Assistente "Ativar equipamento": o estado de cada equipamento é DERIVADO de fatos (túnel, cadastro, arquivo clients.d,
 * último "Aplicar", registros do roteador em radacct). A URL só escolhe qual etapa mostrar; nunca é a fonte da verdade.
 */

const SETUP_STEPS = [
    1 => 'Túnel',
    2 => 'Conexão',
    3 => 'Cadastro',
    4 => 'Aplicar',
    5 => 'Roteador',
    6 => 'Ativação',
];
const SETUP_HANDSHAKE_MAX_AGE = 300;   // segundos: com keepalive de 25 s, mais que isso = túnel parado

function setup_valid_mode(string $m): ?string
{
    return in_array($m, ['wg', 'fixed'], true) ? $m : null;
}

/** Segredo aleatório de 20 caracteres (letras e números: aceito pelo cadastro e pelo gerador de script do MikroTik). */
function setup_gen_secret(int $len = 20): string
{
    $alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789';
    $out = '';
    $max = strlen($alphabet) - 1;
    for ($i = 0; $i < $len; $i++) {
        $out .= $alphabet[random_int(0, $max)];
    }
    return $out;
}

/** Etapas exibidas para o modo (IP fixo não tem túnel). */
function setup_steps_for(string $mode): array
{
    $steps = SETUP_STEPS;
    if ($mode === 'fixed') {
        unset($steps[1], $steps[2]);
    }
    return $steps;
}

/**
 * Fatos e próxima etapa. $mode é o sugerido pela URL, usado só enquanto o equipamento ainda não existe em lugar nenhum.
 */
function setup_state(PDO $pdo, string $name, string $mode): array
{
    $st = $pdo->prepare('SELECT id, nasname FROM nas WHERE shortname = ?');
    $st->execute([$name]);
    $nas = $st->fetch() ?: null;

    $peers = [];
    $wgError = '';
    try {
        $peers = wg_status();
    } catch (Throwable $e) {
        $wgError = friendly_error($e, 'setup');
    }
    $peer = $peers[$name] ?? null;

    if ($peer !== null) {
        $mode = 'wg';
    } elseif ($nas !== null) {
        $mode = str_starts_with((string)$nas['nasname'], WG_NET) ? 'wg' : 'fixed';
    }
    $ip = $peer['ip'] ?? ($nas['nasname'] ?? '');

    $file = $nas !== null && clients_d_exists($name);
    $applied = false;
    if ($nas !== null) {
        $a = $pdo->query("SELECT MAX(ts) FROM panel_audit WHERE action = 'nas.apply'")->fetchColumn();
        $q = $pdo->prepare("SELECT MAX(ts) FROM panel_audit WHERE action = 'nas.add' AND target = ?");
        $q->execute([$name]);
        $added = $q->fetchColumn();
        $applied = $a !== null && $a !== false && ($added === null || $added === false || (string)$a >= (string)$added);
    }

    $signals = 0;
    $lastSignal = null;
    if ($ip !== '' && $nas !== null) {
        $q = $pdo->prepare('SELECT COUNT(*), MAX(acctstarttime) FROM radacct WHERE nasipaddress = ?');
        $q->execute([$ip]);
        [$signals, $lastSignal] = $q->fetch(PDO::FETCH_NUM);
        $signals = (int)$signals;
    }

    $handshakeEver = $peer !== null && $peer['handshake'] > 0;
    $connected = $peer !== null && $peer['age'] !== null && $peer['age'] <= SETUP_HANDSHAKE_MAX_AGE;

    if ($mode === 'wg' && $peer === null) {
        $next = 1;
    } elseif ($mode === 'wg' && !$handshakeEver) {
        $next = 2;
    } elseif ($nas === null) {
        $next = 3;
    } elseif (!($file && $applied)) {
        $next = 4;
    } elseif ($signals === 0) {
        $next = 5;
    } else {
        $next = 6;
    }
    // Do "Aplicar" em diante todas as etapas finais já podem ser vistas (a 5 e a 6 não têm o que bloquear).
    $max = $next >= 5 ? 6 : $next;
    // Quem já tem túnel/cadastro pode rever as etapas anteriores.
    return [
        'mode' => $mode, 'peer' => $peer !== null, 'ip' => $ip, 'handshake_ever' => $handshakeEver, 'connected' => $connected,
        'age' => $peer['age'] ?? null, 'key' => $peer['key'] ?? '', 'nas' => $nas !== null, 'file' => $file, 'applied' => $applied,
        'signals' => $signals, 'last_signal' => $lastSignal, 'next' => $next, 'max' => $max,
        'active' => $signals > 0 && $file && $applied, 'wg_error' => $wgError,
    ];
}

/** Equipamentos conhecidos (cadastrados ou só no túnel) com a etapa em que cada um está. */
function setup_list(PDO $pdo): array
{
    $names = [];
    foreach ($pdo->query('SELECT shortname FROM nas ORDER BY shortname')->fetchAll(PDO::FETCH_COLUMN) as $n) {
        $names[(string)$n] = true;
    }
    try {
        foreach (array_keys(wg_status()) as $n) {
            $names[$n] = true;
        }
    } catch (Throwable $e) {
        // sem WireGuard configurado: só os cadastrados
    }
    $out = [];
    foreach (array_keys($names) as $n) {
        $s = setup_state($pdo, (string)$n, 'wg');
        $out[] = ['name' => (string)$n, 'mode' => $s['mode'], 'next' => $s['next'], 'active' => $s['active']];
    }
    return $out;
}
