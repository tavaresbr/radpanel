<?php
declare(strict_types=1);
require __DIR__ . '/../lib/bootstrap.php';
require __DIR__ . '/../lib/layout.php';
require_role('viewer');

$pdo = db();
$users  = (int)$pdo->query('SELECT COUNT(DISTINCT username) FROM radcheck')->fetchColumn();
$plans  = count(ru_plans($pdo));
$nas    = (int)$pdo->query('SELECT COUNT(*) FROM nas')->fetchColumn();
$online = (int)$pdo->query(
    'SELECT COUNT(*) FROM radacct
     WHERE acctstoptime IS NULL AND acctupdatetime > (NOW() - INTERVAL 1 DAY)'
)->fetchColumn();
$today = $pdo->query(
    'SELECT COALESCE(SUM(acctinputoctets),0) AS up, COALESCE(SUM(acctoutputoctets),0) AS down
     FROM radacct WHERE acctstarttime >= CURDATE()'
)->fetch();

$rej = $pdo->query(
    "SELECT username, authdate FROM radpostauth
     WHERE reply LIKE 'Access-Reject%' ORDER BY id DESC LIMIT 10"
)->fetchAll();

page_header('Início', 'dashboard');
?>
<div class="grid">
  <div class="card stat"><b><?= $online ?></b><span>Online agora</span></div>
  <div class="card stat"><b><?= $users ?></b><span>Usuários</span></div>
  <div class="card stat"><b><?= $plans ?></b><span>Planos</span></div>
  <div class="card stat"><b><?= $nas ?></b><span>Equipamentos</span></div>
</div>
<div class="card">
  <strong>Hoje</strong>:
  upload <?= h(fmt_bytes((int)$today['up'])) ?> ·
  download <?= h(fmt_bytes((int)$today['down'])) ?>
</div>
<h2>Últimas autenticações rejeitadas</h2>
<div class="scroll"><table>
<tr><th>Usuário</th><th>Data</th></tr>
<?php foreach ($rej as $r): ?>
<tr><td><?= h($r['username']) ?></td><td><?= h($r['authdate']) ?></td></tr>
<?php endforeach; if (!$rej): ?>
<tr><td colspan="2" class="muted">Nenhuma rejeição registrada.</td></tr>
<?php endif; ?>
</table></div>
<?php page_footer();
