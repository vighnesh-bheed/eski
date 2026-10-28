import argparse
import html
import json
import math
from pathlib import Path
import sys

sys.dont_write_bytecode = True

SLOTS = {'eski-docker': 0, 'eski': 0, 'redis': 1, 'valkey': 2, 'dragonfly': 3}
SERIES = {'light': ('#2a78d6', '#eb6834', '#1baf7a', '#eda100'), 'dark': ('#3987e5', '#d95926', '#199e70', '#c98500')}
INK = {
    'light': dict(surface='#fcfcfb', primary='#0b0b0b', secondary='#52514e', muted='#898781', grid='#e1e0d9', axis='#c3c2b7'),
    'dark': dict(surface='#1a1a19', primary='#f0efec', secondary='#c3c2b7', muted='#898781', grid='#2c2c2a', axis='#383835'),
}
CSS = dict(surface='var(--surface)', primary='var(--ink-1)', secondary='var(--ink-2)', muted='var(--ink-3)', grid='var(--grid)', axis='var(--axis)',
           series=tuple('var(--series-%d)' % n for n in range(1, 5)))
METRICS = {
    'ops': dict(title='Throughput', unit='operations per second', direction='higher is better', divisor=1, file='throughput'),
    'p99': dict(title='p99 latency', unit='milliseconds', direction='lower is better', divisor=1, file='latency-p99'),
    'mem': dict(title='Server memory peak', unit='MiB, container memory.peak', direction='lower is better', divisor=1024 ** 2, file='memory'),
}
FONT = "system-ui, -apple-system, 'Segoe UI', Helvetica, Arial, sans-serif"
SUBJECT = ('eski-docker', 'eski')


def esc(value):
    return html.escape(str(value), quote=True)


def paint(theme):
    if theme == 'css':
        return dict(CSS)
    return dict(INK[theme], series=SERIES[theme])


def color(engine, engines, colors):
    slot = SLOTS.get(engine)
    if slot is None:
        slot = [item['target'] for item in engines].index(engine) % len(colors['series'])
    return colors['series'][slot]


def short(label):
    return str(label).split(' ')[0]


def nice_ticks(top):
    if not top or top <= 0 or not math.isfinite(top):
        return [0, 1]
    raw = top / 4
    magnitude = 10 ** math.floor(math.log10(raw))
    step = next(c * magnitude for c in (1, 2, 2.5, 5, 10) if c * magnitude >= raw)
    ticks, value = [], 0.0
    while value < top - 1e-12 * top:
        ticks.append(value)
        value += step
    ticks.append(value)
    return ticks


def compact(value, metric):
    if value is None:
        return 'n/a'
    if metric == 'ops':
        if value >= 1e6:
            return ('%.2f' % (value / 1e6)).rstrip('0').rstrip('.') + 'M'
        if value >= 1e3:
            return '%.0fK' % (value / 1e3) if value >= 1e4 else '%.1fK' % (value / 1e3)
        return '%.0f' % value
    if metric == 'mem':
        return '%.0f' % value if value >= 100 or float(value).is_integer() else '%.1f' % value
    return '%.3g' % value if value < 10 else '%.1f' % value


def exact(value, metric):
    if value is None:
        return 'n/a'
    if metric == 'ops':
        return '{:,.0f} ops/s'.format(value)
    if metric == 'mem':
        return '%.1f MiB' % (value / 1024 ** 2)
    return '%.3f ms' % value


def cells(dataset):
    return {(cell['workload'], cell['engine']): cell for cell in dataset.get('summary') or []}


def tooltip(engine_label, cell, metric):
    stats = cell.get(metric) if cell else None
    parts = []
    if stats:
        parts.append('%s: median %s, range %s to %s over %d valid repetitions' % (
            engine_label, exact(stats['median'], metric), exact(stats['min'], metric), exact(stats['max'], metric), len(stats['values'])))
    else:
        parts.append('%s: no valid repetition' % engine_label)
    if cell and cell.get('client_limited'):
        parts.append('client limited in %d, so throughput is a lower bound' % cell['client_limited'])
    for item in (cell or {}).get('excluded') or []:
        parts.append('excluded repetition %d (%s): %s' % (item['repetition'], exact(item.get(metric), metric) if item.get(metric) is not None else 'no value',
                                                         '; '.join(item.get('reasons') or [item.get('state', '')]).replace('_', ' ')))
    return '. '.join(parts)


def panel(dataset, workload, metric, x, y, width, height, colors, heading=None):
    spec = METRICS[metric]
    divisor = spec['divisor']
    engines = dataset['engines']
    table = cells(dataset)
    entries = [(engine, table.get((workload['key'], engine['target']))) for engine in engines]
    valid = [stats['max'] / divisor for _, cell in entries if cell and (stats := cell.get(metric))]
    excluded = [item[metric] / divisor for _, cell in entries if cell for item in cell.get('excluded') or [] if item.get(metric) is not None]
    top_valid = max(valid) if valid else 0
    candidates = [value for value in excluded if value <= top_valid * 1.5] if valid else excluded
    ticks = nice_ticks(max(valid + candidates) * 1.08 if (valid or candidates) else 1)
    scale = ticks[-1]
    left, right, top, bottom = 44, 8, 26 if heading else 10, 24
    plot_w, plot_h = width - left - right, height - top - bottom
    base_y = top + plot_h

    def yv(value):
        return top + plot_h - plot_h * min(value, scale) / scale

    out = ['<g transform="translate(%.1f %.1f)">' % (x, y)]
    if heading:
        out.append('<text x="%d" y="14" font-size="12" font-weight="600" fill="%s">%s</text>' % (left - 36, colors['primary'], esc(heading)))
    for tick in ticks:
        out.append('<line x1="%d" x2="%d" y1="%.1f" y2="%.1f" stroke="%s" stroke-width="1"/>' % (left, width - right, yv(tick), yv(tick), colors['grid'] if tick else colors['axis']))
        out.append('<text x="%d" y="%.1f" font-size="9.5" text-anchor="end" fill="%s" style="font-variant-numeric: tabular-nums">%s</text>' % (
            left - 5, yv(tick) + 3.2, colors['muted'], esc(compact(tick, metric))))
    band = plot_w / max(1, len(entries))
    bar = min(24, band * 0.58)
    for position, (engine, cell) in enumerate(entries):
        cx = left + band * position + band / 2
        fill = color(engine['target'], engines, colors)
        out.append('<text x="%.1f" y="%.1f" font-size="9.5" text-anchor="middle" fill="%s">%s</text>' % (cx, base_y + 14, colors['secondary'], esc(short(engine['label']))))
        out.append('<g class="mark"><title>%s</title>' % esc(tooltip(engine['label'], cell, metric)))
        out.append('<rect x="%.1f" y="%d" width="%.1f" height="%d" fill="transparent"/>' % (cx - band / 2, top, band, plot_h))
        stats = cell.get(metric) if cell else None
        if stats:
            median, low, high = stats['median'] / divisor, stats['min'] / divisor, stats['max'] / divisor
            height_px = max(0.0, base_y - yv(median))
            radius = min(4.0, height_px / 2, bar / 2)
            x0 = cx - bar / 2
            out.append('<path d="M%.1f %.1f V%.1f Q%.1f %.1f %.1f %.1f H%.1f Q%.1f %.1f %.1f %.1f V%.1f Z" fill="%s"/>' % (
                x0, base_y, base_y - height_px + radius, x0, base_y - height_px, x0 + radius, base_y - height_px,
                x0 + bar - radius, x0 + bar, base_y - height_px, x0 + bar, base_y - height_px + radius, base_y, fill))
            if high > low:
                out.append('<path d="M%.1f %.1f V%.1f M%.1f %.1f H%.1f M%.1f %.1f H%.1f" stroke="%s" stroke-width="1.5" fill="none"/>' % (
                    cx, yv(high), yv(low), cx - 4, yv(high), cx + 4, cx - 4, yv(low), cx + 4, colors['primary']))
            if engine['target'] in SUBJECT:
                out.append('<text x="%.1f" y="%.1f" font-size="10" text-anchor="middle" fill="%s" style="font-variant-numeric: tabular-nums">%s</text>' % (
                    cx, max(top - 2, yv(high) - 5), colors['primary'], esc(compact(median, metric))))
        else:
            out.append('<text x="%.1f" y="%.1f" font-size="9" text-anchor="middle" fill="%s">no valid run</text>' % (cx, base_y - 6, colors['muted']))
        for item in (cell or {}).get('excluded') or []:
            if item.get(metric) is None:
                continue
            value = item[metric] / divisor
            ex = cx + bar / 2 + 6
            if value > scale:
                out.append('<path d="M%.1f %.1f l4 7 h-8 z" fill="%s" stroke="%s" stroke-width="1.5"/>' % (ex, top, colors['surface'], colors['primary']))
            else:
                out.append('<circle cx="%.1f" cy="%.1f" r="4" fill="%s" stroke="%s" stroke-width="1.5"/>' % (ex, yv(value), colors['surface'], colors['primary']))
        out.append('</g>')
    out.append('</g>')
    return out


def context_line(dataset):
    machine, design = dataset.get('machine') or {}, dataset.get('design') or {}
    cpus = machine.get('cpus') or {}
    client, data = design.get('client') or {}, design.get('dataset') or {}
    parts = [machine.get('cpu_model') or 'machine unavailable']
    if cpus:
        parts.append('server CPU %s, client CPUs %s' % (','.join(map(str, cpus.get('server', []))), ','.join(map(str, cpus.get('client', [])))))
    if data.get('keys'):
        parts.append('{:,} keys'.format(data['keys']))
    if client.get('threads'):
        parts.append('%d connections' % (client['threads'] * client['connections_per_thread']))
    if client.get('test_seconds'):
        parts.append('%d s timed after %d s warmup' % (client['test_seconds'], client.get('warmup_seconds', 0)))
    return ' | '.join(parts)


def legend(dataset, colors, x, y, excluded=True):
    out, position = [], x
    for engine in dataset['engines']:
        out.append('<rect x="%.1f" y="%.1f" width="12" height="12" rx="3" fill="%s"/>' % (position, y - 10, color(engine['target'], dataset['engines'], colors)))
        out.append('<text x="%.1f" y="%.1f" font-size="11.5" fill="%s">%s</text>' % (position + 17, y, colors['secondary'], esc(engine['label'])))
        position += 17 + 6.6 * len(engine['label']) + 22
    if excluded:
        out.append('<circle cx="%.1f" cy="%.1f" r="4" fill="%s" stroke="%s" stroke-width="1.5"/>' % (position + 5, y - 4, colors['surface'], colors['primary']))
        out.append('<text x="%.1f" y="%.1f" font-size="11.5" fill="%s">excluded repetition</text>' % (position + 15, y, colors['secondary']))
    return out


def metric_figure(dataset, metric, theme):
    colors = paint(theme)
    spec = METRICS[metric]
    workloads = dataset['workloads']
    columns = 4
    rows = max(1, math.ceil(len(workloads) / columns))
    width, panel_w, panel_h, header = 960, 236, 196, 92
    height = header + rows * panel_h + 34
    out = ['<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %d %d" width="%d" height="%d" font-family="%s" role="img" aria-labelledby="title desc">' % (
        width, height, width, height, esc(FONT))]
    out.append('<title id="title">%s per workload: Eski, Redis, Valkey and Dragonfly</title>' % esc(spec['title']))
    out.append('<desc id="desc">Small multiples, one panel per workload with its own scale. Bars are medians of the valid repetitions, whiskers the observed minimum and maximum, hollow circles excluded repetitions.</desc>')
    out.append('<rect width="%d" height="%d" fill="%s"/>' % (width, height, colors['surface']))
    out.append('<text x="12" y="24" font-size="16" font-weight="600" fill="%s">%s, median of valid repetitions with observed range</text>' % (colors['primary'], esc(spec['title'])))
    out.append('<text x="12" y="44" font-size="12" fill="%s">%s, %s; each panel has its own scale</text>' % (colors['secondary'], esc(spec['unit']), esc(spec['direction'])))
    out.append('<text x="12" y="62" font-size="11" fill="%s">%s</text>' % (colors['muted'], esc(context_line(dataset))))
    out += legend(dataset, colors, 12, 84)
    for index, workload in enumerate(workloads):
        out += panel(dataset, workload, metric, 4 + (index % columns) * panel_w, header + (index // columns) * panel_h, panel_w, panel_h - 6, colors, workload['name'])
    out.append('<text x="12" y="%d" font-size="11" fill="%s">Bars: median of valid repetitions. Whiskers: observed minimum to maximum. Hollow circles: excluded repetitions, never part of a median. A caret marks one beyond the scale.</text>' % (
        height - 12, colors['muted']))
    out.append('</svg>')
    return '\n'.join(out) + '\n'


def fill_figure(dataset, theme):
    fill = dataset.get('fill')
    if not fill:
        return None
    colors = paint(theme)
    engines = {engine['target']: engine for engine in dataset['engines']}
    rows = fill['engines']
    width, left, row_h, header = 960, 150, 40, 76
    height = header + row_h * len(rows) + 30
    values = [row['bytes_per_key_rss'] for row in rows if row.get('status') == 'valid' and row.get('bytes_per_key_rss')]
    scale = max(values) * 1.25 if values else 1
    plot_w = width - left - 300
    design = fill.get('design') or {}
    out = ['<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %d %d" width="%d" height="%d" font-family="%s" role="img" aria-labelledby="fill-title">' % (
        width, height, width, height, esc(FONT))]
    out.append('<title id="fill-title">Resident bytes per key after a fill of {:,} keys</title>'.format(design.get('keys') or 0))
    out.append('<rect width="%d" height="%d" fill="%s"/>' % (width, height, colors['surface']))
    out.append('<text x="12" y="24" font-size="16" font-weight="600" fill="%s">Resident bytes per key after filling {:,} keys of {} B</text>'.format(design.get('keys') or 0, design.get('data_size')) % colors['primary'])
    out.append('<text x="12" y="44" font-size="12" fill="%s">server resident set divided by the key count, lower is better; pipeline %s, same server core and memory cap as the comparison</text>' % (
        colors['secondary'], esc(design.get('pipeline'))))
    out.append('<text x="12" y="62" font-size="11" fill="%s">%s</text>' % (colors['muted'], esc((fill.get('machine') or {}).get('cpu_model') or '')))
    for index, row in enumerate(rows):
        top = header + index * row_h
        label = (engines.get(row['target']) or {}).get('label') or row.get('label') or row['target']
        out.append('<text x="%d" y="%.1f" font-size="12" text-anchor="end" fill="%s">%s</text>' % (left - 10, top + 17, colors['secondary'], esc(label)))
        if row.get('status') == 'valid' and row.get('bytes_per_key_rss'):
            length = max(4.0, plot_w * row['bytes_per_key_rss'] / scale)
            out.append('<g class="mark"><title>%s</title>' % esc('%s: %.1f bytes per key resident, %s bytes per key used, %s keys, fill at %s, worst request %s ms' % (
                label, row['bytes_per_key_rss'], '%.1f' % row['bytes_per_key_used'] if row.get('bytes_per_key_used') else 'n/a',
                '{:,}'.format(row['dbsize']) if row.get('dbsize') else 'n/a', exact(row.get('ops_per_sec'), 'ops'), row.get('max_ms'))))
            out.append('<path d="M%d %.1f H%.1f Q%.1f %.1f %.1f %.1f V%.1f Q%.1f %.1f %.1f %.1f H%d Z" fill="%s"/>' % (
                left, top + 4, left + length - 4, left + length, top + 4, left + length, top + 8, top + 20, left + length, top + 24, left + length - 4, top + 24,
                left, color(row['target'], dataset['engines'], colors)))
            out.append('</g>')
            out.append('<text x="%.1f" y="%.1f" font-size="11.5" fill="%s" style="font-variant-numeric: tabular-nums">%.1f B per key, worst request %s ms</text>' % (
                left + length + 8, top + 18, colors['primary'], row['bytes_per_key_rss'], '%.1f' % row['max_ms'] if row.get('max_ms') is not None else 'n/a'))
        else:
            out.append('<text x="%d" y="%.1f" font-size="11.5" fill="%s">not measured: %s</text>' % (left + 8, top + 18, colors['muted'], esc(row.get('error') or row.get('status'))))
    out.append('<line x1="%d" x2="%d" y1="%d" y2="%d" stroke="%s" stroke-width="1"/>' % (left, left, header, header + row_h * len(rows) - 12, colors['axis']))
    out.append('</svg>')
    return '\n'.join(out) + '\n'


def render(dataset, output):
    output = Path(output)
    output.mkdir(parents=True, exist_ok=True)
    written = []
    for theme in ('light', 'dark'):
        suffix = '' if theme == 'light' else '-dark'
        for metric, spec in METRICS.items():
            path = output / (spec['file'] + suffix + '.svg')
            path.write_text(metric_figure(dataset, metric, theme))
            written.append(path)
        figure = fill_figure(dataset, theme)
        if figure:
            path = output / ('fill-bytes-per-key' + suffix + '.svg')
            path.write_text(figure)
            written.append(path)
    return written


def main(argv=None):
    parser = argparse.ArgumentParser(description='Render the throughput, p99, memory and fill charts of a dataset as SVG in light and dark variants.')
    parser.add_argument('--dataset', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        written = render(json.loads(args.dataset.read_text()), args.out)
    except (OSError, ValueError, KeyError, TypeError) as error:
        print('charts.py: error: ' + str(error), file=sys.stderr)
        return 2
    for path in written:
        print(path)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
