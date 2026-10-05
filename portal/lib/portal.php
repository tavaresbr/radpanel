<?php
declare(strict_types=1);

/*
 * Portal do cliente. Isolado do painel admin: sessão e cookie próprios ("radportal"),
 * namespace $_SESSION['cust'], outro usuário MySQL (config via RADPANEL_CONFIG do portal).
 * NÃO carrega lib/bootstrap.php (admin), só lib/core.php.
 */
define('PANEL_SESSION_NAME', 'radportal');
require __DIR__ . '/../../lib/core.php';

const CUST_IDLE_SECS = 1200;   // 20 min ocioso
const CUST_MAX_SECS  = 28800;  // 8 h absoluto
const PORTAL_REALM   = 'portal';
const PORTAL_MAX_PAIR = 5;     // por (ip, usuário)
const PORTAL_MAX_IP   = 30;    // por ip
const PORTAL_WINDOW_MIN = 15;
const PORTAL_MIN_PASS = 8;
const PORTAL_GENERIC_FAIL = 'Usuário ou senha inválidos, ou acesso temporariamente bloqueado.';
// Segredo fixo só para igualar o tempo quando o usuário não existe.
const PORTAL_DUMMY_PASS = 'x-dummy-not-a-real-password';

function cust_stamp(string $user, string $pass): string
{
    return substr(hash_hmac('sha256', $pass, 'portal|' . $user), 0, 32);
}

/** Linha do usuário (username exato, case-sensitive) na view portal_user_auth, ou null. */
function cust_rows(string $user): array
{
    $st = db()->prepare('SELECT username, password, expiration FROM portal_user_auth WHERE username = ?');
    $st->execute([$user]);
    return array_values(array_filter(
        $st->fetchAll(),
        static fn(array $r): bool => hash_equals((string)$r['username'], $user)
    ));
}

function cust_destroy(): void
{
    $_SESSION = [];
    if (ini_get('session.use_cookies')) {
        $p = session_get_cookie_params();
        setcookie(session_name(), '', [
            'expires' => time() - 3600, 'path' => $p['path'], 'secure' => $p['secure'],
            'httponly' => true, 'samesite' => 'Strict',
        ]);
    }
    session_destroy();
}

/** Cliente da sessão, revalidado no banco a cada requisição (null se não logado/revogado). */
function current_customer(): ?array
{
    static $cache = false;
    if ($cache !== false) {
        return $cache;
    }
    $cache = null;
    // Sessão que veio do painel admin (id compartilhado/forjado): nunca aceita.
    // Não apaga a sessão do admin: move para um id novo e vazio, mantendo a original intacta.
    if (isset($_SESSION['admin_id']) || isset($_SESSION['admin_stamp'])) {
        session_regenerate_id(false);
        $_SESSION = [];
        return null;
    }
    $c = $_SESSION['cust'] ?? null;
    if (!is_array($c) || !isset($c['user'], $c['stamp'], $c['started'], $c['last']) || !is_string($c['user'])) {
        return null;
    }
    $now = time();
    if ($now - (int)$c['last'] > CUST_IDLE_SECS || $now - (int)$c['started'] > CUST_MAX_SECS) {
        cust_destroy();
        return null;
    }
    $rows = cust_rows($c['user']);
    $match = null;
    foreach ($rows as $r) {
        if (hash_equals(cust_stamp($c['user'], (string)$r['password']), (string)$c['stamp'])) {
            $match = $r;
            break;
        }
    }
    if ($match === null) {   // usuário removido ou senha trocada em outro lugar
        cust_destroy();
        return null;
    }
    $cache = ['username' => (string)$match['username'], 'expiration' => $match['expiration']];
    return $cache;
}

function login_customer(string $user, string $pass): void
{
    session_regenerate_id(true);
    $_SESSION = [
        'cust' => [
            'user' => $user, 'stamp' => cust_stamp($user, $pass),
            'started' => time(), 'last' => time(),
        ],
        'csrf' => bin2hex(random_bytes(32)),
    ];
}

function require_customer(): array
{
    $c = current_customer();
    if ($c === null) {
        redirect('login.php');
    }
    $_SESSION['cust']['last'] = time();
    return $c;
}

/** Limites de tentativas (realm 'portal'; não interfere no admin). */
function portal_rate_blocked(string $user, string $ip): bool
{
    $st = db()->prepare(
        'SELECT COALESCE(SUM(username = ?), 0) AS pair, COUNT(*) AS per_ip FROM panel_login_attempts
         WHERE realm = ? AND ip = ? AND attempted_at > (NOW() - INTERVAL ' . PORTAL_WINDOW_MIN . ' MINUTE)'
    );
    $st->execute([$user, PORTAL_REALM, $ip]);
    $c = $st->fetch();
    return (int)$c['pair'] >= PORTAL_MAX_PAIR || (int)$c['per_ip'] >= PORTAL_MAX_IP;
}

function portal_rate_fail(string $user, string $ip): void
{
    db()->prepare('INSERT INTO panel_login_attempts (ip, username, realm) VALUES (?, ?, ?)')
        ->execute([$ip, $user, PORTAL_REALM]);
}

function portal_rate_clear(string $user, string $ip): void
{
    db()->prepare('DELETE FROM panel_login_attempts WHERE realm = ? AND ip = ? AND username = ?')
        ->execute([PORTAL_REALM, $ip, $user]);
}

function portal_rate_gc(): void
{
    db()->prepare('DELETE FROM panel_login_attempts WHERE realm = ? AND attempted_at < (NOW() - INTERVAL 1 DAY)')
        ->execute([PORTAL_REALM]);
}

function portal_header(string $title, bool $nav = true): void
{
    $f = $_SESSION['flash'] ?? null;
    unset($_SESSION['flash']);
    echo '<!doctype html><html lang="pt-BR"><head><meta charset="utf-8">'
        . '<meta name="viewport" content="width=device-width, initial-scale=1">'
        . '<meta name="robots" content="noindex">'
        . '<title>' . h($title) . ' · Portal do Cliente</title>'
        . '<link rel="stylesheet" href="portal.css"></head><body>';
    if ($nav) {
        echo '<header><strong>Portal do Cliente</strong><nav>'
            . '<a href="dashboard.php">Minha conta</a><a href="password.php">Alterar senha</a></nav>'
            . '<form method="post" action="logout.php">' . csrf_field() . '<button class="link">Sair</button></form></header>';
    }
    echo '<main>';
    if (is_array($f)) {
        echo '<div class="flash ' . ($f[0] === 'err' ? 'err' : 'ok') . '">' . h((string)$f[1]) . '</div>';
    }
}

function portal_footer(): void
{
    echo '</main></body></html>';
}
