<?php
declare(strict_types=1);

// Uso: sudo php create-admin.php USUARIO [admin|operator|viewer]   (senha pedida sem eco)
if (PHP_SAPI !== 'cli') {
    exit(1);
}
$user = $argv[1] ?? '';
$role = $argv[2] ?? 'admin';
if (!preg_match('/^[A-Za-z0-9_.@-]{3,64}$/', $user)) {
    fwrite(STDERR, "Usuário inválido (3-64: letras, números e _ . @ -).\n");
    exit(1);
}
if (!in_array($role, ['admin', 'operator', 'viewer'], true)) {
    fwrite(STDERR, "Papel inválido. Use admin, operator ou viewer.\n");
    exit(1);
}

$cfgFile = getenv('RADPANEL_CONFIG') ?: '/etc/radpanel/config.php';
if (!is_readable($cfgFile)) {
    fwrite(STDERR, "Configuração não encontrada: $cfgFile\n");
    exit(1);
}
$cfg = require $cfgFile;

function read_secret(string $prompt): string
{
    fwrite(STDOUT, $prompt);
    $tty = stream_isatty(STDIN);
    if ($tty) {
        system('stty -echo');
        register_shutdown_function(static function () {
            system('stty echo');
        });
    }
    $line = rtrim((string)fgets(STDIN), "\r\n");
    if ($tty) {
        system('stty echo');
    }
    fwrite(STDOUT, "\n");
    return $line;
}

$p1 = read_secret('Senha (mín. 10 caracteres): ');
$p2 = read_secret('Repita a senha: ');
if ($p1 !== $p2 || strlen($p1) < 10) {
    fwrite(STDERR, "Senhas diferentes ou menores que 10 caracteres.\n");
    exit(1);
}

$pdo = new PDO(
    sprintf(
        'mysql:host=%s;port=%d;dbname=%s;charset=utf8mb4',
        $cfg['db_host'],
        (int)($cfg['db_port'] ?? 3306),
        $cfg['db_name']
    ),
    $cfg['db_user'],
    $cfg['db_pass'],
    [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]
);
$st = $pdo->prepare('SELECT COUNT(*) FROM panel_admins WHERE username = ?');
$st->execute([$user]);
$exists = (int)$st->fetchColumn() > 0;
if ($exists && getenv('RADPANEL_FORCE') !== '1') {
    fwrite(STDERR, "O admin '$user' já existe. Para trocar a senha/papel rode com RADPANEL_FORCE=1.\n");
    exit(1);
}
$pdo->prepare(
    'INSERT INTO panel_admins (username, pass_hash, role) VALUES (?, ?, ?)
     ON DUPLICATE KEY UPDATE pass_hash = VALUES(pass_hash), role = VALUES(role)'
)->execute([$user, password_hash($p1, PASSWORD_ARGON2ID), $role]);
$pdo->prepare('INSERT INTO panel_audit (admin_name, ip, action, target) VALUES (?, ?, ?, ?)')
    ->execute(['cli', 'local', $exists ? 'admin.reset.cli' : 'admin.create.cli', $user]);
fwrite(STDOUT, "Admin '$user' ($role) salvo.\n");
