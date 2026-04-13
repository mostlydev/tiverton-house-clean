#!/usr/bin/env python3
"""Apply small compatibility fixes to the pinned Hermes install."""

from __future__ import annotations

import pathlib
import shutil
import sysconfig


purelib = pathlib.Path(sysconfig.get_paths()["purelib"])


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if old not in text:
        raise SystemExit(f"expected to patch {label}")
    return text.replace(old, new, 1)

shutil.copy("/tmp/minisweagent_path.py", purelib / "minisweagent_path.py")

discord_adapter = purelib / "gateway" / "platforms" / "discord.py"
text = discord_adapter.read_text()
text = replace_once(
    text,
    "            intents.members = True\n",
    "            intents.members = False\n",
    "discord members intent",
)
text = replace_once(
    text,
    "            intents.voice_states = True\n",
    "            intents.voice_states = False\n",
    "discord voice intent",
)
text = replace_once(
    text,
    """                # Resolve any usernames in the allowed list to numeric IDs
                await adapter_self._resolve_allowed_usernames()
                
                # Sync slash commands with Discord
                try:
                    synced = await adapter_self._client.tree.sync()
                    logger.info("[%s] Synced %d slash command(s)", adapter_self.name, len(synced))
                except Exception as e:  # pragma: no cover - defensive logging
                    logger.warning("[%s] Slash command sync failed: %s", adapter_self.name, e, exc_info=True)
                adapter_self._ready_event.set()
""",
    """                # Mark the gateway ready before best-effort post-connect work.
                adapter_self._ready_event.set()

                async def finalize_startup():
                    client = adapter_self._client
                    if client is None:
                        return

                    # Resolve any usernames in the allowed list to numeric IDs.
                    await adapter_self._resolve_allowed_usernames()

                    # Slash-command sync can be slow on larger guilds; keep it best-effort.
                    try:
                        synced = await asyncio.wait_for(client.tree.sync(), timeout=20)
                        logger.info("[%s] Synced %d slash command(s)", adapter_self.name, len(synced))
                    except Exception as e:  # pragma: no cover - defensive logging
                        logger.warning("[%s] Slash command sync failed: %s", adapter_self.name, e, exc_info=True)

                asyncio.create_task(finalize_startup())
""",
    "discord ready handler",
)
# ── Disable reply-mentions so agent replies do not ping the original author ──
# Discord's default is replied_user=True, which triggers mention loops in
# multi-agent pods.  We inject allowed_mentions on every channel.send that
# carries a reference.
text = replace_once(
    text,
    """                    msg = await channel.send(
                        content=chunk,
                        reference=chunk_reference,
                    )""",
    """                    msg = await channel.send(
                        content=chunk,
                        reference=chunk_reference,
                        allowed_mentions=discord.AllowedMentions(replied_user=False),
                    )""",
    "discord reply mention (primary send)",
)
text = replace_once(
    text,
    """                        msg = await channel.send(
                            content=chunk,
                            reference=None,
                        )""",
    """                        msg = await channel.send(
                            content=chunk,
                            reference=None,
                            allowed_mentions=discord.AllowedMentions(replied_user=False),
                        )""",
    "discord reply mention (fallback send)",
)
discord_adapter.write_text(text)
