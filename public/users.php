<?php
declare(strict_types=1);
require __DIR__ . '/../lib/bootstrap.php';
require __DIR__ . '/../lib/layout.php';
$admin = require_role('viewer');
$canWrite = role_at_least($admin, 'operator');

$pdo = db();

if (($_SERVER['REQUEST_METHOD'] ?? '') === 'POST') {
    require_role('operator');
    csrf_check();
    $action = post('action');
    $user = post('username');
    try {
        switch ($action) {
            case 'create':
                ru_create($pdo, $user, (string)($_POST['password'] ?? ''), post('plan'), post('expires') ?: null);
                flash('Usuário criado.');
                break;
            case 'password':
                ru_set_password($pdo, $user, (string)($_POST['password'] ?? ''));
                flash('Senha alterada.');
                break;
            case 'plan':
                ru_set_plan_audited($pdo, $user, post('plan'));
                flash('Plano atualizado.');
                break;
            case 'expires':
                if (ru_set_expiration($pdo, $user, post('expires'))) {
                    flash('Usuário bloqueado: a nova validade será aplicada quando for desbloqueado.');
                } else {
                    flash('Validade atualizada.');
                }
                break;
            case 'block':
                ru_block($pdo, $user);
                flash('Usuário bloqueado.');
                break;
            case 'unblock':
                ru_unblock($pdo, $user);
                flash('Usuário desbloqueado.');
                break;
            case 'delete':
                ru_delete($pdo, $user);
                flash('Usuário excluído.');
                break;
            default:
                throw new RuntimeException('Ação desconhecida.');
        }
    } catch (Throwable $e) {
        flash(friendly_error($e, 'users'), 'err');
    }
    redirect('users.php?' . http_build_query(['q' => mb_substr(post('back'), 0, 64)]));
}

$q = mb_substr(trim((string)($_GET['q'] ?? '')), 0, 64);
$page = max(1, (int)($_GET['page'] ?? 1));
$like = '%' . addcslashes($q, '%_\\') . '%';

$st = $pdo->prepare('SELECT COUNT(DISTINCT username) FROM radcheck WHERE username LIKE ?');
$st->execute([$like]);
$total = (int)$st->fetchColumn();

$st = $pdo->prepare(
    'SELECT c.username,
            (SELECT groupname FROM radusergroup g WHERE g.username = c.username ORDER BY priority LIMIT 1) AS plan,
            (SELECT value FROM radcheck e WHERE e.username = c.username AND e.attribute = :exp LIMIT 1) AS expires,
            COALESCE(m.blocked, 0) AS blocked
     FROM (SELECT DISTINCT username FROM radcheck WHERE username LIKE :like) c
     LEFT JOIN panel_user_meta m ON m.username = c.username
     ORDER BY c.username
     LIMIT ' . PER_PAGE . ' OFFSET ' . page_offset($page)
);
$st->execute([':exp' => ATTR_EXPIRATION, ':like' => $like]);
$rows = $st->fetchAll();
$plans = ru_plans($pdo);

page_header('Usuários', 'users');
?>
<?php if ($canWrite): ?>
<div class="card">
<form method="post" class="row" autocomplete="off">
  <?= csrf_field() ?><input type="hidden" name="action" value="create">
  <label>Usuário<input name="username" required maxlength="64"></label>
  <label>Senha<input name="password" type="text" required minlength="4" maxlength="128" autocomplete="new-password"></label>
  <label>Plano<?= plan_select($plans) ?></label>
  <label>Validade (opcional)<input name="expires" type="date"></label>
  <button>Criar usuário</button>
</form>
</div>
<?php endif; ?>

<form method="get" class="row gap">
  <label>Buscar<input name="q" value="<?= h($q) ?>" placeholder="usuário"></label>
  <button>Filtrar</button>
</form>

<div class="scroll"><table>
<tr><th>Usuário</th><th>Plano</th><th>Validade</th><th>Estado</th><th>Limites</th><?php if ($canWrite): ?><th>Ações</th><?php endif; ?></tr>
<?php foreach ($rows as $r): ?>
<tr>
  <td><?= h($r['username']) ?></td>
  <td>
  <?php if ($canWrite): ?>
    <form method="post" class="inline">
      <?= csrf_field() ?><input type="hidden" name="action" value="plan">
      <input type="hidden" name="username" value="<?= h($r['username']) ?>">
      <input type="hidden" name="back" value="<?= h($q) ?>">
      <?= plan_select($plans, (string)$r['plan']) ?> <button>OK</button>
    </form>
  <?php else: echo h($r['plan'] ?? '—'); endif; ?>
  </td>
  <td><?= $r['blocked'] ? '<span class="muted">—</span>' : h(fmt_expiration($r['expires'])) ?></td>
  <td><?= $r['blocked'] ? '<span class="tag bad">bloqueado</span>' : '<span class="tag good">ativo</span>' ?></td>
  <td><a href="user_limits.php?u=<?= h(urlencode($r['username'])) ?>">Limites</a></td>
  <?php if ($canWrite): ?>
  <td>
    <form method="post" class="inline" autocomplete="off">
      <?= csrf_field() ?><input type="hidden" name="action" value="password">
      <input type="hidden" name="username" value="<?= h($r['username']) ?>">
      <input type="hidden" name="back" value="<?= h($q) ?>">
      <input name="password" placeholder="nova senha" minlength="4" maxlength="128" size="12" required autocomplete="new-password">
      <button>Senha</button>
    </form>
    <form method="post" class="inline">
      <?= csrf_field() ?><input type="hidden" name="action" value="<?= $r['blocked'] ? 'unblock' : 'block' ?>">
      <input type="hidden" name="username" value="<?= h($r['username']) ?>">
      <input type="hidden" name="back" value="<?= h($q) ?>">
      <button><?= $r['blocked'] ? 'Desbloquear' : 'Bloquear' ?></button>
    </form>
    <form method="post" class="inline" data-confirm="Excluir este usuário?">
      <?= csrf_field() ?><input type="hidden" name="action" value="delete">
      <input type="hidden" name="username" value="<?= h($r['username']) ?>">
      <input type="hidden" name="back" value="<?= h($q) ?>">
      <button class="danger">Excluir</button>
    </form>
  </td>
  <?php endif; ?>
</tr>
<?php endforeach; if (!$rows): ?>
<tr><td colspan="6" class="muted">Nenhum usuário encontrado.</td></tr>
<?php endif; ?>
</table></div>
<?php pager($total, $page, 'q=' . urlencode($q)); page_footer();
