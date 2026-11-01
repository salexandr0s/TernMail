#!/usr/bin/env python3
"""Validate measured navigation budgets; GPU presentation remains unverified."""
import json
import math
import sys


def validate(report):
    errors = []
    if report.get('error'):
        errors.append(report['error'])
    if report.get('isOptimizedBuild') is not True:
        errors.append('Optimized build was not verified.')
    if report.get('version') != 3:
        errors.append('Expected report schema version 3.')
    scope = report.get('requestedScenario')
    if scope not in {'all', 'workspace-only', 'reader-only'}:
        errors.append('Unknown requested scenario scope.')
    expected = {'reader-recent', 'reader-local'} if scope == 'reader-only' else {'workspace-warm'}
    if scope == 'all':
        expected |= {'attachments-return', 'reader-recent', 'reader-local', 'reader-network',
                     'reader-image-heavy-local', 'reader-memory-plateau', 'reader-stress-2MiB', 'reader-stress-8MiB'}
        expected |= {prefix + mode for prefix in ['workspace-', 'attachments-', 'reader-']
                     for mode in ['activeSync', 'offline', 'delayed']}
    scenarios = report.get('scenarios', [])
    missing = expected - {item['name'] for item in scenarios}
    if missing:
        errors.append('Missing scenarios: ' + ', '.join(sorted(missing)))

    def check_budget(label, values, p95, p99=None, count=100):
        if len(values) < count:
            errors.append(f'{label}: only {len(values)}/{count} visible samples')
            return
        ordered = sorted(values)
        for percentile, limit in [(0.95, p95), (0.99, p99)]:
            if limit is not None and ordered[math.ceil(len(ordered) * percentile) - 1] > limit:
                errors.append(f'{label}: p{int(percentile * 100)} exceeds {limit} ms')

    for scenario in scenarios:
        name = scenario['name']
        if scenario['failures'] or scenario['completedInteractions'] < scenario['requestedInteractions']:
            errors.append(name + ': incomplete interactions')
        records = [r for r in scenario['timings']['records'] if r['outcome'] == 'visibleCommit']
        readers = [r for r in records if r['kind'] == 'reader']
        if name.startswith('workspace-') or name.startswith('attachments-'):
            destinations = ['calendar', 'mail'] if name.startswith('workspace-') else ['attachments', 'mail']
            for destination in destinations:
                values = [r['elapsedMilliseconds'] for r in records if r['kind'] == 'workspace' and r.get('destination') == destination]
                check_budget(name + '.' + destination, values, 100, 200)
        if name.startswith('reader-') and not name.startswith('reader-stress-'):
            if name == 'reader-network':
                values = [r['readyToVisibleMilliseconds'] for r in readers if r.get('readyToVisibleMilliseconds') is not None]
                check_budget(name + '.response-to-visible', values, 200)
                if any(r.get('cacheTier') != 'network' or r.get('processingOrigin') != 'syntheticTransportResponse' for r in readers):
                    errors.append(name + ': expected verified network misses with synthetic response timing')
            else:
                if name in {'reader-local', 'reader-image-heavy-local', 'reader-memory-plateau'} and any(r.get('cacheTier') == 'network' for r in readers):
                    errors.append(name + ': a required local body came from the network')
                recent = name in {'reader-recent', 'reader-offline', 'reader-activeSync', 'reader-delayed'}
                check_budget(name, [r['elapsedMilliseconds'] for r in readers], 100 if recent else 200, 200 if recent else None)
                if name == 'reader-local':
                    # Prepared-document hits are useful, but cannot establish
                    # the separate local-body preparation budget.
                    preparation_misses = [r['elapsedMilliseconds'] for r in readers if r.get('cacheTier') == 'local']
                    check_budget(name + '.preparation-miss', preparation_misses, 200)
            check_budget(name + '.header', [r['elapsedMilliseconds'] for r in records if r['kind'] == 'readerHeader'], 100)
            if name in {'reader-recent', 'reader-offline', 'reader-activeSync', 'reader-delayed'}:
                check_budget(name + '.selection-feedback', [r['elapsedMilliseconds'] for r in records if r['kind'] == 'selectionFeedback'], 50)
        start, end = scenario.get('transportAtStart'), scenario.get('transportAtEnd')
        if start and end:
            mode = end['mode']
            requests = {k: v - start['requestCounts'].get(k, 0) for k, v in end['requestCounts'].items()}
            if mode == 'offline' and end['offlineFailures'] <= start['offlineFailures']:
                errors.append(name + ': offline transport was not exercised')
            if mode == 'activeSync' and not requests.get('history', 0):
                errors.append(name + ': sync history was not exercised')
            if mode == 'delayed' and not requests.get('body', 0):
                errors.append(name + ': delayed body transport was not exercised')
        if name == 'reader-memory-plateau':
            samples = scenario['memorySamples']
            content = [s.get('storedContent') for s in samples]
            if len(samples) < 51 or any(c is None for c in content):
                errors.append(name + ': missing memory progression or stored-corpus byte counts')
            elif len({(c['bodyBytes'], c['resourceBytes']) for c in content}) != 1:
                errors.append(name + ': stored corpus grew, so this cannot establish a reader-memory plateau')
            if any(s['preparedDocumentBytes'] > 56 * 1024 * 1024 for s in samples):
                errors.append(name + ': prepared-document budget exceeded')
    scrolls = report.get('scrolling', [])
    expected_scrolls = {'mailbox', 'reader-20', 'reader-100', 'calendar', 'attachments'} if scope == 'all' else set()
    if expected_scrolls - {s['name'] for s in scrolls}:
        errors.append('Required scrolling scenarios are missing.')
    for scroll in scrolls:
        if scroll.get('durationSeconds', 0) < 30 or scroll.get('timedOut') or scroll.get('failureReason'):
            errors.append(scroll['name'] + ': incomplete sustained scrolling')
        if scroll.get('mainRunLoopStallsOver100ms', 0) or scroll.get('delayedCallbackFraction', 1) >= .01:
            errors.append(scroll['name'] + ': display-link callback proxy exceeds budget')
    return errors


if __name__ == '__main__':
    with open(sys.argv[1]) as stream:
        report = json.load(stream)
        errors = validate(report)
    for error in errors:
        print(error, file=sys.stderr)
    print('Measured scope: ' + str(report.get('requestedScenario')))
    for scenario in report.get('scenarios', []):
        if scenario.get('name', '').startswith('reader-'):
            tiers = {}
            for record in scenario.get('timings', {}).get('records', []):
                if record.get('kind') == 'reader' and record.get('outcome') == 'visibleCommit':
                    tier = record.get('cacheTier', 'unknown')
                    tiers[tier] = tiers.get(tier, 0) + 1
            print(scenario['name'] + ' visible cache tiers: ' + json.dumps(tiers, sort_keys=True))
    print('GPU frame presentation, normal-mailbox performance and memory-plateau slope still require separate evidence.')
    sys.exit(bool(errors))
