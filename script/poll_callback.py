#!/usr/bin/env python3
"""Poll a chain for the Reactive loop evidence.

Usage:
  poll_callback.py callback-request <lasna_rpc> <system_addr> <reactive_addr> <timeout_s>
      Prints REACTIVE_TX=<hash> for the first CallbackRequest log whose
      indexed sender is the reactive contract.
  poll_callback.py position-exited <base_rpc> <vault_addr> <timeout_s>
      Prints DEST_TX=<hash> for the first PositionExited log from the vault.

Only the standard library is used. Event topic hashes are computed with a
small pure-Python keccak-256 (Ethereum variant) implementation.
"""

import json
import sys
import time
import urllib.request

# --- minimal keccak-256 (Ethereum padding) ---------------------------------
_RC = [
    0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000,
    0x000000000000808B, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
    0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
    0x000000008000808B, 0x800000000000008B, 0x8000000000008089, 0x8000000000008003,
    0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
    0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
]
_R = [
    [0, 36, 3, 41, 18],
    [1, 44, 10, 45, 2],
    [62, 6, 43, 15, 61],
    [28, 55, 25, 21, 56],
    [27, 20, 39, 8, 14],
]
_MASK = (1 << 64) - 1


def _rot(x, n):
    return ((x << n) | (x >> (64 - n))) & _MASK if n else x


def _keccak_f(state):
    for rc in _RC:
        c = [state[x] ^ state[x + 5] ^ state[x + 10] ^ state[x + 15] ^ state[x + 20] for x in range(5)]
        d = [c[(x - 1) % 5] ^ _rot(c[(x + 1) % 5], 1) for x in range(5)]
        for x in range(5):
            for y in range(5):
                state[x + 5 * y] ^= d[x]
        b = [0] * 25
        for x in range(5):
            for y in range(5):
                b[y + 5 * ((2 * x + 3 * y) % 5)] = _rot(state[x + 5 * y], _R[x][y])
        for x in range(5):
            for y in range(5):
                state[x + 5 * y] = b[x + 5 * y] ^ ((~b[(x + 1) % 5 + 5 * y]) & b[(x + 2) % 5 + 5 * y])
        state[0] ^= rc


def keccak256(data: bytes) -> bytes:
    rate = 136
    padded = bytearray(data)
    padded.append(0x01)
    while len(padded) % rate != rate - 1:
        padded.append(0x00)
    padded.append(0x80)
    state = [0] * 25
    for off in range(0, len(padded), rate):
        block = padded[off:off + rate]
        for i in range(rate // 8):
            state[i] ^= int.from_bytes(block[i * 8:(i + 1) * 8], "little")
        _keccak_f(state)
    return b"".join(state[i].to_bytes(8, "little") for i in range(4))


# --- JSON-RPC ---------------------------------------------------------------

def rpc(url, method, params):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    req = urllib.request.Request(url, data=body, headers={"content-type": "application/json"})
    with urllib.request.urlopen(req, timeout=20) as resp:
        out = json.load(resp)
    if "error" in out:
        raise RuntimeError(f"{method}: {out['error']}")
    return out["result"]


def topic_address(addr):
    return "0x" + "0" * 24 + addr.lower().removeprefix("0x")


def poll_logs(url, address, topics, timeout_s, label):
    deadline = time.time() + timeout_s
    start_block = int(rpc(url, "eth_blockNumber", []), 16)
    while time.time() < deadline:
        latest = int(rpc(url, "eth_blockNumber", []), 16)
        logs = rpc(url, "eth_getLogs", [{
            "fromBlock": hex(start_block),
            "toBlock": hex(latest),
            "address": address,
            "topics": topics,
        }])
        if logs:
            return logs[0]
        time.sleep(5)
    raise SystemExit(f"TIMEOUT waiting for {label} after {timeout_s}s")


def main():
    mode = sys.argv[1]
    if mode == "callback-request":
        _, _, url, system_addr, reactive_addr, timeout = sys.argv
        sig = "0x" + keccak256(b"CallbackRequest(uint256,address,address,uint8,bytes)").hex()
        log = poll_logs(
            url, system_addr, [sig, None, topic_address(reactive_addr)],
            int(timeout), "CallbackRequest",
        )
        print(f"REACTIVE_TX={log['transactionHash']}")
    elif mode == "position-exited":
        _, _, url, vault_addr, timeout = sys.argv
        sig = "0x" + keccak256(b"PositionExited(address,uint8,uint256,uint256,uint256)").hex()
        log = poll_logs(url, vault_addr, [sig], int(timeout), "PositionExited")
        print(f"DEST_TX={log['transactionHash']}")
    else:
        raise SystemExit(f"unknown mode {mode}")


if __name__ == "__main__":
    main()
