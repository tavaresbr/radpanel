<?php
declare(strict_types=1);
require __DIR__ . '/../lib/bootstrap.php';
require __DIR__ . '/../lib/layout.php';
require __DIR__ . '/../lib/coa.php';
$admin = require_role('viewer');
$canKick = role_at_least($admin, 'operator');

$pdo = db();

if (($_SERVER['REQUEST_METHOD'] ?? '') === 'POST') {
    require_role('operator');
    csrf_check();
    $action = post('action');
    try {
        if ($action === 'disconnect') {
            $st = $pdo->prepare(
                'SELECT radacctid, username, nasipaddress, acctsessionid, framedipaddress FROM radacct
                 WHERE radacctid = ? AND acctstoptime IS NULL'
            );
            $st->execute([(int)post('id')]);
            $r = $st->fetch();
            if (!$r) {
                throw new RuntimeException('Sessão não encontrada ou já encerrada.');
            }
            $res = coa_disconnect($pdo, (string)$r['username'], (string)$r['nasipaddress'],
                (string)$r['acctsessionid'], (string)$r['framedipaddress']);
            flash($res['message'], $res['ok'] ? 'ok' : 'err');
        } elseif ($action === 'disconnect_user') {
            $res = coa_disconnect_user($pdo, post('username'));
            flash($res['message'], ($res['failed'] === 0) ? 'ok' : 'err');
        } else {
            throw new RuntimeException('Ação desconhecida.');
        }
    } catch (Throwable $e) {
        flash(friendly_error($e, 'sessions'), 'err');
    }
    redirect('sessions.php?tab=online');
}
$tab = (string)($_GET['tab'] ?? 'online');
if (!in_array($tab, ['online', 'history', 'usage'], true)) {
    $tab = 'online';
}

$q = mb_substr(trim((string)($_GET['q'] ?? '')), 0, 64);
$from = (string)($_GET['from'] ?? date('Y-m-01'));
$to = (string)($_GET['to'] ?? date('Y-m-d'));
if (!valid_date($from)) {
    $from = date('Y-m-01');
}
if (!valid_date($to)) {
    $to = date('Y-m-d');
}
$page = max(1, (int)($_GET['page'] ?? 1));
$like = '%' . addcslashes($q, '%_\\') . '%';
$offset = page_offset($page);
$filters = 'q=' . urlencode($q) . '&from=' . $from . '&to=' . $to;

page_header('Sessões e consumo', 'sessions');
echo '<p class="pager">';
foreach (['online' => 'Online agora', 'history' => 'Histórico', 'usage' => 'Consumo por usuário'] as $k => $l) {
    echo '<a' . ($k === $tab ? ' class="on"' : '') . ' href="?tab=' . $k . '&amp;' . h($filters) . '">' . h($l) . '</a> ';
}
echo '</p>';

if ($tab === 'online') {
    $rows = $pdo->query(
        'SELECT username, nasipaddress, framedipaddress, callingstationid, acctstarttime,
                acctsessiontime, acctinputoctets, acctoutputoctets, acctupdatetime
         FROM radacct
         WHERE acctstoptime IS NULL AND acctupdatetime > (NOW() - INTERVAL 1 DAY)
         ORDER BY acctstarttime DESC LIMIT 500'
    )->fetchAll();
    echo '<p class="muted">Sessões sem fim registrado e atualizadas nas últimas 24 h. '
        . 'Sem "Interim-Update" no NAS a sessão não aparece como online.</p>';
    echo '<div class="scroll"><table><tr><th>Usuário</th><th>NAS</th><th>IP</th><th>MAC</th><th>Início</th><th>Tempo</th><th>Upload</th><th>Download</th>' . ($canKick ? '<th></th>' : '') . '</tr>';
    foreach ($rows as $r) {
        echo '<tr><td>' . h($r['username']) . '</td><td>' . h($r['nasipaddress']) . '</td><td>' . h($r['framedipaddress'])
            . '</td><td>' . h($r['callingstationid']) . '</td><td>' . h($r['acctstarttime'])
            . '</td><td>' . h(fmt_secs((int)$r['acctsessiontime'])) . '</td><td>' . h(fmt_bytes((int)$r['acctinputoctets']))
            . '</td><td>' . h(fmt_bytes((int)$r['acctoutputoctets'])) . '</td>';
        if ($canKick) {
            echo '<td>'
                . '<form method="post" class="inline" data-confirm="Derrubar esta sessão? O usuário será desconectado do NAS.">'
                . csrf_field() . '<input type="hidden" name="action" value="disconnect">'
                . '<input type="hidden" name="id" value="' . (int)$r['radacctid'] . '"><button class="danger">Derrubar</button></form> '
                . '<form method="post" class="inline" data-confirm="Derrubar TODAS as sessões deste usuário?">'
                . csrf_field() . '<input type="hidden" name="action" value="disconnect_user">'
                . '<input type="hidden" name="username" value="' . h($r['username']) . '"><button class="link">Derrubar todas deste usuário</button></form>'
                . '</td>';
        }
        echo '</tr>';
    }
    if (!$rows) {
        echo '<tr><td colspan="' . ($canKick ? 9 : 8) . '" class="muted">Ninguém online.</td></tr>';
    }
    echo '</table></div>';
} else {
    echo '<form method="get" class="row gap"><input type="hidden" name="tab" value="' . h($tab) . '">'
        . '<label>Usuário<input name="q" value="' . h($q) . '"></label>'
        . '<label>De<input type="date" name="from" value="' . h($from) . '"></label>'
        . '<label>Até<input type="date" name="to" value="' . h($to) . '"></label>'
        . '<button>Filtrar</button></form>';
    $where = 'username LIKE :like AND acctstarttime >= :from AND acctstarttime < DATE_ADD(:to, INTERVAL 1 DAY)';
    $params = [':like' => $like, ':from' => $from, ':to' => $to];
    $base = 'tab=' . $tab . '&' . $filters;

    if ($tab === 'history') {
        $st = $pdo->prepare("SELECT COUNT(*) FROM radacct WHERE $where");
        $st->execute($params);
        $total = (int)$st->fetchColumn();
        $st = $pdo->prepare(
            "SELECT username, nasipaddress, framedipaddress, acctstarttime, acctstoptime, acctsessiontime,
                    acctinputoctets, acctoutputoctets, acctterminatecause
             FROM radacct WHERE $where ORDER BY acctstarttime DESC
             LIMIT " . PER_PAGE . " OFFSET $offset"
        );
        $st->execute($params);
        echo '<div class="scroll"><table><tr><th>Usuário</th><th>NAS</th><th>IP</th><th>Início</th><th>Fim</th><th>Tempo</th><th>Upload</th><th>Download</th><th>Motivo</th></tr>';
        foreach ($st as $r) {
            echo '<tr><td>' . h($r['username']) . '</td><td>' . h($r['nasipaddress']) . '</td><td>' . h($r['framedipaddress'])
                . '</td><td>' . h($r['acctstarttime']) . '</td><td>' . h($r['acctstoptime'] ?? 'em andamento')
                . '</td><td>' . h(fmt_secs((int)$r['acctsessiontime'])) . '</td><td>' . h(fmt_bytes((int)$r['acctinputoctets']))
                . '</td><td>' . h(fmt_bytes((int)$r['acctoutputoctets'])) . '</td><td>' . h($r['acctterminatecause']) . '</td></tr>';
        }
        echo '</table></div>';
        pager($total, $page, $base);
    } else {
        $st = $pdo->prepare("SELECT COUNT(DISTINCT username) FROM radacct WHERE $where");
        $st->execute($params);
        $total = (int)$st->fetchColumn();
        $st = $pdo->prepare(
            "SELECT username, COUNT(*) AS sessions, SUM(acctsessiontime) AS secs,
                    SUM(acctinputoctets) AS up, SUM(acctoutputoctets) AS down
             FROM radacct WHERE $where GROUP BY username
             ORDER BY (SUM(acctinputoctets) + SUM(acctoutputoctets)) DESC
             LIMIT " . PER_PAGE . " OFFSET $offset"
        );
        $st->execute($params);
        echo '<p class="muted">Upload = enviado pelo usuário; download = recebido pelo usuário.</p>';
        echo '<div class="scroll"><table><tr><th>Usuário</th><th>Sessões</th><th>Tempo</th><th>Upload</th><th>Download</th><th>Total</th></tr>';
        foreach ($st as $r) {
            echo '<tr><td>' . h($r['username']) . '</td><td>' . (int)$r['sessions'] . '</td><td>' . h(fmt_secs((int)$r['secs']))
                . '</td><td>' . h(fmt_bytes((int)$r['up'])) . '</td><td>' . h(fmt_bytes((int)$r['down']))
                . '</td><td>' . h(fmt_bytes((int)$r['up'] + (int)$r['down'])) . '</td></tr>';
        }
        echo '</table></div>';
        pager($total, $page, $base);
    }
}
page_footer();
