"""LangChain integration — RemitToolkit providing payment tools as BaseTool instances.

Usage:
    from langchain_openai import ChatOpenAI
    from langchain.agents import AgentExecutor, create_tool_calling_agent
    from remitmd.integrations.langchain import RemitToolkit
    from remitmd import Wallet

    wallet = Wallet.from_env()
    tools = RemitToolkit(wallet).get_tools()
    agent = create_tool_calling_agent(ChatOpenAI(), tools, prompt)
    executor = AgentExecutor(agent=agent, tools=tools)

Requires: pip install remitmd[langchain]
"""

from __future__ import annotations

import asyncio
from typing import TYPE_CHECKING, Any

try:
    from langchain_core.tools import BaseTool, BaseToolkit
    from pydantic import BaseModel, Field
except ImportError as exc:  # pragma: no cover
    raise ImportError(
        "LangChain integration requires langchain-core. "
        "Install with: pip install remitmd[langchain]"
    ) from exc

if TYPE_CHECKING:
    pass


def _run_async(coro: Any) -> Any:
    """Run an async coroutine from a sync context.

    Uses ``asyncio.run()`` when no event loop is running. Falls back to
    ``loop.run_until_complete()`` when called from within an existing
    async context (e.g. Jupyter notebooks, async frameworks).
    """
    try:
        loop = asyncio.get_running_loop()
    except RuntimeError:
        loop = None

    if loop is None:
        return asyncio.run(coro)

    # Already inside a running loop — cannot use asyncio.run().
    import concurrent.futures

    with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
        return pool.submit(asyncio.run, coro).result()


class RemitToolkit(BaseToolkit):
    """LangChain toolkit providing remit.md payment tools."""

    wallet: Any  # Wallet — can't annotate directly to avoid circular import

    class Config:
        arbitrary_types_allowed = True

    def get_tools(self) -> list[BaseTool]:
        return [
            RemitPayDirectTool(wallet=self.wallet),
            RemitCreateEscrowTool(wallet=self.wallet),
            RemitReleaseEscrowTool(wallet=self.wallet),
            RemitOpenTabTool(wallet=self.wallet),
            RemitCloseTabTool(wallet=self.wallet),
            RemitOpenStreamTool(wallet=self.wallet),
            RemitCheckBalanceTool(wallet=self.wallet),
            RemitGetReputationTool(wallet=self.wallet),
        ]


# ─── Tool schemas ─────────────────────────────────────────────────────────────


class _PayDirectInput(BaseModel):
    to: str = Field(description="Recipient wallet address (0x...)")
    amount: float = Field(description="Amount in USD (e.g. 5.00)")
    memo: str = Field(default="", description="Optional payment memo")


class _CreateEscrowInput(BaseModel):
    to: str = Field(description="Payee wallet address")
    amount: float = Field(description="Escrow amount in USD")
    task: str = Field(description="Task description")
    timeout: int = Field(default=86400, description="Timeout in seconds")


class _InvoiceIdInput(BaseModel):
    invoice_id: str = Field(description="Invoice or escrow ID")


class _OpenTabInput(BaseModel):
    to: str = Field(description="Payee wallet address")
    limit: float = Field(description="Maximum spend limit in USD")
    per_unit: float = Field(description="Price per unit in USD")
    expires: int = Field(default=86400, description="Expiry in seconds")


class _TabIdInput(BaseModel):
    tab_id: str = Field(description="Tab ID to close")


class _OpenStreamInput(BaseModel):
    to: str = Field(description="Payee wallet address")
    rate: float = Field(description="Rate per second in USD")
    max_duration: int = Field(default=3600, description="Maximum duration in seconds")


# ─── Tool implementations ─────────────────────────────────────────────────────


class RemitPayDirectTool(BaseTool):
    name: str = "remit_pay_direct"
    description: str = "Send a direct USDC payment to another agent or address."
    args_schema: type[BaseModel] = _PayDirectInput
    wallet: Any

    class Config:
        arbitrary_types_allowed = True

    def _run(self, to: str, amount: float, memo: str = "") -> str:
        result = _run_async(self.wallet.pay_direct(to, amount, memo))
        return f"Payment sent. tx_hash={result.tx_hash}"

    async def _arun(self, to: str, amount: float, memo: str = "") -> str:
        result = await self.wallet.pay_direct(to, amount, memo)
        return f"Payment sent. tx_hash={result.tx_hash}"


class RemitCreateEscrowTool(BaseTool):
    name: str = "remit_create_escrow"
    description: str = (
        "Fund an escrow for a task. Funds are locked until you call remit_release_escrow."
    )
    args_schema: type[BaseModel] = _CreateEscrowInput
    wallet: Any

    class Config:
        arbitrary_types_allowed = True

    def _run(self, to: str, amount: float, task: str, timeout: int = 86400) -> str:
        from remitmd.models.invoice import Invoice

        invoice = Invoice(to=to, amount=amount, memo=task, timeout=timeout)
        result = _run_async(self.wallet.pay(invoice))
        return f"Escrow created. invoice_id={result.invoice_id}"

    async def _arun(self, to: str, amount: float, task: str, timeout: int = 86400) -> str:
        from remitmd.models.invoice import Invoice

        invoice = Invoice(to=to, amount=amount, memo=task, timeout=timeout)
        result = await self.wallet.pay(invoice)
        return f"Escrow created. invoice_id={result.invoice_id}"


class RemitReleaseEscrowTool(BaseTool):
    name: str = "remit_release_escrow"
    description: str = "Release escrowed funds to the payee after task completion."
    args_schema: type[BaseModel] = _InvoiceIdInput
    wallet: Any

    class Config:
        arbitrary_types_allowed = True

    def _run(self, invoice_id: str) -> str:
        _run_async(self.wallet.release_escrow(invoice_id))
        return f"Escrow {invoice_id} released."

    async def _arun(self, invoice_id: str) -> str:
        await self.wallet.release_escrow(invoice_id)
        return f"Escrow {invoice_id} released."


class RemitOpenTabTool(BaseTool):
    name: str = "remit_open_tab"
    description: str = "Open a metered payment tab for a service (pay-per-use)."
    args_schema: type[BaseModel] = _OpenTabInput
    wallet: Any

    class Config:
        arbitrary_types_allowed = True

    def _run(self, to: str, limit: float, per_unit: float, expires: int = 86400) -> str:
        tab = _run_async(self.wallet.open_tab(to, limit, per_unit, expires))
        return f"Tab opened. tab_id={tab.id}, limit={tab.limit_amount}"

    async def _arun(self, to: str, limit: float, per_unit: float, expires: int = 86400) -> str:
        tab = await self.wallet.open_tab(to, limit, per_unit, expires)
        return f"Tab opened. tab_id={tab.id}, limit={tab.limit_amount}"


class RemitCloseTabTool(BaseTool):
    name: str = "remit_close_tab"
    description: str = "Close a metered payment tab and settle the balance."
    args_schema: type[BaseModel] = _TabIdInput
    wallet: Any

    class Config:
        arbitrary_types_allowed = True

    def _run(self, tab_id: str) -> str:
        _run_async(self.wallet.close_tab(tab_id))
        return f"Tab {tab_id} closed."

    async def _arun(self, tab_id: str) -> str:
        await self.wallet.close_tab(tab_id)
        return f"Tab {tab_id} closed."


class RemitOpenStreamTool(BaseTool):
    name: str = "remit_open_stream"
    description: str = "Start a streaming payment (continuous per-second USDC flow)."
    args_schema: type[BaseModel] = _OpenStreamInput
    wallet: Any

    class Config:
        arbitrary_types_allowed = True

    def _run(self, to: str, rate: float, max_duration: int = 3600) -> str:
        max_total = rate * max_duration
        result = _run_async(self.wallet.open_stream(to, rate, max_total))
        return f"Stream opened. stream_id={result.id}, rate={result.rate_per_second}/s"

    async def _arun(self, to: str, rate: float, max_duration: int = 3600) -> str:
        max_total = rate * max_duration
        stream = await self.wallet.open_stream(to, rate, max_total)
        return f"Stream opened. stream_id={stream.id}, rate={stream.rate_per_second}/s"


class RemitCheckBalanceTool(BaseTool):
    name: str = "remit_check_balance"
    description: str = "Check your current USDC balance and wallet status."
    wallet: Any

    class Config:
        arbitrary_types_allowed = True

    def _run(self) -> str:
        ws = _run_async(self.wallet.status())
        return f"Balance: ${ws.balance} USDC (tier={ws.tier}, fee={ws.fee_rate_bps}bps)"

    async def _arun(self) -> str:
        ws = await self.wallet.status()
        return f"Balance: ${ws.balance} USDC (tier={ws.tier}, fee={ws.fee_rate_bps}bps)"


class RemitGetReputationTool(BaseTool):
    name: str = "remit_get_reputation"
    description: str = "Get the reputation score for a wallet address."
    wallet: Any

    class Config:
        arbitrary_types_allowed = True

    def _run(self, wallet: str) -> str:
        rep = _run_async(self.wallet.get_reputation(wallet))
        return f"Reputation for {wallet[:10]}...: score={rep.score:.2f}"

    async def _arun(self, wallet: str) -> str:
        rep = await self.wallet.get_reputation(wallet)
        return f"Reputation for {wallet[:10]}...: score={rep.score:.2f}"
