#!/usr/bin/env python3
"""Validate a private device log from two syncSeekProbe runs (resume and fresh start).

Usage: python3 native/tests/check_seek_log.py /path/to/private-device.log
This checks transport state and timeline, not physical HDMI lip synchronization.
Do not commit the input log: it may contain private device/library information.
"""
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(errors='replace')
runs = re.findall(r'AppleTV\[(\d+)\].*sync seek probe ready sample=0', text)
if not runs:
    raise SystemExit('FAIL: no resume probe started')
pid = runs[-1]
lines = '\n'.join(line for line in text.splitlines() if 'AppleTV[' + pid + ']' in line)
assert 'Terminating app due to uncaught exception' not in lines, 'Device process crashed'
seeks = re.findall(r'queued precise seek requested=([\d.]+) actual=([\d.]+) completed=(\d) resume=(\d)', lines)
assert len(seeks) >= 5, 'Missing resume or directional seek completions'
for requested, actual, completed, _ in seeks:
    assert completed == '1', 'A seek did not complete'
    assert abs(float(requested) - float(actual)) < 0.05, 'Seek missed its requested position'
for sample in (0, 1):
    checks = {int(second): (float(position), float(rate)) for second, position, rate in
              re.findall(r'sync seek checkpoint=(\d+) sample=' + str(sample) + r' position=([\d.]+) rate=([\d.-]+)', lines)}
    assert all(second in checks for second in (70, 73, 85, 100)), 'Missing transport checkpoints'
    assert checks[70][1] == 1 and checks[73][1] == 0, 'Pause did not hold'
    assert abs(checks[73][0] - checks[70][0]) < 1, 'Position advanced while paused'
    assert checks[85][1] == checks[100][1] == 1, 'Resume did not restore normal playback'
    assert 13 <= checks[100][0] - checks[85][0] <= 17, 'Timeline did not advance normally'
    assert re.search(r'sync seek probe finished sample=' + str(sample) + r' position=[\d.]+ rate=1.00', lines), 'Probe did not finish playing'
print('PASS: two device runs, precise seek completions, pause hold and resumed timeline. HDMI lip sync requires observation.')
