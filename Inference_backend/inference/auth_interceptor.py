"""Shared-secret gRPC auth for the internal Go<->Python inference link.

The Go backend (Backend/internal/stream/ai_client.go) is the only intended
caller of this service. Without this interceptor, any network client that
can reach the listen address gets full unauthenticated access to
UploadModel (replace the live model), SetTuning (degrade recognition for
everyone / flip debug_mode), and StreamLogs (a live tap on other users'
recognized signs while debug_mode is on).

Enforced only when SIGNMIND_AI_SHARED_SECRET is set (see server.main()) so
an unconfigured local dev loop-back setup still works without extra steps;
main() logs a loud warning when the secret is unset.
"""

import hmac
import logging

import grpc

logger = logging.getLogger("inference.auth")

METADATA_KEY = "x-signmind-shared-secret"

_HANDLER_FACTORY_BY_SHAPE = {
    (False, False): grpc.unary_unary_rpc_method_handler,
    (False, True): grpc.unary_stream_rpc_method_handler,
    (True, False): grpc.stream_unary_rpc_method_handler,
    (True, True): grpc.stream_stream_rpc_method_handler,
}


class SharedSecretInterceptor(grpc.ServerInterceptor):
    """Rejects any RPC whose metadata doesn't carry the matching secret."""

    def __init__(self, secret: str):
        if not secret:
            raise ValueError("secret must be non-empty")
        self._secret = secret

    def intercept_service(self, continuation, handler_call_details):
        metadata = dict(handler_call_details.invocation_metadata or ())
        supplied = metadata.get(METADATA_KEY, "")
        if hmac.compare_digest(supplied, self._secret):
            return continuation(handler_call_details)

        handler = continuation(handler_call_details)
        if handler is None:
            return None
        logger.warning(
            "Rejected unauthenticated RPC %s (missing/invalid %s)",
            handler_call_details.method,
            METADATA_KEY,
        )

        def deny(request_or_iterator, context):
            context.abort(
                grpc.StatusCode.UNAUTHENTICATED,
                "missing or invalid shared secret",
            )

        factory = _HANDLER_FACTORY_BY_SHAPE[
            (handler.request_streaming, handler.response_streaming)
        ]
        return factory(
            deny,
            request_deserializer=handler.request_deserializer,
            response_serializer=handler.response_serializer,
        )
