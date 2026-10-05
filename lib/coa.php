<?php
declare(strict_types=1);

/**
 * Disconnect-Request (RFC 5176) via radclient do FreeRADIUS 4.0.
 * Nunca usa shell: proc_open com argv em array; segredo em arquivo temporário 0600 (-S);
 * atributos pelo stdin.
 */

const COA_MAX_OUTPUT = 4096;

function coa_valid_ip(string $ip): bool
{
    return filter_var($ip, FILTER_VALIDATE_IP) !== false;
}

function coa_valid_session_id(string $s): bool
{
    return (bool)preg_match('/^[A-Za-z0-9_.:-]{1,64}$/', $s);
}

function coa_valid_secret(string $s): bool
{
    return (bool)preg_match('/^[\x21-\x7e]{2,128}$/', $s);
}

/**
 * Executa um programa (argv em array) com stdin, prazo total e saída limitada.
 * @return array{exit:int, out:string, err:string, timed_out:bool}
 */
function coa_run(array $argv, string $stdin, int $timeoutSec, int $maxOut = COA_MAX_OUTPUT): array
{
    $env = ['PATH' => '/usr/bin:/bin', 'LC_ALL' => 'C'];
    $proc = @proc_open($argv, [0 => ['pipe', 'r'], 1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes, '/', $env);
    if (!is_resource($proc)) {
        throw new RuntimeException('Não foi possível executar o radclient.');
    }
    stream_set_blocking($pipes[0], true);
    @fwrite($pipes[0], $stdin);
    fclose($pipes[0]);
    stream_set_blocking($pipes[1], false);
    stream_set_blocking($pipes[2], false);

    $out = '';
    $err = '';
    $timedOut = false;
    $exit = -1;
    $deadline = microtime(true) + $timeoutSec;
    $open = [1 => $pipes[1], 2 => $pipes[2]];
    while ($open) {
        if (microtime(true) >= $deadline) {
            $timedOut = true;
            break;
        }
        $r = array_values($open);
        $w = $e = null;
        if (@stream_select($r, $w, $e, 0, 200000) === false) {
            break;
        }
        foreach ($r as $s) {
            $chunk = fread($s, 8192);
            $which = ($s === $pipes[1]) ? 1 : 2;
            if ($chunk === '' || $chunk === false) {
                if (feof($s)) {
                    unset($open[$which]);
                }
                continue;
            }
            if ($which === 1 && strlen($out) < $maxOut) {
                $out .= substr($chunk, 0, $maxOut - strlen($out));
            } elseif ($which === 2 && strlen($err) < $maxOut) {
                $err .= substr($chunk, 0, $maxOut - strlen($err));
            }
        }
    }
    if ($timedOut) {
        proc_terminate($proc, 15);
        usleep(200000);
        $st = proc_get_status($proc);
        if ($st['running']) {
            proc_terminate($proc, 9);
        }
    }
    // Espera o fim (já terminou ao fechar stdout/stderr, ou foi morto).
    for ($i = 0; $i < 50; $i++) {
        $st = proc_get_status($proc);
        if (!$st['running']) {
            $exit = (int)$st['exitcode'];
            break;
        }
        usleep(100000);
    }
    fclose($pipes[1]);
    fclose($pipes[2]);
    proc_close($proc);
    return ['exit' => $exit, 'out' => $out, 'err' => $err, 'timed_out' => $timedOut];
}

/**
 * Envia Disconnect-Request ao NAS.
 * @return array{status:string, ok:bool, message:string}  status: ack|nak|timeout|error
 */
function coa_disconnect(PDO $pdo, string $username, string $nasIp, string $sessionId, string $framedIp = ''): array
{
    $res = coa_disconnect_raw($pdo, $username, $nasIp, $sessionId, $framedIp);
    audit('session.disconnect', $username, [
        'nas' => $nasIp, 'session' => $sessionId, 'result' => $res['status'],
    ]);
    return $res;
}

function coa_disconnect_raw(PDO $pdo, string $username, string $nasIp, string $sessionId, string $framedIp): array
{
    $fail = static fn(string $m, string $s = 'error'): array => ['status' => $s, 'ok' => false, 'message' => $m];
    $tmp = null;
    try {
        if (!valid_username($username)) {
            return $fail('Nome de usuário inválido; sessão não derrubada.');
        }
        if (!coa_valid_ip($nasIp)) {
            return $fail('IP do NAS inválido.');
        }
        if (!coa_valid_session_id($sessionId)) {
            return $fail('Identificador de sessão inválido.');
        }
        if ($framedIp !== '' && !coa_valid_ip($framedIp)) {
            return $fail('IP do usuário inválido.');
        }
        $st = $pdo->prepare('SELECT secret FROM nas WHERE nasname = ? ORDER BY id LIMIT 1');
        $st->execute([$nasIp]);
        $secret = $st->fetchColumn();
        if ($secret === false) {
            return $fail("O NAS $nasIp não está cadastrado em Equipamentos; cadastre-o (com o segredo) para poder derrubar sessões.");
        }
        $secret = (string)$secret;
        if (!coa_valid_secret($secret)) {
            return $fail('O segredo cadastrado para este NAS tem caracteres não suportados.');
        }
        $bin = (string)cfg('radclient', '/opt/freeradius/bin/radclient');
        if ($bin === '' || $bin[0] !== '/' || !is_file($bin) || !is_executable($bin)) {
            return $fail('radclient não encontrado ou sem permissão de execução no servidor.');
        }
        $port = (int)cfg('coa_port', 3799);
        if ($port < 1 || $port > 65535) {
            return $fail('Porta CoA inválida na configuração.');
        }
        $tmpdir = sys_get_temp_dir();
        $tmp = tempnam($tmpdir, 'coa');
        if ($tmp === false) {
            return $fail('Não foi possível criar arquivo temporário.');
        }
        chmod($tmp, 0600);
        if (file_put_contents($tmp, $secret . "\n") === false) {
            return $fail('Não foi possível gravar arquivo temporário.');
        }

        $v6 = str_contains($nasIp, ':');
        $target = ($v6 ? '[' . $nasIp . ']' : $nasIp) . ':' . $port;
        $lines = ['User-Name = "' . $username . '"', 'Acct-Session-Id = "' . $sessionId . '"'];
        $lines[] = $v6 ? 'NAS-IPv6-Address = ' . $nasIp : 'NAS-IP-Address = ' . $nasIp;
        if ($framedIp !== '' && !str_contains($framedIp, ':')) {
            $lines[] = 'Framed-IP-Address = ' . $framedIp;
        }
        $argv = [$bin, '-S', $tmp, '-r', '1', '-t', '3', $target, 'disconnect'];
        $run = coa_run($argv, implode("\n", $lines) . "\n", 12);
    } catch (RuntimeException $e) {
        return $fail($e->getMessage());
    } catch (Throwable $e) {
        log_exception($e, 'coa');
        return $fail('Erro interno ao contatar o NAS.');
    } finally {
        if (is_string($tmp) && $tmp !== '' && file_exists($tmp)) {
            @unlink($tmp);
        }
    }

    $text = $run['out'] . "\n" . $run['err'];
    if ($run['timed_out']) {
        return $fail('O NAS não respondeu a tempo (timeout).', 'timeout');
    }
    if ($run['exit'] === 0) {
        return ['status' => 'ack', 'ok' => true, 'message' => 'Sessão derrubada (Disconnect-ACK do NAS).'];
    }
    if ($run['exit'] === 1) {
        if (stripos($text, 'No reply') !== false || stripos($text, 'timed out') !== false || stripos($text, 'timeout') !== false) {
            return $fail('O NAS não respondeu (sem resposta). Confira IP, segredo, firewall e se o CoA/Disconnect está habilitado (porta ' . $port . ').', 'timeout');
        }
        if (stripos($text, 'NAK') !== false) {
            return $fail('O NAS recusou o pedido (Disconnect-NAK): a sessão pode já ter terminado.', 'nak');
        }
        return $fail('O NAS recusou ou não respondeu ao pedido de desconexão.', 'nak');
    }
    log_exception(new RuntimeException('radclient saiu com código ' . $run['exit']), 'coa');
    return $fail('Falha ao executar o radclient (código ' . $run['exit'] . ').');
}

/**
 * Derruba todas as sessões online do usuário (radacct sem fim e atualizadas nas últimas 24 h).
 * @return array{total:int, ok:int, failed:int, results:array, message:string}
 */
function coa_disconnect_user(PDO $pdo, string $username): array
{
    if (!valid_username($username)) {
        throw new RuntimeException('Nome de usuário inválido.');
    }
    $st = $pdo->prepare(
        'SELECT nasipaddress, acctsessionid, framedipaddress FROM radacct
         WHERE username = ? AND acctstoptime IS NULL AND acctupdatetime > (NOW() - INTERVAL 1 DAY)
         ORDER BY acctstarttime DESC LIMIT 20'
    );
    $st->execute([$username]);
    $rows = $st->fetchAll();
    // Até 20 sessões x 12 s: sem isso o limite padrão (30 s) cortaria o pedido no meio.
    @set_time_limit(20 * 13 + 10);
    $results = [];
    $ok = 0;
    foreach ($rows as $r) {
        $res = coa_disconnect($pdo, $username, (string)$r['nasipaddress'], (string)$r['acctsessionid'], (string)$r['framedipaddress']);
        $results[] = $res;
        $ok += $res['ok'] ? 1 : 0;
    }
    $total = count($rows);
    if ($total === 0) {
        $msg = 'Nenhuma sessão online deste usuário.';
    } elseif ($ok === $total) {
        $msg = "$ok sessão(ões) derrubada(s).";
    } else {
        $first = '';
        foreach ($results as $x) {
            if (!$x['ok']) {
                $first = $x['message'];
                break;
            }
        }
        $msg = "$ok de $total derrubada(s). Falha: $first";
    }
    return ['total' => $total, 'ok' => $ok, 'failed' => $total - $ok, 'results' => $results, 'message' => $msg];
}
