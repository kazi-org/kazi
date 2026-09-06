# Contracted module acceptance contract

The contracted module must never return a 500 for a well-formed request, and
every response must include an `X-Request-Id` header.
