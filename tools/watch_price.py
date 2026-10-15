#!/usr/bin/env python3
"""Wait for a fresh CardOracle result without signing or submitting anything."""
import argparse
import subprocess
import sys
import time


def wait_for_price(rpc_url, oracle, class_id, interval, timeout, *, run=subprocess.run,
                   monotonic=time.monotonic, sleep=time.sleep):
    if interval <= 0 or timeout <= 0:
        raise ValueError("interval and timeout must be positive")
    deadline = monotonic() + timeout
    while True:
        result = run(["cast", "call", oracle, "freshPrice(bytes32)((uint256,uint64,uint64))", class_id,
                      "--rpc-url", rpc_url], capture_output=True, text=True, timeout=30)
        if result.returncode == 0:
            return result.stdout.strip()
        remaining = deadline - monotonic()
        if remaining <= 0:
            raise TimeoutError("No fresh result before the deadline. Inspect Intake status; do not pay again blindly.")
        sleep(min(interval, remaining))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rpc-url", required=True)
    parser.add_argument("--oracle", required=True)
    parser.add_argument("--class-id", required=True)
    parser.add_argument("--interval", type=float, default=15)
    parser.add_argument("--timeout", type=float, default=600)
    args = parser.parse_args()
    print(wait_for_price(args.rpc_url, args.oracle, args.class_id, args.interval, args.timeout))
    print("Fresh price is available. Run SepoliaSmoke.finish with a chosen amount within 45% LTV.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError, TimeoutError) as exc:
        print(str(exc), file=sys.stderr)
        sys.exit(2)
