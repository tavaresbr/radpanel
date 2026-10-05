<?php
declare(strict_types=1);

/*
 * Limites por usuário (radcheck) e por plano (radgroupcheck).
 *
 * As funções de conversão/validação/montagem de linhas são puras (sem banco).
 * As chaves casam com a configuração do servidor em server-config/
 * (mods-available/panel_counters e policy.d/panel_limits).
 *
 * Precedência usuário x plano: o rlm_sql lê primeiro o radcheck do usuário e depois o
 * radgroupcheck dos grupos. Um item ":=" do grupo SUBSTITUIRIA o do usuário; por isso as linhas
 * de plano usam o operador "=" (só define se ainda não existir): o limite do usuário prevalece.
 */

const LIM_OP_USER = ':=';
const LIM_OP_PLAN = '=';
const LIM_MAC_ATTR = 'Calling-Station-Id';
const LIM_MAC_OP = '==';

const LIM_KEY_DAILY   = 'control.Max-Daily-Session';
const LIM_KEY_MONTHLY = 'control.Max-Monthly-Session';
const LIM_KEY_TOTAL   = 'control.Max-All-Session';
const LIM_KEY_SIMULT  = 'control.Simultaneous-Use';
/** período => atributo da franquia de dados (soma entrada+saída, em bytes). */
const LIM_QUOTA_KEYS = [
    'daily'   => 'control.Max-Quota-Daily-Octets',
    'monthly' => 'control.Max-Quota-Monthly-Octets',
    'total'   => 'control.Max-Quota-Total-Octets',
];

// Máximos sensatos.
const LIM_MAX_DAILY   = 86400;                 // 24 h
const LIM_MAX_MONTHLY = 2678400;               // 31 dias
const LIM_MAX_TOTAL   = 315360000;             // 10 anos
const LIM_MAX_SIMULT  = 100;
const LIM_MAX_QUOTA   = 109951162777600;       // 100 TiB
const LIM_UNITS = ['MB' => 1048576, 'GB' => 1073741824];
const LIM_PERIODS = ['daily' => 'Diária', 'monthly' => 'Mensal', 'total' => 'Total'];

/** Inteiro positivo opcional: '' => null; erro amigável em qualquer outra entrada inválida. */
function lim_parse_int(string $s, int $min, int $max, string $label): ?int
{
    $s = trim($s);
    if ($s === '') {
        return null;
    }
    if (!preg_match('/^[0-9]{1,18}$/', $s)) {
        throw new RuntimeException("$label: use apenas números inteiros positivos.");
    }
    $n = (int)$s;
    if ($n < $min || $n > $max) {
        throw new RuntimeException("$label: o valor deve estar entre $min e $max.");
    }
    return $n;
}

/** Valor + unidade (MB/GB, base 1024) => bytes. '' => null. Aceita até 2 casas decimais (ponto ou vírgula). */
function lim_parse_quota(string $value, string $unit): ?int
{
    $value = trim($value);
    if ($value === '') {
        return null;
    }
    $unit = strtoupper(trim($unit));
    if (!isset(LIM_UNITS[$unit])) {
        throw new RuntimeException('Franquia: unidade inválida (use MB ou GB).');
    }
    if (!preg_match('/^([0-9]{1,9})(?:[.,]([0-9]{1,2}))?$/', $value, $m)) {
        throw new RuntimeException('Franquia: informe um número positivo (ex.: 50 ou 1,5).');
    }
    $mult = LIM_UNITS[$unit];
    $frac = $m[2] ?? '';
    $bytes = (int)$m[1] * $mult;
    if ($frac !== '') {
        $bytes += intdiv((int)$frac * $mult, 10 ** strlen($frac));
    }
    if ($bytes < 1) {
        throw new RuntimeException('Franquia: o valor deve ser maior que zero.');
    }
    if ($bytes > LIM_MAX_QUOTA) {
        throw new RuntimeException('Franquia: máximo de 100 TB.');
    }
    return $bytes;
}

/** Bytes => [valor, unidade] para preencher o formulário (GB quando exato, senão MB). */
function lim_quota_split(?int $bytes): array
{
    if ($bytes === null || $bytes <= 0) {
        return ['', 'GB'];
    }
    if ($bytes % LIM_UNITS['GB'] === 0) {
        return [(string)intdiv($bytes, LIM_UNITS['GB']), 'GB'];
    }
    if ($bytes % LIM_UNITS['MB'] === 0) {
        return [(string)intdiv($bytes, LIM_UNITS['MB']), 'MB'];
    }
    return [rtrim(rtrim(number_format($bytes / LIM_UNITS['MB'], 2, '.', ''), '0'), '.'), 'MB'];
}

/** MAC opcional: aceita AA:BB:.., AA-BB-.. ou 12 hex; devolve AA-BB-CC-DD-EE-FF ou null se vazio. */
function lim_parse_mac(string $m): ?string
{
    $m = trim($m);
    if ($m === '') {
        return null;
    }
    if (preg_match('/^[0-9A-Fa-f]{12}$/', $m)) {
        $m = implode('-', str_split($m, 2));
    }
    if (!valid_mac($m)) {
        throw new RuntimeException('MAC inválido. Use o formato AA-BB-CC-DD-EE-FF.');
    }
    $n = normalize_mac($m);
    if ($n === '00-00-00-00-00-00' || $n === 'FF-FF-FF-FF-FF-FF') {
        throw new RuntimeException('MAC inválido (zerado ou broadcast).');
    }
    return $n;
}

/**
 * Valida os campos do formulário e devolve o conjunto normalizado:
 * [daily, monthly, total, simult (?int), quota (?int bytes), quota_period, mac (?string)].
 * $withMac = false (planos) ignora o campo MAC.
 */
function lim_from_input(array $in, bool $withMac): array
{
    $period = (string)($in['quota_period'] ?? 'monthly');
    if (!isset(LIM_PERIODS[$period])) {
        throw new RuntimeException('Franquia: período inválido.');
    }
    return [
        'daily'        => lim_parse_int((string)($in['daily'] ?? ''), 1, LIM_MAX_DAILY, 'Tempo diário'),
        'monthly'      => lim_parse_int((string)($in['monthly'] ?? ''), 1, LIM_MAX_MONTHLY, 'Tempo mensal'),
        'total'        => lim_parse_int((string)($in['total'] ?? ''), 1, LIM_MAX_TOTAL, 'Tempo total'),
        'simult'       => lim_parse_int((string)($in['simult'] ?? ''), 1, LIM_MAX_SIMULT, 'Sessões simultâneas'),
        'quota'        => lim_parse_quota((string)($in['quota'] ?? ''), (string)($in['quota_unit'] ?? 'GB')),
        'quota_period' => $period,
        'mac'          => $withMac ? lim_parse_mac((string)($in['mac'] ?? '')) : null,
    ];
}

/** Todos os atributos que esta tela gerencia (para limpar antes de regravar). */
function lim_managed_attrs(bool $withMac): array
{
    $a = array_merge([LIM_KEY_DAILY, LIM_KEY_MONTHLY, LIM_KEY_TOTAL, LIM_KEY_SIMULT], array_values(LIM_QUOTA_KEYS));
    if ($withMac) {
        $a[] = LIM_MAC_ATTR;
    }
    return $a;
}

/**
 * Linhas a gravar: lista de [atributo, operador, valor] (apenas campos preenchidos).
 * $op: operador dos itens de limite (usuário ':=', plano '='); o MAC sempre usa '=='.
 */
function lim_build_rows(array $lim, string $op): array
{
    $rows = [];
    $map = [
        'daily'   => LIM_KEY_DAILY,
        'monthly' => LIM_KEY_MONTHLY,
        'total'   => LIM_KEY_TOTAL,
        'simult'  => LIM_KEY_SIMULT,
    ];
    foreach ($map as $field => $attr) {
        if (($lim[$field] ?? null) !== null) {
            $rows[] = [$attr, $op, (string)$lim[$field]];
        }
    }
    if (($lim['quota'] ?? null) !== null) {
        $rows[] = [LIM_QUOTA_KEYS[$lim['quota_period']], $op, (string)$lim['quota']];
    }
    if (($lim['mac'] ?? null) !== null) {
        $rows[] = [LIM_MAC_ATTR, LIM_MAC_OP, (string)$lim['mac']];
    }
    return $rows;
}

/** Inverso: [atributo => valor] (do banco) => conjunto normalizado (campos ausentes = null). */
function lim_from_rows(array $attrs): array
{
    $int = static fn(string $k): ?int => (isset($attrs[$k]) && ctype_digit((string)$attrs[$k])) ? (int)$attrs[$k] : null;
    $lim = [
        'daily' => $int(LIM_KEY_DAILY), 'monthly' => $int(LIM_KEY_MONTHLY), 'total' => $int(LIM_KEY_TOTAL),
        'simult' => $int(LIM_KEY_SIMULT), 'quota' => null, 'quota_period' => 'monthly',
        'mac' => isset($attrs[LIM_MAC_ATTR]) && valid_mac((string)$attrs[LIM_MAC_ATTR])
            ? normalize_mac((string)$attrs[LIM_MAC_ATTR]) : null,
    ];
    foreach (LIM_QUOTA_KEYS as $period => $attr) {
        if ($int($attr) !== null) {
            $lim['quota'] = $int($attr);
            $lim['quota_period'] = $period;
            break;
        }
    }
    return $lim;
}

/** Linhas de radcheck do usuário => [atributo => valor] (só atributos gerenciados). */
function lim_read_user(PDO $pdo, string $user): array
{
    $attrs = lim_managed_attrs(true);
    $ph = implode(',', array_fill(0, count($attrs), '?'));
    $st = $pdo->prepare("SELECT attribute, value FROM radcheck WHERE username = ? AND attribute IN ($ph) ORDER BY id");
    $st->execute(array_merge([$user], $attrs));
    $out = [];
    foreach ($st as $r) {
        $out[$r['attribute']] = $r['value'];
    }
    return lim_from_rows($out);
}

function lim_read_plan(PDO $pdo, string $plan): array
{
    $attrs = lim_managed_attrs(false);
    $ph = implode(',', array_fill(0, count($attrs), '?'));
    $st = $pdo->prepare("SELECT attribute, value FROM radgroupcheck WHERE groupname = ? AND attribute IN ($ph) ORDER BY id");
    $st->execute(array_merge([$plan], $attrs));
    $out = [];
    foreach ($st as $r) {
        $out[$r['attribute']] = $r['value'];
    }
    return lim_from_rows($out);
}

/** Todos os limites de todos os planos de uma vez: [plano => conjunto]. */
function lim_read_all_plans(PDO $pdo): array
{
    $attrs = lim_managed_attrs(false);
    $ph = implode(',', array_fill(0, count($attrs), '?'));
    $st = $pdo->prepare("SELECT groupname, attribute, value FROM radgroupcheck WHERE attribute IN ($ph) ORDER BY id");
    $st->execute($attrs);
    $by = [];
    foreach ($st as $r) {
        $by[$r['groupname']][$r['attribute']] = $r['value'];
    }
    return array_map('lim_from_rows', $by);
}

/** Grava os limites do usuário (campos vazios removem a linha). Não audita. */
function lim_save_user(PDO $pdo, string $user, array $lim): void
{
    ru_tx($pdo, function () use ($pdo, $user, $lim) {
        ru_require_exists($pdo, $user);
        $pdo->prepare('DELETE FROM radcheck WHERE username = ? AND attribute IN ('
            . implode(',', array_fill(0, count(lim_managed_attrs(true)), '?')) . ')')
            ->execute(array_merge([$user], lim_managed_attrs(true)));
        foreach (lim_build_rows($lim, LIM_OP_USER) as [$attr, $op, $value]) {
            ru_set_check($pdo, $user, $attr, $value, $op);
        }
    });
}

/** Grava os limites do plano em radgroupcheck (operador '='). Não audita. */
function lim_save_plan(PDO $pdo, string $plan, array $lim): void
{
    ru_tx($pdo, function () use ($pdo, $plan, $lim) {
        $attrs = lim_managed_attrs(false);
        $pdo->prepare('DELETE FROM radgroupcheck WHERE groupname = ? AND attribute IN ('
            . implode(',', array_fill(0, count($attrs), '?')) . ')')
            ->execute(array_merge([$plan], $attrs));
        $ins = $pdo->prepare('INSERT INTO radgroupcheck (groupname, attribute, op, value) VALUES (?, ?, ?, ?)');
        foreach (lim_build_rows($lim, LIM_OP_PLAN) as [$attr, $op, $value]) {
            $ins->execute([$plan, $attr, $op, $value]);
        }
    });
}

/** Detalhe para auditoria (sem nada sensível). */
function lim_audit_detail(array $lim): array
{
    return [
        'daily_s' => $lim['daily'], 'monthly_s' => $lim['monthly'], 'total_s' => $lim['total'],
        'simult' => $lim['simult'], 'quota_bytes' => $lim['quota'],
        'quota_period' => $lim['quota'] !== null ? $lim['quota_period'] : null,
        'mac' => $lim['mac'],
    ];
}

/** Resumo curto de um conjunto, para tabelas: lista de textos. */
function lim_summary(array $lim): array
{
    $out = [];
    if ($lim['daily'] !== null) {
        $out[] = 'Dia: ' . fmt_secs($lim['daily']);
    }
    if ($lim['monthly'] !== null) {
        $out[] = 'Mês: ' . fmt_secs($lim['monthly']);
    }
    if ($lim['total'] !== null) {
        $out[] = 'Total: ' . fmt_secs($lim['total']);
    }
    if ($lim['quota'] !== null) {
        $out[] = 'Dados (' . strtolower(LIM_PERIODS[$lim['quota_period']]) . '): ' . fmt_bytes($lim['quota']);
    }
    if ($lim['simult'] !== null) {
        $out[] = 'Simultâneas: ' . $lim['simult'];
    }
    return $out;
}

/**
 * Início dos períodos (timestamps Unix) no fuso do painel; o servidor RADIUS usa o fuso do SO
 * (sqlcounter sem `utc = yes`): mantenha os dois iguais.
 */
function lim_period_starts(?int $now = null): array
{
    $now ??= time();
    $d = (new DateTimeImmutable('@' . $now))->setTimezone(new DateTimeZone(date_default_timezone_get()));
    return [
        'daily'   => $d->setTime(0, 0, 0)->getTimestamp(),
        'monthly' => $d->setDate((int)$d->format('Y'), (int)$d->format('n'), 1)->setTime(0, 0, 0)->getTimestamp(),
        'total'   => 0,
    ];
}

/** Consumo atual do usuário (radacct), com as mesmas fórmulas das queries do servidor. */
function lim_usage(PDO $pdo, string $user, ?int $now = null): array
{
    $starts = lim_period_starts($now);
    $use = ['time' => [], 'bytes' => [], 'open' => 0];
    foreach ($starts as $period => $start) {
        $st = $pdo->prepare(
            'SELECT IFNULL(SUM(acctsessiontime - GREATEST(? - UNIX_TIMESTAMP(acctstarttime), 0)), 0)
             FROM radacct WHERE username = ? AND UNIX_TIMESTAMP(acctstarttime) + acctsessiontime > ?'
        );
        $st->execute([$start, $user, $start]);
        $use['time'][$period] = (int)$st->fetchColumn();

        $st = $pdo->prepare(
            'SELECT IFNULL(SUM(IFNULL(acctinputoctets, 0) + IFNULL(acctoutputoctets, 0)), 0)
             FROM radacct WHERE username = ? AND UNIX_TIMESTAMP(acctstarttime) >= ?'
        );
        $st->execute([$user, $start]);
        $use['bytes'][$period] = (int)$st->fetchColumn();
    }
    $st = $pdo->prepare(
        'SELECT COUNT(*) FROM radacct WHERE username = ? AND acctstoptime IS NULL
         AND acctupdatetime > DATE_SUB(NOW(), INTERVAL 1 DAY)'
    );
    $st->execute([$user]);
    $use['open'] = (int)$st->fetchColumn();
    return $use;
}
