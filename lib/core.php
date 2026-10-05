<?php
declare(strict_types=1);

/*
 * Núcleo compartilhado (painel admin e portal do cliente):
 * configuração, cabeçalhos, sessão, banco, CSRF, helpers.
 * Antes de incluir, o chamador pode definir PANEL_SESSION_NAME.
 */

// Nomes de atributos do FreeRADIUS 4.0.
const ATTR_PASSWORD   = 'Password.Cleartext';
const ATTR_EXPIRATION = 'Expiration';
const ATTR_RATE       = 'Mikrotik.Rate-Limit';
const BLOCK_DATE_UTC  = '2000-01-01T00:00:00Z';
const PER_PAGE        = 50;

$cfgFile = getenv('RADPANEL_CONFIG') ?: '/etc/radpanel/config.php';
if (!is_readable($cfgFile)) {
    http_response_code(500);
    error_log('radpanel: configuração ausente ou ilegível');
    exit('Erro de configuração do servidor.');
}
$CFG = require $cfgFile;
unset($cfgFile);

date_default_timezone_set((string)($CFG['timezone'] ?? 'America/Sao_Paulo'));

ini_set('display_errors', '0');
ini_set('log_errors', '1');
error_reporting(E_ALL);

function cfg(string $key, $default = null)
{
    global $CFG;
    return $CFG[$key] ?? $default;
}

function trusted_proxy(): bool
{
    $remote = $_SERVER['REMOTE_ADDR'] ?? '';
    return in_array($remote, (array)cfg('trusted_proxies', ['127.0.0.1', '::1']), true);
}

function is_https(): bool
{
    if (!empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off') {
        return true;
    }
    return trusted_proxy()
        && strtolower((string)($_SERVER['HTTP_X_FORWARDED_PROTO'] ?? '')) === 'https';
}

function client_ip(): string
{
    $remote = $_SERVER['REMOTE_ADDR'] ?? '0.0.0.0';
    if (trusted_proxy() && !empty($_SERVER['HTTP_X_FORWARDED_FOR'])) {
        $parts = array_map('trim', explode(',', (string)$_SERVER['HTTP_X_FORWARDED_FOR']));
        $ip = end($parts);
        if (filter_var($ip, FILTER_VALIDATE_IP)) {
            return $ip;
        }
    }
    return $remote;
}

/**
 * IP usado nos limites de tentativas: IPv4 como está; IPv6 agrupado por /64 (um atacante
 * costuma ter um /64 inteiro e giraria o endereço para escapar do limite).
 */
function rate_ip(): string
{
    $ip = client_ip();
    $bin = @inet_pton($ip);
    if ($bin !== false && strlen($bin) === 16) {
        return bin2hex(substr($bin, 0, 8)) . '::/64';
    }
    return $ip;
}

$https = is_https();
ini_set('zend.exception_ignore_args', '1'); // senhas (ex.: do banco) não vão para rastros de erro
ini_set('session.use_strict_mode', '1');
ini_set('session.use_only_cookies', '1');
session_name(defined('PANEL_SESSION_NAME') ? PANEL_SESSION_NAME : 'radpanel');
session_set_cookie_params([
    'lifetime' => 0,
    'path'     => '/',
    'secure'   => $https,
    'httponly' => true,
    'samesite' => 'Strict',
]);
session_start();

header('X-Frame-Options: DENY');
header('X-Content-Type-Options: nosniff');
header('Referrer-Policy: same-origin');
header("Content-Security-Policy: default-src 'self'; style-src 'self'; img-src 'self'; "
    . "form-action 'self'; frame-ancestors 'none'; base-uri 'none'; object-src 'none'");
header('Cache-Control: no-store');
if ($https) {
    header('Strict-Transport-Security: max-age=31536000');
}

function db(): PDO
{
    static $pdo = null;
    if ($pdo === null) {
        $pdo = new PDO(
            sprintf(
                'mysql:host=%s;port=%d;dbname=%s;charset=utf8mb4',
                cfg('db_host', 'localhost'),
                (int)cfg('db_port', 3306),
                cfg('db_name', 'radius')
            ),
            (string)cfg('db_user'),
            (string)cfg('db_pass'),
            [
                PDO::ATTR_ERRMODE            => PDO::ERRMODE_EXCEPTION,
                PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
                PDO::ATTR_EMULATE_PREPARES   => false,
                PDO::ATTR_TIMEOUT            => 5,
            ]
        );
    }
    return $pdo;
}

function h(?string $s): string
{
    return htmlspecialchars((string)$s, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
}

function csrf_token(): string
{
    if (empty($_SESSION['csrf'])) {
        $_SESSION['csrf'] = bin2hex(random_bytes(32));
    }
    return $_SESSION['csrf'];
}

function csrf_field(): string
{
    return '<input type="hidden" name="csrf" value="' . h(csrf_token()) . '">';
}

function csrf_check(): void
{
    $ok = isset($_POST['csrf'], $_SESSION['csrf'])
        && hash_equals($_SESSION['csrf'], (string)$_POST['csrf']);
    if (!$ok) {
        http_response_code(400);
        exit('Requisição inválida (CSRF). Volte e tente de novo.');
    }
}

/** Exige POST válido (método + CSRF). */
function require_post(): void
{
    if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
        http_response_code(405);
        exit('Método não permitido.');
    }
    csrf_check();
}

function flash(string $msg, string $type = 'ok'): void
{
    $_SESSION['flash'] = [$type, $msg];
}

/** Redireciona somente para caminhos relativos do próprio painel. */
function redirect(string $to): never
{
    if (!preg_match('~^[A-Za-z0-9_./?=&%+-]{1,300}$~', $to) || str_contains($to, '//') || str_starts_with($to, '/')) {
        $to = 'dashboard.php';
    }
    header('Location: ' . $to);
    exit;
}

function post(string $k): string
{
    return trim((string)($_POST[$k] ?? ''));
}

/** Registra o erro real no log e devolve mensagem genérica ao usuário. */
function log_exception(Throwable $e, string $where = ''): void
{
    error_log('radpanel ' . $where . ': ' . get_class($e) . ': ' . $e->getMessage());
}

/**
 * Mensagem segura para mostrar ao usuário. Só RuntimeException "de negócio" aparece;
 * PDOException (que também é RuntimeException!) e qualquer outro erro viram texto genérico
 * e o detalhe real vai só para o log do servidor.
 */
function friendly_error(Throwable $e, string $where = ''): string
{
    if ($e instanceof RuntimeException && !($e instanceof PDOException)) {
        return $e->getMessage();
    }
    log_exception($e, $where);
    return 'Erro ao salvar no banco.';
}

function fmt_bytes(?int $n): string
{
    $n = (float)($n ?? 0);
    $u = ['B', 'KB', 'MB', 'GB', 'TB'];
    $i = 0;
    while ($n >= 1024 && $i < count($u) - 1) {
        $n /= 1024;
        $i++;
    }
    return number_format($n, $i ? 2 : 0, ',', '.') . ' ' . $u[$i];
}

function fmt_secs(?int $s): string
{
    $s = (int)($s ?? 0);
    return sprintf('%dh %02dm %02ds', intdiv($s, 3600), intdiv($s % 3600, 60), $s % 60);
}

function valid_username(string $u): bool
{
    return (bool)preg_match('/^[A-Za-z0-9_.@-]{1,64}$/', $u);
}

function valid_plan(string $p): bool
{
    return (bool)preg_match('/^[A-Za-z0-9_.-]{1,64}$/', $p);
}

function valid_rate(string $r): bool
{
    return $r === '' || (bool)preg_match('/^[0-9]{1,9}[kKmMgG]?$/', $r);
}

function valid_date(string $d): bool
{
    $dt = DateTime::createFromFormat('Y-m-d', $d);
    return $dt && $dt->format('Y-m-d') === $d;
}

function valid_mac(string $m): bool
{
    return (bool)preg_match('/^([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}$/', $m);
}

/** AA-BB-CC-DD-EE-FF (formato esperado pela política do FreeRADIUS). */
function normalize_mac(string $m): string
{
    return strtoupper(str_replace(':', '-', $m));
}

/** Data local (Y-m-d) -> fim do dia em UTC, formato RFC 3339 aceito pelo FreeRADIUS. */
function expiration_from_date(string $date): string
{
    if (!valid_date($date)) {
        throw new RuntimeException('Data de validade inválida.');
    }
    $dt = new DateTime($date . ' 23:59:59', new DateTimeZone(date_default_timezone_get()));
    $dt->setTimezone(new DateTimeZone('UTC'));
    return $dt->format('Y-m-d\TH:i:s\Z');
}

/** Valor de Expiration (RFC 3339, "Mon DD YYYY ..." ou timestamp) -> timestamp Unix ou null. */
function expiration_ts(?string $v): ?int
{
    if ($v === null || $v === '') {
        return null;
    }
    if (ctype_digit($v)) {
        return (int)$v;
    }
    $ts = strtotime($v);
    return $ts === false ? null : $ts;
}

function fmt_expiration(?string $v): string
{
    $ts = expiration_ts($v);
    if ($v === null || $v === '') {
        return 'sem validade';
    }
    return $ts === null ? $v : date('d/m/Y H:i', $ts);
}

/** Código aleatório sem caracteres ambíguos (0/O, 1/I/L). */
function random_code(int $len, string $alphabet = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789'): string
{
    $out = '';
    $max = strlen($alphabet) - 1;
    for ($i = 0; $i < $len; $i++) {
        $out .= $alphabet[random_int(0, $max)];
    }
    return $out;
}
