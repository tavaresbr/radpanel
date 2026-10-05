#!/usr/bin/env php
<?php
declare(strict_types=1);

/*
 * Define uma chave simples no config.php do painel (arquivo que retorna um array PHP), sem apagar o resto.
 * Uso: php bin/config-set.php ARQUIVO CHAVE VALOR      (hoje só a chave server_ip, validada como IPv4/IPv6 ou nome de host)
 * - se a chave existe (mesmo vazia): troca o valor; se não existe: insere antes do "];" final.
 * Sai com 0 se gravou (ou já estava igual), 1 se recusou/falhou.
 */
if ($argc !== 4) {
    fwrite(STDERR, "uso: config-set.php ARQUIVO CHAVE VALOR\n");
    exit(1);
}
[, $file, $key, $value] = $argv;
if ($key !== 'server_ip') {
    fwrite(STDERR, "chave não permitida: $key\n");
    exit(1);
}
if (filter_var($value, FILTER_VALIDATE_IP) === false
    && !preg_match('/^(?=.{1,253}$)([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$/D', $value)) {
    fwrite(STDERR, "valor inválido para server_ip\n");
    exit(1);
}
$src = @file_get_contents($file);
if ($src === false) {
    fwrite(STDERR, "não consegui ler $file\n");
    exit(1);
}
$line = "    'server_ip' => '" . $value . "',";
if (preg_match("/^[ \t]*'server_ip'[ \t]*=>[^\n]*$/m", $src)) {
    $new = preg_replace("/^[ \t]*'server_ip'[ \t]*=>[^\n]*$/m", $line, $src, 1);
} else {
    $pos = strrpos($src, '];');
    if ($pos === false) {
        fwrite(STDERR, "formato inesperado: não achei o ']; ' final\n");
        exit(1);
    }
    $new = substr($src, 0, $pos) . $line . "\n" . substr($src, $pos);
}
// confere que continua sendo um PHP válido que devolve array com a chave certa antes de gravar
$tmp = tempnam(dirname($file), '.cfg-');
if ($tmp === false || file_put_contents($tmp, $new) === false) {
    fwrite(STDERR, "não consegui gravar o temporário\n");
    exit(1);
}
$chk = @include $tmp;
if (!is_array($chk) || ($chk['server_ip'] ?? null) !== $value) {
    @unlink($tmp);
    fwrite(STDERR, "o arquivo resultante não passou na conferência; nada foi alterado\n");
    exit(1);
}
$st = @stat($file);
@chmod($tmp, $st ? ($st['mode'] & 0777) : 0640);
if ($st) {
    @chown($tmp, $st['uid']);
    @chgrp($tmp, $st['gid']);
}
if (!rename($tmp, $file)) {
    @unlink($tmp);
    fwrite(STDERR, "não consegui substituir $file\n");
    exit(1);
}
exit(0);
