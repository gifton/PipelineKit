#!/usr/bin/env python3
"""Run every discovered correctness target and reject successful empty execution."""
import argparse
import subprocess
import sys

from coverage import TARGETS
from test_execution import run_tests


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--configuration', choices=['debug', 'release'], required=True)
    args = parser.parse_args()
    common = ['--configuration', args.configuration, '--skip-build']
    discovery = subprocess.run(['swift', 'test', 'list', *common], capture_output=True, text=True)
    if discovery.returncode:
        sys.stderr.write(discovery.stdout + discovery.stderr)
        return discovery.returncode
    lines = discovery.stdout.splitlines()
    missing = [target for target in TARGETS
               if not any(line.startswith((target + '.', target + '/')) for line in lines)]
    if missing:
        parser.error('correctness suites have no discovered tests: ' + ', '.join(missing))
    for target in TARGETS:
        print(f'Qualifying {target} ({args.configuration})', flush=True)
        try:
            run_tests(['swift', 'test', *common, '--filter', '^' + target + '[./]'])
        except subprocess.CalledProcessError as error:
            return error.returncode
        except ValueError as error:
            parser.error(f'{target}: {error}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
