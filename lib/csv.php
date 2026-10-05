<?php
declare(strict_types=1);

/**
 * Exportação CSV segura (UTF-8 com BOM, separador ";" para Excel pt-BR).
 */

const CSV_SEP = ';';

/**
 * Neutraliza injeção de fórmula (CSV/Excel injection).
 * - null -> ''; int/float nativos e strings estritamente numéricas ("-5", "12.5") passam como estão.
 * - Texto cujo primeiro caractere (ignorando espaços/quebras iniciais) é = + - @ ,
 *   ou que começa com TAB/CR, recebe o prefixo ' (apóstrofo).
 */
function csv_cell($v): string
{
    if ($v === null) {
        return '';
    }
    if (is_bool($v)) {
        return $v ? '1' : '0';
    }
    if (is_int($v)) {
        return (string)$v;
    }
    if (is_float($v)) {
        return is_finite($v) ? rtrim(rtrim(number_format($v, 6, '.', ''), '0'), '.') : '';
    }
    $s = str_replace("\0", '', (string)$v);
    if ($s === '') {
        return '';
    }
    if (preg_match('/^-?[0-9]{1,30}(\.[0-9]{1,15})?$/', $s)) {
        return $s;
    }
    if (preg_match('/^[\t\r]/', $s) || preg_match('/^[ \n]*[=+\-@]/', $s)) {
        return "'" . $s;
    }
    return $s;
}

/** Linha pronta para fputcsv (todas as células neutralizadas). */
function csv_row(array $cells): array
{
    return array_map('csv_cell', array_values($cells));
}

/** Escreve uma linha no fluxo (sem caractere de escape; fim de linha CRLF). */
function csv_write($out, array $cells): void
{
    fputcsv($out, csv_row($cells), CSV_SEP, '"', '', "\r\n");
}

/** Nome de arquivo fixo e seguro: radpanel-<relatorio>-<AAAAMMDD>.csv */
function csv_filename(string $report): string
{
    $r = preg_replace('/[^a-z0-9]+/', '', strtolower($report)) ?: 'relatorio';
    return 'radpanel-' . $r . '-' . date('Ymd') . '.csv';
}
