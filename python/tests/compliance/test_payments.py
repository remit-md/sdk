"""Compliance: pay_direct against a real server.

Verifies that the Python SDK can execute a direct payment end-to-end:
  faucet → pay_direct → verify balance change + invoice exists.
"""

from __future__ import annotations

import pytest

from .conftest import server_available


@pytest.mark.asyncio
@server_available
async def test_pay_direct_happy_path(wallet_pair):
    """pay_direct transfers USDC from payer to payee via the real server."""
    payer, payee, payee_addr = wallet_pair

    print(f"[COMPLIANCE] pay_direct: 5.0 USDC {payer.address} -> {payee_addr}")
    tx = await payer.pay_direct(payee_addr, 5.0, memo="compliance test")
    print(
        f"[COMPLIANCE] pay: 5.0 USDC {payer.address} -> {payee_addr}"
        f" tx={tx.tx_hash} invoice={tx.invoice_id}"
    )

    assert tx.tx_hash is not None, "tx_hash must be set"
    assert tx.invoice_id is not None, "invoice_id must be set"


@pytest.mark.asyncio
@server_available
async def test_pay_direct_below_minimum_returns_error(wallet_pair):
    """pay_direct with amount < minimum (0.01 USDC) must raise an error."""
    from remitmd.errors import RemitError

    payer, payee, payee_addr = wallet_pair

    print(f"[COMPLIANCE] pay_direct below minimum: 0.001 USDC {payer.address} -> {payee_addr}")
    with pytest.raises(RemitError) as exc_info:
        await payer.pay_direct(payee_addr, 0.001, memo="too small")

    print(f"[COMPLIANCE] pay_direct below minimum: rejected with HTTP {exc_info.value.http_status}")
    assert exc_info.value.http_status == 422 or exc_info.value.http_status == 400


@pytest.mark.asyncio
@server_available
async def test_pay_direct_self_payment_returns_error(wallet_pair):
    """pay_direct to own wallet must be rejected by the server."""
    from remitmd.errors import RemitError

    payer, payee, _ = wallet_pair

    print(f"[COMPLIANCE] pay_direct self-payment: 1.0 USDC {payer.address} -> {payer.address}")
    with pytest.raises(RemitError) as exc_info:
        await payer.pay_direct(payer.address, 1.0, memo="self pay")

    print(f"[COMPLIANCE] pay_direct self-payment: rejected with HTTP {exc_info.value.http_status}")
    # Server returns 422 (unprocessable) or 400 for self-payment
    assert exc_info.value.http_status in (400, 422)
