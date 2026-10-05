<?php
declare(strict_types=1);

require_once __DIR__ . '/coa.php';

/** Gera/remove clients.d/<nome>.conf lidos pelo FreeRADIUS 4.0 via `$INCLUDE clients.d/`. */

function clients_d_dir(): string
{
    return rtrim((string)cfg('radius_etc', '/opt/freeradius/etc/raddb'), '/') . '/clients.d';
}

/** Nome do arquivo sem caminho; não começa com ponto (o FreeRADIUS ignora esses). */
function clients_d_valid_name(string $short): bool
{
    return (bool)preg_match('/^[A-Za-z0-9_][A-Za-z0-9_.-]{0,31}$/', $short);
}

function clients_d_path(string $short): string
{
    if (!clients_d_valid_name($short)) {
        throw new RuntimeException('Nome curto inválido para arquivo de cliente.');
    }
    return clients_d_dir() . '/' . $short . '.conf';
}

function clients_d_quote(string $v): string
{
    return '"' . str_replace(['\\', '"'], ['\\\\', '\\"'], $v) . '"';
}

function clients_d_render(string $short, string $nasname, string $secret): string
{
    if (!clients_d_valid_name($short) || !preg_match('/^[A-Za-z0-9.:\/-]{1,128}$/', $nasname)) {
        throw new RuntimeException('Dados do cliente inválidos.');
    }
    if (!preg_match('/^[\x21-\x7e]{1,128}$/', $secret)) {
        throw new RuntimeException('Segredo com caracteres inválidos para o clients.d.');
    }
    return "client $short {\n\tipaddr = $nasname\n\tproto = *\n\tsecret = " . clients_d_quote($secret)
        . "\n\trequire_message_authenticator = auto\n\tlimit_proxy_state = auto\n}\n";
}

/** Grava de forma atômica (tmp + rename), modo 0640. Idempotente. */
function clients_d_write(string $short, string $nasname, string $secret): string
{
    $path = clients_d_path($short);
    $content = clients_d_render($short, $nasname, $secret);
    $dir = clients_d_dir();
    if (!is_dir($dir) || !is_writable($dir)) {
        throw new RuntimeException('O diretório clients.d não existe ou não é gravável pelo painel.');
    }
    $tmp = tempnam($dir, '.tmp-');
    if ($tmp === false) {
        throw new RuntimeException('Não foi possível criar arquivo em clients.d.');
    }
    try {
        chmod($tmp, 0640);
        $grp = (string)cfg('clients_d_group', '');
        if ($grp !== '' && preg_match('/^[A-Za-z0-9_-]{1,32}$/', $grp)) {
            @chgrp($tmp, $grp);
        }
        if (file_put_contents($tmp, $content) !== strlen($content)) {
            throw new RuntimeException('Falha ao gravar o arquivo do cliente.');
        }
        if (!rename($tmp, $path)) {
            throw new RuntimeException('Falha ao instalar o arquivo do cliente.');
        }
        $tmp = null;
    } finally {
        if (is_string($tmp) && file_exists($tmp)) {
            @unlink($tmp);
        }
    }
    return $path;
}

/** Remove o arquivo; true se existia. */
function clients_d_remove(string $short): bool
{
    if (!clients_d_valid_name($short)) {
        return false;
    }
    $path = clients_d_path($short);
    if (is_file($path)) {
        return @unlink($path);
    }
    return false;
}

function clients_d_exists(string $short): bool
{
    return clients_d_valid_name($short) && is_file(clients_d_path($short));
}

/** Roda o helper de reinício via sudo -n. Valida antes; o helper valida de novo. */
function clients_d_apply(): array
{
    $helper = (string)cfg('restart_helper', '/opt/radpanel/bin/panel-restart-radius.sh');
    $sudo = (string)cfg('sudo_bin', '/usr/bin/sudo');
    if (!is_file($sudo) || !is_file($helper)) {
        throw new RuntimeException('Helper de reinício não instalado (veja server-config/sudoers.radpanel).');
    }
    $run = coa_run([$sudo, '-n', $helper], '', 90, 2000);
    $full = trim($run['out'] . ' ' . $run['err']);
    $first = trim((string)strtok($run['out'], "\n"));
    if ($full !== '') {
        error_log('radpanel restart-helper rc=' . $run['exit'] . ': ' . mb_substr($full, 0, 800));
    }
    $msg = $first;
    if ($run['timed_out']) {
        return ['ok' => false, 'message' => 'O reinício demorou demais; verifique o serviço no servidor.'];
    }
    return ['ok' => $run['exit'] === 0, 'message' => $msg !== '' ? mb_substr($msg, 0, 160) : 'sem saída (código ' . $run['exit'] . ')'];
}
