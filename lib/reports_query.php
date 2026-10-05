<?php
declare(strict_types=1);

/**
 * Consultas dos relatórios (somente leitura em radacct, radpostauth, nas, radusergroup).
 * Compartilhadas por reports.php (tela) e export.php (CSV). Tudo parametrizado.
 * Nunca selecionar radpostauth.pass (senha digitada).
 */

const RQ_MAX_DAYS = 731;       // limite do período (evita varreduras gigantes)
const RQ_VIEW_LIMIT = 1000;    // linhas exibidas na tela
const RQ_EXPORT_LIMIT = 100000;

function rq_reports(): array
{
    return [
        'dia'       => 'Consumo por dia',
        'mes'       => 'Consumo por mês',
        'top'       => 'Top 20 usuários',
        'nas'       => 'Por NAS',
        'plano'     => 'Por plano',
        'rejeicoes' => 'Rejeições',
        'hora'      => 'Sessões por hora',
    ];
}

/** Colunas: [campo, rótulo, tipo]  tipos: text | int (soma) | cnt (sem soma) | bytes | secs */
function rq_columns(string $report): array
{
    $usage = [
        ['sessoes', 'Sessões', 'int'], ['usuarios', 'Usuários', 'cnt'], ['tempo', 'Tempo online', 'secs'],
        ['up', 'Upload', 'bytes'], ['down', 'Download', 'bytes'], ['total', 'Total', 'bytes'],
    ];
    return match ($report) {
        'dia'       => array_merge([['dia', 'Dia', 'text']], $usage),
        'mes'       => array_merge([['mes', 'Mês', 'text']], $usage),
        'top'       => array_merge([['username', 'Usuário', 'text']], array_slice($usage, 0, 1), array_slice($usage, 2)),
        'nas'       => array_merge([['nasipaddress', 'NAS (IP)', 'text'], ['nome', 'Nome', 'text']], $usage),
        'plano'     => array_merge([['plano', 'Plano', 'text']], $usage),
        'rejeicoes' => [['dia', 'Dia', 'text'], ['username', 'Usuário', 'text'], ['tentativas', 'Rejeições', 'int']],
        'hora'      => array_merge([['hora', 'Hora', 'text']], $usage),
        default     => [],
    };
}

/** Filtros a partir de GET/POST, já validados. */
function rq_filters(array $src): array
{
    $from = (string)($src['from'] ?? '');
    $to = (string)($src['to'] ?? '');
    $from = valid_date($from) ? $from : date('Y-m-01');
    $to = valid_date($to) ? $to : date('Y-m-d');
    $swapped = false;
    $clamped = false;
    if ($from > $to) {
        [$from, $to] = [$to, $from];
        $swapped = true;
    }
    $days = (int)((strtotime($to) - strtotime($from)) / 86400);
    if ($days > RQ_MAX_DAYS) {
        $from = date('Y-m-d', strtotime($to . ' -' . RQ_MAX_DAYS . ' days'));
        $clamped = true;
    }
    $user = preg_replace('/[\x00-\x1f\x7f]/', '', trim((string)($src['user'] ?? ''))) ?? '';
    $user = mb_substr($user, 0, 64);
    $nas = trim((string)($src['nas'] ?? ''));
    if (!preg_match('/^[0-9.]{1,15}$/', $nas)) {
        $nas = '';
    }
    $plan = trim((string)($src['plan'] ?? ''));
    if (!valid_plan($plan)) {
        $plan = '';
    }
    return compact('from', 'to', 'user', 'nas', 'plan', 'swapped', 'clamped');
}

/** Primeiro dia do mês, 11 meses antes do mês de $to (janela de 12 meses). */
function rq_month_start(string $to): string
{
    return date('Y-m-01', strtotime(substr($to, 0, 7) . '-01 -11 months'));
}

/** Condição de usuário: exata, ou prefixo se terminar em "*". Evita LIKE '%x%'. */
function rq_user_cond(string $col, string $user, array &$params): string
{
    if (str_ends_with($user, '*')) {
        $prefix = substr($user, 0, -1);
        $params[':user'] = str_replace(['!', '%', '_'], ['!!', '!%', '!_'], $prefix) . '%';
        return "$col LIKE :user ESCAPE '!'";
    }
    $params[':user'] = $user;
    return "$col = :user";
}

/** Subconsulta do plano principal (menor prioridade) de cada usuário. */
const RQ_PRIMARY_PLAN = "(SELECT username, SUBSTRING_INDEX(GROUP_CONCAT(groupname ORDER BY priority, id SEPARATOR ','), ',', 1) AS plano
                          FROM radusergroup GROUP BY username)";

/** @return array{0:string,1:array} WHERE e parâmetros para radacct (alias a; ug quando $primary). */
function rq_acct_where(array $f, bool $primary = false): array
{
    $w = ['a.acctstarttime >= :from', 'a.acctstarttime < DATE_ADD(CAST(:to AS DATE), INTERVAL 1 DAY)'];
    $p = [':from' => $f['from'], ':to' => $f['to']];
    if ($f['user'] !== '' && $f['user'] !== '*') {
        $w[] = rq_user_cond('a.username', $f['user'], $p);
    }
    if ($f['nas'] !== '') {
        $w[] = 'a.nasipaddress = :nas';
        $p[':nas'] = $f['nas'];
    }
    if ($f['plan'] !== '') {
        $w[] = $primary ? 'ug.plano = :plan'
            : 'a.username IN (SELECT username FROM radusergroup WHERE groupname = :plan)';
        $p[':plan'] = $f['plan'];
    }
    return [implode(' AND ', $w), $p];
}

const RQ_SUMS = 'COUNT(*) AS sessoes, COUNT(DISTINCT a.username) AS usuarios,
    SUM(COALESCE(a.acctsessiontime, 0)) AS tempo,
    SUM(COALESCE(a.acctinputoctets, 0)) AS up, SUM(COALESCE(a.acctoutputoctets, 0)) AS down,
    SUM(COALESCE(a.acctinputoctets, 0) + COALESCE(a.acctoutputoctets, 0)) AS total';

/** Executa o relatório e devolve o statement (linhas associativas). */
function rq_stmt(PDO $pdo, string $report, array $f, int $limit): PDOStatement
{
    $limit = max(1, min($limit, RQ_EXPORT_LIMIT));
    $sums = RQ_SUMS;
    switch ($report) {
        case 'dia':
            [$w, $p] = rq_acct_where($f);
            $sql = "SELECT DATE(a.acctstarttime) AS dia, $sums FROM radacct a WHERE $w
                    GROUP BY DATE(a.acctstarttime) ORDER BY dia LIMIT $limit";
            break;
        case 'mes':
            $f['from'] = rq_month_start($f['to']);
            [$w, $p] = rq_acct_where($f);
            $sql = "SELECT DATE_FORMAT(a.acctstarttime, '%Y-%m') AS mes, $sums FROM radacct a WHERE $w
                    GROUP BY DATE_FORMAT(a.acctstarttime, '%Y-%m') ORDER BY mes LIMIT $limit";
            break;
        case 'top':
            [$w, $p] = rq_acct_where($f);
            $limit = min($limit, 20);
            $sql = "SELECT a.username, $sums FROM radacct a WHERE $w
                    GROUP BY a.username ORDER BY total DESC, a.username LIMIT $limit";
            break;
        case 'nas':
            [$w, $p] = rq_acct_where($f);
            $sql = "SELECT t.*, (SELECT MIN(n.shortname) FROM nas n WHERE n.nasname = t.nasipaddress) AS nome
                    FROM (SELECT a.nasipaddress, $sums FROM radacct a WHERE $w GROUP BY a.nasipaddress) t
                    ORDER BY t.total DESC, t.nasipaddress LIMIT $limit";
            break;
        case 'plano':
            [$w, $p] = rq_acct_where($f, true);
            $ug = RQ_PRIMARY_PLAN;
            $sql = "SELECT COALESCE(ug.plano, '(sem plano)') AS plano, $sums
                    FROM radacct a LEFT JOIN $ug ug ON ug.username = a.username WHERE $w
                    GROUP BY COALESCE(ug.plano, '(sem plano)') ORDER BY total DESC, plano LIMIT $limit";
            break;
        case 'hora':
            [$w, $p] = rq_acct_where($f);
            $sql = "SELECT LPAD(HOUR(a.acctstarttime), 2, '0') AS hora, $sums FROM radacct a WHERE $w
                    GROUP BY HOUR(a.acctstarttime) ORDER BY HOUR(a.acctstarttime) LIMIT $limit";
            break;
        case 'rejeicoes':
            $w = ["p.reply LIKE 'Access-Reject%'", 'p.authdate >= :from',
                  'p.authdate < DATE_ADD(CAST(:to AS DATE), INTERVAL 1 DAY)'];
            $p = [':from' => $f['from'], ':to' => $f['to']];
            if ($f['user'] !== '' && $f['user'] !== '*') {
                $w[] = rq_user_cond('p.username', $f['user'], $p);
            }
            if ($f['plan'] !== '') {
                $w[] = 'p.username IN (SELECT username FROM radusergroup WHERE groupname = :plan)';
                $p[':plan'] = $f['plan'];
            }
            $ws = implode(' AND ', $w);
            // NÃO selecionar p.pass: contém a senha digitada.
            $sql = "SELECT DATE(p.authdate) AS dia, p.username, COUNT(*) AS tentativas FROM radpostauth p
                    WHERE $ws GROUP BY DATE(p.authdate), p.username
                    ORDER BY dia DESC, tentativas DESC, p.username LIMIT $limit";
            break;
        default:
            throw new InvalidArgumentException('relatório inválido');
    }
    $st = $pdo->prepare($sql);
    $st->execute($p);
    return $st;
}

/** Converte uma linha do banco para os tipos esperados (inteiros nos números). */
function rq_row(array $cols, array $r): array
{
    $o = [];
    foreach ($cols as [$k, , $type]) {
        $v = $r[$k] ?? null;
        $o[$k] = in_array($type, ['int', 'cnt', 'bytes', 'secs'], true) ? (int)$v : (string)($v ?? '');
    }
    return $o;
}

/** Linhas completas (para tela). */
function rq_rows(PDO $pdo, string $report, array $f, int $limit = RQ_VIEW_LIMIT): array
{
    $cols = rq_columns($report);
    $rows = [];
    foreach (rq_stmt($pdo, $report, $f, $limit)->fetchAll() as $r) {
        $rows[] = rq_row($cols, $r);
    }
    return $rows;
}
