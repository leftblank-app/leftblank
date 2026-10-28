#!/usr/bin/env python3
"""Staple and validate an accepted app, retrying ticket-service network errors."""
import argparse
from pathlib import Path
import re
import subprocess
import time


RETRY_DELAYS = (15, 30, 60, 120)
NETWORK_ERROR = re.compile(r'NSURLErrorDomain Code=-(1001|1003|1004|1005|1006|1009)\b')


def staple(app, diagnostics):
    diagnostics.mkdir(parents=True, exist_ok=True)
    for action in ('staple', 'validate'):
        for attempt in range(1, len(RETRY_DELAYS) + 2):
            result = subprocess.run(['xcrun', 'stapler', action, str(app)],
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                    text=True, errors='replace')
            (diagnostics / f'stapler-{action}-{attempt}.log').write_text(result.stdout)
            print(result.stdout, end='', flush=True)
            if result.returncode == 0:
                break
            # EX_NOHOST also covers unnotarized apps. Retry only when Apple's
            # output explicitly identifies a transient URL-loading error.
            if (result.returncode != 68 or not NETWORK_ERROR.search(result.stdout)
                    or attempt > len(RETRY_DELAYS)):
                return result.returncode
            delay = RETRY_DELAYS[attempt - 1]
            print(f'Apple ticket service network error during {action}; '
                  f'retrying in {delay}s ({attempt}/5).', flush=True)
            time.sleep(delay)
    return 0


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('--diagnostics', type=Path, default=Path('build/notarization'))
    args = parser.parse_args()
    raise SystemExit(staple(args.app, args.diagnostics))
