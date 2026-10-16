---
max_turns: 8
allowed_tools: [Read, Glob, Grep, Skill]
tags: [trigger, security-essentials]
---

Review this Phoenix controller action for security problems:

```elixir
def go(conn, %{"to" => url}), do: redirect(conn, external: url)
```

Keep your answer short.
