<?php
declare(strict_types=1);
require __DIR__ . '/../lib/portal.php';

if (current_customer()) {
    redirect('dashboard.php');
}

$err = '';
if (($_SERVER['REQUEST_METHOD'] ?? '') === 'POST') {
    csrf_check();
    $user = mb_substr(post('user'), 0, 64);
    $pass = (string)($_POST['pass'] ?? '');
    $ip = rate_ip();
    try {
        portal_rate_gc();
        $blocked = portal_rate_blocked($user, $ip);
        $rows = (valid_username($user) && strlen($pass) <= 253) ? cust_rows($user) : [];
        // Compara sempre (com um valor falso se não existir) para igualar o tempo de resposta.
        $valid = false;
        $cands = $rows ?: [['password' => PORTAL_DUMMY_PASS]];
        foreach ($cands as $r) {
            $same = hash_equals(hash('sha256', (string)$r['password']), hash('sha256', $pass));
            $valid = $valid || $same;
        }
        $valid = $valid && $rows && !$blocked;

        if ($valid) {
            portal_rate_clear($user, $ip);
            login_customer((string)$rows[0]['username'], $pass);
            redirect('dashboard.php');
        }
        if (!$blocked) {
            portal_rate_fail($user, $ip);
        }
        $err = PORTAL_GENERIC_FAIL;
    } catch (Throwable $e) {
        log_exception($e, 'portal.login');
        $err = 'Erro interno. Tente novamente.';
    }
}
portal_header('Entrar', false);
?>
<div class="login card">
<h1>Portal do Cliente</h1>
<?php if ($err): ?><div class="flash err"><?= h($err) ?></div><?php endif; ?>
<form method="post" autocomplete="off">
<?= csrf_field() ?>
<p><label>Usuário<br><input name="user" required autofocus maxlength="64"></label></p>
<p><label>Senha<br><input name="pass" type="password" required maxlength="253"></label></p>
<button>Entrar</button>
</form>
<p class="muted">Esqueceu a senha? Procure o atendimento.</p>
</div>
<?php portal_footer();
