<?php
declare(strict_types=1);
require __DIR__ . '/../lib/bootstrap.php';
require __DIR__ . '/../lib/layout.php';
require __DIR__ . '/../lib/clients_d.php';
require __DIR__ . '/../lib/wireguard.php';
require __DIR__ . '/../lib/mikrotik.php';
require_role('admin');

$pdo = db();
$newScript = null;
$newIp = '';
$newName = '';

if (($_SERVER['REQUEST_METHOD'] ?? '') === 'POST') {
    csrf_check();
    $action = post('action');
    try {
        if ($action === 'add') {
            $name = post('name');
            $key = trim((string)($_POST['pubkey'] ?? ''));
            $ip = wg_peer_add($name, $key);
            $pub = wg_server_pubkey();
            if ($pub === null) {
                throw new RuntimeException('Não consegui ler a chave pública do servidor.');
            }
            // A chave pública do roteador não é segredo, mas também não vai para a auditoria.
            audit('wg.add', $name, ['ip' => $ip]);
            $newScript = mikrotik_wg_script([
                'server_ip' => (string)cfg('server_ip', ''), 'server_pub' => $pub, 'address' => $ip, 'name' => $name,
            ]);
            $newIp = $ip;
            $newName = $name;
        } elseif ($action === 'remove') {
            $name = post('name');
            wg_peer_remove($name);
            audit('wg.remove', $name);
            flash_redirect('Roteador removido do túnel. Se ele estava em Equipamentos, remova-o lá também.', 'ok', 'wireguard.php');
        } elseif ($action === 'register') {
            // Cadastra o IP do túnel como equipamento (mesmas regras de nas.php).
            $name = post('name');
            $ip = post('ip');
            $secret = (string)($_POST['secret'] ?? '');
            $known = array_column(wg_peers(), 'ip', 'name');
            if (($known[$name] ?? null) !== $ip) {
                throw new RuntimeException('Roteador não encontrado no túnel.');
            }
            if (strlen($secret) < 8 || strlen($secret) > 60 || !preg_match('/^[\x21-\x7e]+$/', $secret)
                || str_contains($secret, '${') || str_contains($secret, '%{')) {
                throw new RuntimeException('Segredo: de 8 a 60 caracteres, sem espaços, sem "${" nem "%{".');
            }
            $st = $pdo->prepare('SELECT COUNT(*) FROM nas WHERE nasname = ? OR shortname = ?');
            $st->execute([$ip, $name]);
            if ((int)$st->fetchColumn() > 0) {
                throw new RuntimeException('Já existe equipamento com esse IP ou nome.');
            }
            $pdo->prepare('INSERT INTO nas (nasname, shortname, type, secret, description) VALUES (?, ?, "other", ?, ?)')
                ->execute([$ip, $name, $secret, 'WireGuard']);
            audit('nas.add', $name, ['ip' => $ip, 'via' => 'wireguard']);
            try {
                clients_d_write($name, $ip, $secret);
                flash_redirect('Equipamento cadastrado. Agora vá em Equipamentos e clique em "Aplicar (reiniciar serviço)".', 'ok', 'wireguard.php');
            } catch (RuntimeException $e) {
                flash_redirect('Cadastrado, mas o arquivo clients.d não foi gravado: ' . friendly_error($e, 'nas')
                    . ' Use "Aplicar" em Equipamentos, que regrava os arquivos.', 'err', 'wireguard.php');
            }
        } else {
            throw new RuntimeException('Ação desconhecida.');
        }
    } catch (Throwable $e) {
        flash(friendly_error($e, 'wg'), 'err');
        redirect('wireguard.php');
    }
}

$setupErr = '';
$serverPub = null;
$peers = [];
try {
    $serverPub = wg_server_pubkey();
    if ($serverPub !== null) {
        $peers = wg_peers();
    }
} catch (Throwable $e) {
    $setupErr = friendly_error($e, 'wg');
}
$registered = array_flip($pdo->query('SELECT nasname FROM nas')->fetchAll(PDO::FETCH_COLUMN));

page_header('VPN WireGuard', 'wireguard');
?>
<div class="card">
<p class="muted">Para roteadores com <strong>IP dinâmico</strong>: o MikroTik liga um túnel criptografado até este servidor e ganha um
IP fixo interno (<code>10.99.0.N</code>). É esse IP que vai em Equipamentos. Só a chave <strong>pública</strong> do roteador entra aqui.</p>
<?php if ($setupErr !== ''): ?>
  <p><span class="tag bad">erro</span> <?= h($setupErr) ?></p>
<?php elseif ($serverPub === null): ?>
  <p><span class="tag bad">não configurado</span> No servidor, rode uma vez:</p>
  <pre>sudo bash /opt/radpanel/bin/wg-setup.sh</pre>
  <p class="muted">Depois libere <strong>UDP 51820</strong> na Security List da Oracle e recarregue esta página.</p>
<?php else: ?>
  <p><span class="tag good">ativo</span> Servidor <span class="mono">10.99.0.1</span> · porta UDP 51820 ·
  chave pública: <span class="mono"><?= h($serverPub) ?></span></p>
<?php endif; ?>
</div>

<?php if ($serverPub !== null): ?>
<?php if ($newScript !== null): ?>
<h2>Roteador "<?= h($newName) ?>" adicionado: IP do túnel <?= h($newIp) ?></h2>
<div class="card">
<ol>
<li>Cole este script no terminal do MikroTik. Ele pode ser repetido sem criar nada em duplicidade.</li>
<li>Cadastre o equipamento abaixo (ou em Equipamentos, com IP <span class="mono"><?= h($newIp) ?></span>) e clique em "Aplicar".</li>
<li>Em Ferramentas, gere o script do RADIUS com servidor <span class="mono">10.99.0.1</span> e "IP do túnel" <span class="mono"><?= h($newIp) ?></span>.</li>
</ol>
<pre><?= h($newScript) ?></pre>
</div>
<?php endif; ?>

<h2>Adicionar roteador</h2>
<div class="card">
<p><strong>Passo 1.</strong> No terminal do MikroTik (WinBox → New Terminal) rode estas duas linhas e copie a chave que aparecer:</p>
<pre>/interface wireguard add name=wg-radius listen-port=13231
:put [/interface wireguard get wg-radius public-key]</pre>
<p><strong>Passo 2.</strong> Cole a chave aqui. O painel dá um IP fixo de túnel e gera o resto do script.</p>
<form method="post" autocomplete="off">
  <?= csrf_field() ?><input type="hidden" name="action" value="add">
  <div class="row gap">
    <label>Nome curto<input name="name" required maxlength="32" placeholder="loja-centro"></label>
    <label>Chave pública do MikroTik<input name="pubkey" required minlength="44" maxlength="44" placeholder="44 caracteres terminando em ="></label>
  </div>
  <button>Adicionar e gerar script</button>
</form>
</div>

<h2>Roteadores no túnel</h2>
<?php if (!$peers): ?>
  <p class="muted">Nenhum ainda.</p>
<?php else: ?>
<table>
  <tr><th>Nome</th><th>IP do túnel</th><th>Equipamento</th><th></th></tr>
  <?php foreach ($peers as $p): ?>
  <tr>
    <td><?= h($p['name']) ?></td>
    <td class="mono"><?= h($p['ip']) ?></td>
    <td>
      <?php if (isset($registered[$p['ip']])): ?>
        <span class="tag good">cadastrado</span>
      <?php else: ?>
        <form method="post" class="inline" autocomplete="off">
          <?= csrf_field() ?><input type="hidden" name="action" value="register">
          <input type="hidden" name="name" value="<?= h($p['name']) ?>"><input type="hidden" name="ip" value="<?= h($p['ip']) ?>">
          <input name="secret" required minlength="8" maxlength="60" autocomplete="new-password" placeholder="segredo RADIUS">
          <button>Cadastrar</button>
        </form>
      <?php endif; ?>
    </td>
    <td>
      <form method="post" class="inline" data-confirm="Remover este roteador do túnel? Ele perde o acesso ao servidor.">
        <?= csrf_field() ?><input type="hidden" name="action" value="remove"><input type="hidden" name="name" value="<?= h($p['name']) ?>">
        <button class="danger">Remover</button>
      </form>
    </td>
  </tr>
  <?php endforeach; ?>
</table>
<?php endif; ?>
<?php endif; ?>
<?php page_footer();
