#!/usr/bin/env python3
"""Read CardOracle's exact body and run the public, unpaid oracle preflight.

Python standard library + Foundry cast only. Never reads wallet configuration or sends a transaction.
The endpoint accepts a draft subset; definitions and guards remain in the saved exact on-chain body.
"""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
import urllib.error
import urllib.request

DRAFT_KEYS = ("question", "chainId", "answerType", "evidence", "panelSize", "toleranceBps", "consumer")


def cast(*args):
    return subprocess.check_output(["cast", *args], text=True).strip()


def draft(body):
    return {"action": "oracle.request", "input": {k: body[k] for k in DRAFT_KEYS if k in body}}


def post_check(body, base_url="https://api.imd.fun"):
    request = urllib.request.Request(
        base_url.rstrip("/") + "/requests/check",
        data=json.dumps(draft(body)).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=45) as response:
        return json.load(response)


def read_body(rpc_url, oracle, class_id):
    if not re.fullmatch(r"0x[0-9a-fA-F]{40}", oracle) or int(oracle, 16) == 0:
        raise ValueError("Supply the confirmed, nonzero CardOracle address")
    if not re.fullmatch(r"0x[0-9a-fA-F]{64}", class_id) or int(class_id, 16) == 0:
        raise ValueError("Supply the configured classId")
    if int(cast("chain-id", "--rpc-url", rpc_url)) != 11155111:
        raise ValueError("The consumer must be on Sepolia")
    if cast("code", oracle, "--rpc-url", rpc_url) == "0x":
        raise ValueError("CardOracle has not been deployed at that address")
    encoded = cast("call", oracle, "requestBody(bytes32)(bytes)", class_id, "--rpc-url", rpc_url)
    body = json.loads(bytes.fromhex(encoded.removeprefix("0x")).decode("utf-8"))
    if body["consumer"]["chainId"] != 11155111 or body["consumer"]["verifyingContract"].lower() != oracle.lower():
        raise ValueError("Unexpected consumer domain")
    return body


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rpc-url", required=True)
    parser.add_argument("--oracle", required=True)
    parser.add_argument("--class-id", required=True)
    parser.add_argument("--output-dir", type=Path, default=Path("preflight"))
    args = parser.parse_args()
    body = read_body(args.rpc_url, args.oracle, args.class_id)
    result = post_check(body)
    args.output_dir.mkdir(parents=True, exist_ok=True)
    (args.output_dir / "body.json").write_text(json.dumps(body, indent=2) + "\n")
    (args.output_dir / "check-input.json").write_text(json.dumps(draft(body), indent=2) + "\n")
    (args.output_dir / "check-result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))
    print("The endpoint checks the draft subset. Review saved definitions, source guards, and all suggestions before paying.")
    if "blockers" not in result or result["blockers"]:
        return 2
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError, urllib.error.URLError) as exc:
        print(f"Preflight failed: {exc}", file=sys.stderr)
        sys.exit(2)
