<?php
declare(strict_types=1);

const ROLES = ['viewer' => 1, 'operator' => 2, 'admin' => 3];
const SESSION_IDLE_SECS = 1800;
const SESSION_MAX_SECS = 43200;

// Hash fixo (argon2id) usado para igualar o tempo de resposta quando o usuário não existe.
const DUMMY_HASH = '$argon2id$v=19$m=65536,t=4,p=1$TVlOc0Rucm9qbGl6OEdOZA$kOEWsmxo9GMyGJQneYtkoC+5ArqnM2z0X0tMIz6l6T0';

/** Carimbo que invalida a sessão quando a senha, o papel ou o estado do admin muda. */
function admin_stamp(array $row): string
{
    return substr(hash('sha256', $row['pass_hash'] . '|' . $row['id'] . '|' . $row['role']), 0, 32);
}

/** Admin da sessão, relido do banco a cada requisição (null se não logado/revogado). */
function current_admin(): ?array
{
    static $cache = false;
    if ($cache !== false) {
        return $cache;
    }
    $cache = null;
    if (empty($_SESSION['admin_id'])) {
        return null;
    }
    $st = db()->prepare('SELECT id, username, pass_hash, role FROM panel_admins WHERE id = ?');
    $st->execute([(int)$_SESSION['admin_id']]);
    $row = $st->fetch();
    if (!$row || !hash_equals(admin_stamp($row), (string)($_SESSION['admin_stamp'] ?? ''))) {
        return null;
    }
    unset($row['pass_hash']);
    $cache = $row;
    return $cache;
}

function destroy_session(): void
{
    $_SESSION = [];
    if (ini_get('session.use_cookies')) {
        $p = session_get_cookie_params();
        setcookie(session_name(), '', [
            'expires'  => time() - 3600,
            'path'     => $p['path'],
            'secure'   => $p['secure'],
            'httponly' => true,
            'samesite' => 'Strict',
        ]);
    }
    session_destroy();
}

function login_admin(array $row): void
{
    session_regenerate_id(true);
    $_SESSION = [
        'admin_id'    => (int)$row['id'],
        'admin_stamp' => admin_stamp($row),
        'started'     => time(),
        'last'        => time(),
        'csrf'        => bin2hex(random_bytes(32)),
    ];
}

function require_login(): array
{
    $admin = current_admin();
    $now = time();
    $expired = $admin && (
        $now - (int)($_SESSION['last'] ?? 0) > SESSION_IDLE_SECS
        || $now - (int)($_SESSION['started'] ?? 0) > SESSION_MAX_SECS
    );
    if (!$admin || $expired) {
        if (!empty($_SESSION)) {
            destroy_session();
        }
        redirect('login.php');
    }
    $_SESSION['last'] = $now;
    return $admin;
}

function role_at_least(array $admin, string $min): bool
{
    return (ROLES[$admin['role']] ?? 0) >= (ROLES[$min] ?? 99);
}

/** Exige papel mínimo; responde 403 caso contrário. Valida no servidor, não só esconde botões. */
function require_role(string $min): array
{
    $admin = require_login();
    if (!role_at_least($admin, $min)) {
        http_response_code(403);
        exit('Acesso negado: seu perfil não permite esta ação.');
    }
    return $admin;
}

function role_label(string $role): string
{
    return ['viewer' => 'Visualizador', 'operator' => 'Operador', 'admin' => 'Administrador'][$role] ?? $role;
}
