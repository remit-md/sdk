"""RemitClient — read-only API client (no private key required)."""

from __future__ import annotations

from remitmd._http import AuthenticatedClient, get_chain_config
from remitmd.models.bounty import Bounty
from remitmd.models.common import Event, Reputation, WalletStatus, Webhook
from remitmd.models.deposit import Deposit
from remitmd.models.escrow import Escrow
from remitmd.models.invoice import Invoice
from remitmd.models.stream import Stream
from remitmd.models.tab import Tab


class RemitClient:
    """
    Read-only remit.md client.

    Does not require a private key. Suitable for querying state on behalf of
    a user-provided address or for monitoring purposes.

    Usage:
        client = RemitClient(chain="base")
        invoice = await client.get_invoice("inv_abc123")
    """

    def __init__(
        self,
        chain: str = "base",
        testnet: bool = False,
        api_url: str | None = None,
    ) -> None:
        chain_id, url = get_chain_config(chain, testnet, api_url)
        self.chain = chain
        self.testnet = testnet
        self._http = AuthenticatedClient(url, signer=None, chain_id=chain_id)

    # ─── Invoices ─────────────────────────────────────────────────────────────

    async def get_invoice(self, invoice_id: str) -> Invoice:
        data = await self._http.get(f"/api/v0/invoices/{invoice_id}")
        return Invoice.model_validate(data)

    # ─── Escrows ──────────────────────────────────────────────────────────────

    async def get_escrow(self, invoice_id: str) -> Escrow:
        data = await self._http.get(f"/api/v0/escrows/{invoice_id}")
        return Escrow.model_validate(data)

    # ─── Tabs ─────────────────────────────────────────────────────────────────

    async def get_tab(self, tab_id: str) -> Tab:
        data = await self._http.get(f"/api/v0/tabs/{tab_id}")
        return Tab.model_validate(data)

    # ─── Streams ──────────────────────────────────────────────────────────────

    async def get_stream(self, stream_id: str) -> Stream:
        data = await self._http.get(f"/api/v0/streams/{stream_id}")
        return Stream.model_validate(data)

    # ─── Bounties ─────────────────────────────────────────────────────────────

    async def get_bounty(self, bounty_id: str) -> Bounty:
        data = await self._http.get(f"/api/v0/bounties/{bounty_id}")
        return Bounty.model_validate(data)

    async def list_bounties(
        self,
        status: str = "open",
        limit: int = 20,
        poster: str | None = None,
        submitter: str | None = None,
    ) -> list[Bounty]:
        kwargs: dict[str, object] = {"status": status, "limit": limit}
        if poster is not None:
            kwargs["poster"] = poster
        if submitter is not None:
            kwargs["submitter"] = submitter
        data = await self._http.get("/api/v0/bounties", **kwargs)
        items: list[dict[str, object]] = data.get("items", []) if isinstance(data, dict) else data
        return [Bounty.model_validate(d) for d in items]

    # ─── Deposits ─────────────────────────────────────────────────────────────

    async def get_deposit(self, deposit_id: str) -> Deposit:
        data = await self._http.get(f"/api/v0/deposits/{deposit_id}")
        return Deposit.model_validate(data)

    # ─── Wallet status ────────────────────────────────────────────────────────

    async def get_status(self, wallet: str) -> WalletStatus:
        data = await self._http.get(f"/api/v0/status/{wallet}")
        return WalletStatus.model_validate(data)

    # ─── Reputation ───────────────────────────────────────────────────────────

    async def get_reputation(self, wallet: str) -> Reputation:
        data = await self._http.get(f"/api/v0/reputation/{wallet}")
        return Reputation.model_validate(data)

    # ─── Events ───────────────────────────────────────────────────────────────

    async def get_events(self, since: int | None = None) -> list[Event]:
        params: dict[str, object] = {}
        if since is not None:
            params["since"] = since
        data = await self._http.get("/api/v0/events", **params)
        items: list[dict[str, object]] = data.get("items", []) if isinstance(data, dict) else data
        return [Event.model_validate(d) for d in items]

    # ─── Webhooks (read-only) ─────────────────────────────────────────────────

    async def get_webhook(self, webhook_id: str) -> Webhook:
        data = await self._http.get(f"/api/v0/webhooks/{webhook_id}")
        return Webhook.model_validate(data)

    # ─── Lifecycle ────────────────────────────────────────────────────────────

    async def close(self) -> None:
        await self._http.close()

    async def __aenter__(self) -> RemitClient:
        return self

    async def __aexit__(self, *_: object) -> None:
        await self.close()
