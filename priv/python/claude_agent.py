#!/usr/bin/env python3
"""
Claude Agent SDK bridge for Orchid.
Uses Claude subscription (Pro/Max) instead of API billing.
"""

import sys
import json
import asyncio
from claude_code_sdk import query, ClaudeCodeOptions

async def run_query(prompt: str, system_prompt: str | None = None, max_turns: int = 10):
    """Run a query using the Claude subscription."""
    options = ClaudeCodeOptions(
        system_prompt=system_prompt,
        max_turns=max_turns,
    )

    try:
        async for message in query(prompt=prompt, options=options):
            msg_type = type(message).__name__

            if msg_type == "AssistantMessage":
                # Extract text content
                for block in message.content:
                    if hasattr(block, 'text'):
                        output = {"type": "text", "content": block.text}
                        print(json.dumps(output), flush=True)
                    elif hasattr(block, 'name'):
                        # Tool use block
                        output = {
                            "type": "tool_use",
                            "tool_use": {
                                "id": getattr(block, 'id', None),
                                "name": block.name,
                                "input": getattr(block, 'input', {})
                            }
                        }
                        print(json.dumps(output), flush=True)

            elif msg_type == "ResultMessage":
                # Final result
                output = {
                    "type": "result",
                    "success": not message.is_error,
                    "cost_usd": getattr(message, 'total_cost_usd', None),
                    "turns": message.num_turns
                }
                print(json.dumps(output), flush=True)

        # Signal completion
        print(json.dumps({"type": "done"}), flush=True)

    except Exception as e:
        print(json.dumps({"type": "error", "content": str(e)}), flush=True)

def main():
    """Main loop - reads JSON commands from stdin."""
    for line in sys.stdin:
        try:
            cmd = json.loads(line.strip())

            if cmd.get("action") == "query":
                asyncio.run(run_query(
                    prompt=cmd["prompt"],
                    system_prompt=cmd.get("system_prompt"),
                    max_turns=cmd.get("max_turns", 10)
                ))
            elif cmd.get("action") == "ping":
                print(json.dumps({"type": "pong"}), flush=True)
            else:
                print(json.dumps({"type": "error", "content": "Unknown action"}), flush=True)

        except json.JSONDecodeError as e:
            print(json.dumps({"type": "error", "content": f"Invalid JSON: {e}"}), flush=True)
        except Exception as e:
            print(json.dumps({"type": "error", "content": str(e)}), flush=True)

if __name__ == "__main__":
    main()
