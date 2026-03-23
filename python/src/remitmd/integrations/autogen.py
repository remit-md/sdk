"""AutoGen integration — remit.md tools as registerable async functions.

Usage:
    import autogen
    from remitmd.integrations.autogen import register_remit_tools
    from remitmd import Wallet

    wallet = Wallet.from_env()
    assistant = autogen.AssistantAgent("assistant", llm_config=llm_config)
    user = autogen.UserProxyAgent("user", human_input_mode="NEVER")
    register_remit_tools(wallet, assistant, user)

Requires: pip install remitmd[autogen]
"""

from __future__ import annotations

from typing import TYPE_CHECKING

try:
    from autogen import AssistantAgent, UserProxyAgent  # type: ignore[import]
except ImportError as exc:  # pragma: no cover
    raise ImportError(
        "AutoGen integration requires pyautogen. Install with: pip install remitmd[autogen]"
    ) from exc

if TYPE_CHECKING:
    from remitmd.wallet import Wallet


def register_remit_tools(
    wallet: Wallet,
    assistant: AssistantAgent,
    executor: UserProxyAgent,
) -> None:
    """Register all remit.md payment tools with an AutoGen agent pair."""

    @executor.register_for_execution()  # type: ignore[misc]
    @assistant.register_for_llm(description="Send a direct USDC payment.")  # type: ignore[misc]
    async def remit_pay_direct(to: str, amount: float, memo: str = "") -> str:
        result = await wallet.pay_direct(to, amount, memo)
        return f"Payment sent. tx_hash={result.tx_hash}"

    @executor.register_for_execution()  # type: ignore[misc]
    @assistant.register_for_llm(description="Check current USDC balance.")  # type: ignore[misc]
    async def remit_check_balance() -> str:
        info = await wallet.status()
        return f"Balance: ${info.balance:.2f} USDC"

    @executor.register_for_execution()  # type: ignore[misc]
    @assistant.register_for_llm(description="Open a metered payment tab.")  # type: ignore[misc]
    async def remit_open_tab(to: str, limit: float, per_unit: float) -> str:
        tab = await wallet.open_tab(to, limit, per_unit)
        return f"Tab opened: {tab.id}"

    @executor.register_for_execution()  # type: ignore[misc]
    @assistant.register_for_llm(description="Close a metered payment tab.")  # type: ignore[misc]
    async def remit_close_tab(tab_id: str) -> str:
        await wallet.close_tab(tab_id)
        return f"Tab {tab_id} closed."

    @executor.register_for_execution()  # type: ignore[misc]
    @assistant.register_for_llm(description="Create an escrow for a task.")  # type: ignore[misc]
    async def remit_create_escrow(to: str, amount: float, task: str) -> str:
        from remitmd.models.invoice import Invoice

        invoice = Invoice(to=to, amount=amount, memo=task)
        result = await wallet.pay(invoice)
        return f"Escrow created: {result.invoice_id}"

    @executor.register_for_execution()  # type: ignore[misc]
    @assistant.register_for_llm(description="Release escrow funds to payee.")  # type: ignore[misc]
    async def remit_release_escrow(invoice_id: str) -> str:
        await wallet.release_escrow(invoice_id)
        return f"Escrow {invoice_id} released."
