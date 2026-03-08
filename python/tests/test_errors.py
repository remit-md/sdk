"""Tests for error mapping: every error code maps to the correct exception class."""

import pytest

from remitmd.errors import (
    BountyNotFound,
    ChainUnavailable,
    EscrowNotFound,
    InsufficientBalance,
    InvalidAddress,
    InvalidChain,
    InvalidSignature,
    InvalidState,
    NonceReused,
    RateLimitExceeded,
    RemitError,
    ServerError,
    SignatureExpired,
    TabExpired,
    TabLimitExceeded,
    TabNotFound,
    TransactionFailed,
    Unauthorized,
    from_error_code,
)


@pytest.mark.parametrize(
    ("code", "expected_cls"),
    [
        ("INVALID_SIGNATURE", InvalidSignature),
        ("SIGNATURE_EXPIRED", SignatureExpired),
        ("NONCE_REUSED", NonceReused),
        ("UNAUTHORIZED", Unauthorized),
        ("INSUFFICIENT_BALANCE", InsufficientBalance),
        ("ESCROW_NOT_FOUND", EscrowNotFound),
        ("TAB_NOT_FOUND", TabNotFound),
        ("BOUNTY_NOT_FOUND", BountyNotFound),
        ("INVALID_STATE", InvalidState),
        ("TAB_LIMIT_EXCEEDED", TabLimitExceeded),
        ("TAB_EXPIRED", TabExpired),
        ("INVALID_ADDRESS", InvalidAddress),
        ("INVALID_CHAIN", InvalidChain),
        ("RATE_LIMIT_EXCEEDED", RateLimitExceeded),
        ("CHAIN_UNAVAILABLE", ChainUnavailable),
        ("TRANSACTION_FAILED", TransactionFailed),
        ("SERVER_ERROR", ServerError),
    ],
)
def test_error_code_maps_to_correct_class(code: str, expected_cls: type):
    exc = from_error_code(code, "test message", 400)
    assert isinstance(exc, expected_cls)
    assert isinstance(exc, RemitError)
    assert exc.code == code
    assert str(exc) == "test message"


def test_unknown_error_code_returns_base():
    exc = from_error_code("COMPLETELY_NEW_CODE", "msg", 500)
    assert type(exc) is RemitError
    assert exc.code == "COMPLETELY_NEW_CODE"


def test_all_errors_are_subclasses_of_remit_error():
    classes = [
        InvalidSignature, SignatureExpired, NonceReused, Unauthorized,
        InsufficientBalance, EscrowNotFound, TabNotFound, BountyNotFound,
        InvalidState, TabLimitExceeded, TabExpired, InvalidAddress, InvalidChain,
        RateLimitExceeded, ChainUnavailable, TransactionFailed, ServerError,
    ]
    for cls in classes:
        assert issubclass(cls, RemitError), f"{cls.__name__} is not a subclass of RemitError"
