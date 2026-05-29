# BFCL Tool-Call Fixtures

These JSONL fixtures are a small GenieClaw-specific BFCL-style suite for local
tool-call accuracy. They are designed to run on the NVIDIA Jetson Orin 8GB path
without a live home backend: the scorer parses model responses and checks tool
names plus JSON arguments, but never executes tools.

Run:

```bash
cargo run -p genie-ctl -- bfcl-score \
  --cases tests/bfcl/home_tool_cases.jsonl \
  --predictions tests/bfcl/home_tool_predictions.jsonl
```

The fixture format is intentionally plain:

- `home_tool_cases.jsonl`: one case per line with `id`, `prompt`,
  `expected_tool_calls`, and optional `allow_extra_arguments`.
- `home_tool_predictions.jsonl`: one model response per line with matching
  `id` and `response`.

The first suite covers every static built-in tool name from `ToolDispatcher`,
including home/device calls, memory read/write/diagnostic tools, timers,
weather/search, calculations, media, no-tool responses, multi-tool responses,
and OpenAI-compatible `tool_calls` output. Dynamic native skill tools are loaded
at runtime, so each installed skill should add its own BFCL fixture.

For local stress testing, put large generated suites under `tests/bfcl/local/`.
That directory is gitignored on purpose. A useful local run shape is:

```bash
cargo run -p genie-ctl -- bfcl-score \
  --cases tests/bfcl/local/long_home_tool_cases.jsonl \
  --predictions tests/bfcl/local/long_home_tool_predictions.jsonl
```
