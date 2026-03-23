"""A2A/AP2 client — agent card discovery and A2A JSON-RPC task interface."""

from __future__ import annotations

import secrets
from dataclasses import dataclass, field
from typing import Any
from urllib.parse import urlparse


@dataclass
class A2AExtension:
    uri: str
    description: str
    required: bool = False


@dataclass
class A2ACapabilities:
    streaming: bool = False
    push_notifications: bool = False
    state_transition_history: bool = False
    extensions: list[A2AExtension] = field(default_factory=list)


@dataclass
class A2ASkill:
    id: str
    name: str
    description: str
    tags: list[str] = field(default_factory=list)


@dataclass
class AgentCard:
    """
    A2A agent card parsed from /.well-known/agent-card.json.

    Usage::

        card = await AgentCard.discover("https://remit.md")
        print(card.name, card.url)
        for skill in card.skills:
            print(skill.id, skill.description)
    """

    name: str
    description: str
    url: str
    version: str
    protocol_version: str = "0.6"
    documentation_url: str = ""
    capabilities: A2ACapabilities = field(default_factory=A2ACapabilities)
    skills: list[A2ASkill] = field(default_factory=list)
    x402: dict[str, Any] = field(default_factory=dict)

    @classmethod
    async def discover(cls, base_url: str) -> AgentCard:
        """
        Fetch and parse the A2A agent card from *base_url*/.well-known/agent-card.json.

        :param base_url: Root URL of the agent (e.g. ``"https://remit.md"``).
        :returns: Parsed :class:`AgentCard`.
        :raises httpx.HTTPStatusError: If the server returns a non-2xx response.
        """
        import httpx  # noqa: PLC0415

        url = base_url.rstrip("/") + "/.well-known/agent-card.json"
        async with httpx.AsyncClient() as client:
            resp = await client.get(url, timeout=10.0)
            resp.raise_for_status()
            data: dict[str, Any] = resp.json()

        return cls._from_dict(data)

    @classmethod
    def _from_dict(cls, data: dict[str, Any]) -> AgentCard:
        caps_data: dict[str, Any] = data.get("capabilities", {})
        extensions = [
            A2AExtension(
                uri=e.get("uri", ""),
                description=e.get("description", ""),
                required=bool(e.get("required", False)),
            )
            for e in caps_data.get("extensions", [])
        ]
        capabilities = A2ACapabilities(
            streaming=bool(caps_data.get("streaming", False)),
            push_notifications=bool(caps_data.get("pushNotifications", False)),
            state_transition_history=bool(caps_data.get("stateTransitionHistory", False)),
            extensions=extensions,
        )
        skills = [
            A2ASkill(
                id=s.get("id", ""),
                name=s.get("name", ""),
                description=s.get("description", ""),
                tags=list(s.get("tags", [])),
            )
            for s in data.get("skills", [])
        ]
        return cls(
            name=str(data.get("name", "")),
            description=str(data.get("description", "")),
            url=str(data.get("url", "")),
            version=str(data.get("version", "")),
            protocol_version=str(data.get("protocolVersion", "0.6")),
            documentation_url=str(data.get("documentationUrl", "")),
            capabilities=capabilities,
            skills=skills,
            x402=dict(data.get("x402", {})),
        )


@dataclass
class IntentMandate:
    """
    AP2 IntentMandate — pre-authorizes a payment on behalf of an issuer.

    Pass to :meth:`A2AClient.send` to include the mandate in the request metadata.
    """

    mandate_id: str
    expires_at: str
    issuer: str
    max_amount: str
    currency: str = "USDC"


@dataclass
class A2ATask:
    """
    Result of an A2A JSON-RPC task (message/send, tasks/get, tasks/cancel).

    States: ``"completed"``, ``"failed"``, ``"canceled"``, ``"working"``
    """

    id: str
    state: str
    artifacts: list[dict[str, Any]] = field(default_factory=list)
    error: str | None = None

    @property
    def tx_hash(self) -> str | None:
        """Extract ``txHash`` from task artifacts, if present."""
        for artifact in self.artifacts:
            for part in artifact.get("parts", []):
                if isinstance(part, dict):
                    tx = part.get("data", {}).get("txHash")
                    if tx:
                        return str(tx)
        return None

    @property
    def succeeded(self) -> bool:
        return self.state == "completed"


class A2AClient:
    """
    A2A JSON-RPC client for sending and managing tasks.

    Authenticates every request with EIP-712 signed headers — requires a
    :class:`~remitmd.signer.Signer` (or a :class:`~remitmd.wallet.Wallet`).

    Usage::

        from remitmd import Wallet
        from remitmd.a2a import AgentCard, A2AClient

        card = await AgentCard.discover("https://remit.md")
        wallet = Wallet.from_env()
        async with A2AClient.from_wallet(card, wallet) as client:
            task = await client.send(to="0xRecipient...", amount=10.0, memo="work")
            print(task.tx_hash)
    """

    def __init__(
        self,
        endpoint: str,
        signer: Any,
        chain_id: int,
        verifying_contract: str = "",
    ) -> None:
        from remitmd._http import AuthenticatedClient  # noqa: PLC0415

        parsed = urlparse(endpoint)
        base_url = f"{parsed.scheme}://{parsed.netloc}"
        self._path = parsed.path or "/a2a"
        self._auth = AuthenticatedClient(
            base_url=base_url,
            signer=signer,
            chain_id=chain_id,
            verifying_contract=verifying_contract,
        )

    @classmethod
    def from_wallet(cls, card: AgentCard, wallet: Any) -> A2AClient:
        """
        Construct an :class:`A2AClient` from an :class:`AgentCard` and a
        :class:`~remitmd.wallet.Wallet`.
        """
        return cls(
            endpoint=card.url,
            signer=wallet._signer,
            chain_id=wallet._http._chain_id,
            verifying_contract=wallet._http._verifying_contract,
        )

    async def send(
        self,
        to: str,
        amount: float,
        memo: str = "",
        mandate: IntentMandate | None = None,
    ) -> A2ATask:
        """
        Send a direct USDC payment via ``message/send``.

        :param to: Recipient wallet address (0x...).
        :param amount: Amount in USDC (e.g. ``10.0``).
        :param memo: Optional description / memo.
        :param mandate: Optional AP2 :class:`IntentMandate`.
        :returns: :class:`A2ATask` with state ``"completed"`` on success.
        """
        nonce = secrets.token_hex(16)
        message_id = secrets.token_hex(16)

        message: dict[str, Any] = {
            "messageId": message_id,
            "role": "user",
            "parts": [
                {
                    "kind": "data",
                    "data": {
                        "model": "direct",
                        "to": to,
                        "amount": f"{amount:.2f}",
                        "memo": memo,
                        "nonce": nonce,
                    },
                }
            ],
        }

        if mandate is not None:
            message["metadata"] = {
                "mandate": {
                    "mandateId": mandate.mandate_id,
                    "expiresAt": mandate.expires_at,
                    "issuer": mandate.issuer,
                    "allowance": {
                        "maxAmount": mandate.max_amount,
                        "currency": mandate.currency,
                    },
                }
            }

        result = await self._auth.post(
            self._path,
            {
                "jsonrpc": "2.0",
                "id": message_id,
                "method": "message/send",
                "params": {"message": message},
            },
        )
        return _parse_task(result)

    async def get(self, task_id: str) -> A2ATask:
        """Fetch the current state of an A2A task by ID."""
        call_id = task_id.removeprefix("task_")[:16] or secrets.token_hex(8)
        result = await self._auth.post(
            self._path,
            {
                "jsonrpc": "2.0",
                "id": call_id,
                "method": "tasks/get",
                "params": {"id": task_id},
            },
        )
        return _parse_task(result)

    async def cancel(self, task_id: str) -> A2ATask:
        """Cancel an in-progress A2A task."""
        call_id = task_id.removeprefix("task_")[:16] or secrets.token_hex(8)
        result = await self._auth.post(
            self._path,
            {
                "jsonrpc": "2.0",
                "id": call_id,
                "method": "tasks/cancel",
                "params": {"id": task_id},
            },
        )
        return _parse_task(result)

    async def close(self) -> None:
        await self._auth.close()

    async def __aenter__(self) -> A2AClient:
        return self

    async def __aexit__(self, *_: object) -> None:
        await self.close()


# ─── Internal helpers ─────────────────────────────────────────────────────────


def _parse_task(data: Any) -> A2ATask:
    """Parse a raw JSON-RPC response dict into an :class:`A2ATask`."""
    if isinstance(data, dict) and "error" in data:
        err = data["error"]
        msg = err.get("message", "Unknown A2A error") if isinstance(err, dict) else str(err)
        raise ValueError(f"A2A error: {msg}")

    result: dict[str, Any] = data.get("result", data) if isinstance(data, dict) else {}
    status: dict[str, Any] = result.get("status", {}) if isinstance(result, dict) else {}
    state = str(status.get("state", "unknown")) if isinstance(status, dict) else "unknown"

    artifacts: list[dict[str, Any]] = []
    if isinstance(result, dict):
        artifacts = list(result.get("artifacts", []))

    error: str | None = None
    if isinstance(status, dict):
        msg_obj = status.get("message")
        if isinstance(msg_obj, dict):
            error = msg_obj.get("text")

    return A2ATask(
        id=str(result.get("id", "")) if isinstance(result, dict) else "",
        state=state,
        artifacts=artifacts,
        error=error,
    )
