<?php
declare(strict_types=1);

/*
 * Clientes e cobrança simples. Dinheiro: SEMPRE centavos inteiros no PHP (nunca float);
 * no banco, DECIMAL(10,2) lido como texto ("12.50") e convertido por texto.
 * Dados pessoais (e-mail/telefone/documento) NUNCA vão para audit().
 */

const CUST_METHODS = [
    'dinheiro' => 'Dinheiro', 'pix' => 'PIX', 'cartao' => 'Cartão',
    'transferencia' => 'Transferência', 'outro' => 'Outro',
];
const MONEY_MAX_CENTS = 9999999999; // 99.999.999,99 (cabe em DECIMAL(10,2))

// ---------------------------------------------------------------- dinheiro

/** "12,50" | "12.50" | "1.234,56" | "R$ 12,5" | "12" -> centavos (int). Só aceita valor > 0. */
function money_parse(string $s): int
{
    $s = trim(str_ireplace('R$', '', $s));
    $s = preg_replace('/\s+/', '', $s) ?? '';
    $bad = new RuntimeException('Valor inválido. Use o formato 12,50 (máx. 99.999.999,99).');
    if ($s === '') {
        throw $bad;
    }
    if (str_contains($s, ',')) {
        if (str_contains($s, '.') && !preg_match('/^\d{1,3}(\.\d{3})+,\d{1,2}$/', $s)) {
            throw $bad;
        }
        $s = str_replace(['.', ','], ['', '.'], $s);
    }
    if (!preg_match('/^(\d{1,8})(?:\.(\d{1,2}))?$/', $s, $m)) {
        throw $bad;
    }
    $cents = (int)$m[1] * 100 + (int)str_pad($m[2] ?? '0', 2, '0');
    if ($cents <= 0 || $cents > MONEY_MAX_CENTS) {
        throw $bad;
    }
    return $cents;
}

/** DECIMAL do banco ("12.50", "-3.1", "7") -> centavos, por texto (sem float). */
function money_from_db(?string $d): int
{
    $d = trim((string)$d);
    if ($d === '') {
        return 0;
    }
    if (!preg_match('/^(-?)(\d+)(?:\.(\d+))?$/', $d, $m)) {
        throw new RuntimeException('Valor monetário inválido no banco.');
    }
    $c = (int)$m[2] * 100 + (int)str_pad(substr($m[3] ?? '', 0, 2), 2, '0');
    return $m[1] === '-' ? -$c : $c;
}

/** centavos -> "12.50" para gravar em DECIMAL. */
function money_to_db(int $cents): string
{
    $sign = $cents < 0 ? '-' : '';
    $a = abs($cents);
    return sprintf('%s%d.%02d', $sign, intdiv($a, 100), $a % 100);
}

/** centavos -> "R$ 1.234,56". */
function money_fmt(int $cents): string
{
    $a = abs($cents);
    return ($cents < 0 ? '-' : '') . 'R$ ' . number_format(intdiv($a, 100), 0, ',', '.') . ',' . sprintf('%02d', $a % 100);
}

/** centavos -> "1234,50" (valor de campo de formulário). */
function money_input(int $cents): string
{
    return intdiv($cents, 100) . ',' . sprintf('%02d', $cents % 100);
}

// ---------------------------------------------------------------- validação de clientes

function cust_text(string $v, string $label, int $max, bool $required = false, bool $multiline = false): string
{
    $v = trim($v);
    if (!mb_check_encoding($v, 'UTF-8')) {
        throw new RuntimeException("$label contém caracteres inválidos.");
    }
    if ($required && $v === '') {
        throw new RuntimeException("$label é obrigatório.");
    }
    $re = $multiline ? '/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/' : '/[\x00-\x1F\x7F]/';
    if (preg_match($re, $v)) {
        throw new RuntimeException("$label contém caracteres inválidos.");
    }
    if (mb_strlen($v) > $max) {
        throw new RuntimeException("$label deve ter no máximo $max caracteres.");
    }
    return $v;
}

// ---------------------------------------------------------------- CPF / CNPJ

function cust_doc_digits(string $s): string
{
    return preg_replace('/\D+/', '', $s) ?? '';
}

/** 'cpf' | 'cnpj' (dígitos verificadores corretos) ou null. Aceita só dígitos. */
function cust_doc_type(string $d): ?string
{
    if (!preg_match('/^\d{11}$|^\d{14}$/', $d) || preg_match('/^(\d)\1+$/', $d)) {
        return null;
    }
    $n = strlen($d);
    $w = $n === 11 ? [10, 9, 8, 7, 6, 5, 4, 3, 2] : [5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2];
    for ($k = 0; $k < 2; $k++) {
        $sum = 0;
        foreach ($w as $i => $wt) {
            $sum += (int)$d[$i] * $wt;
        }
        $dv = $sum % 11 < 2 ? 0 : 11 - $sum % 11;
        if ((int)$d[count($w)] !== $dv) {
            return null;
        }
        $w = $n === 11 ? [11, ...$w] : [6, ...$w];
    }
    return $n === 11 ? 'cpf' : 'cnpj';
}

function cust_doc_format(string $d, string $type): string
{
    return $type === 'cpf'
        ? preg_replace('/^(\d{3})(\d{3})(\d{3})(\d{2})$/', '$1.$2.$3-$4', $d)
        : preg_replace('/^(\d{2})(\d{3})(\d{3})(\d{4})(\d{2})$/', '$1.$2.$3/$4-$5', $d);
}

/** Valida e formata o CPF/CNPJ digitado. '' só é aceito se !$required. */
function cust_doc_normalize(string $in, bool $required): string
{
    $in = cust_text($in, 'CPF/CNPJ', 30);
    $d = cust_doc_digits($in);
    if ($d === '' && $in !== '') {
        throw new RuntimeException('CPF ou CNPJ inválido.');
    }
    if ($d === '') {
        if ($required) {
            throw new RuntimeException('Informe o CPF ou CNPJ do cliente.');
        }
        return '';
    }
    $type = cust_doc_type($d);
    if ($type === null) {
        throw new RuntimeException('CPF ou CNPJ inválido.');
    }
    return cust_doc_format($d, $type);
}

/** Mapeia a resposta da BrasilAPI para os campos do formulário. */
function cust_cnpj_map(array $j): array
{
    $s = fn($k) => trim((string)($j[$k] ?? ''));
    $name = $s('razao_social') !== '' ? $s('razao_social') : $s('nome_fantasia');
    $phone = preg_replace('/[^0-9]/', '', $s('ddd_telefone_1')) ?? '';
    if (strlen($phone) === 10 || strlen($phone) === 11) {
        $phone = '(' . substr($phone, 0, 2) . ') ' . substr($phone, 2, -4) . '-' . substr($phone, -4);
    } else {
        $phone = '';
    }
    $street = trim($s('descricao_tipo_de_logradouro') . ' ' . $s('logradouro'));
    $parts = array_filter([
        trim($street . ($s('numero') !== '' ? ', ' . $s('numero') : '') . ($s('complemento') !== '' ? ' - ' . $s('complemento') : '')),
        $s('bairro'),
        trim($s('municipio') . ($s('uf') !== '' ? '/' . $s('uf') : '')),
        $s('cep') !== '' ? 'CEP ' . $s('cep') : '',
    ], fn($x) => $x !== '');
    $email = strtolower($s('email'));
    return [
        'name' => mb_substr($name, 0, 120),
        'email' => filter_var($email, FILTER_VALIDATE_EMAIL) ? mb_substr($email, 0, 120) : '',
        'phone' => $phone,
        'address' => mb_substr(implode(', ', $parts), 0, 255),
        'situacao' => $s('descricao_situacao_cadastral'),
    ];
}

/** Consulta o CNPJ na BrasilAPI (servidor -> HTTPS; o navegador não sai da CSP). */
function cust_cnpj_lookup(string $cnpjDigits): array
{
    if (cust_doc_type($cnpjDigits) !== 'cnpj') {
        throw new RuntimeException('CNPJ inválido.');
    }
    $ch = curl_init('https://brasilapi.com.br/api/cnpj/v1/' . $cnpjDigits);
    curl_setopt_array($ch, [
        CURLOPT_RETURNTRANSFER => true, CURLOPT_FOLLOWLOCATION => false,
        CURLOPT_CONNECTTIMEOUT => 4, CURLOPT_TIMEOUT => 8,
        CURLOPT_PROTOCOLS => CURLPROTO_HTTPS, CURLOPT_MAXFILESIZE => 262144,
        CURLOPT_HTTPHEADER => ['Accept: application/json'], CURLOPT_USERAGENT => 'radpanel',
    ]);
    $body = curl_exec($ch);
    $code = (int)curl_getinfo($ch, CURLINFO_RESPONSE_CODE);
    if ($body === false) {
        error_log('radpanel cnpj: ' . curl_error($ch));
    }
    curl_close($ch);
    if ($code === 404 || $code === 400) {
        throw new RuntimeException('CNPJ não encontrado na Receita Federal.');
    }
    $j = is_string($body) ? json_decode($body, true) : null;
    if ($code !== 200 || !is_array($j)) {
        throw new RuntimeException('Consulta de CNPJ indisponível agora. Preencha manualmente.');
    }
    return cust_cnpj_map($j);
}

/**
 * Valida os campos do formulário de cliente. $selfId: cliente em edição (para o vínculo),
 * $currentUser: vínculo atual (mantido mesmo que o usuário RADIUS tenha sumido).
 * Devolve campos normalizados; lança RuntimeException amigável.
 */
function cust_validate(PDO $pdo, array $in, ?int $selfId = null, ?string $currentUser = null, bool $requireDoc = false): array
{
    $name = cust_text((string)($in['name'] ?? ''), 'Nome', 120, true);
    $email = cust_text((string)($in['email'] ?? ''), 'E-mail', 120);
    if ($email !== '' && !filter_var($email, FILTER_VALIDATE_EMAIL)) {
        throw new RuntimeException('E-mail inválido.');
    }
    $phone = cust_text((string)($in['phone'] ?? ''), 'Telefone', 30);
    if ($phone !== '' && (!preg_match('/^[0-9+()\- ]+$/', $phone) || !preg_match('/\d/', $phone))) {
        throw new RuntimeException('Telefone inválido (use só dígitos e + ( ) - espaço).');
    }
    $document = cust_doc_normalize((string)($in['document'] ?? ''), $requireDoc);
    if ($document !== '') {
        $st = $pdo->prepare('SELECT id FROM panel_customers WHERE document = ? AND id <> ? LIMIT 1');
        $st->execute([$document, $selfId ?? 0]);
        if ($st->fetchColumn() !== false) {
            throw new RuntimeException('Já existe um cliente com esse CPF/CNPJ.');
        }
    }
    $address = cust_text((string)($in['address'] ?? ''), 'Endereço', 255);
    $notes = cust_text((string)($in['notes'] ?? ''), 'Observações', 1000, false, true);

    $username = trim((string)($in['username'] ?? ''));
    $link = null;
    if ($username !== '') {
        if (!valid_username($username)) {
            throw new RuntimeException('Nome de usuário RADIUS inválido.');
        }
        $st = $pdo->prepare('SELECT username FROM radcheck WHERE username = ? LIMIT 1');
        $st->execute([$username]);
        $canon = $st->fetchColumn();
        if ($canon === false) {
            if ($currentUser !== null && strcasecmp($currentUser, $username) === 0) {
                $canon = $currentUser; // vínculo antigo cujo usuário foi removido: mantém
            } else {
                throw new RuntimeException('Usuário RADIUS não existe.');
            }
        }
        $link = (string)$canon;
        $st = $pdo->prepare('SELECT id FROM panel_customers WHERE username = ? AND id <> ? LIMIT 1');
        $st->execute([$link, $selfId ?? 0]);
        if ($st->fetchColumn() !== false) {
            throw new RuntimeException('Esse usuário RADIUS já está vinculado a outro cliente.');
        }
    }
    return [
        'name' => $name, 'email' => $email, 'phone' => $phone, 'document' => $document,
        'address' => $address, 'notes' => $notes, 'username' => $link,
    ];
}

function cust_is_dup_error(PDOException $e): bool
{
    return ($e->errorInfo[1] ?? 0) === 1062;
}

function cust_create(PDO $pdo, array $in): int
{
    $f = cust_validate($pdo, $in, null, null, true);
    try {
        $pdo->prepare(
            'INSERT INTO panel_customers (name, email, phone, document, address, notes, username)
             VALUES (?, ?, ?, ?, ?, ?, ?)'
        )->execute([$f['name'], $f['email'], $f['phone'], $f['document'], $f['address'], $f['notes'], $f['username']]);
    } catch (PDOException $e) {
        if (cust_is_dup_error($e)) {
            throw new RuntimeException('Esse usuário RADIUS já está vinculado a outro cliente.');
        }
        throw $e;
    }
    $id = (int)$pdo->lastInsertId();
    audit('customer.create', 'customer#' . $id, ['linked' => $f['username'] !== null]);
    return $id;
}

function cust_get(PDO $pdo, int $id): ?array
{
    $st = $pdo->prepare('SELECT * FROM panel_customers WHERE id = ?');
    $st->execute([$id]);
    $r = $st->fetch();
    return $r ?: null;
}

/** Atualiza; devolve a lista de nomes de campos alterados (vazia = nada mudou). */
function cust_update(PDO $pdo, int $id, array $in): array
{
    $cur = cust_get($pdo, $id);
    if (!$cur) {
        throw new RuntimeException('Cliente não encontrado.');
    }
    $f = cust_validate($pdo, $in, $id, $cur['username']);
    $changed = [];
    foreach ($f as $k => $v) {
        if ((string)($cur[$k] ?? '') !== (string)($v ?? '')) {
            $changed[] = $k;
        }
    }
    if (!$changed) {
        return [];
    }
    try {
        $pdo->prepare(
            'UPDATE panel_customers SET name=?, email=?, phone=?, document=?, address=?, notes=?, username=? WHERE id=?'
        )->execute([$f['name'], $f['email'], $f['phone'], $f['document'], $f['address'], $f['notes'], $f['username'], $id]);
    } catch (PDOException $e) {
        if (cust_is_dup_error($e)) {
            throw new RuntimeException('Esse usuário RADIUS já está vinculado a outro cliente.');
        }
        throw $e;
    }
    audit('customer.update', 'customer#' . $id, ['changed' => $changed]);
    return $changed;
}

function cust_payment_count(PDO $pdo, int $id): int
{
    $st = $pdo->prepare('SELECT COUNT(*) FROM panel_payments WHERE customer_id = ?');
    $st->execute([$id]);
    return (int)$st->fetchColumn();
}

/** Exclui só se não houver pagamentos (senão: arquivar). Nunca toca no usuário RADIUS. */
function cust_delete(PDO $pdo, int $id): void
{
    ru_tx($pdo, function () use ($pdo, $id) {
        $st = $pdo->prepare('SELECT id FROM panel_customers WHERE id = ? FOR UPDATE');
        $st->execute([$id]);
        if ($st->fetchColumn() === false) {
            throw new RuntimeException('Cliente não encontrado.');
        }
        if (cust_payment_count($pdo, $id) > 0) {
            throw new RuntimeException('Cliente tem pagamentos registrados e não pode ser excluído. Use "Arquivar".');
        }
        $pdo->prepare('DELETE FROM panel_customers WHERE id = ?')->execute([$id]);
    });
    audit('customer.delete', 'customer#' . $id);
}

function cust_set_archived(PDO $pdo, int $id, bool $archived): void
{
    if (!cust_get($pdo, $id)) {
        throw new RuntimeException('Cliente não encontrado.');
    }
    $pdo->prepare('UPDATE panel_customers SET archived = ? WHERE id = ?')->execute([$archived ? 1 : 0, $id]);
    audit($archived ? 'customer.archive' : 'customer.unarchive', 'customer#' . $id);
}

// ---------------------------------------------------------------- pagamentos

function cust_date(string $v, string $label): string
{
    $v = trim($v);
    if (!valid_date($v)) {
        throw new RuntimeException("$label inválida.");
    }
    return $v;
}

/** Valida o formulário de pagamento. $renew exige período final. */
function cust_validate_payment(array $in, bool $renew): array
{
    $amount = money_parse((string)($in['amount'] ?? ''));
    $method = (string)($in['method'] ?? '');
    if (!isset(CUST_METHODS[$method])) {
        throw new RuntimeException('Forma de pagamento inválida.');
    }
    $paidAt = cust_date((string)($in['paid_at'] ?? ''), 'Data do pagamento');
    if ($paidAt > date('Y-m-d')) {
        throw new RuntimeException('Data do pagamento não pode ser futura.');
    }
    $from = trim((string)($in['period_from'] ?? ''));
    $to = trim((string)($in['period_to'] ?? ''));
    if ($renew && $to === '') {
        throw new RuntimeException('Informe o período coberto (até) para renovar a validade.');
    }
    if ($to !== '' && $from === '') {
        $from = $paidAt;
    }
    if ($from !== '' && $to === '') {
        throw new RuntimeException('Informe também o fim do período coberto.');
    }
    if ($to !== '') {
        $from = cust_date($from, 'Início do período');
        $to = cust_date($to, 'Fim do período');
        if ($to < $from) {
            throw new RuntimeException('O fim do período não pode ser anterior ao início.');
        }
        $days = (int)((strtotime($to . ' 12:00') - strtotime($from . ' 12:00')) / 86400);
        if ($days > 3660) {
            throw new RuntimeException('Período coberto grande demais (máx. 10 anos).');
        }
    }
    $notes = cust_text((string)($in['notes'] ?? ''), 'Observação', 255);
    return [
        'amount' => $amount, 'method' => $method, 'paid_at' => $paidAt,
        'from' => $from === '' ? null : $from, 'to' => $to === '' ? null : $to, 'notes' => $notes,
    ];
}

/**
 * Registra o pagamento e (se $renew) estende a Expiration do usuário vinculado até period_to,
 * tudo na MESMA transação: se algo falhar, nada é gravado.
 * - Usuário bloqueado: o pagamento é gravado, mas NÃO desbloqueia; só atualiza a validade que
 *   será restaurada quando alguém desbloquear (panel_user_meta.prev_expiration).
 * - Nunca encurta a validade: se a atual já é posterior ao período pago, mantém.
 * Devolve ['payment_id' => int, 'renewed' => bool, 'note' => string].
 */
function cust_pay(PDO $pdo, int $customerId, array $in, bool $renew, string $by): array
{
    $p = cust_validate_payment($in, $renew);
    $res = ru_tx($pdo, function () use ($pdo, $customerId, $p, $renew, $by) {
        $st = $pdo->prepare('SELECT id, username, archived FROM panel_customers WHERE id = ? FOR UPDATE');
        $st->execute([$customerId]);
        $c = $st->fetch();
        if (!$c) {
            throw new RuntimeException('Cliente não encontrado.');
        }
        if ((int)$c['archived'] === 1) {
            throw new RuntimeException('Cliente arquivado: desarquive antes de registrar pagamento.');
        }
        if ($renew && ($c['username'] === null || $c['username'] === '')) {
            throw new RuntimeException('Cliente sem usuário RADIUS vinculado: use "Registrar pagamento" ou vincule um usuário.');
        }
        $pdo->prepare(
            'INSERT INTO panel_payments (customer_id, amount, method, paid_at, period_from, period_to, notes, created_by)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?)'
        )->execute([
            $customerId, money_to_db($p['amount']), $p['method'], $p['paid_at'],
            $p['from'], $p['to'], $p['notes'], mb_substr($by, 0, 64),
        ]);
        $pid = (int)$pdo->lastInsertId();
        $renewed = false;
        $note = '';
        if ($renew) {
            $user = (string)$c['username'];
            ru_require_exists($pdo, $user);
            $newValue = expiration_from_date((string)$p['to']);
            $newTs = (int)expiration_ts($newValue);
            if (ru_is_blocked($pdo, $user)) {
                $st = $pdo->prepare('SELECT prev_expiration FROM panel_user_meta WHERE username = ?');
                $st->execute([$user]);
                $prev = $st->fetchColumn();
                if ($prev !== false && $prev !== null && $prev !== '' && (expiration_ts((string)$prev) ?? 0) < $newTs) {
                    $pdo->prepare('UPDATE panel_user_meta SET prev_expiration = ? WHERE username = ?')
                        ->execute([$newValue, $user]);
                }
                $note = 'blocked';
            } else {
                $curTs = expiration_ts(ru_get_check($pdo, $user, ATTR_EXPIRATION));
                if ($curTs !== null && $curTs >= $newTs) {
                    $note = 'already_later';
                } else {
                    ru_set_expiration($pdo, $user, (string)$p['to']);
                    $renewed = true;
                }
            }
        }
        return ['payment_id' => $pid, 'renewed' => $renewed, 'note' => $note];
    });
    audit('customer.payment', 'customer#' . $customerId, [
        'payment_id' => $res['payment_id'], 'amount_cents' => $p['amount'], 'method' => $p['method'],
        'renew' => $renew, 'renewed' => $res['renewed'], 'note' => $res['note'],
    ]);
    return $res;
}

// ---------------------------------------------------------------- consultas de apoio

/** Soma (centavos) por consulta que devolve DECIMAL em texto. */
function cust_sum_cents(PDO $pdo, string $sql, array $params = []): int
{
    $st = $pdo->prepare($sql);
    $st->execute($params);
    return money_from_db((string)$st->fetchColumn());
}

/** Último período pago (Y-m-d) do cliente, ou null. */
function cust_paid_until(PDO $pdo, int $id): ?string
{
    $st = $pdo->prepare('SELECT MAX(period_to) FROM panel_payments WHERE customer_id = ?');
    $st->execute([$id]);
    $v = $st->fetchColumn();
    return ($v === false || $v === null) ? null : (string)$v;
}

/** Preços dos planos: groupname => ['cents' => int, 'days' => int]. */
function cust_prices(PDO $pdo): array
{
    $out = [];
    foreach ($pdo->query('SELECT groupname, price, period_days FROM panel_plan_prices ORDER BY groupname') as $r) {
        $out[$r['groupname']] = ['cents' => money_from_db($r['price']), 'days' => (int)$r['period_days']];
    }
    return $out;
}

function cust_set_price(PDO $pdo, string $plan, string $price, string $days): void
{
    if (!in_array($plan, ru_plans($pdo), true)) {
        throw new RuntimeException('Plano não existe.');
    }
    $cents = money_parse($price);
    if (!preg_match('/^\d{1,4}$/', $days) || (int)$days < 1 || (int)$days > 3660) {
        throw new RuntimeException('Periodicidade inválida (1 a 3660 dias).');
    }
    $pdo->prepare(
        'INSERT INTO panel_plan_prices (groupname, price, period_days) VALUES (?, ?, ?)
         ON DUPLICATE KEY UPDATE price = VALUES(price), period_days = VALUES(period_days)'
    )->execute([$plan, money_to_db($cents), (int)$days]);
    audit('customer.price', 'plan:' . $plan, ['price_cents' => $cents, 'period_days' => (int)$days]);
}

function cust_delete_price(PDO $pdo, string $plan): void
{
    $pdo->prepare('DELETE FROM panel_plan_prices WHERE groupname = ?')->execute([$plan]);
    audit('customer.price_delete', 'plan:' . $plan);
}

/** Escapa % _ \ para LIKE. */
function like_escape(string $s): string
{
    return addcslashes($s, '%_\\');
}

/** Estado do usuário RADIUS: ['exists','plan','expiration','blocked','state','state_label']. */
function cust_user_info(PDO $pdo, string $user): array
{
    $info = ['exists' => ru_exists($pdo, $user), 'plan' => '', 'expiration' => null, 'blocked' => false,
             'state' => 'missing', 'state_label' => 'usuário não existe mais'];
    if (!$info['exists']) {
        return $info;
    }
    $st = $pdo->prepare('SELECT groupname FROM radusergroup WHERE username = ? ORDER BY priority LIMIT 1');
    $st->execute([$user]);
    $info['plan'] = (string)($st->fetchColumn() ?: '');
    $info['expiration'] = ru_get_check($pdo, $user, ATTR_EXPIRATION);
    $info['blocked'] = ru_is_blocked($pdo, $user);
    $ts = expiration_ts($info['expiration']);
    if ($info['blocked']) {
        [$info['state'], $info['state_label']] = ['blocked', 'bloqueado'];
    } elseif ($ts !== null && $ts < time()) {
        [$info['state'], $info['state_label']] = ['expired', 'vencido'];
    } else {
        [$info['state'], $info['state_label']] = ['active', 'ativo'];
    }
    return $info;
}

/** Valores de Expiration e flag de bloqueio, em lote: user => ['exp' => ?string, 'blocked' => bool, 'prev' => ?string]. */
function cust_expirations(PDO $pdo, array $users): array
{
    $out = [];
    foreach (array_chunk(array_values($users), 400) as $chunk) {
        $in = implode(',', array_fill(0, count($chunk), '?'));
        $st = $pdo->prepare("SELECT username, value FROM radcheck WHERE attribute = ? AND username IN ($in)");
        $st->execute(array_merge([ATTR_EXPIRATION], $chunk));
        foreach ($st as $r) {
            $out[strtolower($r['username'])]['exp'] = (string)$r['value'];
        }
        $st = $pdo->prepare("SELECT username FROM radcheck WHERE username IN ($in) GROUP BY username");
        $st->execute($chunk);
        foreach ($st as $r) {
            $out[strtolower($r['username'])]['exists'] = true;
        }
        $st = $pdo->prepare("SELECT username, blocked, prev_expiration FROM panel_user_meta WHERE username IN ($in)");
        $st->execute($chunk);
        foreach ($st as $r) {
            $out[strtolower($r['username'])]['blocked'] = (bool)$r['blocked'];
            $out[strtolower($r['username'])]['prev'] = $r['prev_expiration'];
        }
    }
    return $out;
}

/** Últimos 12 meses (incluindo o atual), do mais antigo ao mais novo: ['2026-05', ...]. */
function cust_last_months(int $n = 12): array
{
    $d = new DateTime('first day of this month 12:00');
    $d->modify('-' . ($n - 1) . ' months');
    $out = [];
    for ($i = 0; $i < $n; $i++) {
        $out[] = $d->format('Y-m');
        $d->modify('+1 month');
    }
    return $out;
}
