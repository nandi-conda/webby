#!/usr/bin/env python3
"""A tiny HTTP/3 server for tests/net.sh (aioquic from PyPI): h3-server.py PORT CERT KEY [SECONDS].
Answers every request with 200 and 72000 bytes of text."""
import asyncio, sys
from aioquic.asyncio import serve
from aioquic.asyncio.protocol import QuicConnectionProtocol
from aioquic.h3.connection import H3_ALPN, H3Connection
from aioquic.h3.events import HeadersReceived
from aioquic.quic.configuration import QuicConfiguration
from aioquic.quic.events import ProtocolNegotiated

BODY = b"hello over http/3 " * 4000

class P(QuicConnectionProtocol):
    def __init__(self, *a, **k):
        super().__init__(*a, **k); self.h3 = None
    def quic_event_received(self, ev):
        if isinstance(ev, ProtocolNegotiated):
            self.h3 = H3Connection(self._quic)
        if self.h3:
            for e in self.h3.handle_event(ev):
                if isinstance(e, HeadersReceived):
                    self.h3.send_headers(e.stream_id, [(b":status", b"200"), (b"content-type", b"text/plain"), (b"content-length", str(len(BODY)).encode())])
                    self.h3.send_data(e.stream_id, BODY, end_stream=True)
                    self.transmit()

async def main():
    c = QuicConfiguration(alpn_protocols=H3_ALPN, is_client=False)
    c.load_cert_chain(sys.argv[2], sys.argv[3])
    await serve("127.0.0.1", int(sys.argv[1]), configuration=c, create_protocol=P)
    await asyncio.sleep(float(sys.argv[4]) if len(sys.argv) > 4 else 60)
asyncio.run(main())
