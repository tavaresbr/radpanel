<?php
declare(strict_types=1);

/**
 * Gráfico de barras empilhadas em SVG inline, gerado no servidor.
 * Sem style=, <style> ou <script>: só atributos de apresentação e classes de reports.css.
 *
 * $series: [['name' => 'Upload', 'class' => 'bar-up', 'values' => [..]], ...]
 * $labels: rótulos do eixo X (mesmo tamanho dos values)
 * $opts:   title (aria-label), fmt (callable float->string para dicas/eixo), width, height
 */
function chart_num($v): float
{
    $f = is_numeric($v) ? (float)$v : 0.0;
    if (!is_finite($f) || $f < 0) {
        return 0.0;
    }
    return min($f, 1.0e18);
}

function chart_bars(array $series, array $labels, array $opts = []): string
{
    $fmt = $opts['fmt'] ?? fn(float $n): string => number_format($n, 0, ',', '.');
    $title = (string)($opts['title'] ?? 'Gráfico');
    $W = max(320, min((int)($opts['width'] ?? 900), 2000));
    $H = max(160, min((int)($opts['height'] ?? 320), 1000));
    $n = min(count($labels), 800);
    $labels = array_slice(array_values($labels), 0, $n);

    $clean = [];
    foreach (array_slice(array_values($series), 0, 6) as $i => $s) {
        $cls = preg_replace('/[^a-z0-9-]/', '', strtolower((string)($s['class'] ?? ''))) ?: 'bar-s' . ($i + 1);
        $vals = [];
        $src = array_values((array)($s['values'] ?? []));
        for ($k = 0; $k < $n; $k++) {
            $vals[$k] = chart_num($src[$k] ?? 0);
        }
        $clean[] = ['name' => (string)($s['name'] ?? ''), 'class' => $cls, 'values' => $vals];
    }

    $svgOpen = '<svg class="chart" viewBox="0 0 ' . $W . ' ' . $H . '" role="img" aria-label="' . h($title)
        . '" preserveAspectRatio="xMidYMid meet" xmlns="http://www.w3.org/2000/svg">';
    if ($n === 0 || !$clean) {
        return $svgOpen . '<title>' . h($title) . '</title><text class="chart-text" x="' . ($W / 2)
            . '" y="' . ($H / 2) . '" text-anchor="middle" font-size="14">Sem dados no período</text></svg>';
    }

    $totals = array_fill(0, $n, 0.0);
    foreach ($clean as $s) {
        foreach ($s['values'] as $k => $v) {
            $totals[$k] += $v;
        }
    }
    $max = max($totals) ?: 1.0;
    // eixo Y com valor "redondo"
    $mag = 10 ** floor(log10($max));
    foreach ([1, 2, 2.5, 5, 10] as $m) {
        if ($max <= $m * $mag) {
            $max = $m * $mag;
            break;
        }
    }

    $padL = 72; $padR = 12; $padT = 30; $padB = 46;
    $pw = $W - $padL - $padR;
    $ph = $H - $padT - $padB;
    $slot = $pw / $n;
    $bw = max(1.0, $slot * 0.72);

    $o = $svgOpen . '<title>' . h($title) . '</title>';
    // grade e eixo Y
    foreach ([0, 0.5, 1] as $g) {
        $y = $padT + $ph - $ph * $g;
        $o .= '<line class="chart-grid" x1="' . $padL . '" x2="' . ($W - $padR) . '" y1="' . round($y, 1) . '" y2="' . round($y, 1) . '"/>';
        $o .= '<text class="chart-text" x="' . ($padL - 6) . '" y="' . round($y + 4, 1) . '" text-anchor="end" font-size="11">'
            . h($fmt($max * $g)) . '</text>';
    }
    // barras
    $baseY = $padT + $ph;
    for ($k = 0; $k < $n; $k++) {
        $x = $padL + $k * $slot + ($slot - $bw) / 2;
        $tip = (string)$labels[$k];
        foreach ($clean as $s) {
            $tip .= ' · ' . $s['name'] . ': ' . $fmt($s['values'][$k]);
        }
        $o .= '<g><title>' . h($tip) . '</title>';
        $yy = $baseY;
        foreach ($clean as $s) {
            $hh = $s['values'][$k] / $max * $ph;
            if ($hh <= 0) {
                continue;
            }
            $yy -= $hh;
            $o .= '<rect class="' . h($s['class']) . '" x="' . round($x, 2) . '" y="' . round($yy, 2)
                . '" width="' . round($bw, 2) . '" height="' . round($hh, 2) . '"/>';
        }
        // área transparente para a dica cobrir a coluna inteira
        $o .= '<rect class="bar-hit" x="' . round($padL + $k * $slot, 2) . '" y="' . $padT . '" width="' . round($slot, 2)
            . '" height="' . $ph . '"/></g>';
    }
    $o .= '<line class="chart-axis" x1="' . $padL . '" x2="' . ($W - $padR) . '" y1="' . $baseY . '" y2="' . $baseY . '"/>';
    // rótulos X espaçados
    $every = max(1, (int)ceil($n / max(1, floor($pw / 54))));
    for ($k = 0; $k < $n; $k += $every) {
        $cx = $padL + $k * $slot + $slot / 2;
        $o .= '<text class="chart-text" x="' . round($cx, 1) . '" y="' . ($baseY + 16) . '" text-anchor="middle" font-size="11">'
            . h(mb_substr((string)$labels[$k], 0, 12)) . '</text>';
    }
    // legenda
    $lx = $padL;
    foreach ($clean as $s) {
        $o .= '<rect class="' . h($s['class']) . '" x="' . $lx . '" y="8" width="12" height="12"/>'
            . '<text class="chart-text" x="' . ($lx + 17) . '" y="18" font-size="12">' . h($s['name']) . '</text>';
        $lx += 30 + 8 * mb_strlen($s['name']);
    }
    return $o . '</svg>';
}
