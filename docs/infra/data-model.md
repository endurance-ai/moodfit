# 데이터 모델 — dev-app Postgres

> 모든 영속 데이터는 **dev-app EC2 의 자체호스트 Postgres 16** 단일 인스턴스. PostgREST + nginx shim 으로 `/rest/v1/*` 노출. SPEC-INFRA-MIGRATE-001 P2/P4/P6 이후. (이전: Supabase Postgres — 2026-05-10 pause)
>
> 서버 접근은 PostgREST service JWT (`DB_TOKEN`, 구 SUPABASE_SERVICE_ROLE_KEY) 또는 `pg` Pool 직접 (Auth.js 인증 경로). 어드민 SSR 쿠키는 Auth.js v5 JWT 로 전환됨 (SPEC-INFRA-MIGRATE-001 P3).

## 테이블 인벤토리

| 영역 | 테이블 | 마이그 | 역할 |
|---|---|---|---|
| **분석 로그** | ~~`analyses`~~ | ~~001~~→**089 드롭** | **migration 089 DROP (2026-05-22)** — /admin/eval 제거 + writer(/api/analyze) 제거로 dead. |
| | ~~`analysis_items`~~ | ~~002~~→**089 드롭** | **migration 089 DROP** — eval 상세 전용이었음 |
| | ~~`analysis_sessions`~~ | ~~021~~→**087 드롭** | **migration 087 DROP (2026-05-22)** — 레거시 refine 세션. /api/analyze + user-voice 제거에 동반 |
| **상품** | `products` | 004 + 005 + 006 + 011 + 027 + **070** + **107** + **110** | 크롤로 들어온 모든 SKU. **070: id uuid→bigserial 전환 (2026-05-18)**. `gender` 는 크롤러 write-path의 단일 출처이며, 크롤러 색상 컬럼 `color` 는 **107 에서 DROP**. 색상 정본은 `product_features.feature_metadata->>'primary_color'`. **`image_url`이 serving/search/embedding 대표 이미지 SOT**이고 `images[0]`은 호환용 mirror다. 110은 대표 변경 시 이미지 파생 자산을 자동 무효화한다. |
| | `product_features` | **095** (실물은 2026-07-28 선행 생성) | **VLM 이 만드는 이미지 파생 피처 — color 의 단일 출처.** PK `product_id` → products.id ON DELETE CASCADE. `feature_metadata jsonb` (`primary_color`(16 canonical family UPPERCASE) / `secondary_colors` / `material` / `pattern` / `style_tags` / `neckline` / `details` / `fit`, + 레거시 `gender` 스칼라), `retrieval_text`, `text_embedding halfvec(768)` + HNSW. 진행률은 097 의 `product_features_coverage` 로 본다 |
| | `product_catalog_jobs` | **118** | 신규·동일성·대표 이미지 변경 상품의 대표 이미지→VLM 피처→임베딩→교차몰 매핑을 연결하는 내구성 큐. 상품별 최신 generation만 완료할 수 있고 lease 기반 claim 및 3회 재시도를 지원한다. 가격·재고 변경만으로는 enqueue하지 않는다. |
| | `product_embeddings` | **071 + 110** | canonical `products.image_url`의 FashionSigLIP(768) 임베딩. halfvec + HNSW, product_id bigint PK/FK. 대표 이미지 변경·소실 시 110 트리거가 자동 삭제한다. |
| | `product_image_failures` | **110** | 대표 이미지 다운로드 실패 상태. retryable은 `next_retry_at` 이후 재시도하고 permanent는 같은 `image_url`이 유지되는 동안 격리한다. URL 변경 시 자동 삭제된다. |
| | `product_reviews` | 019 | 상품 리뷰. **070 에서 product_id uuid→bigint swap** |
| | `product_refresh_sources` | **094** | 브랜드 상태와 분리된 storefront/source 갱신 큐. PK는 실행 가능한 config의 `platform_key` |
| | `product_refresh_runs` | **094** | source별 목록 갱신 실행 이력, coverage/update/error metrics |
| | `product_refresh_candidates` | **094** | 갱신 중 발견된 신규 URL 큐. 기존 브랜드와 정확히 매칭된 후보만 별도 LLM worker가 상품으로 적재 |
| | ~~`product_ai_analysis`~~ | ~~012~~→**069 드랍** | **migration 069 (2026-05-18) 에서 CASCADE DROP. v6 embedding-first 는 PAI 비의존 (REQ-V6-031)** |
| **브랜드** | `brand_nodes` | 002 + 007 + 037 + 040 + 041 + 042 + **055** + **056** + **067** + **084** + **105** | Fashion Genome v2 슬림화. **067 (2026-05-15)**: 037 BGE-m3 텍스트 임베딩 자산(embedding/x_umap/y_umap 등) + 옛 LLM 메타(sensitivity_tags/brand_keywords/aliases/category_type/representative_image_urls/price_band) 13 컬럼 DROP. price_min_usd / price_max_usd (numeric, USD) 신규 + products 기준 backfill. **id bigserial** (056). primary/secondary_node_id FK + node_confidence (055). **084 (2026-05-21)**: `wiki jsonb` 컬럼 및 country/ig_handle/status 인덱스 추가. **105 (2026-08-06)**: 서비스용 `description text`를 일반 컬럼으로 분리하고 기존 wiki 설명을 한국어 우선·원문 폴백으로 이관한 뒤 JSON 키 제거. |
| | `brand_attributes` | 010 | 어드민에서 채우는 브랜드 속성 |
| | ~~`brand_similar`~~ | ~~038 + 056~~→**080 드롭** | **migration 080 DROP** — BGE-m3 텍스트 임베딩 기반 42k edge 그래프. `brand_multimodal_embeddings` + `find_similar_brands` RPC (063~066) 로 대체 |
| | `brand_attribute_proposals` | 039 + **056** | LLM 추론 브랜드 속성 검수큐 (confidence ≥ 0.85 자동/0.7~0.85 pending/< 0.7 폐기). brand_id bigint 전환 (056) |
| | `brand_node_review_queue` | **055** + **056** | Brand-VLM 분류 실패/저신뢰/충돌/image 부족 admin 수동 검수 큐. open 1건 per brand (partial unique). reason: insufficient_images/low_confidence/multi_node_conflict/vlm_failed/alias_candidate |
| | ~~`brand_sku_counts`~~ | ~~043~~→**085 드롭** | **migration 085 (2026-05-22) DROP** — 0참조 perf 캐시. 크롤모니터는 `admin_crawl_platform_stats()` 가 직접 집계 |
| **검색 품질** | ~~`search_quality_logs`~~ | ~~014~~→**087 드롭** | **migration 087 DROP** — analytics/pipeline-health 전용이었고 둘 다 제거. 2026-05-10 이후 write 중단 stale |
| **평가** | ~~`eval_reviews`~~ | ~~013 + 015~~→**089 드롭** | **migration 089 DROP** — /admin/eval 제거 동반 |
| | ~~`eval_golden_set`~~ | ~~013~~→**048 드랍** | migration 048 (2026-05-13) 에서 삭제됨 |
| | ~~`eval_golden_queries`~~ | ~~033~~→**048 드랍** | migration 048 에서 삭제됨 |
| | ~~`eval_judgments`~~ | ~~033~~→**048 드랍** | migration 048 에서 삭제됨 |
| | ~~`eval_runs`~~ | ~~033~~→**048 드랍** | migration 048 에서 삭제됨 |
| **유저 피드백** | ~~`user_feedbacks`~~ | ~~021~~→**087 드롭** | **migration 087 DROP** — user-voice(read) + /api/feedback(write) 제거에 동반 |
| **어드민 인증** | `admin_profiles` | 022 + 023 + 024 | `status: pending/approved/rejected` 승인 게이트 |
| **Instagram** | ~~`instagram_post_scrapes`~~ | ~~028~~→**087 드롭** | **migration 087 DROP** — 공개 IG 메인플로우 제거에 동반 (admin 미사용) |
| | ~~`instagram_post_scrape_images`~~ | ~~028~~→**087 드롭** | **migration 087 DROP** — 동일 |
| **카테고리** | `category_canonical` | **073** | raw `products.category` (752 distinct) → 20 canonical family 매핑 테이블. v6 FILTER 2 family 게이트 + Vision-normalize 공유 계약. `raw_category` PK, `family` (tops/bottoms/…/other). |
| **스타일 노드** | `style_nodes` | 049 + 050 | Fashion Genome taxonomy DB 관리 (20 nodes A~T, admin CRUD). `src/lib/style-nodes-db.ts` 로 fetch (5 min cache). `fashion-genome.ts` 의 hardcoded 15-node 대체 |
| | `style_node_adjacency` | 051 | 스타일 노드 간 관계 그래프 (빈 테이블 — SPEC-BRAND-EMBED-001 이 채울 예정) |
| **프롬프트 레지스트리** | `prompts` | 052 + 053 + **059** | VLM/Text prompt DB 관리. situation 별 active 1개 유지 (partial unique index). `src/lib/prompts/registry.ts` 로 fetch (5 min cache + in-flight dedup). Admin 편집 가능 (/admin/prompts). 059: brand-vlm v1 row 추가 (gpt-4o-mini, 5-image multimodal, NODES_BLOCK/NODE_CODES/BRAND_NAME placeholders) |
| **API 로깅** | ~~`api_access_logs`~~ | —→**089 드롭** | **migration 089 DROP** — writer(/api/analyze) 제거로 dead (코드 0참조) |
| **검색 디버거** | `search_debug_runs` | **083** | 어드민 v6 search-debugger Run 스냅샷. mode/query/image_url/filters/steps/response(jsonb) + rating(1-5)/notes/tags. 어드민 간 공유 (RLS 없음, requireApprovedAdmin 게이트). |
| **크롤 통계** | `crawl_platform_stats` | **078** | 플랫폼별 SKU 카운트 + 최근 크롤 타임스탬프 집계 뷰. `/admin/crawl` 페이지가 소비. |

---

## Postgres 확장 / 인덱스 현황 (SPEC-SEARCH-V6-001 P0 이후)

### pgvector (027 + 031 + 071)

```sql
-- product_embeddings (071 — 활성 v6 ranking 인덱스)
CREATE INDEX idx_product_embeddings_hnsw
  ON product_embeddings USING hnsw (embedding halfvec_cosine_ops)
  WITH (m = 16, ef_construction = 200);

-- ⚠️ products.embedding / embedding_model / embedded_at + idx_products_embedding_pending
--    은 migration 086 (2026-05-22) 에서 DROP됨. 임베딩 단일 출처 = product_embeddings (071).
--    배치 pending 판별도 products.embedding IS NULL → product_embeddings anti-join 으로 전환.
```

> **069 DROP:** `idx_products_embedding_hnsw` (027 products HNSW), `idx_products_embedding_pending` (027 부분인덱스), `product_embedding_coverage` VIEW — 모두 071 에서 `product_embeddings` 기준으로 재작성됨.

### pgroonga

```
⚠️ idx_products_pgroonga_search (027) + product_search_text(products) 함수 — 069 에서 CASCADE DROP.
사유: 유일 소비자 search_products_v5 가 동일 마이그에서 DROP됨 (dead infra).
v6 는 cosine-first 랭킹 — pgroonga 풀텍스트 미사용.
```

### GIN

```sql
CREATE INDEX idx_products_tags_gin ON products USING gin (tags);
```

---

## RPC 함수

| 함수 | 시그니처 | 용도 |
|---|---|---|
| `bulk_update_product_embeddings(payload jsonb)` | returns int | `scripts/aws/embed_products.py` 가 배치 인코딩 결과를 **product_embeddings** 로 bulk UPSERT (071 rework — bigint product_id, ON CONFLICT DO UPDATE). 구 products.embedding 대상 버전은 **069 에서 DROP** |
| `repair_product_image_assets(repairs jsonb)` | returns int | **110 + 111** — optimistic `before_url` 가드로 확인된 쓰레기 URL을 모든 이미지 필드에서 제거하고 정상 대표를 `image_url`/`images[0]`으로 승격한다. 111에서 app_user에 광범위한 products UPDATE 권한을 주지 않는 제한적 SECURITY DEFINER로 보강 |
| `record_product_image_failure(...)` / `clear_product_image_failure(...)` | returns int | **110 + 112** — 이미지 실패 횟수·분류·재시도 시각 기록 및 성공 후 해제. 112에서 실제 임베딩 연결 역할 `ai_user`용 최소권한 SECURITY DEFINER로 보강 |
| `search_products_v6(query_embedding halfvec, p_style_node_id bigint, p_category text, p_subcategory text, p_brand_names text[], p_limit int)` | returns table(id bigint, brand, name, price, image_url, product_url, platform, subcategory, distance, degraded) | **072** — v6 embedding-first 검색 RPC. FILTER 1 EXACT primary_style_node_id → FILTER 2 category family gate (073) + in_stock + product_embeddings row → cosine `<=>` DESC, created_at tie. 0건 시 degraded fallback (category-only, degraded=true). |
| ~~`search_products_v5(vector/halfvec, ...)`~~ | — | **069 DROP** (uuid 시그니처 stale) |
| ~~`product_search_text(products)`~~ | — | **069 CASCADE DROP** (pgroonga 인덱스 의존 — dead infra, 유일 소비자 search_products_v5 가 069 에서 제거됨) |
| ~~`set_hnsw_ef_search(ef int)`~~ | — | **044 드랍** — 호출 0 hits, A/B 실험용 잔재 |
| ~~`get_product_filter_counts()`~~ | ~~returns table~~ | **migration 074 에서 DROP됨** (feature/redesign-admin). 069 PAI DROP 후 런타임 throw 상태 청산. `count_products_by(p_column text)` (074) 로 대체 — platform/category 두 차원 GROUP BY 집계. |
| `count_products_by(p_column text)` | returns table(value text, count bigint) | **074** — 어드민 상품 필터 옵션 fast-path. platform / category 컬럼 집계. `app_user` EXECUTE 권한 부여됨 |
| `product_refresh_source_stats()` | returns table(platform_key text, product_count bigint) | **094** — `products.platform`별 보유 행 수. source 단위 갱신 워크리스트 구성에 사용 |
| `claim_product_refresh_candidates(p_limit int, p_max_attempts int)` | returns setof product_refresh_candidates | **094** — `FOR UPDATE SKIP LOCKED`로 기존 브랜드 신규상품 후보를 원자적으로 claim하고 stale worker를 복구 |
| `activate_prompt(p_id bigint)` | returns prompts | **054** — atomic activate: 동일 situation 의 기존 active row deactivate + 대상 row activate 를 단일 트랜잭션으로 처리. race 조건(unique partial index 위반) 방지. SECURITY DEFINER. `app_user` EXECUTE 권한 부여됨 |
| `classify_brand_acquire(p_brand_id bigint, p_force boolean)` | returns table (id, brand_name, primary_node_id, skip_reason) | **060** — `/api/internal/classify-brand` 진입 가드. SELECT FOR UPDATE + conditional UPDATE sentinel(node_assigned_at). skip_reason NULL=진행 / 'already_classified' / 'recently_assigned'(60초 내). `app_user` EXECUTE 권한 부여됨 |
| `enqueue_brand_review(p_brand_id bigint, p_reason text, p_vlm_output jsonb)` | returns bigint | **060** — brand_node_review_queue atomic upsert. partial unique index (brand_id WHERE resolved_at IS NULL) 와 함께 open row 1건 보장. `app_user` EXECUTE 권한 부여됨 |

### 모니터링 뷰

> ⚠️ **`product_embedding_coverage` VIEW + `brand_sku_counts` MATVIEW + `node_centroids` 테이블은 migration 085 (2026-05-22) 에서 DROP됨** (코드 0참조). 아래 정의는 이력 참고용. 임베딩 진척 확인은 `SELECT count(*) FROM product_embeddings` vs `products` 로 대체.

```sql
-- [DROPPED 085] 071 rework: product_embeddings LEFT JOIN 기준
CREATE VIEW product_embedding_coverage AS
SELECT p.platform,
       count(*)                                                AS total,
       count(pe.product_id)                                    AS embedded,
       round(100.0 * count(pe.product_id) / nullif(count(*),0), 2) AS pct_embedded,
       max(pe.embedded_at)                                     AS last_embedded_at
  FROM products p
  LEFT JOIN product_embeddings pe ON pe.product_id = p.id
 GROUP BY p.platform ORDER BY total DESC;
```

---

## RLS 정책

| 테이블 | 정책 |
|---|---|
| `admin_profiles` | own-row SELECT 정책 필수 — 없으면 middleware가 null 받아서 무한 리다이렉트 (중요한 함정) |
| `instagram_post_scrapes`, `instagram_post_scrape_images` | RLS deny-all — service role만 접근. 메인 플로우는 service role 클라이언트로 INSERT/SELECT |
| 그 외 대부분 | RLS off — 애플리케이션 레벨에서 service role / anon 분리로 통제 |

---

## 마이그레이션 인벤토리 (1~29)

| 번호 | 추가/변경 |
|---|---|
| 001 | `analyses` |
| 002 | brand_nodes 정규화 |
| 003 | style_node 컬럼 |
| 004 | `products` 테이블 |
| 005 | category, sale 컬럼 |
| 006 | subcategory, color hex |
| 007 | brand_nodes v2 업그레이드 |
| 008 | constraints + indexes |
| 009 | admin tables |
| 010 | brand attributes |
| 011 | products 상세 컬럼 + analyses prompt_text |
| 012 | `product_ai_analysis` |
| 013 | eval golden set 확장 |
| 014 | `search_quality_logs` |
| 015 | eval_reviews pin version |
| 016 | analyses.is_pinned |
| 017 | season + pattern enums |
| 018 | data cleansing |
| 019 | `product_reviews` |
| 020 | rating 컬럼 드랍 |
| 021 | analysis_sessions + user_feedbacks |
| 022 | admin_profiles |
| 023 | admin_profiles RLS |
| 024 | admin_profiles search_path |
| 025 | instagram scrapes (구 /dna 용 — 029에서 드랍) |
| 026 | get_product_filter_counts() RPC |
| **027** | **v5 인프라 — pgvector + pgroonga + HNSW + bulk RPC + coverage view** |
| 028 | instagram_post_scrapes (메인 플로우용) |
| 029 | 구 /dna 용 instagram_scrapes 드랍 |
| **033** | **v6 평가 인프라 — eval_golden_queries + eval_judgments + eval_runs + RLS + frozen baseline trigger** |
| **037** | **brand_nodes.embedding vector(1024) + HNSW** — BGE-m3 텍스트 임베딩 |
| **038** | **brand_similar** — 브랜드 유사도 그래프 (cosine, top-20 per brand) |
| **039** | **brand_attribute_proposals** — LLM 메타 추론 검수큐 (admin RLS) |
| **040** | **brand_nodes.aliases** — 브랜드 별칭 배열 |
| **041** | brand_nodes 컬럼 NOT NULL 완화 (style_node / sensitivity_tags / brand_keywords / gender_scope) |
| **042** | brand_sku_counts VIEW + UMAP layout cache 컬럼 (x_umap / y_umap) |
| **043** | brand_sku_counts → MATERIALIZED VIEW (perf 개선) |
| **044** | **legacy 5종 drop** — item_search_results 테이블, set_hnsw_ef_search() 함수, rls_auto_enable event trigger, handle_new_admin_user() 함수, brand_nodes.platform 컬럼 |
| **045** | **product_ai_analysis v6 axis 8 컬럼** — neckline/sleeve/length/closure/texture/decoration/silhouette/formality + 복합 btree 인덱스 8종 |
| **046** | 모든 테이블/컬럼 한글 COMMENT 부여 |
| **047** | pgcrypto extension drop (gen_random_uuid → PG 내장 함수로 대체) |
| **048** | **eval 4 테이블 drop** — eval_golden_queries / eval_golden_set / eval_judgments / eval_runs + prevent_frozen_v4_baseline_overwrite 함수. eval_reviews 는 유지 |
| **049** | **`style_nodes` 테이블** — code(PK), name_en, name_ko, mood, include_rule, exclude_rule, keywords_en[], keywords_ko[], is_active, created_at, updated_at |
| **050** | **`style_nodes` 20-node seed** — A~T 코드 초기 데이터 삽입 (Fashion Genome taxonomy 이전) |
| **051** | **`style_node_adjacency` 테이블** — source_code, target_code, weight (빈 테이블 — SPEC-BRAND-EMBED-001 이 채울 예정) |
| **052** | **`prompts` 테이블** — situation/version (composite natural key), is_active (partial unique index: 1 active per situation), system_md, user_md, placeholders jsonb, model_id, max_tokens, temperature, notes, created_by, updated_at. `style_nodes_set_updated_at()` 트리거 재사용 |
| **053** | **`prompts` 초기 seed** — vision-analyze v1 (이미지 분석) + prompt-search v1 (텍스트 검색) 2 row active 삽입. 옛 analyze.ts / prompt-search.ts 하드코딩 template 이전 |
| **054** | **`activate_prompt(bigint)` PL/pgSQL 함수** — SECURITY DEFINER, atomic activate (siblings deactivate + self activate). `app_user` EXECUTE 권한 부여 |
| **055** | **`brand_nodes` 노드 매핑 컬럼 추가** — primary_node_id / secondary_node_id (FK → style_nodes.id), node_confidence numeric(3,2), node_assigned_at, node_assigned_model, representative_image_urls text[]. 인덱스: idx_brand_nodes_primary/secondary. **`brand_node_review_queue` 신설** — reason enum(insufficient_images/low_confidence/multi_node_conflict/vlm_failed), partial unique open 1건 per brand. SPEC-BRAND-NODE-001 P2a |
| **056** | **`brand_nodes.id` uuid → bigserial 전환** — brand_similar/brand_attribute_proposals/brand_node_review_queue FK 동기 bigint swap. `pg_trgm` CREATE EXTENSION (crawler alias fuzzy match). sequence rename (id_new_seq → id_seq). review_queue.reason 에 `alias_candidate` 추가. SPEC-BRAND-NODE-001 PR-X |
| **059** | **`prompts` brand-vlm v1 seed** — situation='brand-vlm', model='gpt-4o-mini', max_tokens=800, temperature=0.0. system 2,275자 (5-image 브랜드 감도 분류 + taxonomy 주입). placeholders: NODES_BLOCK(style_nodes), NODE_CODES(style_nodes), BRAND_NAME(runtime). SPEC-BRAND-NODE-001 P2b |
| **060** | **classify_brand_acquire + enqueue_brand_review PL/pgSQL 함수** — `classify_brand_acquire(bigint, boolean)`: SELECT FOR UPDATE + 60초 mutex sentinel. `enqueue_brand_review(bigint, text, jsonb)`: partial unique upsert. 양 함수 `app_user` EXECUTE 권한 부여. SPEC-BRAND-NODE-001 P3' |
| **067** | **brand_nodes 슬림화 + price USD 전환** — 13 컬럼 DROP: representative_image_urls / category_type / aliases / sensitivity_tags / brand_keywords / embedding / embedding_model / embedding_text_hash / embedded_at / x_umap / y_umap / umap_at / price_band. 관련 인덱스 cascade 삭제. price_min_usd / price_max_usd (numeric) 신규. products 기준 USD backfill (정적 FX: KRW 1/1370, GBP 1.27, EUR 1.07, JPY 1/156, CNY 1/7.2). price_band 파싱 fallback. |
| **068** | **ai 스키마 app_user READ-ONLY GRANT** — `GRANT USAGE ON SCHEMA ai TO app_user; GRANT SELECT ON ALL TABLES IN SCHEMA ai TO app_user; ALTER DEFAULT PRIVILEGES FOR ROLE ai_user IN SCHEMA ai GRANT SELECT ON TABLES TO app_user`. ai-server(ai_user 소유) 테이블을 어드민 `/admin/ai-insights` 에서 read-only 조회. |
| **069** | **SPEC-SEARCH-V6-001 P0 (1/3) — dead/PAI/blocker DROP** — `product_ai_analysis` DROP CASCADE (012 테이블+인덱스+017/045 컬럼). `search_products_v5` DROP (vector+halfvec 오버로드 2개, 030/031). `product_search_text(products)` DROP CASCADE → `idx_products_pgroonga_search` (027 pgroonga 풀텍스트, dead infra) 동반 제거. 027/031 products 임베딩 자산 DROP (HNSW idx, pending 부분인덱스, VIEW, bulk_update_product_embeddings RPC) — 071 에서 product_embeddings 기준 재생성. |
| **070** | **SPEC-SEARCH-V6-001 P0 (2/3) — products.id uuid→bigserial** — 056 검증 템플릿. FK swap 표면 = `product_reviews.product_id` 단일 (PAI 069 DROP, product_embeddings 071 에서 처음부터 bigint). 옛 uuid 미보존. `products_id_seq` 시퀀스 rename. |
| **071** | **SPEC-SEARCH-V6-001 P0 (3/3) — `product_embeddings` 테이블 생성** — `product_id bigint PK FK → products.id ON DELETE CASCADE`, `embedding halfvec(768)`, HNSW `halfvec_cosine_ops` (직렬 빌드 강제: `SET LOCAL max_parallel_maintenance_workers=0`). 기존 `products.embedding` 전량 backfill (~71k rows). 027/031 자산 전부 `product_embeddings` 기준 rework (HNSW 인덱스·pending 부분인덱스·coverage VIEW·bulk_update_product_embeddings RPC). |
| **072** | **SPEC-SEARCH-V6-001 P1 — `search_products_v6` RPC** — embedding-first 검색 함수. FILTER 1 EXACT `primary_style_node_id` → FILTER 2 `category_canonical` family gate (073) + `in_stock + product_embeddings row` → cosine `<=>` DESC, `created_at` tie. 0건 시 degraded fallback (category-only cosine, `degraded=true`). `p_brand_names` 로 strong/general 분기. |
| **073** | **SPEC-SEARCH-V6-001 follow-up — `category_canonical` 테이블 + search_products_v6 FILTER 2 개선** — 752 distinct `products.category` 값 → 20 canonical family 매핑. method B (family equality gate) + F (relaxation ladder: node+family → node-drop → both-drop) + A (lower/trim normalize). Vision-normalize cross-component 공유 계약. |
| **074** | **SPEC-SEARCH-V6-001 P5 audit 청산 — `get_product_filter_counts()` DROP** (069 PAI DROP 후 런타임 throw 상태였던 함수 제거). `count_products_by(p_column text)` RPC 신설 (platform/category GROUP BY, `app_user` EXECUTE 권한). |
| **075** | **`prompts` brand-attributes v1 seed** — situation='brand-attributes', 12-dimension JSON extraction prompt (vibe/palette/material/silhouette/detail/pattern/gender_lean/formality/price_tier/era_reference/subculture/confidence). nova-lite Vision 기반. |
| **076** | **`brand_multimodal_umap` 클러스터 테이블** — UMAP 2D scatter 관련 클러스터 메타데이터 (brand-clusters 어드민 상세 패널용). |
| **078** | **`crawl_platform_stats` 집계 뷰** — 플랫폼별 SKU 카운트 + 최근 크롤 타임스탬프. `/admin/crawl` 크롤 모니터 페이지가 소비. |
| **079** | **`products.material` 컬럼 DROP** — 크롤러에서 채우지 않는 dead 컬럼 제거. |
| **080** | **`brand_similar` 그래프 DROP** — BGE-m3 텍스트 임베딩 기반 42k edge 그래프. `brand_multimodal_embeddings` + `find_similar_brands` RPC(063~066)로 완전 대체. |
| **081** | **`products.style_node` 레거시 컬럼 + 인덱스 + CHECK constraint DROP** — 004(컬럼+인덱스) + 008(chk_products_style_node) 자산 제거. 118k rows 중 265행만 채워진 dead data (v6 embedding-first는 product-level 라벨 미사용). |
| **082** | **`search_products_v6` category JOIN verbatim 정정** — 3 곳의 `lower(trim(cc.raw_category)) = lower(trim(p.category))` → `cc.raw_category = p.category`. category_canonical seed 가 verbatim 1:1 매핑이므로 정규화 불필요. 동일 normalize 값 N개 매칭 → N배 fanout 버그 수정 (중복 product_id 반환 증상). |
| **083** | **`search_debug_runs` 테이블** — 어드민 v6 search-debugger Run 히스토리. mode(text/image/fused)/query_text/image_url/source_url/filters/steps(jsonb)/response(jsonb)/rating(1-5)/notes/tags(text[]). 인덱스: created_at DESC + rating + tags GIN. |
| **084** | **`brand_nodes.wiki jsonb` 컬럼 추가 (SPEC-BRAND-WIKI-001 P1)** — 브랜드 위키 메타데이터를 단일 jsonb 컬럼에 namespace 묶음. 기존 `attributes`(VLM 결과)와 완전 분리. 신규 컬럼만 추가 — 기존 데이터 무변경. 인덱스 3종: `idx_brand_nodes_wiki_country` (origin_country 클러스터링), `idx_brand_nodes_wiki_ig` (instagram_handle lookup), `idx_brand_nodes_wiki_status` (admin 검수 필터). |
| **085** | **안 쓰는 객체 정리 (2026-05-22)** — 코드 0참조 + 라이브 DB 교차검증 후 DROP: `analyses.sensitivity_tags` 컬럼(v4 잔재), `brand_sku_counts` MATERIALIZED VIEW(0참조, 크롤모니터는 `admin_crawl_platform_stats()` 사용), `product_embedding_coverage` VIEW(모니터링 dead view), `node_centroids` 테이블(8행, dormant 인접그래프 파생값). `style_node_adjacency`는 유지(SPEC-BRAND-EMBED-001 대기). 외부 의존 0. |
| **086** | **`products` 레거시 임베딩 컬럼 DROP (2026-05-22)** — `embedding` / `embedding_model` / `embedded_at` + `idx_products_embedding_pending` 제거 (~109MB stale). 071에서 `product_embeddings`로 이전 완료된 잔존 자산. ⚠️ aws-infra 임베딩 배치(`batch_embed_full.py` / `embed_batch_devapp.py`) pending 판별을 `products.embedding IS NULL` → `product_embeddings` anti-join으로 동시 전환(부수효과: stale sentinel 발 ~47k 중복 재임베딩 해소). |
| **087** | **admin 전용 전환 — 공개플로우 테이블 DROP (2026-05-22)** — `instagram_post_scrape_images` / `instagram_post_scrapes` / `search_quality_logs` / `user_feedbacks` / `analysis_sessions` DROP. 공개 IG 메인플로우 + analytics/user-voice 어드민 코드 제거에 동반. FK 없음 확인. `analyses`/`analysis_items`는 `/admin/eval` 가 읽어 유지(신규 write 없음). |
| **088** | **`analyses` 레거시 세션 컬럼 DROP (2026-05-22)** — 087 follow-up. `session_id` / `parent_analysis_id` / `refinement_prompt` / `sequence_number` 제거 (analysis_sessions 제거 후 dangling, 코드 0참조). |
| **089** | **/admin/eval 제거 — analyses 클러스터 DROP (2026-05-22)** — `api_access_logs` / `analysis_items` / `eval_reviews` / `analyses` DROP. writer(/api/analyze) 제거로 신규 데이터 0 → eval dead-end. eval 페이지/API/컴포넌트 전부 제거 동반. FK 순서: incoming 3개 → analyses. |
| **090** | **product collection queue** — `product_crawl_status` / `product_crawl_runs` 기반 brand_node별 상품 수집 큐와 상태 이력. |
| **091** | **`products.gender` 필수화** — `brand_nodes.gender_scope` 로 가능한 기존 상품 backfill 후 `chk_products_gender_required` CHECK (`NOT VALID`) 추가. 신규/수정 상품은 `gender` 배열이 비어 있으면 적재 불가. |
| **094** | **source 단위 상품 갱신 큐** — `product_refresh_sources` / `product_refresh_runs` / `product_refresh_candidates`, source별 상품 수 RPC, 신규상품 LLM worker claim RPC. 갱신은 기존 상품의 가격·재고만 직접 수정하며 `brand_nodes`를 생성하지 않음. |
| **095** | **`product_features` 읽기 경로 (2026-07-29)** — 실물만 있고 코드에 없던 VLM 피처 테이블을 `CREATE TABLE IF NOT EXISTS` 로 기록. `idx_pf_primary_color` / `idx_pf_gender` **표현식 btree** 추가 — 기존 `jsonb_path_ops` GIN 은 `->>` 등치 비교를 못 탄다. `chk_pf_gender_vocab` CHECK(`NOT VALID`)로 `men\|women\|unisex` 어휘 고정. |
| **096** | **`products.gender` 필수 CHECK 해제 (2026-07-29)** — **091 을 되돌린다.** gender 의 단일 출처가 VLM `product_features` 로 이관돼 크롤러가 gender 를 만들지 않으므로, `chk_products_gender_required` 가 있으면 신규 상품 INSERT 자체가 실패한다. 컬럼에 DEPRECATED 코멘트. `search_products_v6`/curation/PDP 는 VLM → `products.gender` → fail-open 3단 다리로 읽는다. |
| **100** | **후보 claim RPC 에 origin_country 필터 (2026-08-01)** — `claim_product_refresh_candidates(p_limit, p_max_attempts, p_origin_country)`. 후보 큐 75,404건 중 KR 58,917(78%)이고 운영 방침이 한국 브랜드 우선인데 워커가 origin 구분 없이 집어 비KR 16,487건에도 LLM 비용을 쓰고 있었다. 필터를 클라이언트에 둘 수 없다 — 이 함수가 행을 고르는 자리에서 곧바로 `status='enriching'` 으로 잠그기 때문에, 받아서 거르면 이미 claim 된 뒤이고 되돌리면 다음 claim 이 같은 행을 또 집는다. DEFAULT 를 가진 3-arg 를 추가만 하면 2-arg 와 공존해 호출이 모호해지므로(function is not unique) 2-arg 를 DROP 한다. `p_origin_country IS NULL` 이면 필터 없음 = 기존 동작. |
| **105** | **브랜드 설명 일반 컬럼 분리 (2026-08-06)** — `brand_nodes.description text` 추가. 기존 값이 없을 때 `wiki.description_ko` → `wiki.description_original` 순으로 backfill하고 두 JSON 키를 제거한다. 설명의 서비스/API 정본은 일반 컬럼이며 `wiki`는 출처·설립 정보 등 enrichment 메타만 보관한다. |
| **099** | **`products.color` NOT NULL 해제 (2026-08-01)** — VLM 이관 뒤 크롤러가 color 를 쓰지 않아 신규상품 INSERT 가 막히던 문제를 해소한 과도기 마이그레이션. 컬럼 자체는 107 에서 제거. |
| **110** | **대표 이미지 SOT·실패 격리 (2026-08-16)** — `products.image_url`을 serving/search/embedding 단일 출처로 고정. 대표 변경 트리거가 `product_embeddings`/`product_features`/옛 실패 상태를 무효화한다. `product_image_failures`와 repair/record/clear RPC로 영구 404 반복, 쓰레기 URL 잔존, `images[0]` 우선 임베딩을 제거한다. |
| **111** | **이미지 repair 최소권한 보강 (2026-08-16)** — direct DB `app_user`가 products UPDATE 권한 없이도 승인된 repair RPC만 실행하도록 `repair_product_image_assets`와 파생 자산 무효화 trigger function을 SECURITY DEFINER로 전환하고 PUBLIC EXECUTE를 회수한다. |
| **112** | **이미지 실패 기록 최소권한 보강 (2026-08-16)** — 실제 임베딩 DSN 역할인 `ai_user`에 repair/record/clear RPC만 명시적으로 허용하고 failure record/clear를 SECURITY DEFINER로 전환한다. products 또는 파생 테이블의 광범위한 쓰기 권한은 부여하지 않는다. |
| **098** | **`products.product_url` 중복 UNIQUE 제약 정리 (2026-07-31)** — 같은 컬럼에 `products_product_url_key` 와 `uq_products_product_url` 이 동시에 걸려 인덱스가 이중(각 29 MB)으로 유지되고 있었다. 저장공간 29 MB + `product_url` 쓰기마다 인덱스 2개 갱신. 008 이 명시적으로 만든 `uq_products_product_url` 을 남기고, 어느 마이그에도 정의가 없는(070 테이블 재구축 잔재로 추정) 자동 명명 제약을 DROP. FK 4개는 모두 `products.id` 를 보므로 무영향, PostgREST upsert(onConflict=product_url)도 컬럼 기준이라 그대로 동작. |
| **097** | **`product_features` 커버리지 뷰 (2026-07-30)** — `product_features_coverage`(플랫폼별 진행률 + `with_gender`) + `product_features_pending`(VLM 배치가 소비할 대기열). 131,058행이 단일 벌크로 생성됐고 증분 경로가 없어, features 없는 상품이 색상 필터에서 완화 없이 탈락하는 것을 가시화·해소하기 위한 것. 추가 전용(뷰 2개). |
| **107** | **`products.color` DROP (2026-08-14)** — 크롤러 원본 색상 컬럼과 남은 직접 조회를 제거. `admin_crawl_platform_stats.fill_color` 응답 계약은 유지하되 `product_features.feature_metadata->>'primary_color'` 커버리지를 집계한다. |
| **118** | **상품 카탈로그 후처리 큐** — products 신규·동일성·이미지 변경을 `product_catalog_jobs`에 generation-fenced upsert하고 claim/complete/retry RPC를 제공한다. |

---

## DB 클라이언트

| 파일 | 키/드라이버 | 사용처 |
|---|---|---|
| `src/lib/supabase.ts` | PostgREST service JWT (`@supabase/supabase-js` 클라이언트, 엔드포인트는 dev-app nginx shim) | API Routes — DB 쓰기/관리 작업 |
| `src/lib/db.ts` | pg Pool (`DATABASE_URL`) | Auth.js Credentials Provider — `admin_profiles` 직접 조회 (P3). **ai 스키마 직접 raw SQL** — `/api/admin/ai-insights` 가 `ai.card_impression` / `ai.log_conversation_event` / `ai.user_session` 조회 (068 GRANT 후, SELECT-only) |
| ~~`src/lib/supabase-server.ts`~~ | ~~anon (SSR 쿠키)~~ | **삭제됨** — Auth.js 전환 후 폐기 (SPEC-INFRA-MIGRATE-001 P3) |
| ~~`src/lib/supabase-browser.ts`~~ | ~~anon (브라우저)~~ | **삭제됨** — 동일 이유 |

자세한 패턴: `docs/PATTERNS.md` 의 "DB 클라이언트" 섹션.

---

## Brand Graph 테이블 (2026-05-10, migrations 037~043 + 055~056)

### brand_nodes (주요 컬럼 — migration 067 후 현행)

> ⚠️ **067 (2026-05-15) 에서 13 컬럼 삭제됨.** 아래는 현재 존재하는 컬럼만 기재.

| 컬럼 | 타입 | 설명 |
|---|---|---|
| **id** | **bigserial** | **PK — 056 에서 uuid → bigserial 전환 (2026-05-14)** |
| ~~embedding~~ | ~~vector(1024)~~ | **067 DROP** — BGE-m3 텍스트 임베딩 (037 자산). `brand_multimodal_embeddings` 로 대체 |
| ~~aliases~~ | ~~text[]~~ | **067 DROP** |
| ~~x_umap / y_umap~~ | ~~float8~~ | **067 DROP** |
| ~~sensitivity_tags~~ | ~~text[]~~ | **067 DROP** |
| ~~brand_keywords~~ | ~~text[]~~ | **067 DROP** |
| ~~representative_image_urls~~ | ~~text[]~~ | **067 DROP** — `products.is_brand_representative` 가 source of truth |
| ~~category_type~~ | ~~text~~ | **067 DROP** |
| ~~price_band~~ | ~~text~~ | **067 DROP** — price_min_usd / price_max_usd 로 대체 |
| primary_style_node_id | bigint | FK → style_nodes.id. brand 1차 감도 (055, VLM 배정. 062에서 `primary_node_id`→현재명 리네임) |
| secondary_style_node_id | bigint | FK → style_nodes.id. brand 2차 감도 (055) |
| style_node_confidence | numeric(3,2) | VLM 출력 confidence 0-1 (< 0.7 이면 review queue 자동 분기) (055) |
| style_node_assigned_at | timestamptz | VLM 배정 시각 (055) |
| style_node_assigned_model | text | VLM 모델 ID 추적 (055) |
| price_min_usd | numeric | USD 환산 최저가 (067 신규). products 기준 backfill 또는 어드민 수동 입력 |
| price_max_usd | numeric | USD 환산 최고가 (067 신규) |
| description | text | 서비스/API에 노출하는 브랜드 설명 정본 (105 신규). 기존 `wiki.description_ko` 우선, `wiki.description_original` 폴백으로 이관 |
| wiki | jsonb | 브랜드 위키 enrichment 메타 (084 신규, 105 설명 키 제거). 필드: `instagram_handle`, `instagram_url`, `homepage_url`, `founder text[]`, `founded_year smallint`, `origin_country char(2)`, `sources jsonb[]`, `confidence`, `status` (ok/review/no_data), `review_reasons`, `enriched_at`, `schema_version`. attributes(VLM 결과)와 분리. 인덱스: `idx_brand_nodes_wiki_country` (origin_country) / `idx_brand_nodes_wiki_ig` (instagram_handle) / `idx_brand_nodes_wiki_status` (status). |

### brand_similar ⚠️ DROPPED (migration 080)

> **migration 080 (2026-05-21) 에서 DROP됨.** BGE-m3 텍스트 임베딩 기반이었으나 067에서 `brand_nodes.embedding` 삭제 후 재계산 불가. `brand_multimodal_embeddings` + `find_similar_brands` RPC (065) 로 대체. 아래는 이력 참고용.

| 컬럼 | 타입 | 설명 |
|---|---|---|
| brand_id | int8 | FK → brand_nodes.id |
| similar_brand_id | int8 | FK → brand_nodes.id |
| score | float8 | cosine similarity (BGE-m3 기반) |
| created_at | timestamptz | — |

top-20 per brand 기준 약 42,000 edges. `(brand_id, similar_brand_id)` UNIQUE.

### brand_attribute_proposals

| 컬럼 | 타입 | 설명 |
|---|---|---|
| id | uuid | PK |
| brand_id | int8 | FK → brand_nodes.id |
| attribute_key | text | 속성 이름 (vibe, palette, material, sensitivity 등) |
| proposed_value | text | LLM 추론 값 |
| confidence | float8 | 0.0~1.0 (≥ 0.85 auto / 0.7~0.85 pending / < 0.7 폐기) |
| status | text | `auto` / `pending` / `approved` / `rejected` |
| created_at | timestamptz | — |

RLS admin-only. 어드민 `/admin/brand-proposals` 에서 일괄 승인/거절.

### brand_node_review_queue (migration 055)

VLM 분류 실패/저신뢰/충돌/image 부족 케이스를 admin 수동 검수로 보내는 큐.

| 컬럼 | 타입 | 설명 |
|---|---|---|
| id | bigserial | PK |
| brand_id | bigint | FK → brand_nodes.id ON DELETE CASCADE (056 에서 uuid → bigint 전환) |
| reason | text | `insufficient_images` / `low_confidence` / `multi_node_conflict` / `vlm_failed` / `alias_candidate` |
| vlm_output | jsonb | VLM raw response (있으면) |
| admin_note | text | 관리자 메모 |
| resolved_at | timestamptz | NULL이면 미처리 open |
| resolved_by | text | 처리자 |
| created_at | timestamptz | — |

open(resolved_at NULL) 1건 한도 per brand (partial unique). resolved row 는 이력 보존.

### brand_sku_counts (MATERIALIZED VIEW, migration 043)

브랜드별 SKU 카운트 캐시. `REFRESH MATERIALIZED VIEW CONCURRENTLY brand_sku_counts` 로 갱신.

---

## ai 스키마 (migration 068, 2026-05-15)

`ai` 스키마는 **`endurance-ai/ai-server`** (Python FastAPI + Alembic) 가 소유(`ai_user`). kiko.ai Next.js 앱은 **read-only** (`app_user` SELECT 권한, migration 068).

어드민 `/admin/ai-insights` (`GET /api/admin/ai-insights`) 가 `src/lib/db.ts` pg Pool 로 ai schema-qualified SQL 직접 쿼리.

| 테이블 | 역할 |
|---|---|
| `ai.card_impression` | 대화형 봇이 추천 카드를 노출·클릭한 이력 (CTR 통계 원본) |
| `ai.log_conversation_event` | 대화 이벤트 시계열 (user_text/bot_text/intent_routed/search_done 등) + latency_ms |
| `ai.user_taste_profile` | 사용자 취향 프로필 (누적 학습) |
| `ai.user_session` | 현재 진행 중 세션 스냅샷 (chat_id PK, TTL 기반 1 row per user) |

> `ai_user` 가 향후 만드는 신규 테이블도 `ALTER DEFAULT PRIVILEGES` 로 `app_user` 자동 SELECT.
> kiko.ai 는 쓰기 경로 없음 — 어드민 통계 조회 전용.

---

## eval_golden_queries / eval_judgments / eval_runs ⚠️ ALL DROPPED (migration 048)

> **이 3개 테이블(+`eval_golden_set`)은 migration 048 (2026-05-13) 에서 전부 DROP됨.** v4 NDCG/P@5 평가 시스템 폐기. 유지된 평가 테이블은 `eval_reviews` 뿐. 아래 3개 섹션은 모두 이력 참고용 — 현존하지 않음.

## eval_golden_queries (2026-05-04, migration 033) — DROPPED 048

검색 v6 평가용 골든셋 쿼리 카탈로그.

| 컬럼 | 타입 | 제약 |
|---|---|---|
| id | uuid | PRIMARY KEY DEFAULT gen_random_uuid() |
| instagram_url | text | NULL |
| query_signature | text | NULL |
| intent_note | text | NOT NULL |
| created_by | text | NOT NULL |
| created_at | timestamptz | NOT NULL DEFAULT now() |
| updated_at | timestamptz | NOT NULL DEFAULT now() |
| algorithm_version | text | NOT NULL DEFAULT 'v4' CHECK IN ('v4', 'v6') |

제약:
- `CONSTRAINT eval_golden_queries_identity_present CHECK (instagram_url IS NOT NULL OR query_signature IS NOT NULL)` — 최소 한 가지 식별자
- `CREATE UNIQUE INDEX eval_golden_queries_identity_unique ON eval_golden_queries (instagram_url, query_signature) NULLS NOT DISTINCT` — dual identity dedup (PostgreSQL 15+)
- RLS FOR ALL TO authenticated USING/WITH CHECK (EXISTS SELECT 1 FROM admin_profiles WHERE user_id = auth.uid() AND status = 'approved')

인덱스:
- `idx_eval_golden_queries_algo` ON (algorithm_version)

---

## eval_judgments (2026-05-04, migration 033)

사람 라벨링 — (golden_query × product × algorithm_version) 단위 relevance grade 0~3.

| 컬럼 | 타입 | 제약 |
|---|---|---|
| id | uuid | PRIMARY KEY DEFAULT gen_random_uuid() |
| golden_query_id | uuid | NOT NULL REFERENCES eval_golden_queries(id) ON DELETE CASCADE |
| product_id | uuid | NOT NULL REFERENCES products(id) ON DELETE CASCADE |
| relevance_grade | smallint | NOT NULL CHECK (relevance_grade BETWEEN 0 AND 3) |
| labeler_id | text | NOT NULL |
| labeled_at | timestamptz | NOT NULL DEFAULT now() |
| algorithm_version | text | NOT NULL CHECK IN ('v4', 'v6') |
| notes | text | NULL |

제약:
- `UNIQUE (golden_query_id, product_id, algorithm_version)` — 동일 조합 중복 방지
- RLS FOR ALL TO authenticated USING/WITH CHECK (admin_profiles.status='approved')

인덱스:
- `idx_eval_judgments_query_algo` ON (golden_query_id, algorithm_version)
- `idx_eval_judgments_product` ON (product_id)

relevance_grade 스케일: 0=irrelevant / 1=poor / 2=good / 3=excellent. 기존 eval_reviews.verdict (pass/fail/partial) 와 완전히 분리.

---

## eval_runs (2026-05-04, migration 033)

NDCG@10 / Precision@5 메트릭 스냅샷. golden_query_id NULL = 전체 쿼리 aggregate.

| 컬럼 | 타입 | 제약 |
|---|---|---|
| id | uuid | PRIMARY KEY DEFAULT gen_random_uuid() |
| golden_query_id | uuid | NULL REFERENCES eval_golden_queries(id) ON DELETE CASCADE |
| algorithm_version | text | NOT NULL CHECK IN ('v4', 'v6') |
| ndcg_at_10 | numeric(5,4) | NOT NULL CHECK (ndcg_at_10 BETWEEN 0 AND 1) |
| precision_at_5 | numeric(5,4) | NOT NULL CHECK (precision_at_5 BETWEEN 0 AND 1) |
| query_count | integer | NOT NULL CHECK (query_count >= 0) |
| judgment_count | integer | NOT NULL CHECK (judgment_count >= 0) |
| frozen | boolean | NOT NULL DEFAULT false |
| computed_at | timestamptz | NOT NULL DEFAULT now() |
| notes | text | NULL |

제약:
- RLS FOR ALL TO authenticated USING/WITH CHECK (admin_profiles.status='approved')

인덱스:
- `idx_eval_runs_algo_computed` ON (algorithm_version, computed_at DESC)

트리거 — `prevent_frozen_v4_baseline_overwrite()`:
- BEFORE INSERT ON eval_runs
- 조건: algorithm_version='v4' AND golden_query_id IS NULL AND 기존 frozen=true row 존재
- 동작: RAISE EXCEPTION 'baseline already frozen for v4 aggregate' USING ERRCODE = 'check_violation'
- SECURITY DEFINER + SET search_path = public, pg_temp (schema injection guard, migration 024 패턴)

메트릭 알고리즘 상세: `docs/features/search-engine.md` 의 "Evaluation Infrastructure" 섹션

SPEC: SPEC-V6-EVAL
