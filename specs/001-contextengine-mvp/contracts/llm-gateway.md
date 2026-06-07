# Contract: Python LLM Gateway

**Plan**: [../plan.md](../plan.md) | The single chokepoint for **all** LLM access in the Python tier (`services/llm_gateway.py`). No direct provider SDK calls in ingestion, retrieval, or agent code. Mirrors the Go policy chokepoint.

## Model aliases & fallback

Business code references aliases only — never model IDs (FR-029).

| Alias | Primary | Fallback | Used for |
|-------|---------|----------|----------|
| `fast` | OpenAI GPT-4o-mini | Anthropic claude-haiku-4-5 | metadata extraction, image captioning, simple queries |
| `smart` | OpenAI GPT-4o | Anthropic claude-sonnet-4-6 | complex query generation |
| `embed` | OpenAI text-embedding-3-small | Voyage voyage-3-lite | embeddings — **no per-call fallback** (see caveat) |
| `rerank` | Cohere Rerank | local BGE-Reranker | cross-encoder reranking |

**Fallback rules**: fail over on timeout / 5xx / rate-limit only — never on "bad output". Cap at **one** hop. Emit `llm.fallback.count`; a circuit breaker trips back to primary when the primary error rate spikes. **Embedding caveat**: mixing embedding models within one Qdrant collection makes distances meaningless, so the `embed` fallback is never activated per call — a down primary embedder parks the chunk in `ingestion.dlq` for retry (FR-029).

## Interface

```python
@dataclass
class LLMRequest:
    model: str            # alias ("fast"/"smart") or exact name
    messages: list
    workspace_id: str
    user_id: str
    feature: str          # "ingest.metadata" | "ingest.caption" | "query.simple" | "query.complex"
    json_schema: dict | None = None
    max_tokens: int = 2048    # per-call output cap — third cost-defense layer (FR-017)
    stream: bool = False
    idem_key: str | None = None

@dataclass
class LLMResponse:
    content: str
    model: str            # resolved model name
    input_tokens: int
    output_tokens: int
    cost_usd_micros: int
    duration_ms: int
    cache_hit: bool

async def chat(req: LLMRequest) -> LLMResponse: ...
async def chat_stream(req: LLMRequest) -> AsyncIterator[str]: ...
async def embed(texts: list[str], workspace_id: str) -> list[list[float]]: ...
```

## Pipeline (every `chat` call)

`alias resolution → idempotency check → budget check → cache check → provider call → trace write → llm_call_log write → idempotency record`

- **Idempotency**: `idem_key = req.idem_key or sha256(workspace_id | model | messages | json_schema)`. `GETSET llm:idem:{idem_key}` (TTL 24h): hit → return stored response without calling provider or deducting credits; miss → proceed and store. The credit deduction is bound to the same `idem_key` (FR-019, SC-006).
- **Budget check**: per-role daily token budget (Redis) + workspace balance; over-budget short-circuits before the provider call (FR-016/FR-017).
- **Semantic cache**: key = `sha256(workspace_id | user_id | effective_access_level | model | normalize(query))`; personal-knowledge answers per-user, workspace-only answers MAY share per `(workspace_id, access_level)` via `cacheable_scope` (research §2, SC-001).
- **PII scrub before write**: prompts/responses are PII-scrubbed before any Langfuse/eval write; raw bodies retained 30 days then purged (FR-024, Clarification Q5).
- **Logging**: `llm_call_log` gets metadata/token/cost only — never raw message bodies (FR-024).

## Contract test obligations

- A repeated `chat` with identical inputs (same derived `idem_key`) calls the provider once and deducts credits once (SC-006).
- A primary-provider timeout fails over exactly once and increments `llm.fallback.count`; a low-quality (but successful) response does **not** fail over (FR-029).
- `embed` never silently substitutes the fallback model for a live call; the affected item is parked in DLQ (FR-029).
- A prompt containing an email/token is PII-scrubbed before it appears in any trace/eval store (FR-024).
