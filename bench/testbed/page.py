import argparse
import datetime
import html
import importlib.util
import json
from pathlib import Path
import sys

sys.dont_write_bytecode = True

_spec = importlib.util.spec_from_file_location('eski_testbed_charts', Path(__file__).with_name('charts.py'))
charts = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(charts)

STYLE = '''
:root { color-scheme: light; --page: #f9f9f7; --surface: #fcfcfb; --ink-1: #0b0b0b; --ink-2: #52514e; --ink-3: #898781; --grid: #e1e0d9; --axis: #c3c2b7;
  --border: rgba(11,11,11,0.10); --series-1: #2a78d6; --series-2: #eb6834; --series-3: #1baf7a; --series-4: #eda100; }
@media (prefers-color-scheme: dark) { :root:not([data-theme="light"]) { color-scheme: dark; --page: #0d0d0d; --surface: #1a1a19; --ink-1: #f0efec; --ink-2: #c3c2b7;
  --ink-3: #898781; --grid: #2c2c2a; --axis: #383835; --border: rgba(255,255,255,0.10); --series-1: #3987e5; --series-2: #d95926; --series-3: #199e70; --series-4: #c98500; } }
:root[data-theme="dark"] { color-scheme: dark; --page: #0d0d0d; --surface: #1a1a19; --ink-1: #f0efec; --ink-2: #c3c2b7; --ink-3: #898781; --grid: #2c2c2a;
  --axis: #383835; --border: rgba(255,255,255,0.10); --series-1: #3987e5; --series-2: #d95926; --series-3: #199e70; --series-4: #c98500; }
* { box-sizing: border-box; }
body { margin: 0; background: var(--page); color: var(--ink-1); font-family: system-ui, -apple-system, "Segoe UI", Helvetica, Arial, sans-serif;
  font-size: 15px; line-height: 1.5; padding: 32px 16px 64px; }
main { max-width: 1120px; margin: 0 auto; display: grid; gap: 32px; }
h1 { font-size: clamp(24px, 3.4vw, 34px); line-height: 1.15; margin: 0; font-weight: 650; text-wrap: balance; }
h2 { font-size: 20px; margin: 0 0 10px; font-weight: 650; }
h3 { font-size: 16px; margin: 0; font-weight: 600; }
p { margin: 0; max-width: 78ch; }
.eyebrow { font-size: 12px; letter-spacing: 0.06em; text-transform: uppercase; color: var(--ink-3); }
.lede { color: var(--ink-2); font-size: 16px; }
header { display: grid; gap: 10px; }
.legend { display: flex; flex-wrap: wrap; gap: 8px 20px; color: var(--ink-2); font-size: 14px; }
.legend span { display: inline-flex; align-items: center; gap: 8px; }
.swatch { width: 12px; height: 12px; border-radius: 3px; display: inline-block; }
.hollow { width: 9px; height: 9px; border-radius: 50%; border: 1.5px solid var(--ink-1); display: inline-block; }
.facts { display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 10px 24px; }
.facts div { border-top: 1px solid var(--grid); padding-top: 6px; font-size: 14px; overflow-wrap: anywhere; }
.facts b { display: block; font-size: 11.5px; letter-spacing: 0.05em; text-transform: uppercase; color: var(--ink-3); font-weight: 600; }
.workload { display: grid; gap: 8px; padding-top: 16px; border-top: 1px solid var(--grid); }
.panels { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 12px; }
.panel { background: var(--surface); border: 1px solid var(--border); border-radius: 8px; padding: 4px; }
.panel svg, .figure svg { display: block; width: 100%; height: auto; }
.figure { background: var(--surface); border: 1px solid var(--border); border-radius: 8px; padding: 4px; }
.note { color: var(--ink-2); font-size: 14px; }
.tablewrap { overflow-x: auto; border: 1px solid var(--border); border-radius: 8px; background: var(--surface); }
table { border-collapse: collapse; font-size: 13px; width: 100%; }
th, td { text-align: right; padding: 6px 10px; border-bottom: 1px solid var(--grid); white-space: nowrap; font-variant-numeric: tabular-nums; }
th { color: var(--ink-3); font-weight: 600; font-size: 11.5px; letter-spacing: 0.04em; text-transform: uppercase; position: sticky; top: 0; background: var(--surface); }
td.text, th.text { text-align: left; }
td.reason { text-align: left; white-space: normal; min-width: 260px; color: var(--ink-2); }
tr.excluded td { color: var(--ink-3); }
details summary { cursor: pointer; font-weight: 600; padding: 4px 0; }
details summary:focus-visible { outline: 2px solid var(--series-1); outline-offset: 2px; }
code { font-family: ui-monospace, "SF Mono", Menlo, Consolas, monospace; font-size: 0.9em; overflow-wrap: anywhere; }
@media (max-width: 760px) { .panels { grid-template-columns: 1fr; } body { padding-top: 20px; } }
'''


def esc(value):
    return html.escape(str(value), quote=True)


def number(value, digits=3):
    if value is None:
        return ''
    if isinstance(value, int) or float(value).is_integer() and abs(value) >= 1000:
        return '{:,}'.format(int(value))
    return ('{:,.%df}' % digits).format(value)


def svg_panel(dataset, workload, metric):
    width, height = 340, 214
    parts = ['<svg viewBox="0 0 %d %d" role="img" aria-label="%s, %s" font-family="%s">' % (
        width, height, esc(workload['name']), esc(charts.METRICS[metric]['title']), esc(charts.FONT))]
    spec = charts.METRICS[metric]
    parts.append('<text x="8" y="16" font-size="12.5" font-weight="600" fill="var(--ink-1)">%s</text>' % esc(spec['title']))
    parts.append('<text x="%d" y="16" font-size="10.5" text-anchor="end" fill="var(--ink-3)">%s</text>' % (width - 8, esc(spec['unit'].split(',')[0] + ', ' + spec['direction'])))
    parts += charts.panel(dataset, workload, metric, 0, 18, width, height - 18, charts.paint('css'))
    parts.append('</svg>')
    return '\n'.join(parts)


def ratios(dataset, workload):
    table = charts.cells(dataset)
    subject = next((engine for engine in dataset['engines'] if engine['target'] in charts.SUBJECT), None)
    if subject is None:
        return ''
    mine = table.get((workload['key'], subject['target'])) or {}
    if not mine.get('ops'):
        excluded = mine.get('excluded') or []
        reasons = sorted({reason.replace('_', ' ') for item in excluded for reason in item.get('reasons') or [] if not reason.startswith('case ')})
        text = '%s has no valid repetition in this workload' % subject['label']
        if excluded:
            text += ': %d excluded (%s); their values are the hollow circles' % (len(excluded), ', '.join(reasons) or 'see the table')
        return text + '.'
    bits = []
    for engine in dataset['engines']:
        other = table.get((workload['key'], engine['target'])) or {}
        if engine is subject or not other.get('ops'):
            continue
        bits.append('%.2fx %s' % (mine['ops']['median'] / other['ops']['median'], engine['label']))
    text = '%s median throughput %s at p99 %s ms' % (subject['label'], '{:,.0f} ops/s'.format(mine['ops']['median']), number(mine['p99']['median']) if mine.get('p99') else 'n/a')
    if bits:
        text += '; relative throughput: ' + ', '.join(bits)
    text += '.'
    if mine.get('client_limited'):
        text += ' The load generator was above its CPU threshold in %d of %d valid %s repetitions, so those are lower bounds.' % (
            mine['client_limited'], mine['repetitions'], subject['label'])
    return text


def legend_html(dataset):
    colors = charts.paint('css')
    items = ['<span><i class="swatch" style="background: %s"></i>%s</span>' % (charts.color(engine['target'], dataset['engines'], colors), esc(engine['label']))
             for engine in dataset['engines']]
    items.append('<span><i class="hollow"></i>Excluded repetition, with its reason in the tooltip and the tables</span>')
    return '<div class="legend">%s</div>' % ''.join(items)


def facts(dataset):
    machine, design, run = dataset.get('machine') or {}, dataset.get('design') or {}, dataset.get('run') or {}
    cpus = machine.get('cpus') or {}
    policy = machine.get('frequency_policy') or {}
    first = next(iter(policy.values()), {}) if isinstance(policy, dict) else {}
    gates = design.get('gates') or {}
    entries = [
        ('Machine', ' '.join(value for value in (machine.get('product'), machine.get('cpu_model')) if value) or 'unavailable'),
        ('Kernel', '%s, %s' % (machine.get('kernel') or 'unavailable', machine.get('machine') or '')),
        ('Memory', '%.1f GiB' % (machine['mem_total_bytes'] / 1024 ** 3) if machine.get('mem_total_bytes') else 'unavailable'),
        ('CPU roles', 'server %s, client %s, controller %s; online %s' % (tuple(','.join(map(str, cpus.get(role, []))) or 'n/a' for role in ('server', 'client', 'control')) + (machine.get('online_cpus') or 'n/a',))),
        ('Frequency policy', '%s governor, %s driver, %s' % (first.get('scaling_governor'), first.get('scaling_driver'), first.get('energy_performance_preference')) if first else 'unavailable'),
        ('Server budget', '%s container memory and swap, maxmemory %s bytes, Dragonfly %s thread' % (machine.get('server_memory'), number(machine.get('maxmemory')), machine.get('dragonfly_threads'))),
        ('Client', '%s, %s container memory' % ((design.get('load_generator') or {}).get('label', 'memtier_benchmark'), machine.get('client_memory'))),
        ('Gates', 'package at or below %s C before each case and %s C during it, %s%% idle, %s s stable, %s s rest; client limited above %s%%, latency bound %s s' % (
            gates.get('cool_temp_c'), gates.get('max_temp_c'), gates.get('min_idle'), gates.get('stable_seconds'), gates.get('min_rest'),
            gates.get('max_client_utilization_pct'), gates.get('max_latency_seconds'))),
        ('Run', '%s, workflow %s' % (run.get('root'), run.get('workflow_status'))),
        ('Protocol sha256', run.get('protocol_sha256')),
        ('Identity sha256', run.get('identity')),
        ('Archive sha256', (run.get('archive') or {}).get('sha256') or 'not recorded'),
    ]
    for engine in dataset['engines']:
        entries.append((engine['label'], '%s; observed %s; image %s' % (engine.get('reference') or '', ', '.join(engine.get('observed_versions') or []) or 'no version observed', engine.get('image_id') or 'unavailable')))
    return '<div class="facts">%s</div>' % ''.join('<div><b>%s</b>%s</div>' % (esc(name), esc(value)) for name, value in entries)


def measurement_table(dataset):
    labels = {engine['target']: engine['label'] for engine in dataset['engines']}
    head = ('Phase', 'Workload', 'Engine', 'Rep', 'State', 'Included', 'Ops/s', 'p50 ms', 'p99 ms', 'p99.9 ms', 'Max ms', 'Memory MiB', 'Client cores', 'Client %', 'Notes')
    lines = ['<table><thead><tr>%s</tr></thead><tbody>' % ''.join('<th class="%s">%s</th>' % ('text' if index in (0, 1, 2, 4, 5, 14) else '', esc(name)) for index, name in enumerate(head))]
    for row in sorted(dataset['rows'], key=lambda item: (item['phase'] != 'calibration', item['index'], item['repetition'], item['engine'])):
        notes = '; '.join(row['reasons'] + (['client limited'] if row['client_limited'] else []))
        cells = [('text', row['phase']), ('text', row['name']), ('text', labels.get(row['engine'], row['engine'])), ('', row['repetition']),
                 ('text', row['state']), ('text', 'yes' if row['included'] else 'no'), ('', number(row['ops'], 0)), ('', number(row['p50'])),
                 ('', number(row['p99'])), ('', number(row['p999'])), ('', number(row['max_ms'])),
                 ('', number(row['mem'] / 1024 ** 2, 1) if row['mem'] else ''), ('', number(row['client_cores'], 2)),
                 ('', number(row['client_utilization_pct'], 1)), ('reason', notes)]
        lines.append('<tr class="%s">%s</tr>' % ('' if row['included'] else 'excluded', ''.join('<td class="%s">%s</td>' % (kind, esc(value)) for kind, value in cells)))
    lines.append('</tbody></table>')
    return '<div class="tablewrap">%s</div>' % ''.join(lines)


def exclusion_section(dataset):
    labels = {engine['target']: engine['label'] for engine in dataset['engines']}
    rows = dataset.get('exclusions') or []
    if not rows:
        return '<p>No measurement was excluded: every planned case of both phases is a valid measurement.</p>'
    body = ''.join('<tr><td class="text">%s</td><td class="text">%s</td><td class="text">%s</td><td>%s</td><td class="text">%s</td><td class="reason">%s</td></tr>' % (
        esc(row['phase']), esc(row['workload']), esc(labels.get(row['engine'], row['engine'])), esc(row['repetition']), esc(row['state']),
        esc('; '.join(row['reasons']).replace('_', ' ') or row['state'])) for row in rows)
    return ('<p>%d measurements are excluded from the medians. Their values stay in the table below and as hollow circles in the charts.</p>' % len(rows) +
            '<div class="tablewrap"><table><thead><tr><th class="text">Phase</th><th class="text">Workload</th><th class="text">Engine</th><th>Rep</th><th class="text">State</th><th class="text">Reason</th></tr></thead><tbody>%s</tbody></table></div>' % body)


def build(dataset):
    counts = dataset.get('counts') or {}
    run = dataset.get('run') or {}
    design = dataset.get('design') or {}
    sections = []
    for workload in dataset['workloads']:
        sections.append('<section class="workload"><h3>%s</h3><p class="note">%s</p><div class="panels">%s</div></section>' % (
            esc(workload['name']), esc(ratios(dataset, workload)), ''.join('<div class="panel">%s</div>' % svg_panel(dataset, workload, metric) for metric in charts.METRICS)))
    fill = charts.fill_figure(dataset, 'css')
    fill_section = ''
    if fill:
        fill_section = '<section><h2>Memory per key at scale</h2><p class="note">%s</p><div class="figure">%s</div></section>' % (
            esc((design.get('methodology') or {}).get('fill', '')), fill)
    methodology = ''.join('<p><b>%s.</b> %s</p>' % (esc(name.replace('_', ' ').capitalize()), esc(text)) for name, text in (design.get('methodology') or {}).items())
    calibration = (dataset.get('phases') or {}).get('calibration') or {}
    generated = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%d %H:%M UTC')
    return '''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Eski Engine Comparison</title>
<style>%s</style>
</head>
<body>
<main>
<header>
<div class="eyebrow">Benchmark test bed, run %s, workflow %s</div>
<h1>%s</h1>
<p class="lede">Bars are medians over the valid repetitions of each workload, whiskers the observed minimum and maximum; each panel has its own scale. %d of %d planned measurements are valid, %d are excluded and %d valid ones were client limited. The calibration phase ran %d cases before the benchmark and %d of them were valid; calibration values never enter the medians.</p>
%s
</header>
%s
%s
<section><h2>Excluded measurements</h2>%s</section>
<section><h2>Machine and run</h2>%s</section>
<section class="method"><h2>How the numbers were taken</h2><div style="display:grid;gap:10px">%s</div></section>
<section><details><summary>Every measurement as a table</summary>%s</details></section>
<p class="note">Generated %s from dataset schema %s.</p>
</main>
</body>
</html>
''' % (STYLE, esc(run.get('root')), esc(run.get('workflow_status')), esc(dataset.get('title') or 'Engine comparison'),
       counts.get('valid', 0), counts.get('planned', 0), counts.get('excluded', 0), counts.get('client_limited', 0),
       calibration.get('planned', 0), calibration.get('valid', 0), legend_html(dataset), '\n'.join(sections), fill_section,
       exclusion_section(dataset), facts(dataset), methodology, measurement_table(dataset), generated, esc(dataset.get('schema')))


def main(argv=None):
    parser = argparse.ArgumentParser(description='Build a self contained HTML report from a test bed dataset.')
    parser.add_argument('--dataset', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        page = build(json.loads(args.dataset.read_text()))
    except (OSError, ValueError, KeyError, TypeError) as error:
        print('page.py: error: ' + str(error), file=sys.stderr)
        return 2
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(page)
    print('%s (%d bytes)' % (args.out, len(page.encode())))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
