#!/usr/bin/env python3
"""A TCP proxy that adds a fixed one-way delay in each direction, so localhost behaves like a network.

    python3 tools/latency_proxy.py --listen 6543 --target localhost:5432 --delay-ms 0.5

Every chunk is delivered no earlier than delay-ms after it arrived, in order, so a round trip
(client -> server -> client) costs at least 2 x delay-ms extra. Good enough to show what a
round trip costs; it is not a network emulator (no jitter, no bandwidth limit, no loss).
Standard library only.
"""
import argparse
import asyncio
import time


async def pipe(reader, writer, delay):
    queue = asyncio.Queue()

    async def receive():
        while True:
            data = await reader.read(65536)
            await queue.put((time.monotonic() + delay, data))
            if not data:
                return

    async def send():
        while True:
            due, data = await queue.get()
            wait = due - time.monotonic()
            if wait > 0:
                await asyncio.sleep(wait)
            if not data:
                writer.close()
                return
            writer.write(data)
            await writer.drain()

    try:
        await asyncio.gather(receive(), send())
    except (ConnectionError, asyncio.CancelledError):
        writer.close()


async def handle(client_reader, client_writer, host, port, delay):
    try:
        server_reader, server_writer = await asyncio.open_connection(host, port)
    except OSError:
        client_writer.close()
        return
    await asyncio.gather(
        pipe(client_reader, server_writer, delay),
        pipe(server_reader, client_writer, delay),
        return_exceptions=True,
    )


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--listen", type=int, default=6543)
    ap.add_argument("--target", default="localhost:5432")
    ap.add_argument("--delay-ms", type=float, default=0.5, help="one-way delay per direction")
    a = ap.parse_args()
    host, port = a.target.rsplit(":", 1)
    delay = a.delay_ms / 1000.0
    server = await asyncio.start_server(
        lambda r, w: handle(r, w, host, int(port), delay), "127.0.0.1", a.listen
    )
    print(f"latency proxy 127.0.0.1:{a.listen} -> {a.target}, +{a.delay_ms} ms each way", flush=True)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
