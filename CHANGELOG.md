# Changelog

## [0.4.0](https://github.com/kazi-org/kazi/compare/v0.3.0...v0.4.0) (2026-06-24)


### Features

* **authoring:** caller-drafts mode via a supplied :proposal (T15.2) ([5e09014](https://github.com/kazi-org/kazi/commit/5e090142fec242b9ff069b3a98e44605964e16c1))
* **bench:** 3-arm token-benchmark harness + pure capture/report core (T19.4) ([376022f](https://github.com/kazi-org/kazi/commit/376022fbbfb3ffc218f09abe6878ea8e1b5f4cfd))
* **cli:** --json for run --stream, status, list/approve/reject (T15.4/T15.5/T15.6) ([37729b5](https://github.com/kazi-org/kazi/commit/37729b5399f80547a8847de0ba41e0fc955af505))
* **cli:** --json output framework + non-interactive guarantee (T15.1) ([1495bd5](https://github.com/kazi-org/kazi/commit/1495bd54b2f5309967176f235ed0fb4bc17849f6))
* **cli:** help --json + schema for agent introspection (T16.1) ([2c1441e](https://github.com/kazi-org/kazi/commit/2c1441e5806fc2534d09652cb81f54426c91af18))
* **cli:** kazi lint near-duplicate group-name warning (T12.7) ([058da16](https://github.com/kazi-org/kazi/commit/058da1624ec59ce676c170c495d4b57c79c9900b))
* **cli:** propose --json with kazi-drafts + caller-drafts modes (T15.2) ([9764dd5](https://github.com/kazi-org/kazi/commit/9764dd54a8bacb304455f1dc6e38f83a828e7e6e))
* **cli:** run --json versioned result contract (T15.3) ([03d742a](https://github.com/kazi-org/kazi/commit/03d742aba1f512bed83b04139bdfd343bb47c562))
* **cli:** run --parallel routes to the parallel scheduler + --json collective contract (T21.8) ([0793327](https://github.com/kazi-org/kazi/commit/0793327880cc11c4d825775f98106677746a1899))
* **cli:** schedule reporting + run --explain dry-run (T23.6) ([436e332](https://github.com/kazi-org/kazi/commit/436e3328b881a006ff899b53e360e37aa27d2210))
* **cli:** schema-as-data for the versioned --json result schemas (T16.1) ([44c9b7d](https://github.com/kazi-org/kazi/commit/44c9b7debd8408ee640268bc236c6f3b67937d35))
* **cli:** wire `kazi install-skill` into the command table (T16.2) ([099c39c](https://github.com/kazi-org/kazi/commit/099c39cbdffad20a37d3363ae361f9166a1e2ebc))
* **cli:** wire kazi export --obsidian into the command table (T12.6) ([c6e86a6](https://github.com/kazi-org/kazi/commit/c6e86a652b2cb4e108cc8f4b66b34e157302a0fb))
* **export:** Obsidian vault renderer for the group tree (T12.6) ([843082c](https://github.com/kazi-org/kazi/commit/843082ccfab762bab94bbea5e73d8939ca326235))
* **goal:** add needs dependency edges to Group struct (T23.1) ([4a9148c](https://github.com/kazi-org/kazi/commit/4a9148c5ed2be2f2ef51ded374e9753814ac4e8b))
* **goal:** declared [[group]] taxonomy in the loader (T12.1) ([5048077](https://github.com/kazi-org/kazi/commit/50480776365493ded9fe8b8cb627b2074d817445))
* **goal:** dependency DAG ready-set + blocked-subDAG computation (T23.2) ([ae8922c](https://github.com/kazi-org/kazi/commit/ae8922c903323c8c432a8d2ec4682b05a5bc39b3))
* **goal:** derive per-group effective budget rollup (T12.4) ([bad36a1](https://github.com/kazi-org/kazi/commit/bad36a19d1d73f71a4d0751cb82b17f6ee611a55))
* **goal:** group tree + per-group status rollup (T12.3) ([9e859b8](https://github.com/kazi-org/kazi/commit/9e859b85f927436ad1723b5f9467ba3024551b83))
* **goal:** GroupLint near-duplicate group-name fuzzy compare (T12.7) ([639014e](https://github.com/kazi-org/kazi/commit/639014e1bc32fbed3f60e1ee71bf9d7be41d487c))
* **goal:** parse + validate the needs DAG in the loader (T23.1, ADR-0028) ([3f35855](https://github.com/kazi-org/kazi/commit/3f3585554476bb1670198a69956bae73303234b9))
* **goal:** validate group references and parent cycles in loader (T12.2) ([8567597](https://github.com/kazi-org/kazi/commit/856759794061b2cf67bbe1be9f8229fbda5778af))
* **harness:** claw-code profile (:claw, best-effort) (T14.4) ([253195c](https://github.com/kazi-org/kazi/commit/253195c67089b95f92a9d38de5222c972f29760c))
* **harness:** Codex CLI profile (:codex) argv + JSONL parse (T14.2) ([74b5aec](https://github.com/kazi-org/kazi/commit/74b5aecfac91b03ebb929f3a729b8d6423cf238d))
* **harness:** Google Antigravity profile (:antigravity) with non-TTY workaround (T14.3) ([56b6bf0](https://github.com/kazi-org/kazi/commit/56b6bf073b8487d26f13eec9d60931b69e3d9f80))
* **loop:** additive :orientation_prefix flag to disable the T19.1 prefix ([d3c2ce0](https://github.com/kazi-org/kazi/commit/d3c2ce0f08cd9b2cd9371d70665457e481805467))
* **loop:** stable-prefix ordering + truncate evidence on the live dispatch (T19.2/T19.3) ([f7019c0](https://github.com/kazi-org/kazi/commit/f7019c0754c10dbf883d148524c37c0ca101f38e))
* **loop:** wire the cached orientation pack into the live dispatch prefix (T19.1, realize T4.3) ([a0edcba](https://github.com/kazi-org/kazi/commit/a0edcba69e739dcd2003416e845df4d382ed707f))
* **mcp:** mix kazi.mcp entrypoint for the MCP stdio server (T16.5) ([67f846c](https://github.com/kazi-org/kazi/commit/67f846c9989d9f6d19605cc87ebe30ddefac3ed6))
* **mcp:** self-describing JSON-RPC server wrapping the kazi tools (T16.5) ([40ac946](https://github.com/kazi-org/kazi/commit/40ac9469be7cd48faa4aa6f36b6c49146d0d78df))
* **pool:** /claim&lt;-&gt;lease compose-boundary (claim-first, lease-second) (T20.7) ([993cdf1](https://github.com/kazi-org/kazi/commit/993cdf10402e7be80e4189a436233a566ed822fa))
* **pool:** acc_to_predicates runner script (T20.1) ([8aaee5d](https://github.com/kazi-org/kazi/commit/8aaee5d2a0ac0e922f58b6f80ee761642807fc17))
* **pool:** acc: -&gt; predicates bridge module (T20.1) ([2c75cc7](https://github.com/kazi-org/kazi/commit/2c75cc7e33cdd6f1dc55cfc28ea14d15320e112a))
* **pool:** block-unless-converged gate decision (T20.2) ([65af1e8](https://github.com/kazi-org/kazi/commit/65af1e8511974ae29ef024a183f51e72ca66efe6))
* **pool:** per-task blast-radius lease helper for a pooled run (T20.6) ([8b3f84a](https://github.com/kazi-org/kazi/commit/8b3f84a0ad9b50d81485b23377ad8a0df4194944))
* **predicate:** add optional group field (T12.2) ([9fe9572](https://github.com/kazi-org/kazi/commit/9fe9572e47fea8426379477f77510133ba1449c8))
* **reconcile:** Elixir surface scanner (T13.4) ([282ea3a](https://github.com/kazi-org/kazi/commit/282ea3a73c9f471b58d87c073e26bf7c60bb9758))
* **reconcile:** gherkin importer -&gt; grouped acceptance predicates (T13.2) ([c36378b](https://github.com/kazi-org/kazi/commit/c36378ba697a790ef668d38177fdda61f6bd9576))
* **reconcile:** OpenAPI importer -&gt; grouped http_probe predicates (T13.1) ([ae527a5](https://github.com/kazi-org/kazi/commit/ae527a51258d018e4704a0313e9731fdbf8e5322))
* **reconcile:** prose-doc importer via the harness (T13.3) ([3c39e5f](https://github.com/kazi-org/kazi/commit/3c39e5f08698077ccb87d750447624dfcccace6f))
* **reconcile:** surface-coverage meta-predicate (T13.5) ([fd52029](https://github.com/kazi-org/kazi/commit/fd52029ff26e8fb9d2ffcc3b1ddbebe56487a1ad))
* **runtime:** compose a per-iteration stream observer over persistence (T15.4) ([8049bb3](https://github.com/kazi-org/kazi/commit/8049bb376b5386bc489a05b0c6689b3bc5419719))
* **scheduler:** add DepGraph.dependents_of/2 for regression re-gating (T23.4) ([de37853](https://github.com/kazi-org/kazi/commit/de378536e8a3c2f6de5e9d675e56b1bc3b64dda0))
* **scheduler:** dynamic blast-radius overlap policy (T21.6) ([aa7bcb9](https://github.com/kazi-org/kazi/commit/aa7bcb9bd510ccc0015a2aa76d686c0dc391738a))
* **scheduler:** injectable collective integration + merge convergence (T21.5) ([b2e56f8](https://github.com/kazi-org/kazi/commit/b2e56f8e8302849114021fc89df8dd7e61fc4eec))
* **scheduler:** isolated git worktree per partition (T21.4) ([d7fcf54](https://github.com/kazi-org/kazi/commit/d7fcf54076eae0b9db7f7395c56bffe49c649844))
* **scheduler:** parallel coordinator + partition DynamicSupervisor (T21.1) ([fdf8fcb](https://github.com/kazi-org/kazi/commit/fdf8fcb034a51a45fa43a1561a8c21a526f97491))
* **scheduler:** per-partition budgets with derived rollup (T21.7) ([8c14403](https://github.com/kazi-org/kazi/commit/8c14403539fe6477c49fe7a62d23f81120ccde7f))
* **scheduler:** per-partition crash restart/escalation + integrate wiring (T21.10/T21.5) ([059f139](https://github.com/kazi-org/kazi/commit/059f1398a8f69f6db178c23356bf535d1586e448))
* **scheduler:** per-partition lease lifecycle (T21.3) ([3da1c04](https://github.com/kazi-org/kazi/commit/3da1c04f695dfc64b2f8386386ee9359c23e4232))
* **scheduler:** pipelined topological scheduler over the needs-DAG (T23.3) ([644be45](https://github.com/kazi-org/kazi/commit/644be4566c70d034830c80ba5931717c74734129))
* **scheduler:** regression re-gating + blocked-dep escalation (T23.4/T23.5) ([918331d](https://github.com/kazi-org/kazi/commit/918331debbdb0ae7f4d514da208669e99921371b))
* **scheduler:** route run_goals/2 single needs-DAG goal to the pipelined scheduler (T23.3) ([0033514](https://github.com/kazi-org/kazi/commit/0033514215cebe7710a49a85e358295a88571132))
* **scheduler:** run_goals/2 composes partition + lease + worktree (T21.2/T21.3/T21.4) ([271b816](https://github.com/kazi-org/kazi/commit/271b8160a0390c0ca384be11f48f5a2c3a6b1772))
* **scheduler:** supervise the partition DynamicSupervisor in the app tree (T21.1) ([607d47a](https://github.com/kazi-org/kazi/commit/607d47af7ad13f24a5a55f16464ee4cc532f4e53))
* **scheduler:** wire Kazi.Partition blast-radius partitioning (T21.2) ([a6eab42](https://github.com/kazi-org/kazi/commit/a6eab42c1d52e8de01a8c7c6c9b63fc872795fcc))
* **site:** add 'Bring Your Own Model' + 'AI-Ready Execution' feature cards ([37d0737](https://github.com/kazi-org/kazi/commit/37d073777b6bb9da2015d72f60cfb669e3d767b6))
* **site:** OG raster card, OG/Twitter meta, and prefers-color-scheme ([e3bc48d](https://github.com/kazi-org/kazi/commit/e3bc48d7a0bd8ba417cdf9f5570b31427a3825c1))
* **site:** semantic landmarks, heading order, and theme-aware classes ([2266141](https://github.com/kazi-org/kazi/commit/22661414b5675a39e47fc1889c41708d80e14981))
* **site:** source version from manifest, add proof visual + sections ([2dbd4ec](https://github.com/kazi-org/kazi/commit/2dbd4eca205c47a73b514d9dda62311bf9c01067))
* **teach:** the kazi Claude Code SKILL.md writer (T16.2) ([8d89d2f](https://github.com/kazi-org/kazi/commit/8d89d2f11ec658bfb14158c0c5ebe51430abfe4e))


### Bug Fixes

* **examples:** split test_runner cmd into cmd+args (T18.1) ([6f95a2d](https://github.com/kazi-org/kazi/commit/6f95a2dcda4c9de2815d7328235d5181e7bc69ea))
* **read-model:** deep-sanitize predicate evidence to JSON-safe (T18.2) ([38e1db2](https://github.com/kazi-org/kazi/commit/38e1db2a0e97880b5fee3b6f85e618b46e379445))
* **read-model:** idempotent terminal iteration persistence (T18.3) ([3641ff5](https://github.com/kazi-org/kazi/commit/3641ff595d6a9ef8668cffaf05a0e524bb48cdef))
* **readme:** escape quotes in Mermaid diagram label ([1086fd3](https://github.com/kazi-org/kazi/commit/1086fd3f8e7a9af1332d916dc75d1bf42c53b285))
* **readme:** make the reconcile-loop Mermaid diagram render on GitHub ([16c0b48](https://github.com/kazi-org/kazi/commit/16c0b486fa95730623187878c42cef3c068c5b80))
* **runtime:** idempotent iteration projection + over-budget regression test (T18.3/T18.4) ([7d86600](https://github.com/kazi-org/kazi/commit/7d86600eca0bb05366230b186a9af01c5c7dbd60))

## [0.3.0](https://github.com/kazi-org/kazi/compare/v0.2.0...v0.3.0) (2026-06-23)


### Features

* **authoring:** --adr ADR-lite rationale writer (T11.7) ([11f4a61](https://github.com/kazi-org/kazi/commit/11f4a61c0e4db3880e0497271b1d9ebb9dbc2699))
* **authoring:** harness-drafted candidate questions on the stub seam (T11.3) ([e1284a0](https://github.com/kazi-org/kazi/commit/e1284a00df10c96173448b4d5f104a90cf5d1771))
* **authoring:** pure clarify core + deterministic gap floor (T11.1, T11.2) ([cb99011](https://github.com/kazi-org/kazi/commit/cb990117c2b7f2955f0cc4f0d57d66410648a205))
* **authoring:** two-phase propose with clarify + inline rationale (T11.4, T11.5) ([fd5e36a](https://github.com/kazi-org/kazi/commit/fd5e36a97ab78f9667bff0d88dce2de2c4c57e1a))
* **cli:** interactive clarify phase + --yes/--strict/--adr + refine loop (T11.6, T11.8) ([4c2ac1b](https://github.com/kazi-org/kazi/commit/4c2ac1b0a0a3de2d2c78e2db8def256755b9e110))

## [0.2.0](https://github.com/kazi-org/kazi/compare/v0.1.1...v0.2.0) (2026-06-23)


### Features

* **site:** Astro + Tailwind landing page for kazi (T9.1/T9.2/T9.9) ([8f4501f](https://github.com/kazi-org/kazi/commit/8f4501f461fa6c1c78fd20fc2d7d6835e22e9d89))
