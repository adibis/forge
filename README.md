# forge

LLMs are good at following instructions but unreliable about output format. When
you ask a model for JSON, you might get the right data wrapped in a markdown fence,
a number returned as a string, a missing required field, or output truncated at the
token limit. Every team building on LLMs eventually writes the same cleanup code.
forge is that code, as a static binary with no runtime dependencies.

**forge** validates, repairs, and retries structured JSON output from LLMs.

Drop it into any shell pipeline. Works with Python services, Go binaries, bash
scripts, CI jobs — anything that can run a subprocess.

```sh
echo "$llm_response" | forge fix --schema user.schema.json > fixed.json
```

---

## Why

LLMs reliably produce *almost* valid JSON. The last mile failures are predictable:

- JSON wrapped in markdown fences (` ```json ... ``` `)
- Trailing commas (`{"key": "value",}`)
- Single-quoted strings (`{'key': 'value'}`)
- Numeric values as strings (`"age": "32"`)
- Wrong enum casing (`"status": "Active"` instead of `"active"`)
- Extra fields the schema doesn't expect
- Truncated output when the model hits a token limit
- Missing required fields

forge handles all of these. It validates against a JSON Schema, applies safe
coercions automatically, and — if you give it a provider — will re-prompt the
model with a structured error message and retry until the output is clean.

### Compared to other tools

| Tool | Validates | Repairs | Retries | Requirement |
|------|-----------|---------|---------|-------------|
| **forge** | ✓ | ✓ | ✓ | static binary, no runtime |
| [Instructor](https://github.com/instructor-ai/instructor) | ✓ | — | ✓ | Python or TypeScript library |
| [jsonrepair](https://github.com/josdejong/jsonrepair) | — | ✓ | — | Node.js |
| ajv / jsonschema | ✓ | — | — | Node.js or Python |
| [Outlines](https://github.com/outlines-dev/outlines) | ✓ | — | — | Python + local model |
| OpenAI structured outputs | ✓ | — | — | OpenAI API only |

Instructor is the closest equivalent for Python codebases and handles the retry
loop well. Outlines eliminates the problem at generation time if you control the
model. forge's specific value is as a **language-agnostic binary**: drop it into
a bash script, a Go service, a CI job, or any pipeline that isn't Python.

---

## Install

Requires [Zig 0.16](https://ziglang.org/download/).

```sh
git clone https://github.com/adibis/forge.git
cd forge
zig build -Doptimize=ReleaseFast
```

One binary lands in `zig-out/bin/forge`. Copy it anywhere on your `$PATH`.

The three built-in providers (Anthropic, OpenAI, Ollama) are compiled directly into
the binary. Use build flags to include only the ones you need:

```sh
# Ollama only — smallest binary, no cloud API code
zig build -Doptimize=ReleaseFast -Dopenai=false -Danthropiclient=false

# Anthropic + OpenAI, no Ollama
zig build -Doptimize=ReleaseFast -Dollama=false
```

**Cross-compile for Raspberry Pi Zero 2W (aarch64-linux-musl):**

```sh
zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseFast -Dopenai=false -Danthropiclient=false
```

This produces a fully static ARM64 binary with only the Ollama provider, ready to
copy to the device.

---

## Usage

### validate

Check whether JSON conforms to a schema. Prints a structured report to stdout.

```sh
echo '{"name":"Alice","age":25}' | forge validate --schema user.schema.json
```

```json
{
  "status": "ok",
  "errors": [],
  "warnings": [],
  "coercions": []
}
```

```sh
echo '{"name":"Alice"}' | forge validate --schema user.schema.json
```

```json
{
  "status": "error",
  "errors": [
    {
      "field": "age",
      "path": "$.age",
      "expected": "present",
      "received_type": "missing",
      "coercible": false,
      "message": "required field 'age' is missing"
    }
  ]
}
```

From a file:

```sh
forge validate --schema user.schema.json --input response.json
```

### fix

Apply all safe coercions and emit the repaired JSON. Exit 0 if the result is
fully valid, exit 1 if unresolvable errors remain.

```sh
echo '```json
{"name":"Alice","age":"30","status":"ACTIVE","extra":"ignored"}
```' | forge fix --schema user.schema.json
```

```json
{"name":"Alice","age":30,"status":"active"}
```

What happened:
- Markdown fence stripped
- `"30"` (string) coerced to `30` (integer)
- `"ACTIVE"` case-folded to `"active"` via fuzzy match
- `"extra"` field stripped (not in schema)

### retry

Validate the input, and if it fails, re-prompt the LLM with a structured
error message. Loops until valid or max retries exceeded.

```sh
echo "$llm_response" | forge retry \
  --schema user.schema.json \
  --provider anthropic \
  --max-retries 3
```

```json
{"status":"ok","attempts":2,"data":{"name":"Alice","age":30,"status":"active"}}
```

The `--provider` flag names a binary on your `$PATH` prefixed with
`forge-provider-`. The built-in providers are `anthropic`, `openai`, and
`ollama`. See [Custom providers](#custom-providers) to write your own.

Provider configuration is via environment variables:

| Provider | Variables |
|---|---|
| `anthropic` | `ANTHROPIC_API_KEY`, `ANTHROPIC_MODEL` (default: `claude-haiku`) |
| `openai` | `OPENAI_API_KEY`, `OPENAI_MODEL` (default: `gpt-4o-mini`) |
| `ollama` | `OLLAMA_HOST` (default: `http://localhost:11434`), `OLLAMA_MODEL` (required) |

### generate

Emit type definitions from a JSON Schema. Useful for keeping your model
classes in sync with the schema you're validating against.

```sh
forge generate --schema user.schema.json --target pydantic --model-name User
```

```python
from __future__ import annotations
from typing import Optional, List
from pydantic import BaseModel, EmailStr
from enum import Enum

class UserStatus(str, Enum):
    active = "active"
    inactive = "inactive"

class User(BaseModel):
    name: str
    age: int
    status: UserStatus
    email: Optional[EmailStr] = None
```

Available targets: `pydantic`, `typescript`, `zig`, `jsonschema`.

```sh
forge generate --schema user.schema.json --target typescript --model-name User
forge generate --schema user.schema.json --target zig        --model-name User
forge generate --schema user.schema.json --target jsonschema
```

---

## Exit codes

| Code | Meaning |
|------|---------|
| 0 | Valid (or fix succeeded) |
| 1 | Invalid / hard errors remain |
| 2 | Schema load error |
| 3 | Input parse error (malformed JSON, truncated) |
| 4 | Provider plugin error |
| 5 | Panic |

---

## JSON Schema support

forge supports a subset of JSON Schema draft-07:

| Keyword | Notes |
|---------|-------|
| `type` | `string`, `integer`, `number`, `boolean`, `array`, `object`, `null` |
| `properties`, `required` | Object shape validation |
| `additionalProperties` | `false` to forbid extra fields; or a schema to validate them against |
| `items` | Array element schema |
| `enum` | Allowed values; fuzzy case-match applied on `fix` |
| `format` | `email`, `uuid`, `date`, `date-time`, `uri` |
| `minimum`, `maximum` | Numeric bounds |
| `minLength`, `maxLength` | String length bounds |
| `pattern` | Stored and surfaced as a warning; regex evaluation not yet supported |
| `allOf` | Value must be valid against all subschemas |
| `anyOf` | Value must be valid against at least one subschema |
| `oneOf` | Value must be valid against exactly one subschema |
| `not` | Value must not be valid against the subschema |
| `$ref`, `$defs`, `definitions` | Schema references and reusable definitions |
| nullable | `{"type": ["string", "null"]}` |

---

## Custom providers

There are two ways to add a provider: subprocess (no rebuild) or compiled-in (smaller binary).

### Option 1 — subprocess provider (no rebuild required)

Put any executable named `forge-provider-<name>` on your `$PATH`. forge will
spawn it for any provider name that isn't built in.

**Request** (written to stdin):
```json
{
  "prompt": "...",
  "schema_json": "...",
  "previous_errors": ["..."],
  "attempt_number": 1
}
```

**Response** (read from stdout):
```json
{"response": "..."}
```

On error, write to stdout and exit non-zero:
```json
{"error": "reason"}
```

### Option 2 — compiled-in provider

1. Implement `src/providers/myprovider.zig` with a `call` function matching this
   signature:

   ```zig
   pub fn call(
       gpa: std.mem.Allocator,
       io: std.Io,
       req: plugin.PluginRequest,
       env: *const std.process.Environ.Map,
   ) ![]const u8
   ```

   Return a `gpa`-allocated string containing the raw LLM response text (not
   JSON-wrapped). See `src/providers/ollama.zig` for a reference implementation.

2. Add a dispatch branch in `src/providers/dispatch.zig`:

   ```zig
   if (std.mem.eql(u8, provider_name, "myprovider")) {
       return @import("myprovider.zig").call(gpa, io, req, env);
   }
   ```

3. Rebuild: `zig build -Doptimize=ReleaseFast`

The built-in providers (`ollama`, `openai`, `anthropic`) follow the same pattern and
are good reference implementations.

---

## Edge and embedded

forge cross-compiles to any target Zig supports:

```sh
zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseFast
```

`validate`, `fix`, and `generate` are fully self-contained — no network, no
subprocess, no dynamic linking. A single static binary that runs on ARM devices,
embedded Linux routers, and edge nodes where Python or Node runtimes are
unavailable.

`retry` requires spawning a provider subprocess and making HTTP calls to an LLM
API. It works on any edge node with outbound connectivity. If you are running
Ollama locally on the device, the full retry pipeline works there too.

**Tiny LLMs and the JSON validation problem**

Small language models running on edge devices produce structured JSON outputs
that drive real actions — controlling home automation, issuing robot commands,
generating sensor alerts, feeding industrial pipelines. When that JSON is
malformed or schema-invalid, the failure is often silent: a broken automation,
a dropped command, a blocked alert.

The forge binary requires a POSIX environment. However the core algorithms
(`parse/`, `validate/`, `schema/`) are pure Zig with allocator interfaces and
no OS dependencies. A `libforge` build target — a static library with a
C-compatible API, no CLI, no subprocess — can be linked directly into any
application running on the device. This is an active development goal (see
below).

---

## Goals

These are the planned directions for forge, in rough priority order.

**Near term**

- YAML schema input (`--schema model.yaml`)
- `--output <file>` flag on all subcommands
- Streaming input support (validate as tokens arrive)
- Full `pattern` support (regex evaluation)

**Medium term — libforge**

`libforge` is a static library build target that exposes the core
validate/fix/parse logic as a C-compatible API. No CLI layer, no provider
subprocess, no OS dependencies — just the algorithms, linkable into any
application.

Target environments:
- Edge devices running tiny local models
- Go, Rust, and C services that want validation without shelling out
- WASM runtimes (Cloudflare Workers, Deno Deploy, browser)

**Longer term**

- WASM build target
- Additional provider plugins (Gemini, Mistral, local llama.cpp server)
- Schema inference: generate a JSON Schema from example outputs

---

## License

MIT
