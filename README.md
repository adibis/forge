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

Binaries land in `zig-out/bin/`:
- `forge` — main tool
- `forge-provider-anthropic`
- `forge-provider-openai`
- `forge-provider-ollama`

Copy them anywhere on your `$PATH`.

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
| `items` | Array element schema |
| `enum` | Allowed values; fuzzy case-match applied on `fix` |
| `format` | `email`, `uuid`, `date`, `date-time`, `uri` |
| `minimum`, `maximum` | Numeric bounds |
| `$ref`, `$defs`, `definitions` | Schema references and reusable definitions |
| nullable | `{"type": ["string", "null"]}` |

---

## Custom providers

A provider is any executable named `forge-provider-<name>` on your `$PATH`.
forge spawns it, writes a JSON request to its stdin, and reads a JSON response
from its stdout.

**Request** (stdin):
```json
{
  "prompt": "...",
  "schema_json": "...",
  "previous_errors": ["..."],
  "attempt_number": 1
}
```

**Response** (stdout):
```json
{"response": "..."}
```

On error:
```json
{"error": "reason"}
```

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

**Microcontrollers (ESP32 and similar)**

People have run tiny models (100K–1M parameter, heavily quantized) directly on
ESP32-S3 boards. The output validation problem is real in that context: a model
that small will produce well-structured JSON sometimes and near-miss JSON other
times. The `validate` and `fix` logic in forge — lenient parsing, type coercion,
enum case-folding — is exactly what you need between the model and your
application.

The forge binary itself requires a POSIX environment and won't run on FreeRTOS.
However the core algorithms (`parse/`, `validate/`, `schema/`) are pure Zig with
allocator interfaces and no OS dependencies. Zig supports the RISC-V variants of
ESP32 (C3, C6) natively, and Xtensa (ESP32, S3) via Espressif's Zig fork. A
`libforge` build target that exposes the core as a linkable library — usable from
ESP-IDF applications — is a planned milestone (see below).

---

## Goals

These are the planned directions for forge, in rough priority order.

**Near term**

- YAML schema input (`--schema model.yaml`)
- `--output <file>` flag on all subcommands
- Streaming input support (validate as tokens arrive)

**Medium term**

- `libforge`: a static library build target exposing the core validate/fix/parse
  logic as a C-compatible API. No CLI, no provider subprocess — just the
  algorithms. Primary use case: linking into applications that cannot run a
  subprocess, including ESP-IDF firmware, Go/Rust/C services, and WASM runtimes.

- Additional JSON Schema keywords: `allOf`, `anyOf`, `oneOf`, `not`,
  `minLength`/`maxLength`, `pattern`, `additionalProperties`

**Longer term**

- WASM build target for browser and edge-runtime use (Cloudflare Workers,
  Deno Deploy)
- ESP32 reference implementation: a working example of `libforge` embedded in an
  ESP-IDF project running a tiny local model

---

## License

MIT
