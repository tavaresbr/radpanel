<?php
declare(strict_types=1);

require_once __DIR__ . '/clients_d.php';

/*
 * Cadastro de equipamentos (NAS): validação e gravação (tabela `nas` + arquivo clients.d/NOME.conf).
 * Usado por public/nas.php, public/wireguard.php e public/setup.php (assistente).
 */

/** IPv4, IPv4/CIDR, IPv6 ou nome de host simples; recusa redes largas demais. */
function valid_nasname(string $n): bool
{
    if (!preg_match('/^[A-Za-z0-9.:\/-]{1,128}$/', $n)) {
        return false;
    }
    // Rede larga demais abriria o RADIUS a qualquer origem que saiba o segredo (ex.: 0.0.0.0/0).
    if (preg_match('~^[0-9.]+/([0-9]{1,2})$~', $n, $m) && (int)$m[1] < 24) {
        return false;
    }
    if (preg_match('~^[0-9a-fA-F:]+/([0-9]{1,3})$~', $n, $m) && (int)$m[1] < 64) {
        return false;
    }
    if (in_array($n, ['0.0.0.0', '::', '0.0.0.0/0', '::/0'], true)) {
        return false;
    }
    return true;
}

/** Valida o segredo; lança RuntimeException (português) se for inválido. */
function nas_check_secret(string $secret): void
{
    if (strlen($secret) < 8 || strlen($secret) > 60 || !preg_match('/^[\x21-\x7e]+$/', $secret)) {
        throw new RuntimeException('Segredo: de 8 a 60 caracteres, sem espaços.');
    }
    if (str_contains($secret, '${') || str_contains($secret, '%{')) {
        throw new RuntimeException('Segredo não pode conter "${" nem "%{" (o FreeRADIUS os trata como expansão).');
    }
}

/**
 * Cadastra o equipamento e grava o arquivo clients.d. Lança RuntimeException se algo for inválido ou duplicado.
 * Retorna ['file_ok' => bool, 'file_error' => string]: o cadastro vale mesmo se só o arquivo falhar (o "Aplicar" regrava).
 * $auditExtra entra no registro de auditoria (nunca o segredo).
 */
function nas_register(PDO $pdo, string $short, string $nasname, string $secret, string $desc = '', array $auditExtra = []): array
{
    if (!valid_nasname($nasname)) {
        throw new RuntimeException('IP/host inválido.');
    }
    if (!clients_d_valid_name($short)) {
        throw new RuntimeException('Nome curto inválido (até 32: letras, números e _ . -; não pode começar com ponto ou hífen).');
    }
    nas_check_secret($secret);
    $st = $pdo->prepare('SELECT COUNT(*) FROM nas WHERE nasname = ? OR shortname = ?');
    $st->execute([$nasname, $short]);
    if ((int)$st->fetchColumn() > 0) {
        throw new RuntimeException('Já existe equipamento com esse IP ou nome.');
    }
    $pdo->prepare('INSERT INTO nas (nasname, shortname, type, secret, description) VALUES (?, ?, "other", ?, ?)')
        ->execute([$nasname, $short, $secret, mb_substr($desc, 0, 200)]);
    audit('nas.add', $short, ['ip' => $nasname] + $auditExtra);
    try {
        clients_d_write($short, $nasname, $secret);
        return ['file_ok' => true, 'file_error' => ''];
    } catch (Throwable $e) {
        return ['file_ok' => false, 'file_error' => friendly_error($e, 'nas')];
    }
}

/** Regrava todos os arquivos clients.d a partir do banco e reinicia o serviço (validado antes). */
function nas_apply_all(PDO $pdo): array
{
    $all = $pdo->query('SELECT nasname, shortname, secret FROM nas')->fetchAll();
    foreach ($all as $n) {
        clients_d_write((string)$n['shortname'], (string)$n['nasname'], (string)$n['secret']);
    }
    $res = clients_d_apply();
    audit('nas.apply', 'radius', ['ok' => $res['ok'], 'clients' => count($all)]);
    return $res;
}
