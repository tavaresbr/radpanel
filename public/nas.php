<?php
declare(strict_types=1);
require __DIR__ . '/../lib/bootstrap.php';
require __DIR__ . '/../lib/layout.php';
require __DIR__ . '/../lib/clients_d.php';
require_role('admin');

$pdo = db();

function valid_nasname(string $n): bool
{
    // IPv4, IPv4/CIDR, IPv6 ou nome de host simples.
    if (!preg_match('/^[A-Za-z0-9.:\/-]{1,128}$/', $n)) {
        return false;
    }
    // Rede larga demais abriria o RADIUS a qualquer origem que saiba o segredo (ex.: 0.0.0.0/0).
    if (preg_match('~^[0-9.]+/([0-9]{1,2})$~', $n, $m) && (int)$m[1] < 24) {
        return false;
    }
    if (preg_match('~^[0-9a-fA-F:]+/([0-9]{1,3})$~', $n, $m) && (int)$m[1] < 64) {
        return false;
    }
    if (in_array($n, ['0.0.0.0', '::', '0.0.0.0/0', '::/0'], true)) {
        return false;
    }
    return true;
}

/** Valor entre aspas para o clients.conf, com escape de \ e ". */
function conf_quote(string $v): string
{
    return '"' . str_replace(['\\', '"'], ['\\\\', '\\"'], $v) . '"';
}

$revealed = false;

if (($_SERVER['REQUEST_METHOD'] ?? '') === 'POST') {
    csrf_check();
    $action = post('action');
    try {
        if ($action === 'add') {
            $nasname = post('nasname');
            $short = post('shortname');
            $secret = (string)($_POST['secret'] ?? '');
            $desc = post('description');
            if (!valid_nasname($nasname)) {
                throw new RuntimeException('IP/host inválido.');
            }
            if (!clients_d_valid_name($short)) {
                throw new RuntimeException('Nome curto inválido (até 32: letras, números e _ . -; não pode começar com ponto ou hífen).');
            }
            if (strlen($secret) < 8 || strlen($secret) > 60 || !preg_match('/^[\x21-\x7e]+$/', $secret)) {
                throw new RuntimeException('Segredo: de 8 a 60 caracteres, sem espaços.');
            }
            if (str_contains($secret, '${') || str_contains($secret, '%{')) {
                throw new RuntimeException('Segredo não pode conter "${" nem "%{" (o FreeRADIUS os trata como expansão).');
            }
            $st = $pdo->prepare('SELECT COUNT(*) FROM nas WHERE nasname = ? OR shortname = ?');
            $st->execute([$nasname, $short]);
            if ((int)$st->fetchColumn() > 0) {
                throw new RuntimeException('Já existe equipamento com esse IP ou nome.');
            }
            $pdo->prepare('INSERT INTO nas (nasname, shortname, type, secret, description) VALUES (?, ?, "other", ?, ?)')
                ->execute([$nasname, $short, $secret, mb_substr($desc, 0, 200)]);
            audit('nas.add', $short, ['ip' => $nasname]);
            try {
                clients_d_write($short, $nasname, $secret);
                flash('Equipamento cadastrado e arquivo clients.d gerado. Clique em "Aplicar (reiniciar serviço)" para o servidor passar a aceitá-lo.');
            } catch (Throwable $e) {
                flash('Equipamento cadastrado, mas o arquivo clients.d não foi gravado: ' . friendly_error($e, 'nas')
                    . ' Corrija e use "Aplicar", que regrava os arquivos.', 'err');
            }
        } elseif ($action === 'delete') {
            $id = (int)post('id');
            $st = $pdo->prepare('SELECT shortname FROM nas WHERE id = ?');
            $st->execute([$id]);
            $short = $st->fetchColumn();
            if ($short === false) {
                throw new RuntimeException('Equipamento não encontrado.');
            }
            // Primeiro o arquivo de cliente: se não der para removê-lo, o NAS continuaria aceito pelo servidor
            // mesmo sumindo da lista; então não apaga o cadastro.
            if (!clients_d_remove((string)$short) && clients_d_exists((string)$short)) {
                throw new RuntimeException('Não consegui remover o arquivo clients.d/' . $short . '.conf; o equipamento foi mantido.');
            }
            $pdo->prepare('DELETE FROM nas WHERE id = ?')->execute([$id]);
            audit('nas.delete', (string)$short);
            flash('Equipamento removido. Clique em "Aplicar (reiniciar serviço)" para o servidor deixar de aceitá-lo.');
        } elseif ($action === 'apply') {
            $all = $pdo->query('SELECT nasname, shortname, secret FROM nas')->fetchAll();
            foreach ($all as $n) {
                clients_d_write((string)$n['shortname'], (string)$n['nasname'], (string)$n['secret']);
            }
            $res = clients_d_apply();
            audit('nas.apply', 'radius', ['ok' => $res['ok'], 'clients' => count($all)]);
            flash($res['message'], $res['ok'] ? 'ok' : 'err');
        } elseif ($action === 'reveal') {
            audit('nas.reveal', 'todos');
            $revealed = true;
        } else {
            throw new RuntimeException('Ação desconhecida.');
        }
    } catch (Throwable $e) {
        flash(friendly_error($e, 'nas'), 'err');
    }
    if (!$revealed) {
        redirect('nas.php');
    }
}

$rows = $pdo->query('SELECT id, nasname, shortname, description, secret FROM nas ORDER BY shortname')->fetchAll();

page_header('Equipamentos (NAS)', 'nas');
?>
<div class="card">
<p class="muted">Cada equipamento vira um arquivo em <code>clients.d/</code>, incluído pelo
<code>clients.conf</code>. O FreeRADIUS 4.0 não recarrega clientes sem reiniciar: depois de cadastrar ou remover,
use <strong>Aplicar (reiniciar serviço)</strong>. Também é preciso liberar o IP na Security List da Oracle (UDP 1812/1813).</p>
<form method="post" class="inline" data-confirm="Reiniciar o FreeRADIUS agora? Requisições de autenticação em andamento serão perdidas por alguns instantes (os NAS tentam de novo).">
  <?= csrf_field() ?><input type="hidden" name="action" value="apply">
  <button>Aplicar (reiniciar serviço)</button>
  <span class="muted">A configuração é validada antes; se for inválida, o serviço não é reiniciado.</span>
</form>
<form method="post" class="row" autocomplete="off">
  <?= csrf_field() ?><input type="hidden" name="action" value="add">
  <label>IP público<input name="nasname" required placeholder="203.0.113.10"></label>
  <label>Nome curto<input name="shortname" required maxlength="32" placeholder="loja-centro"></label>
  <label>Segredo<input name="secret" required minlength="8" maxlength="60" autocomplete="new-password"></label>
  <label>Descrição<input name="description" maxlength="200"></label>
  <button>Cadastrar</button>
</form>
</div>

<div class="scroll"><table>
<tr><th>Nome</th><th>IP</th><th>Descrição</th><th>Arquivo clients.d</th><th></th></tr>
<?php foreach ($rows as $r): ?>
<tr>
  <td><?= h($r['shortname']) ?></td><td><?= h($r['nasname']) ?></td><td><?= h($r['description']) ?></td>
  <td><?= clients_d_exists((string)$r['shortname']) ? 'gravado' : 'ausente' ?></td>
  <td>
    <form method="post" class="inline" data-confirm="Remover este equipamento?">
      <?= csrf_field() ?><input type="hidden" name="action" value="delete">
      <input type="hidden" name="id" value="<?= (int)$r['id'] ?>">
      <button class="danger">Remover</button>
    </form>
  </td>
</tr>
<?php endforeach; if (!$rows): ?>
<tr><td colspan="5" class="muted">Nenhum equipamento cadastrado.</td></tr>
<?php endif; ?>
</table></div>

<h2>Conteúdo dos arquivos clients.d</h2>
<?php if (!$revealed): ?>
<form method="post" class="inline">
  <?= csrf_field() ?><input type="hidden" name="action" value="reveal">
  <p class="muted">Os segredos ficam ocultos. <button class="link">Mostrar segredos (fica registrado na auditoria)</button></p>
</form>
<?php endif; ?>
<pre><?php
foreach ($rows as $r) {
    echo h("client {$r['shortname']} {\n\tipaddr = {$r['nasname']}\n\tproto = *\n\tsecret = "
        . ($revealed ? conf_quote($r['secret']) : '"********"')
        . "\n\trequire_message_authenticator = auto\n\tlimit_proxy_state = auto\n}\n\n");
}
if (!$rows) {
    echo 'Nenhum equipamento.';
}
?></pre>
<?php page_footer();
