<?php
declare(strict_types=1);
require __DIR__ . '/../lib/bootstrap.php';
require __DIR__ . '/../lib/layout.php';
$admin = require_role('admin');

const PASS_MIN = 10;
const PASS_MAX = 256;

function check_password(string $p): void
{
    if (strlen($p) < PASS_MIN) {
        throw new RuntimeException('A senha precisa ter ao menos ' . PASS_MIN . ' caracteres.');
    }
    if (strlen($p) > PASS_MAX) {
        throw new RuntimeException('Senha longa demais (máximo ' . PASS_MAX . ' bytes).');
    }
}

function check_role(string $r): void
{
    if (!isset(ROLES[$r])) {
        throw new RuntimeException('Papel inválido.');
    }
}

/**
 * Executa $fn dentro de uma transação que já travou (FOR UPDATE) todos os admins.
 * $fn recebe o número de administradores com papel "admin". Serializa operações concorrentes
 * e evita que duas requisições removam, cada uma, "o outro" último admin.
 */
function with_admin_lock(callable $fn)
{
    $pdo = db();
    $pdo->beginTransaction();
    try {
        $n = count($pdo->query("SELECT id FROM panel_admins WHERE role = 'admin' ORDER BY id FOR UPDATE")->fetchAll());
        $r = $fn($n);
        $pdo->commit();
        return $r;
    } catch (Throwable $e) {
        if ($pdo->inTransaction()) {
            $pdo->rollBack();
        }
        throw $e;
    }
}

function load_target(int $id): array
{
    $st = db()->prepare('SELECT id, username, role FROM panel_admins WHERE id = ? FOR UPDATE');
    $st->execute([$id]);
    $row = $st->fetch();
    if (!$row) {
        throw new RuntimeException('Administrador não encontrado.');
    }
    return $row;
}

if (($_SERVER['REQUEST_METHOD'] ?? '') === 'POST') {
    csrf_check();
    $action = post('action');
    try {
        if ($action === 'create') {
            $user = post('username');
            $role = post('role');
            $pass = (string)($_POST['password'] ?? '');
            if (!preg_match('/^[A-Za-z0-9_.@-]{3,64}$/D', $user)) {
                throw new RuntimeException('Usuário inválido (3 a 64: letras, números e _ . @ -).');
            }
            check_role($role);
            check_password($pass);
            $hash = password_hash($pass, PASSWORD_ARGON2ID);
            try {
                db()->prepare('INSERT INTO panel_admins (username, pass_hash, role) VALUES (?, ?, ?)')
                    ->execute([$user, $hash, $role]);
            } catch (PDOException $e) {
                if ($e->getCode() === '23000') {
                    throw new RuntimeException('Já existe um administrador com esse usuário.');
                }
                throw $e;
            }
            audit('admin.create', $user, ['role' => $role]);
            flash('Administrador criado.');
        } elseif ($action === 'role') {
            $id = (int)post('id');
            $role = post('role');
            check_role($role);
            if ($id === (int)$admin['id']) {
                throw new RuntimeException('Você não pode mudar o seu próprio papel; peça a outro administrador.');
            }
            $t = with_admin_lock(function (int $admins) use ($id, $role) {
                $t = load_target($id);
                if ($t['role'] === $role) {
                    throw new RuntimeException('O papel já é esse.');
                }
                if ($t['role'] === 'admin' && $role !== 'admin' && $admins <= 1) {
                    throw new RuntimeException('Não é possível rebaixar o último administrador.');
                }
                db()->prepare('UPDATE panel_admins SET role = ? WHERE id = ?')->execute([$role, $id]);
                return $t;
            });
            audit('admin.role', $t['username'], ['from' => $t['role'], 'to' => $role]);
            flash('Papel alterado. As sessões abertas desse usuário foram encerradas.');
        } elseif ($action === 'password') {
            $id = (int)post('id');
            $pass = (string)($_POST['password'] ?? '');
            check_password($pass);
            $hash = password_hash($pass, PASSWORD_ARGON2ID);
            $t = with_admin_lock(function (int $admins) use ($id, $hash) {
                $t = load_target($id);
                db()->prepare('UPDATE panel_admins SET pass_hash = ? WHERE id = ?')->execute([$hash, $id]);
                return $t;
            });
            audit('admin.password', $t['username']);
            if ($id === (int)$admin['id']) {
                // Mantém a sessão atual (o carimbo muda com o hash); as demais sessões do mesmo usuário caem.
                $st = db()->prepare('SELECT id, pass_hash, role FROM panel_admins WHERE id = ?');
                $st->execute([$id]);
                $_SESSION['admin_stamp'] = admin_stamp($st->fetch());
            }
            flash('Senha redefinida. As outras sessões desse usuário foram encerradas.');
        } elseif ($action === 'delete') {
            $id = (int)post('id');
            if ($id === (int)$admin['id']) {
                throw new RuntimeException('Você não pode excluir a si mesmo.');
            }
            $t = with_admin_lock(function (int $admins) use ($id) {
                $t = load_target($id);
                if ($t['role'] === 'admin' && $admins <= 1) {
                    throw new RuntimeException('Não é possível excluir o último administrador.');
                }
                db()->prepare('DELETE FROM panel_admins WHERE id = ?')->execute([$id]);
                return $t;
            });
            audit('admin.delete', $t['username'], ['role' => $t['role']]);
            flash('Administrador excluído.');
        } else {
            throw new RuntimeException('Ação desconhecida.');
        }
    } catch (Throwable $e) {
        flash(friendly_error($e, 'admins'), 'err');
    }
    redirect('admins.php');
}

$rows = db()->query('SELECT id, username, role, created_at FROM panel_admins ORDER BY username')->fetchAll();

function role_options(string $sel): string
{
    $o = '';
    foreach (array_keys(ROLES) as $r) {
        $o .= '<option value="' . h($r) . '"' . ($r === $sel ? ' selected' : '') . '>' . h(role_label($r)) . '</option>';
    }
    return $o;
}

page_header('Administradores', 'admins', ['css' => ['admin.css']]);
?>
<div class="card">
<form method="post" class="row" autocomplete="off">
  <?= csrf_field() ?><input type="hidden" name="action" value="create">
  <label>Usuário<input name="username" required minlength="3" maxlength="64" pattern="[A-Za-z0-9_.@\-]{3,64}"></label>
  <label>Papel<select name="role" class="role-select"><?= role_options('operator') ?></select></label>
  <label>Senha (mín. <?= PASS_MIN ?>)<input type="password" name="password" required minlength="<?= PASS_MIN ?>" autocomplete="new-password"></label>
  <button>Criar administrador</button>
</form>
<p class="muted">Visualizador: só consulta. Operador: gerencia usuários e vouchers. Administrador: tudo, inclusive esta tela.</p>
</div>

<div class="scroll"><table>
<tr><th>Usuário</th><th>Papel</th><th>Criado em</th><th>Ações</th></tr>
<?php foreach ($rows as $r): $self = (int)$r['id'] === (int)$admin['id']; ?>
<tr>
  <td><?= h($r['username']) ?><?= $self ? ' <span class="tag">você</span>' : '' ?></td>
  <td><?= h(role_label($r['role'])) ?></td>
  <td class="nowrap"><?= h($r['created_at']) ?></td>
  <td><div class="cell-forms">
    <?php if (!$self): ?>
    <form method="post" class="inline row">
      <?= csrf_field() ?><input type="hidden" name="action" value="role"><input type="hidden" name="id" value="<?= (int)$r['id'] ?>">
      <select name="role" class="role-select"><?= role_options($r['role']) ?></select><button>Mudar papel</button>
    </form>
    <?php endif; ?>
    <form method="post" class="inline row" autocomplete="off" data-confirm="Redefinir a senha de <?= h($r['username']) ?>?">
      <?= csrf_field() ?><input type="hidden" name="action" value="password"><input type="hidden" name="id" value="<?= (int)$r['id'] ?>">
      <input type="password" name="password" class="pw-input" required minlength="<?= PASS_MIN ?>" placeholder="nova senha" autocomplete="new-password"><button>Redefinir senha</button>
    </form>
    <?php if (!$self): ?>
    <form method="post" class="inline" data-confirm="Excluir o administrador <?= h($r['username']) ?>?">
      <?= csrf_field() ?><input type="hidden" name="action" value="delete"><input type="hidden" name="id" value="<?= (int)$r['id'] ?>">
      <button class="danger">Excluir</button>
    </form>
    <?php endif; ?>
  </div></td>
</tr>
<?php endforeach; ?>
</table></div>
<?php page_footer();
