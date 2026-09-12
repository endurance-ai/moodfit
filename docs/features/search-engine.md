# 검색 엔진

> 상품 image embedding write는 migration 121의 URL/revision provenance 계약을 사용한다. 세 Python caller가 모두 `bulk_update_product_embeddings_v2`로 전환된 것을 확인한 뒤 migration 123을 별도로 적용한다. 상세 배포·복구 순서는 [`../../../kikoai/kikoai-handoff/pipeline-integrity/rollout-runbook.md`](../../../kikoai/kikoai-handoff/pipeline-integrity/rollout-runbook.md)를 따른다.

> `/api/find/search` (메인 플로우 Step 5) — **v6 embedding-first 단일 엔진** (SPEC-SEARCH-V6-001, 2026-05-18).
> ~~`/api/search-products`~~ — **feature/redesign-admin에서 삭제됨** (v6 search-debugger 전환, `src/domains/search-v4/` 전체 제거).

## 한눈에 (2026-05-18 이후)

| 레이어 | 상태 | 핵심 |
|---|---|---|
| **v6 (메인 플로우)** | ✅ 운영 | `product_embeddings` cosine-first (`search_products_v6` RPC, 072). Modal `/embed` + `/embed/text` query embedding. `SearchEngine` port 단일 구현체 (`v6-adapter.ts`). v4/v5 어댑터·circuit-breaker 제거 (SPEC-SEARCH-V6-001 P2) |
| ~~**v4 (어드민 전용)**~~ | ❌ **feature/redesign-admin에서 삭제** | `src/domains/search-v4/` + `/api/search-products` 전체 제거. 어드민 search-debugger가 `/api/admin/search-v6-debug` 로 전환됨. |
| ~~**PAI (`product_ai_analysis`)**~~ | ❌ **069 DROP (2026-05-18)** | v6 embedding-first 는 PAI 비의존 — CASCADE DROP (REQ-V6-031) |
| ~~**pgroonga 풀텍스트**~~ | ❌ **069 CASCADE DROP** | `idx_products_pgroonga_search` + `product_search_text(products)` — dead infra (유일 소비자 search_products_v5 동시 DROP) |
| ~~**v5 검색 어댑터**~~ | ❌ **P2 삭제** | `v5-adapter.ts`, `v4-fallback-adapter.ts`, `circuit-breaker.ts` 삭제. `registry.ts` `selectEngine()` → v6 단일. `SEARCH_ENGINE_VERSION` env 분기 제거 |
| **product_embeddings** | ✅ 071 생성 | halfvec(768) + HNSW halfvec_cosine_ops. 기존 `products.embedding` 71k backfill. `products.embedding*` 컬럼은 cutover 후 별 마이그서 DROP 예정 |
| **Modal text tower** | ✅ 배포 완료 (2026-05-18) | `/embed/text` + `Embedder.embed_text` (open_clip FashionSigLIP). image+text fusion `normalize(0.7·img+0.3·txt)` 기본 활성. `/embed/text` 5xx 시 image-only 런타임 폴백 |
| **브랜드 그래프 인프라 v2 (multimodal)** | ✅ SPEC-BRAND-EMBED-001 완료 (063~066) | `brand_multimodal_embeddings` (FashionSigLIP 768) + `node_centroids` + auto `style_node_adjacency` + UMAP. **v6 interim 미사용 (Track B — §14)**. crawler bulk 완료 후 풀배치 예정 |

---

## v6 (메인 플로우 — SPEC-SEARCH-V6-001, 2026-05-18)

**엔진 본체: `src/domains/search/adapters/v6-adapter.ts`** (port: `engine-port.ts`, 등록: `registry.ts`)

### 파이프라인 (SPEC §4 + ratified §13)

```
user image (+ optional text prompt)
  → query_emb = Modal /embed [+ /embed/text fusion 0.7/0.3] (FashionSigLIP 768-dim L2-norm)
  → FILTER 1: brand_nodes WHERE primary_style_node_id = styleNode.primary (EXACT)
  → FILTER 2: products WHERE brand_node_id ∈ filter1 AND category family gate (073) AND in_stock AND product_embeddings row
  → RANK:     cosine(query_emb, product_embeddings.embedding) DESC, created_at DESC, LIMIT N
  → FALLBACK (degraded): 0건 시 node 필터 드롭 → category family+in_stock+embedding 전체 cosine, degraded:true
```

### 핵심 특성

| 항목 | 값 |
|---|---|
| RPC | `search_products_v6` (072) |
| query embedding | Modal `/embed` (image) + optional Modal `/embed/text` fusion (α=0.7) |
| ranking | cosine DESC (`product_embeddings.embedding <=> query_embedding`), 가중합 없음 |
| filter | EXACT `primary_style_node_id` + `category_canonical` family gate (073) + `in_stock` |
| degraded fallback | node 0건 → node 드롭, category-only cosine, `engine:"v6-degraded"` |
| brand 분기 | `brandFilter` non-empty → strong call (p_brand_names), general always runs |
| 실패 | query embedding 실패 or DB throw → `failed:true` → route 502 `AI_SERVER_FAILED` |

### 환경변수

| 키 | 의미 |
|---|---|
| `AI_SERVER_URL` | Modal embed 서버 base URL |
| `AI_SERVER_TIMEOUT_MS` | 타임아웃 (기본 60000ms) |

> `SEARCH_ENGINE_VERSION` / `CB_ENABLED` / `CB_FAILURE_THRESHOLD` / `CB_COOLDOWN_MS` — **v6 P2 에서 제거됨** (registry 단일 v6, env 분기 없음).

---

## ~~v4 (어드민 search-debugger 전용)~~ — **삭제됨 (feature/redesign-admin, 2026-05-20)**

> `src/domains/search-v4/` 전체 + `/api/search-products/route.ts` + v4 특성화 테스트 2파일 + locked-filter/season-pattern 유틸 삭제. 어드민 search-debugger가 `/api/admin/search-v6-debug` 기반 v6 디버거로 완전 전환됨.

아래는 아카이브 참조용 (이 PR 이전 상태).

**엔진 본체: `src/domains/search-v4/`** (engine/scorer/ranker/query-builder/constants/types — SPEC-ARCH-APP-001 step 3, 2026-05-17). `src/app/api/search-products/route.ts` 는 852→**207 LOC thin 핸들러**로 축소(입력검증→`searchByEnums` 위임→동일 NextResponse). 동작·스코어링 byte-identical (특성화 테스트 0-diff 검증). 아래 `src/lib/...` 경로 표기는 re-export shim 호환 경로이며 실체는 `src/domains/search-v4/` · `src/shared/{enums,utils}/`.

### 흐름

1. **JOIN** — `products` ⨝ `product_ai_analysis` INNER JOIN
   - ⚠️ AI 분석 없는 상품(해외 35k)은 노출 0 — v5 전환의 핵심 동기
2. **Hard filter**
   - `brandFilter` (brand 이름 배열) — 메인 플로우의 strong matching에서 활성
   - `priceFilter` (min/max) — 있으면 DB+인메모리 필터, null price 제외
   - `passesLockedFilter` — archived flow 잔재. 현재 호출 경로에서는 미사용이지만 코드는 통과
3. **10차원 가중합 스코어링**
   - subcategory 0.25 / colorFamily 0.20 / colorAdjacent 0.10
   - styleNode gradient 0.30 / 0.15
   - fit 0.15 / fabric 0.15 / season 0.15 / pattern 0.15
   - brandDna 0.20 / moodTags 0.05 × N
   - ⚠️ **brandDna 로드 disable (2026-05-15)** — `brand_nodes.sensitivity_tags` migration 067 drop. `brandDnaMap` 빈 채로 진행 → brand boost = 0. SPEC-SEARCH-V6 가 새 ranking 으로 대체 예정.
4. **한국어/색상/스타일 매핑**
   - `src/lib/enums/korean-vocab.ts` — 한국어 패션 용어 → enum (115+ 항목)
   - `src/lib/enums/color-adjacency.ts` — 16색 인접 그래프 (검색 시 유사 색상 폴백)
   - `src/lib/enums/style-adjacency.ts` — 15 스타일 노드 유사도 (gradient scoring)
5. **다양성 캡** — 브랜드당 max 2, 플랫폼당 max 3
   - `brandFilter` 활성 시 브랜드당 cap 완화
6. **Tolerance → 결과 개수** — `toleranceToTargetCount` (`src/lib/search/locked-filter.ts`)
   - 0.0 → 10개 (tight)
   - 0.5 → 15개 (medium)
   - 1.0 → 20개 (loose)

### 입력 페이로드

```ts
interface SearchRequest {
  queries: Array<{ id, category, subcategory?, fit?, fabric?, colorFamily?, searchQuery, searchQueryKo? }>
  gender?: "male" | "female" | "unisex"
  styleNode?: { primary: string; secondary?: string }
  moodTags?: string[]
  priceFilter?: { minPrice?: number; maxPrice?: number }
  brandFilter?: string[]      // 활성 시 hard filter + cap 완화
  styleTolerance?: number     // 0.0 ~ 1.0
}
```

### 로깅

호출당 score breakdown을 `search_quality_logs` 테이블에 저장 → 어드민 검색 디버거 (`/admin/search-debugger`) 에서 시각화.

---

## 임베딩 배치 스크립트 (로컬 실행)

> AWS Spot 불필요 (SPEC §5) — 사용자 로컬에서 실행. ~47k 미임베딩 잔여.

| 파일 | 역할 |
|---|---|
| `scripts/aws/embed_products.py` | **071/110 rework** — `in_stock=true` + `product_embeddings` 부재 상품만 선별하고 canonical `products.image_url`을 임베딩. `images[0]`은 호환용 mirror이며 입력 선택에 사용하지 않는다. DB_URL/DB_TOKEN (구 SUPABASE_URL fallback). |
| `scripts/aws/launch_embed_batch.sh` | EC2 Spot 런처 — 로컬 실행 이후 불필요하나 파일 유지 |

운영용 `ai-server/scripts/embed_batch_devapp.py`는 404/410 대표 이미지를 DB 갤러리와
상품 페이지에서 복구한다. 검증된 대체 URL은 먼저 `image_url`로 승격하고 모든 이미지
필드에서 죽은 URL을 제거한 뒤 임베딩한다. 403/429/5xx/timeout은
`product_image_failures`에 retryable로 기록하며, 영구 실패는 URL이 바뀔 때까지 격리된다.

---

## SearchEngine port (SPEC-SEARCH-V6-001 §6/§10c)

> SPEC-SEARCH-UNIFY-001 에서 도입된 port 인터페이스는 **보존**됨. 단, 다중엔진 머신(v4/v5/breaker/버전 env 분기)은 **SPEC-SEARCH-V6-001 P2 에서 제거**.

### 토폴로지

```
/api/find/search  (입력검증·handle→brand resolution·imageUrl&AI_SERVER_URL gate·HTTP 엔벨로프 route 잔류)
   └─ selectEngine().search(req)   ← 단일 v6 엔진
        └─ v6Adapter               ← embedding-first (SPEC-SEARCH-V6-001 §4)
```

### 핵심 파일 (`src/domains/search/`)

| 파일 | 역할 |
|---|---|
| `engine-port.ts` | `SearchEngine` 인터페이스 + `RecommendRequest`/`RecommendResponse` DTO. **v6 기준 업데이트** — `engine:"v6"` / `"v6-degraded"`. `EngineVersion` 유니온 + `resolveEngineVersion()` **P2 제거** |
| `registry.ts` | `selectEngine()` → `v6Adapter` 단일 반환. `selectEngineByVersion` / `v5Breaker` / `lazyV4Engine` **P2 제거** |
| `adapters/v6-adapter.ts` | **v6 실 구현체** — Modal `/embed` query_emb + `search_products_v6` RPC + strong/general grouping + degraded provenance |
| `adapters/query-embed.ts` | `buildQueryEmbedding` — image-only or `normalize(0.7·img+0.3·txt)` fusion. Modal `/embed` + `/embed/text` 호출 |
| ~~`adapters/v5-adapter.ts`~~ | **P2 삭제** |
| ~~`adapters/v4-fallback-adapter.ts`~~ | **P2 삭제** |
| ~~`circuit-breaker.ts`~~ | **P2 삭제** |

### 응답 계약

- `engine:"v6"` — 정상 EXACT path
- `engine:"v6-degraded"` — §13 결정 1 fallback (node/family gate 드롭)
- `failed:true` → route 502 `AI_SERVER_FAILED` (query embedding 실패 or DB throw)
- `strongMatches` / `general` / `resolvedBrands` shape 불변 (route envelope 변경 0)

### 특성화 게이트 (P2 재정향)

- `src/__characterization__/search-unify-001/find-search-route.test.ts` — **v6 success envelope** 핀 (v5 byte-identity pin 은 v5-adapter 삭제와 함께 retire). `engine:"v6"` / `"v6-degraded"` / 502 계약. v6 DB chain mock (mockRpc, mockBuildQueryEmbedding).
- ~~`src/__characterization__/search-unify-001/search-v4-shape.test.ts`~~ — **feature/redesign-admin에서 삭제됨** (v4 어드민 소비자 `/api/search-products` + `domains/search-v4` 제거와 함께).
- `src/__tests__/search-unify-001/registry-and-forward-compat.test.ts` — **v6 단일 registry** + port forward-compat. `selectEngineByVersion` / breaker singleton 테스트 **retire** (삭제된 코드). `circuit-breaker.test.ts` **삭제**.

### P5 잔여 audit

- `search_quality_logs` (014) — v4 score breakdown 구조. v6 cosine-only 와 불일치. 유지/대체/제거 검토.
- ~~`get_product_filter_counts()`~~ — **migration 074에서 DROP됨** (feature/redesign-admin). PAI DROP(069) 후 런타임 throw 상태였던 audit 항목 청산. `count_products_by(p_column)` RPC + 라우트 직접 집계로 대체.

### 검색 디버거 v2 (관측성 도구, 2026-05-20)

어드민 `/admin/search-debugger` 전면 재작성 — v6 파이프라인 end-to-end 트레이스.

| 기능 | 상세 |
|---|---|
| **모드** | text / image / fused (3종) |
| **Apify URL resolve** | IG/Pinterest URL → 이미지 URL 자동 추출 |
| **Vision/LLM rewrite** | AI 서버 `/debug/*` 엔드포인트 호출 → Vision 분석 + 쿼리 rewrite trace |
| **파이프라인 trace** | `search_products_v6` RPC 직접 호출 + steps 토글 (run_rewrite, apply_rewrite, run_vision, auto_wire_category) |
| **Run 히스토리** | `search_debug_runs` 테이블 (migration 083) — rating(1-5) / notes / tags. 어드민 간 공유 |
| **API** | `POST /api/admin/search-v6-debug` (AI 서버 프록시), `GET/POST /api/admin/search-debug-runs`, `GET/PATCH/DELETE /api/admin/search-debug-runs/[id]` |
| **env 의존** | `AI_API_URL` (AI server base URL, `AI_SERVER_URL` fallback), `INTERNAL_API_TOKEN` (X-Internal-Token 헤더) |

### search_products_v6 fanout 버그 수정 (migration 082)

`category_canonical` JOIN 의 `lower(trim())` 정규화가 동일 normalize 값을 가진 cc row N개에 매칭 → N배 fanout 발생 (같은 product_id 2~3회 중복 반환). `cc.raw_category = p.category` verbatim 비교로 정정. v_target_family lookup (p_category 인자 → family) 의 `lower(trim())` 는 보존.

---


## 핵심 파일

> SPEC-ARCH-APP-001 (2026-05-17) 후 아래 `src/lib/...` 경로는 **re-export shim** — 실체는 `src/shared/{enums,utils}/`. 신규 코드는 실체 경로 직접 참조.

| 파일 | 설명 |
|---|---|
| ~~`src/domains/search-v4/`~~ | **feature/redesign-admin에서 전체 삭제** (engine/scorer/ranker/query-builder/constants/types) |
| ~~`src/app/api/search-products/route.ts`~~ | **feature/redesign-admin에서 삭제** — 어드민 search-debugger가 v6으로 전환됨 |
| ~~`src/lib/search/locked-filter.ts`~~ / ~~`src/shared/utils/locked-filter.ts`~~ | **feature/redesign-admin에서 삭제** — v4 전용 유틸, 소비자 없음 |
| `src/lib/enums/product-enums.ts` | enum 정의 + validation + `buildEnumReference()` |
| `src/lib/enums/korean-vocab.ts` | 한국어 → enum 매핑 (115+) |
| `src/lib/enums/color-adjacency.ts` | 16색 인접 |
| `src/lib/enums/style-adjacency.ts` | 15 스타일 노드 gradient |
| `src/lib/enums/season-pattern.ts` | season(5) + pattern(10) |
| `src/lib/enums/enum-display-ko.ts` | enum → 한글 디스플레이 (`toKo()`) |
| ~~`src/lib/fashion-genome.ts`~~ | **deprecated (SPEC-NODE-REDESIGN-001, 2026-05-13)** — STYLE_NODES → `style_nodes` DB 이전. SENSITIVITY_TAGS + legacy 의존성만 임시 유지. 새 코드는 `src/lib/style-nodes-db.ts` 사용 |
| `src/lib/style-nodes-db.ts` | DB-managed style node taxonomy fetch — `fetchActiveStyleNodes()` / `buildNodeReference()` / `getActiveNodeCodes()` (5 min cache + in-flight dedup) |
| `scripts/eval-search.ts` | 골든셋 기반 자동 평가 |
| `scripts/aws/embed_products.py` | v5 임베딩 배치 |
| `scripts/aws/launch_embed_batch.sh` | EC2 Spot 런처 |

## 관련 문서

- `docs/plans/26-04-23-embedding-rewrite-plan.md` — v5 plan v1 (reference)
- `docs/plans/26-04-24-aws-embedding-infra.md` — AWS 인프라 스펙
- `docs/research/26-04-12-search-engine-differentiation-research.md` — 차별화 연구

---

## Brand Multimodal Embedding (SPEC-BRAND-EMBED-001, 2026-05-15)

v6 검색의 Stage 4 brand 후보 좁힘 (style_node + adjacency 확장) 의존 인프라. **검색 엔진 자체는 아직 호출 안 함** — SPEC-SEARCH-V6 가 통합 시점.

**파이프라인** (`scripts/refresh_brand_embeddings_all.sh` 한 번에):

```
crawler: brand 분류 (primary_style_node_id + representative_image_urls 5장)
         │
         ▼
embed_brand_multimodal.py
         │  Marqo/marqo-fashionSigLIP image×5 + text chunks → mean → L2 norm
         ▼
brand_multimodal_embeddings (768 halfvec, HNSW)
         │
         ▼ build_node_centroids.py (--min-members 5)
node_centroids (per style_node centroid)
         │
         ▼ build_adjacency_from_centroids.py (--apply --mode top-k --k 5)
style_node_adjacency.source='embedding_derived' (manual override 보존)
         │
         ▼ build_brand_umap.py
brand_multimodal_umap (admin /admin/brand-clusters 시각화)
```

**현재 상태** (2026-05-15): 11 brand 임베딩 + 8 centroid (member=1~3). crawler bulk 완료 시 같은 스크립트로 ~700 brand 채워짐 (idempotent). adjacency `--apply` 는 threshold 결정 필요 → 데이터 차고 분포 보고 결정 (mode threshold / top-k / percentile 셋 중).

**Helper**: `findSimilarBrands(brandId, k)` (RPC `find_similar_brands`, admin endpoint `/api/admin/brand/[id]/similar`).

**검색 통합 시점**: SPEC-SEARCH-V6 가 Stage 4 hard filter (현재 brandFilter) 를 `style_node + adjacency 1-hop` 으로 확장하면서 같이 통합. 그 SPEC 가 진입 전까지 검색 엔진 본체 변경 없음.

**운영 가이드**: [features/brand-embed.md](brand-embed.md)

---

## Evaluation Infrastructure (v6-EVAL — 드랍됨, 2026-05-13)

> ⚠️ **Migration 048 (2026-05-13) 로 드랍 완료.** eval_golden_queries / eval_golden_set / eval_judgments / eval_runs 4 테이블 + 관련 API 7개 + `src/lib/eval/` 전체 삭제. `eval_reviews` (114 rows) 만 유지. v6 평가 재설계 시 새 SPEC 에서 재구성 예정.

유지되는 것:
- `eval_reviews` 테이블 (migration 013) — 어드민 평가 대기열 직접 사용
- `/admin/eval` — queue-only 단일 탭으로 단순화

삭제된 것:
- DB: `eval_golden_queries`, `eval_golden_set`, `eval_judgments`, `eval_runs` (migration 033) + `prevent_frozen_v4_baseline_overwrite` 트리거/함수
- API: `/api/admin/eval/{compute, freeze-baseline, golden-queries, golden-set, judgments/[id], run, runs}` 7개 디렉토리
- Lib: `src/lib/eval/` (ndcg.ts / precision.ts / judgment-store.ts / run-snapshot.ts)
- UI: eval-golden-queries / eval-golden-set / eval-labeling-form / eval-runs-dashboard 컴포넌트

SPEC: SPEC-V6-EVAL (완료 → 드랍), SPEC-V6-EVAL-V2 (완료 → 드랍)
