"""Compatibility wrapper for legacy imports.

The active WebUI/HTTP/UDP implementation lives in protocol_server.py.  Keep
this module tiny so old code that imports ``webui`` or treats it as a package
continues to resolve without carrying a second server implementation.
"""

from protocol_server import ProtocolServer

__path__ = ['webui']
__all__ = ['ProtocolServer']
