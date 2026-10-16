---
max_turns: 8
allowed_tools: [Read, Glob, Grep, Skill]
tags: [trigger, elixir-essentials]
---

Refactor this to pattern matching instead of nested ifs:

```elixir
def status(user) do
  if user.active do
    if user.admin, do: :admin, else: :member
  else
    :inactive
  end
end
```

Keep your answer short.
