<?php
declare(strict_types=1);
require __DIR__ . '/../lib/portal.php';

$cust = require_customer();
$user = $cust['username'];

try {
    $st = db()->prepare('SELECT blocked FROM panel_user_meta WHERE username = ?');
    $st->execute([$user]);
    $blocked = (int)($st->fetchColumn() ?: 0) === 1;
} catch (Throwable $e) {
    log_exception($e, 'portal.password');
    $blocked = true;
}
if ($blocked) {
    flash('Conta bloqueada. Procure o atendimento.', 'err');
    redirect('dashboard.php');
}

if (($_SERVER['REQUEST_METHOD'] ?? '') === 'POST') {
    csrf_check();
    $old = (string)($_POST['old'] ?? '');
    $new = (string)($_POST['new'] ?? '');
    $conf = (string)($_POST['confirm'] ?? '');
    $ip = rate_ip();
    try {
        if ($old === '' || strlen($old) > 253) {
            flash('Informe a senha atual.', 'err');
        } elseif (mb_strlen($new) < PORTAL_MIN_PASS || strlen($new) > 253) {
            flash('A nova senha deve ter pelo menos ' . PORTAL_MIN_PASS . ' caracteres.', 'err');
        } elseif (!hash_equals($new, $conf)) {
            flash('A confirmação não confere com a nova senha.', 'err');
        } elseif (hash_equals($old, $new)) {
            flash('A nova senha deve ser diferente da atual.', 'err');
        } elseif (portal_rate_blocked($user, $ip)) {
            flash('Muitas tentativas. Aguarde alguns minutos.', 'err');
        } else {
            // Usuário SEMPRE o da sessão. A procedure só altera Password.Cleartext se "old" confere.
            $st = db()->prepare('CALL portal_set_password(?, ?, ?)');
            $st->execute([$user, $old, $new]);
            $changed = (int)($st->fetchColumn() ?: 0);
            $st->closeCursor();
            if ($changed > 0) {
                portal_rate_clear($user, $ip);
                session_regenerate_id(true);
                $_SESSION['cust']['stamp'] = cust_stamp($user, $new);
                error_log('radportal: senha alterada pelo cliente ' . $user);
                flash('Senha alterada com sucesso.');
                redirect('dashboard.php');
            }
            portal_rate_fail($user, $ip);
            flash('Senha atual incorreta.', 'err');
        }
    } catch (Throwable $e) {
        flash(friendly_error($e, 'portal.password'), 'err');
    }
    redirect('password.php');
}

portal_header('Alterar senha');
?>
<h1>Alterar senha</h1>
<div class="card">
<form method="post" autocomplete="off">
<?= csrf_field() ?>
<p><label>Senha atual<br><input name="old" type="password" required maxlength="253" autocomplete="current-password"></label></p>
<p><label>Nova senha (mínimo <?= (int)PORTAL_MIN_PASS ?> caracteres)<br><input name="new" type="password" required minlength="<?= (int)PORTAL_MIN_PASS ?>" maxlength="253" autocomplete="new-password"></label></p>
<p><label>Confirme a nova senha<br><input name="confirm" type="password" required maxlength="253" autocomplete="new-password"></label></p>
<button>Alterar senha</button>
</form>
</div>
<p class="muted">Esqueceu a senha atual? Procure o atendimento.</p>
<?php portal_footer();
