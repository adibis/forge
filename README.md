# forge

**forge** validates, repairs, and retries structured JSON output from LLMs.

Drop it into any shell pipeline. No runtime, no SDK, no configuration files.
Works with Python services, Go binaries, bash scripts, CI jobs — anything that
can run a subprocess.

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

forge accepts a subset of JSON Schema draft-07:

- Types: `string`, `integer`, `number`, `boolean`, `array`, `object`, `null`
- `properties`, `required`, `items`
- `enum`
- `format`: `email`, `uuid`, `date`, `date-time`, `uri`
- `minimum`, `maximum`
- `$ref`, `$defs` / `definitions`
- Nullable types: `{"type": ["string", "null"]}`

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

## License

MIT
