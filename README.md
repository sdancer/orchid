# 🪴 Orchid

[![Elixir](https://img.shields.io/badge/Elixir-1.17+-purple?logo=elixir&logoColor=white)](https://elixir-lang.org)
[![Phoenix LiveView](https://img.shields.io/badge/Phoenix-LiveView-FF6F61?logo=phoenixframework&logoColor=white)](https://github.com/phoenixframework/phoenix_live_view)
[![Podman](https://img.shields.io/badge/Podman-Container-2C3E50?logo=podman&logoColor=white)](https://podman.io)

**Secure • Sandboxed • Multi-Agent LLM Orchestration**

Run reliable teams of LLM agents locally with **strong container isolation**, persistent goals, structured object editing, and a beautiful real-time dashboard.

---

![Orchid LiveView Dashboard](https://via.placeholder.com/1200x600/111827/22d3ee?text=Orchid+LiveView+Dashboard+%E2%9C%A8)

*(Replace this placeholder with a real screenshot or 10-second GIF of the dashboard after you record one!)*

## ✨ Features

- **Hard Sandboxing** — Every agent runs in its own Podman container (overlayfs preferred + smart Elixir union-fs fallback)
- **Goal-Driven Workflows** — Persistent goals, planning, execution, self-review, and human approval loops
- **Structured Object Editing** — Agents create/edit rich objects (codebases, documents, data structures, plans) instead of just text
- **Human-in-the-Loop Review Queue** — Built-in approval system for critical or high-stakes actions
- **Real-time LiveView Dashboard** — Monitor, intervene, and collaborate with all agents live
- **Developer-First CLI** — `./orchid start`, `stop`, `logs`, `status`, `shell <agent>`
- **Local & Private** — Everything runs on your machine. Full control, zero data leaves your laptop

## 🚀 Quick Start (under 60 seconds)

```bash
git clone https://github.com/sdancer/orchid.git && cd orchid

mix deps.get

# Configure your LLM keys
cp .env.example .env # ← edit this file

./orchid start
