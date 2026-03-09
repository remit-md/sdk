"""OpenAI Agents SDK integration — remit.md tools for use with function_tool().

Usage:
    from agents import Agent, Runner
    from remitmd.integrations.openai_agents import remit_tools
    from remitmd import Wallet

    wallet = Wallet.from_env()
    agent = Agent(
        name="Payment Agent",
        tools=remit_tools(wallet),
    )

Requires: pip install remitmd[openai-agents]
"""

from __future__ import annotations

from typing import TYPE_CHECKING, Any

try:
    from agents import function_tool  # type: ignore[import]
except ImportError as exc:  # pragma: no cover
    raise ImportError(
        "OpenAI Agents integration requires openai-agents. "
        "Install with: pip install remitmd[openai-agents]"
    ) from exc

if TYPE_CHECKING:
    from remitmd.wallet import Wallet


def remit_tools(wallet: Wallet) -> list[Any]:
    """Return all remit.md tools as openai-agents function_tool objects."""

    @function_tool
    async def remit_pay_direct(to: str, amount: float, memo: str = "") -> str:
        """Send a direct USDC payment to a wallet address."""
        result = await wallet.pay_direct(to, amount, memo)
        return f"Payment of ${amount:.2f} sent to {to}. tx_hash={result.tx_hash}"

    @function_tool
    async def remit_check_balance() -> str:
        """Check the current USDC wallet balance."""
        bal = await wallet.balance()
        return f"Current USDC balance: ${bal:.2f}"

    @function_tool
    async def remit_open_tab(to: str, limit: float, per_unit: float) -> str:
        """Open a metered payment tab for pay-per-use billing."""
        tab = await wallet.open_tab(to, limit, per_unit)
        return f"Tab {tab.id} opened. Limit: ${limit:.2f}"

    @function_tool
    async def remit_close_tab(tab_id: str) -> str:
        """Close a metered payment tab and settle the balance."""
        await wallet.close_tab(tab_id)
        return f"Tab {tab_id} closed."

    @function_tool
    async def remit_create_escrow(to: str, amount: float, task: str) -> str:
        """Lock funds in escrow for a task. Funds released only after completion."""
        from remitmd.models.invoice import Invoice

        invoice = Invoice(to=to, amount=amount, memo=task)
        result = await wallet.pay(invoice)
        return f"Escrow created. invoice_id={result.invoice_id}"

    @function_tool
    async def remit_release_escrow(invoice_id: str) -> str:
        """Release escrow funds to the payee after task completion."""
        await wallet.release_escrow(invoice_id)
        return f"Escrow {invoice_id} released."

    @function_tool
    async def remit_open_stream(to: str, rate_per_second: float, max_duration: int = 3600) -> str:
        """Start a continuous streaming payment at rate USD/second."""
        stream = await wallet.open_stream(to, rate_per_second, max_duration)
        return f"Stream {stream.id} started at ${rate_per_second:.6f}/s"

    @function_tool
    async def remit_get_reputation(wallet_address: str) -> str:
        """Get reputation score for a wallet address."""
        rep = await wallet.get_reputation(wallet_address)
        return f"Score: {rep.score:.2f}, dispute_rate: {rep.dispute_rate:.1%}"

    return [
        remit_pay_direct,
        remit_check_balance,
        remit_open_tab,
        remit_close_tab,
        remit_create_escrow,
        remit_release_escrow,
        remit_open_stream,
        remit_get_reputation,
    ]
