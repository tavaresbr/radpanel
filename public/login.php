<?php
declare(strict_types=1);
require __DIR__ . '/../lib/bootstrap.php';

const MAX_FAILS_PAIR = 5;     // por IP + usuário
const MAX_FAILS_IP = 30;      // por IP, qualquer usuário
const WINDOW_MIN = 15;
const REALM = 'admin';

if (current_admin()) {
    redirect('dashboard.php');
}

$err = '';
if (($_SERVER['REQUEST_METHOD'] ?? '') === 'POST') {
    csrf_check();
    $user = mb_substr(post('user'), 0, 64);
    $pass = (string)($_POST['pass'] ?? '');
    $ip = rate_ip();
    $generic = 'Usuário ou senha inválidos, ou acesso temporariamente bloqueado.';

    try {
        $pdo = db();
        $pdo->exec('DELETE FROM panel_login_attempts WHERE attempted_at < (NOW() - INTERVAL 1 DAY)');

        $st = $pdo->prepare(
            'SELECT SUM(username = ?) AS pair, COUNT(*) AS per_ip FROM panel_login_attempts
             WHERE realm = ? AND ip = ? AND attempted_at > (NOW() - INTERVAL ' . WINDOW_MIN . ' MINUTE)'
        );
        $st->execute([$user, REALM, $ip]);
        $c = $st->fetch();
        $blocked = (int)$c['pair'] >= MAX_FAILS_PAIR || (int)$c['per_ip'] >= MAX_FAILS_IP;

        $st = $pdo->prepare('SELECT id, username, pass_hash, role FROM panel_admins WHERE username = ?');
        $st->execute([$user]);
        $row = $st->fetch();
        // Sempre verifica um hash (o do usuário ou um fixo) para igualar o tempo de resposta.
        $valid = password_verify($pass, $row['pass_hash'] ?? DUMMY_HASH) && $row && !$blocked;

        if ($valid) {
            $pdo->prepare('DELETE FROM panel_login_attempts WHERE realm = ? AND ip = ? AND username = ?')
                ->execute([REALM, $ip, $user]);
            login_admin($row);
            audit('login.ok', $row['username'], [], $row['username']);
            redirect('dashboard.php');
        }
        if (!$blocked) {
            $pdo->prepare('INSERT INTO panel_login_attempts (ip, username, realm) VALUES (?, ?, ?)')
                ->execute([$ip, $user, REALM]);
            // Só registra tentativas fora do bloqueio (o log não cresce com ataque) e nunca o texto cru:
            // quem erra o campo pode ter digitado a senha no lugar do usuário.
            audit('login.fail', valid_username($user) ? $user : '(nome inválido)', [], '-');
        }
        $err = $generic;
    } catch (Throwable $e) {
        log_exception($e, 'login');
        $err = 'Erro interno. Tente novamente.';
    }
}
?><!doctype html>
<html lang="pt-BR"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Entrar · RadPanel</title><link rel="stylesheet" href="style.css"></head>
<body><div class="login card">
<h1>RadPanel</h1>
<?php if ($err): ?><div class="flash err"><?= h($err) ?></div><?php endif; ?>
<form method="post" autocomplete="off">
<?= csrf_field() ?>
<p><label>Usuário<br><input name="user" required autofocus maxlength="64"></label></p>
<p><label>Senha<br><input name="pass" type="password" required></label></p>
<button>Entrar</button>
</form></div></body></html>
