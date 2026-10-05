<?php
declare(strict_types=1);
require __DIR__ . '/../lib/bootstrap.php';
require __DIR__ . '/../lib/layout.php';
require __DIR__ . '/../lib/setup.php';
require __DIR__ . '/../lib/mikrotik.php';
require_role('admin');

$pdo = db();

/** Caminho do assistente para um equipamento/etapa (somente caracteres seguros: passa pelo redirect()). */
function setup_url(string $name = '', string $mode = '', int $step = 0): string
{
    $q = [];
    if ($name !== '') {
        $q[] = 'name=' . rawurlencode($name);
    }
    if ($mode !== '') {
        $q[] = 'mode=' . rawurlencode($mode);
    }
    if ($step > 0) {
        $q[] = 'step=' . $step;
    }
    return 'setup.php' . ($q ? '?' . implode('&', $q) : '');
}

$name = trim((string)($_GET['name'] ?? $_POST['name'] ?? ''));
$modeIn = trim((string)($_GET['mode'] ?? $_POST['mode'] ?? ''));
if ($name !== '' && !clients_d_valid_name($name)) {
    flash('Nome inválido (até 32: letras, números e _ . -).', 'err');
    redirect('setup.php');
}
$mode = setup_valid_mode($modeIn) ?? 'wg';

if (($_SERVER['REQUEST_METHOD'] ?? '') === 'POST') {
    csrf_check();
    $action = post('action');
    $back = setup_url($name, $mode);
    try {
        if ($action === 'start') {
            if ($name === '' || setup_valid_mode($modeIn) === null) {
                throw new RuntimeException('Informe o nome e escolha o tipo de conexão.');
            }
            $s = setup_state($pdo, $name, $mode);
            audit('setup.start', $name, ['mode' => $s['mode']]);
            redirect(setup_url($name, $s['mode'], $s['mode'] === $mode ? ($mode === 'wg' ? 1 : 3) : $s['next']));
        }
        if ($name === '') {
            throw new RuntimeException('Escolha ou crie um equipamento primeiro.');
        }
        $s = setup_state($pdo, $name, $mode);
        if ($action === 'peer') {
            if ($s['mode'] !== 'wg') {
                throw new RuntimeException('Este equipamento usa IP fixo; não há túnel.');
            }
            $ip = wg_peer_add($name, trim((string)($_POST['pubkey'] ?? '')));
            audit('setup.peer', $name, ['ip' => $ip]);
            redirect(setup_url($name, 'wg', 2));
        } elseif ($action === 'rekey') {
            if ($s['mode'] !== 'wg' || !$s['peer']) {
                throw new RuntimeException('Este equipamento ainda não está no túnel; use "Adicionar ao túnel".');
            }
            $ip = wg_peer_rekey($name, trim((string)($_POST['pubkey'] ?? '')));
            audit('setup.rekey', $name, ['ip' => $ip]);
            flash('Chave trocada. O roteador usa o mesmo IP do túnel (' . $ip . '). Confira a conexão abaixo.');
            redirect(setup_url($name, 'wg', 2));
        } elseif ($action === 'register') {
            if ($s['nas']) {
                throw new RuntimeException('Este equipamento já está cadastrado.');
            }
            if ($s['mode'] === 'wg') {
                if (!$s['peer'] || !$s['handshake_ever']) {
                    throw new RuntimeException('Conclua antes o túnel (etapas 1 e 2).');
                }
                $ip = $s['ip'];
                $desc = 'WireGuard';
            } else {
                $ip = post('ip');
                if (str_starts_with($ip, WG_NET)) {
                    throw new RuntimeException('Esse IP é da rede interna do túnel; escolha "IP dinâmico (túnel)" para usá-lo.');
                }
                $desc = 'IP fixo';
            }
            $r = nas_register($pdo, $name, $ip, (string)($_POST['secret'] ?? ''), $desc, ['via' => 'setup']);
            audit('setup.register', $name, ['ip' => $ip]);
            if ($r['file_ok']) {
                flash('Equipamento cadastrado. Falta aplicar no servidor.');
            } else {
                flash('Cadastrado, mas o arquivo clients.d não foi gravado: ' . $r['file_error'] . ' O "Aplicar" regrava os arquivos.', 'err');
            }
            redirect(setup_url($name, $s['mode'], 4));
        } elseif ($action === 'apply') {
            if (!$s['nas']) {
                throw new RuntimeException('Cadastre o equipamento antes de aplicar.');
            }
            $res = nas_apply_all($pdo);
            audit('setup.apply', $name, ['ok' => $res['ok']]);
            flash($res['message'], $res['ok'] ? 'ok' : 'err');
            redirect(setup_url($name, $s['mode'], 4));
        }
        throw new RuntimeException('Ação desconhecida.');
    } catch (RuntimeException $e) {
        flash(friendly_error($e, 'setup'), 'err');
        redirect($back);
    }
}

// ---------- GET: lista de equipamentos (sem nome) ou etapa do equipamento
page_header('Ativar equipamento', 'setup');

if ($name === '') {
    $list = [];
    $listErr = '';
    try {
        $list = setup_list($pdo);
    } catch (Throwable $e) {
        $listErr = friendly_error($e, 'setup');
    }
    ?>
<div class="card">
<p class="muted">Este assistente leva um MikroTik, passo a passo, até autenticar neste servidor: túnel (se o IP muda), cadastro, aplicar no servidor, script do roteador e teste.
Em cada etapa o painel confere o que já está feito.</p>
<h2>Novo equipamento</h2>
<form method="post" autocomplete="off">
  <?= csrf_field() ?><input type="hidden" name="action" value="start">
  <div class="row gap">
    <label>Nome curto<input name="name" required maxlength="32" placeholder="loja-centro"></label>
  </div>
  <div class="checks gap">
    <label><input type="radio" name="mode" value="wg" checked> IP dinâmico (túnel WireGuard, recomendado)</label>
    <label><input type="radio" name="mode" value="fixed"> IP fixo (o roteador tem sempre o mesmo IP público)</label>
  </div>
  <button>Começar</button>
</form>
</div>
<?php if ($listErr !== ''): ?><div class="flash err"><?= h($listErr) ?></div><?php endif; ?>
<h2>Equipamentos</h2>
<?php if (!$list): ?>
  <p class="muted">Nenhum ainda.</p>
<?php else: ?>
<div class="scroll"><table>
  <tr><th>Nome</th><th>Tipo</th><th>Situação</th><th></th></tr>
  <?php foreach ($list as $d): ?>
  <tr>
    <td><?= h($d['name']) ?></td>
    <td><?= $d['mode'] === 'wg' ? 'Túnel' : 'IP fixo' ?></td>
    <td><?= $d['active'] ? '<span class="tag good">ativo</span>' : '<span class="tag">etapa ' . (int)$d['next'] . ' de 6: ' . h(SETUP_STEPS[$d['next']]) . '</span>' ?></td>
    <td><a href="<?= h(setup_url($d['name'], $d['mode'], $d['next'])) ?>"><?= $d['active'] ? 'Rever' : 'Continuar' ?></a></td>
  </tr>
  <?php endforeach; ?>
</table></div>
<?php endif;
    page_footer();
    exit;
}

$s = setup_state($pdo, $name, $mode);
$mode = $s['mode'];
$step = (int)($_GET['step'] ?? 0);
if ($step < 1 || $step > 6) {
    $step = $s['next'];
}
if ($mode === 'fixed' && $step < 3) {
    $step = 3;
}
if ($step > $s['max']) {
    flash('Antes dessa etapa, conclua a etapa ' . $s['next'] . ' (' . SETUP_STEPS[$s['next']] . ').', 'err');
    redirect(setup_url($name, $mode, $s['next']));
}

$steps = setup_steps_for($mode);
echo '<ol class="steps">';
foreach ($steps as $n => $label) {
    $cls = $n === $step ? 'cur' : ($n < $s['next'] || ($n <= 5 && $s['active']) ? 'done' : '');
    $reach = $n <= $s['max'];
    echo '<li class="' . $cls . '">' . ($reach ? '<a href="' . h(setup_url($name, $mode, $n)) . '">' : '') . $n . '. ' . h($label) . ($reach ? '</a>' : '') . '</li>';
}
echo '</ol>';
echo '<p class="muted">Equipamento: <strong>' . h($name) . '</strong>'
    . ($s['ip'] !== '' ? ' · IP ' . h($s['ip']) : '') . ' · <a href="setup.php">outros equipamentos</a></p>';

$serverPublic = (string)cfg('server_ip', '');
echo '<div class="card">';
if ($serverPublic === '' && ($mode === 'fixed' ? $step >= 5 : $step === 2)) {
    echo '<p><span class="tag bad">falta configurar</span> O painel não sabe o <strong>IP público do servidor</strong> (<code>server_ip</code> em <code>/etc/radpanel/config.php</code>), '
        . 'e sem ele não dá para montar o script. No servidor, rode: <code>sudo /opt/radpanel/bin/update.sh</code> (ele descobre o IP) '
        . 'ou defina na mão: <code>sudo sed -i "s#\'server_ip\' =&gt; \'\'#\'server_ip\' =&gt; \'SEU_IP\'#" /etc/radpanel/config.php</code></p>';
}

if ($step === 1) {
    ?>
<h2>1. Túnel: chave do roteador</h2>
<p>No terminal do MikroTik (WinBox → New Terminal) rode estas duas linhas e copie a chave que aparecer:</p>
<pre data-copy>/interface wireguard add name=wg-radius listen-port=13231
:put [/interface wireguard get wg-radius public-key]</pre>
<p class="muted">Se aparecer "already have interface with name wg-radius", tudo bem: a segunda linha já mostra a chave.</p>
<?php if ($s['peer']): ?>
  <p><span class="tag good">feito</span> Este roteador já está no túnel com o IP <span class="mono"><?= h($s['ip']) ?></span>.
  <a href="<?= h(setup_url($name, $mode, 2)) ?>">Continuar para a etapa 2</a></p>
  <h3>Trocar a chave deste roteador</h3>
  <p class="muted">Use se você recriou a interface <code>wg-radius</code> no MikroTik: a chave muda e o túnel não conecta até o painel receber a nova. O IP do túnel continua o mesmo.</p>
  <form method="post" autocomplete="off">
    <?= csrf_field() ?><input type="hidden" name="action" value="rekey">
    <input type="hidden" name="name" value="<?= h($name) ?>"><input type="hidden" name="mode" value="wg">
    <label>Nova chave pública do MikroTik<input name="pubkey" required minlength="44" maxlength="44" placeholder="44 caracteres terminando em ="></label>
    <button>Trocar a chave</button>
  </form>
<?php else: ?>
<form method="post" autocomplete="off">
  <?= csrf_field() ?><input type="hidden" name="action" value="peer">
  <input type="hidden" name="name" value="<?= h($name) ?>"><input type="hidden" name="mode" value="wg">
  <label>Chave pública do MikroTik<input name="pubkey" required minlength="44" maxlength="44" placeholder="44 caracteres terminando em ="></label>
  <button>Adicionar ao túnel</button>
</form>
<?php endif;
    if ($s['wg_error'] !== '') {
        echo '<p><span class="tag bad">erro</span> ' . h($s['wg_error']) . '</p>';
    }
} elseif ($step === 2) {
    $pub = null;
    $scriptErr = '';
    try {
        $pub = wg_server_pubkey();
    } catch (Throwable $e) {
        $scriptErr = friendly_error($e, 'setup');
    }
    ?>
<h2>2. Túnel: ligar o roteador ao servidor</h2>
<p>Cole este script no terminal do MikroTik. Pode repetir sem criar nada em duplicidade.</p>
<?php
    if ($pub !== null && $s['peer']) {
        try {
            echo '<pre data-copy>' . h(mikrotik_wg_script([
                'server_ip' => $serverPublic, 'server_pub' => $pub, 'address' => $s['ip'], 'name' => $name,
            ])) . '</pre>';
        } catch (RuntimeException $e) {
            $scriptErr = $e->getMessage();
        }
    }
    if ($scriptErr !== '') {
        echo '<p><span class="tag bad">erro</span> ' . h($scriptErr) . '</p>';
    }
    ?>
<h3>Conferir a conexão</h3>
<?php if ($s['connected']): ?>
  <p><span class="tag good">conectado</span> Último contato há <?= (int)$s['age'] ?> s. O túnel está funcionando.</p>
<?php elseif ($s['handshake_ever']): ?>
  <p><span class="tag good">já conectou</span> mas o último contato foi há <?= h(fmt_age((int)$s['age'])) ?>. Se o roteador está ligado, confira a internet dele.</p>
<?php else: ?>
  <p><span class="tag bad">ainda sem conexão</span> Depois de colar o script, espere uns segundos e use "Verificar de novo".</p>
  <ul class="muted">
    <li>Libere <strong>UDP 51820</strong> na Security List da Oracle.</li>
    <li>No MikroTik: <code>/interface wireguard peers print</code> (deve mostrar o servidor) e <code>/ping 10.99.0.1 count=3</code>.</li>
    <li>O relógio do roteador precisa estar certo (<code>/system clock print</code>).</li>
    <li>Recriou a interface <code>wg-radius</code> no MikroTik? A chave mudou: rode <code>:put [/interface wireguard get wg-radius public-key]</code> e use
      <a href="<?= h(setup_url($name, $mode, 1)) ?>">Trocar a chave (etapa 1)</a>.</li>
  </ul>
<?php endif; ?>
<p><a class="btn" href="<?= h(setup_url($name, $mode, 2)) ?>">Verificar de novo</a>
<?php if ($s['handshake_ever']): ?> <a class="btn" href="<?= h(setup_url($name, $mode, 3)) ?>">Continuar</a><?php endif; ?></p>
<?php
} elseif ($step === 3) {
    ?>
<h2>3. Cadastrar o equipamento</h2>
<?php if ($s['nas']): ?>
  <p><span class="tag good">feito</span> Cadastrado com o IP <span class="mono"><?= h($s['ip']) ?></span>.
  <a href="<?= h(setup_url($name, $mode, 4)) ?>">Continuar</a></p>
<?php else: ?>
<p>O <strong>segredo</strong> é a senha entre o roteador e o servidor. Sugerimos um aleatório; guarde-o, ele aparece de novo na etapa 5.</p>
<form method="post" autocomplete="off">
  <?= csrf_field() ?><input type="hidden" name="action" value="register">
  <input type="hidden" name="name" value="<?= h($name) ?>"><input type="hidden" name="mode" value="<?= h($mode) ?>">
  <div class="row gap">
    <?php if ($mode === 'wg'): ?>
      <label>IP do túnel<input value="<?= h($s['ip']) ?>" readonly></label>
    <?php else: ?>
      <label>IP público do roteador<input name="ip" required placeholder="203.0.113.10"></label>
    <?php endif; ?>
    <label>Segredo<input name="secret" required minlength="8" maxlength="60" value="<?= h(setup_gen_secret()) ?>" autocomplete="new-password"></label>
  </div>
  <button>Cadastrar</button>
</form>
<?php endif;
} elseif ($step === 4) {
    ?>
<h2>4. Aplicar no servidor</h2>
<p>O FreeRADIUS só passa a conhecer o equipamento depois de reiniciar. A configuração é validada antes; se for inválida, o serviço não é reiniciado.</p>
<p>Arquivo do equipamento: <?= $s['file'] ? '<span class="tag good">gravado</span>' : '<span class="tag bad">ausente</span>' ?>
 · Aplicado: <?= $s['applied'] ? '<span class="tag good">sim</span>' : '<span class="tag bad">ainda não</span>' ?></p>
<?php if ($s['file'] && $s['applied']): ?>
  <p><span class="tag good">feito</span> <a href="<?= h(setup_url($name, $mode, 5)) ?>">Continuar</a></p>
<?php endif; ?>
<form method="post" data-confirm="Reiniciar o FreeRADIUS agora? Autenticações em andamento serão perdidas por alguns instantes (os roteadores tentam de novo).">
  <?= csrf_field() ?><input type="hidden" name="action" value="apply">
  <input type="hidden" name="name" value="<?= h($name) ?>"><input type="hidden" name="mode" value="<?= h($mode) ?>">
  <button>Aplicar (reiniciar serviço)</button>
</form>
<?php
} elseif ($step === 5) {
    $q = $pdo->prepare('SELECT nasname, secret FROM nas WHERE shortname = ?');
    $q->execute([$name]);
    $row = $q->fetch();
    ?>
<h2>5. Configurar o RADIUS no roteador</h2>
<p>Cole este script no terminal do MikroTik. Ele aponta o hotspot para este servidor<?= $mode === 'wg' ? ' pelo túnel' : '' ?>. Para outras opções (só hotspot, só PPP, portas) use <a href="tools.php">Ferramentas</a>.</p>
<?php
    try {
        if (!$row) {
            throw new RuntimeException('Equipamento não cadastrado.');
        }
        echo '<pre data-copy>' . h(mikrotik_script([
            'server_ip' => $mode === 'wg' ? '10.99.0.1' : $serverPublic, 'secret' => (string)$row['secret'], 'name' => $name,
            'services' => ['hotspot', 'ppp'], 'auth_port' => '1812', 'acct_port' => '1813', 'accounting' => true, 'interim' => '5',
            'incoming' => true, 'coa_port' => '3799', 'hotspot_profile' => '',
            'src_address' => $mode === 'wg' ? (string)$row['nasname'] : '',
        ])) . '</pre>';
    } catch (RuntimeException $e) {
        echo '<p><span class="tag bad">erro</span> ' . h($e->getMessage()) . ' O segredo pode ter caracteres que o MikroTik não aceita; use o botão de cadastrar de novo com um segredo só de letras e números.</p>';
    }
    echo '<p><a class="btn" href="' . h(setup_url($name, $mode, 6)) . '">Já colei, ir para o teste</a></p>';
} else {
    ?>
<h2>6. Teste e ativação</h2>
<ul class="checklist">
<?php if ($mode === 'wg'): ?>
  <li><?= $s['connected'] ? '<span class="tag good">ok</span> Túnel conectado (há ' . (int)$s['age'] . ' s)' : '<span class="tag bad">falha</span> Túnel sem contato recente: veja a etapa 2' ?></li>
<?php endif; ?>
  <li><?= ($s['file'] && $s['applied']) ? '<span class="tag good">ok</span> Servidor aplicado com este equipamento' : '<span class="tag bad">falta</span> Aplicar no servidor: veja a etapa 4' ?></li>
  <li><?= $s['signals'] > 0
        ? '<span class="tag good">ok</span> O roteador já registrou ' . (int)$s['signals'] . ' sessão(ões)' . ($s['last_signal'] ? ' (a última em ' . h((string)$s['last_signal']) . ')' : '')
        : '<span class="tag bad">aguardando</span> Nenhuma sessão deste roteador ainda' ?></li>
</ul>
<?php if ($s['active']): ?>
  <p><span class="tag good">equipamento ativo</span> O roteador está autenticando neste servidor.</p>
<?php else: ?>
  <p>Conecte um aparelho ao hotspot e entre com um usuário do painel (por exemplo o usuário <span class="mono">teste</span>). Depois use "Verificar de novo".</p>
  <ul class="muted">
    <li>No MikroTik: <code>/radius print</code> deve listar o servidor; <code>/radius monitor 0</code> mostra pedidos aceitos e recusados.</li>
    <li>Confira se o perfil do hotspot usa RADIUS (<code>/ip hotspot profile print</code>).</li>
    <li>Se aparecer "recusado", veja a lista de rejeições no Início do painel.</li>
  </ul>
<?php endif; ?>
<p><a class="btn" href="<?= h(setup_url($name, $mode, 6)) ?>">Verificar de novo</a></p>
<?php
}
echo '</div>';
if ($step > min(array_keys($steps))) {
    $prev = $step - 1;
    if ($mode === 'fixed' && $prev < 3) {
        $prev = 0;
    }
    if ($prev > 0) {
        echo '<p><a href="' . h(setup_url($name, $mode, $prev)) . '">← Voltar</a></p>';
    }
}
page_footer(['js' => []]);
