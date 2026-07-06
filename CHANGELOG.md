# Changelog

> **Deprecated (removal in v2.0.0):** the command-runner provider names
> `test_runner` and `prod_log` are **deprecated** -- folded onto the unified
> `custom_script` engine as presets (ADR-0040). Both names still resolve, so this
> is NON-BREAKING; a goal still using either name loads and evaluates identically
> and the loader prints a one-line migration hint to STDERR (never into `--json`
> stdout). Migrate `test_runner` -> `custom_script` with `verdict = "exit_zero"`,
> and `prod_log` -> `custom_script` with `verdict = "match_count"`. The names are
> removed in v2.0.0. See [docs/deprecations.md](docs/deprecations.md).

> **Breaking (v1.0.0):** the deprecated CLI aliases `kazi run`, `kazi propose`,
> and `mix kazi.run` were **removed** (verb unification under ADR-0032). They no
> longer parse: `kazi run` / `kazi propose` now error as unknown commands, and the
> MCP server no longer advertises `kazi_run` / `kazi_propose`. Use `kazi apply`,
> `kazi plan`, and `mix kazi.apply` instead. See
> [docs/deprecations.md](docs/deprecations.md) for the migration.

## [1.79.1](https://github.com/kazi-org/kazi/compare/v1.79.0...v1.79.1) (2026-07-06)


### Bug Fixes

* integrate stages scoped, waits for CI, says what it landed (issue [#819](https://github.com/kazi-org/kazi/issues/819)) ([ce2b542](https://github.com/kazi-org/kazi/commit/ce2b542af71b44709a38b772e3da3551da9b09f7))

## [1.79.0](https://github.com/kazi-org/kazi/compare/v1.78.0...v1.79.0) (2026-07-06)


### Features

* **site:** add fleet dashboard feature card (T46.9) ([827396d](https://github.com/kazi-org/kazi/commit/827396d879d73bc14de9e783c31537010099f894))

## [1.78.0](https://github.com/kazi-org/kazi/compare/v1.77.0...v1.78.0) (2026-07-06)


### Features

* attention queue -- rank what needs the operator (T46.6) ([7f23dd3](https://github.com/kazi-org/kazi/commit/7f23dd3b8bbe7ae8fb110bbba8ce1d0be052b9d8))

## [1.77.0](https://github.com/kazi-org/kazi/compare/v1.76.0...v1.77.0) (2026-07-06)


### Features

* transcript peek LiveView -- tail a run's transcript.jsonl (T46.8) ([437fda6](https://github.com/kazi-org/kazi/commit/437fda6105facebba7acd7a8994b546c45b10932))

## [1.76.0](https://github.com/kazi-org/kazi/compare/v1.75.0...v1.76.0) (2026-07-06)


### Features

* drill-in convergence heatmap + iteration scrubber LiveView (T46.7) ([2ca81e5](https://github.com/kazi-org/kazi/commit/2ca81e53fd2614717785ec847b6f53ed051a2999))

## [1.75.0](https://github.com/kazi-org/kazi/compare/v1.74.1...v1.75.0) (2026-07-06)


### Features

* per-run events.jsonl sink -- append-only loop events, retention-capped (T46.2) ([042d120](https://github.com/kazi-org/kazi/commit/042d120f99fecfbc61b2b482665500658fabfa84))

## [1.74.1](https://github.com/kazi-org/kazi/compare/v1.74.0...v1.74.1) (2026-07-06)


### Bug Fixes

* land converged change (kazi/integrate-1783324901) ([d746a5d](https://github.com/kazi-org/kazi/commit/d746a5d93b504303a3002de8cad0dbf09d441c0b))

## [1.74.0](https://github.com/kazi-org/kazi/compare/v1.73.8...v1.74.0) (2026-07-06)


### Features

* first-class `kazi apply --check` observe-only mode (issue [#805](https://github.com/kazi-org/kazi/issues/805)) ([48db05e](https://github.com/kazi-org/kazi/commit/48db05eb0ef66213257ac950fbe5982445ef6653))

## [1.73.8](https://github.com/kazi-org/kazi/compare/v1.73.7...v1.73.8) (2026-07-06)


### Bug Fixes

* re-evaluate the predicate vector before a terminal over_budget result (issue [#790](https://github.com/kazi-org/kazi/issues/790)) ([5403f8c](https://github.com/kazi-org/kazi/commit/5403f8c0aaf4f06e780ba57bd7c925fd45c6e653))

## [1.73.7](https://github.com/kazi-org/kazi/compare/v1.73.6...v1.73.7) (2026-07-06)


### Bug Fixes

* caller-drafts proposal identity + plan-time validation (issues [#787](https://github.com/kazi-org/kazi/issues/787), [#793](https://github.com/kazi-org/kazi/issues/793), [#788](https://github.com/kazi-org/kazi/issues/788)) ([960a3b7](https://github.com/kazi-org/kazi/commit/960a3b784bcb5aeab5930f317347429c64eab595))

## [1.73.6](https://github.com/kazi-org/kazi/compare/v1.73.5...v1.73.6) (2026-07-06)


### Bug Fixes

* stop folding a partition's vacuous-goal outcome into :stuck (issue [#786](https://github.com/kazi-org/kazi/issues/786)) ([6707853](https://github.com/kazi-org/kazi/commit/6707853f60f27eb7bc5dd858b48a63cdcd7b891c))

## [1.73.5](https://github.com/kazi-org/kazi/compare/v1.73.4...v1.73.5) (2026-07-06)


### Bug Fixes

* route the default logger handler to stderr -- stdout purity under --json (issue [#804](https://github.com/kazi-org/kazi/issues/804)) ([1be4b8d](https://github.com/kazi-org/kazi/commit/1be4b8d927e8a9bce18471304ce08dbcd37b3855))

## [1.73.4](https://github.com/kazi-org/kazi/compare/v1.73.3...v1.73.4) (2026-07-06)


### Bug Fixes

* kazi dashboard /dag 500 when standalone (issue [#801](https://github.com/kazi-org/kazi/issues/801)) ([c63ed4e](https://github.com/kazi-org/kazi/commit/c63ed4ee3f80ef352602c7326819cc9040b3f51d))

## [1.73.3](https://github.com/kazi-org/kazi/compare/v1.73.2...v1.73.3) (2026-07-05)


### Bug Fixes

* wire the transcript sink into the live kazi apply path (T46.3) ([f2cd369](https://github.com/kazi-org/kazi/commit/f2cd369a16877fc9c14103d5d3d79d5ba6e50604))

## [1.73.2](https://github.com/kazi-org/kazi/compare/v1.73.1...v1.73.2) (2026-07-05)


### Bug Fixes

* **loop:** unknown/quarantined verdicts never satisfy convergence ([#795](https://github.com/kazi-org/kazi/issues/795)) ([6bac321](https://github.com/kazi-org/kazi/commit/6bac321dab5a0ecb4f66a6421d01d764671d165c))

## [1.73.1](https://github.com/kazi-org/kazi/compare/v1.73.0...v1.73.1) (2026-07-05)


### Bug Fixes

* wire the fleet run registry into the live kazi apply path (T46.1) ([c9a6afe](https://github.com/kazi-org/kazi/commit/c9a6afe5982685187e0dbaae3e7a82ccdbf6e560))

## [1.73.0](https://github.com/kazi-org/kazi/compare/v1.72.2...v1.73.0) (2026-07-04)


### Features

* **dashboard:** fleet run registry, starmap LiveView, kazi dashboard verb (E46 slice) ([090da6b](https://github.com/kazi-org/kazi/commit/090da6b26b6f852725ac22d7a66eecdff073c9ed))

## [1.72.2](https://github.com/kazi-org/kazi/compare/v1.72.1...v1.72.2) (2026-07-04)


### Bug Fixes

* remediate deep-review 001 code findings (H1,M2-M9,L4,lows) ([59cc094](https://github.com/kazi-org/kazi/commit/59cc0948bacb8c07f4edfbc1205c80ce382890ba))


### Reverts

* back out M8 lease-holder-monitor (broke lease CAS atomicity) ([f15f4cf](https://github.com/kazi-org/kazi/commit/f15f4cf175104d2af1de9e76377dc9592568f565))

## [1.72.1](https://github.com/kazi-org/kazi/compare/v1.72.0...v1.72.1) (2026-07-03)


### Bug Fixes

* **harness:** surface claude permission_denials in parse/1 ([#769](https://github.com/kazi-org/kazi/issues/769)) ([0262ed4](https://github.com/kazi-org/kazi/commit/0262ed4d4e6733cdacfbce478fb753ee339dd689))

## [1.72.0](https://github.com/kazi-org/kazi/compare/v1.71.0...v1.72.0) (2026-07-03)


### Features

* **goal:** parse permission_mode/allowed_tools in the [harness] table ([9ea9334](https://github.com/kazi-org/kazi/commit/9ea93343d9df5beb190de214e7d2affbde4ada81))


### Bug Fixes

* **runtime:** fold permission_mode/allowed_tools into adapter_opts ([#769](https://github.com/kazi-org/kazi/issues/769)) ([1599ff1](https://github.com/kazi-org/kazi/commit/1599ff1ae891cf5752107f27c6548b468517f64f))

## [1.71.0](https://github.com/kazi-org/kazi/compare/v1.70.1...v1.71.0) (2026-07-01)


### Features

* **cli:** thread --permission-mode/--allowed-tools through apply; fix stale propose/run verbs ([4496100](https://github.com/kazi-org/kazi/commit/449610065de777a43dc0d4ca7413df3d29c56301))

## [1.70.1](https://github.com/kazi-org/kazi/compare/v1.70.0...v1.70.1) (2026-06-30)


### Bug Fixes

* **providers:** scrub host release/ERTS env from spawned children (L-0022) ([5f884d7](https://github.com/kazi-org/kazi/commit/5f884d7395fafed6bf1b1019e781f57ae171298a))

## [1.70.0](https://github.com/kazi-org/kazi/compare/v1.69.0...v1.70.0) (2026-06-30)


### Features

* **economy:** price claude-sonnet-5 in the cost table ([cf8937e](https://github.com/kazi-org/kazi/commit/cf8937ebe9581654ac9e806099179edff3815b01))

## [1.69.0](https://github.com/kazi-org/kazi/compare/v1.68.0...v1.69.0) (2026-06-29)


### Features

* **harness:** forward claude --effort reasoning lever (T36.6) ([e2bfcba](https://github.com/kazi-org/kazi/commit/e2bfcba16f02592c0dc153114a7b39e01ab6cc80))

## [1.68.0](https://github.com/kazi-org/kazi/compare/v1.67.0...v1.68.0) (2026-06-28)


### Features

* **scheduler:** inject default lease on the CLI --parallel path (T21.9) ([3fcc7ce](https://github.com/kazi-org/kazi/commit/3fcc7ce4c40a5f8ce00d9b3bf1990006113df1fb))

## [1.67.0](https://github.com/kazi-org/kazi/compare/v1.66.0...v1.67.0) (2026-06-28)


### Features

* **assets:** replace proof-loop mockup with a real recorded cast (T25.2) ([e6ea9d2](https://github.com/kazi-org/kazi/commit/e6ea9d25a87aeb842fd021cc3ea93890efac75f1))
* **examples:** add hero-cast demo fixture (T25.2) ([36f5a62](https://github.com/kazi-org/kazi/commit/36f5a6278efe4498434ba08578bcf1c08c86e836))
* **site:** use the real recorded cast as the home proof asset (T25.2) ([5ac6613](https://github.com/kazi-org/kazi/commit/5ac66138d1f4ab836797edde934c50b944875f3a))

## [1.66.0](https://github.com/kazi-org/kazi/compare/v1.65.1...v1.66.0) (2026-06-27)


### Features

* **coordination:** readable native-lease registry (LeaseTable) ([d85632a](https://github.com/kazi-org/kazi/commit/d85632ac39cea134975547d58bd5f02d0cd92b1c))


### Bug Fixes

* **scheduler:** parallelize disjoint groups of a no-needs goal ([153b114](https://github.com/kazi-org/kazi/commit/153b1143220bb7e0a9327e851e9f8ea50f14809a))
* **web:** default /leases to a NATS-free coordination source ([162cdc8](https://github.com/kazi-org/kazi/commit/162cdc8e877819c6c5cf1159ae783955cf56c605))

## [1.65.1](https://github.com/kazi-org/kazi/compare/v1.65.0...v1.65.1) (2026-06-27)


### Bug Fixes

* **doc-freshness:** exclude oss-gates.md from dead-command-ref check (T31.7) ([2c5553a](https://github.com/kazi-org/kazi/commit/2c5553a6136d16e22f10372c0b4d0f92b5d24dff))

## [1.65.0](https://github.com/kazi-org/kazi/compare/v1.64.2...v1.65.0) (2026-06-27)


### Features

* **site:** add the dogfood "done" proof gallery (T25.7) ([25d7f9d](https://github.com/kazi-org/kazi/commit/25d7f9d090c05389321444a557127896e6ec9dc0))


### Bug Fixes

* **site:** keep per-run cost in the methodology doc, not the proof surface ([8f35d9e](https://github.com/kazi-org/kazi/commit/8f35d9e4dfa3cdf81dc0c4f925eb6c2d8d143b1a))

## [1.64.2](https://github.com/kazi-org/kazi/compare/v1.64.1...v1.64.2) (2026-06-26)


### Bug Fixes

* **partition:** term-scope the repo-map blast radius so disjoint groups split ([5b21475](https://github.com/kazi-org/kazi/commit/5b214756fb55d7517489b8d342065cf8f8377cad))
* **scheduler:** start PartitionSupervisor on CLI apply --parallel path ([1708f3b](https://github.com/kazi-org/kazi/commit/1708f3bda36b67eae3bbbb9b6cc4c66801a67ebe))

## [1.64.1](https://github.com/kazi-org/kazi/compare/v1.64.0...v1.64.1) (2026-06-26)


### Bug Fixes

* **site:** order /blog index by series part, not just date ([6120084](https://github.com/kazi-org/kazi/commit/61200840b561254e91ee4a9ab4b2a1b662f104e3))

## [1.64.0](https://github.com/kazi-org/kazi/compare/v1.63.0...v1.64.0) (2026-06-26)


### Features

* **blog:** T38.17 Post 12 -- your on-ramp (series finale) ([e91d302](https://github.com/kazi-org/kazi/commit/e91d3023c1a95304d35335e080323e3a4e47ba46))

## [1.63.0](https://github.com/kazi-org/kazi/compare/v1.62.0...v1.63.0) (2026-06-26)


### Features

* **blog:** T38.16 Post 11 — meet kazi: "done," proven ([541baaf](https://github.com/kazi-org/kazi/commit/541baaf71c7112526c3a93785420d544b39ecbc1))

## [1.62.0](https://github.com/kazi-org/kazi/compare/v1.61.0...v1.62.0) (2026-06-26)


### Features

* **blog:** T38.15 Post 10 — the pattern underneath: reconciliation ([0c4e2aa](https://github.com/kazi-org/kazi/commit/0c4e2aad9fa061344124281588a338b8ff0f0a01))

## [1.61.0](https://github.com/kazi-org/kazi/compare/v1.60.0...v1.61.0) (2026-06-26)


### Features

* **blog:** T38.14 Post 9 — one developer, many agents ([b635764](https://github.com/kazi-org/kazi/commit/b635764368c97edd0fcd63ac4d2d35927f3bcac8))

## [1.60.0](https://github.com/kazi-org/kazi/compare/v1.59.0...v1.60.0) (2026-06-26)


### Features

* **blog:** T38.13 Post 8 — a definition of "done" that can't lie ([e178360](https://github.com/kazi-org/kazi/commit/e1783600a19979e8f371bda918a4406b55aaf9c2))

## [1.59.0](https://github.com/kazi-org/kazi/compare/v1.58.0...v1.59.0) (2026-06-26)


### Features

* **blog:** T38.12 Post 7 -- plan the work, then work the plan ([27135da](https://github.com/kazi-org/kazi/commit/27135daa58a32d12896010e24c04e9d92c3715db))

## [1.58.0](https://github.com/kazi-org/kazi/compare/v1.57.0...v1.58.0) (2026-06-26)


### Features

* **blog:** T38.11 Post 6 — from prompts to skills ([0a47769](https://github.com/kazi-org/kazi/commit/0a47769a65b10dc537071141dfa4cb118df347fb))

## [1.57.0](https://github.com/kazi-org/kazi/compare/v1.56.0...v1.57.0) (2026-06-26)


### Features

* **blog:** T38.10 Post 5 — stop re-reading the whole repo ([3c5589e](https://github.com/kazi-org/kazi/commit/3c5589e7b3b8628cb1cf15c86be75bd6b1a2f67f))

## [1.56.0](https://github.com/kazi-org/kazi/compare/v1.55.0...v1.56.0) (2026-06-26)


### Features

* **blog:** T38.9 Post 4 — give your agent eyes (all the way to prod) ([50e2626](https://github.com/kazi-org/kazi/commit/50e2626fb92610a91eedc6f37d2e2b79cd2bd0aa))

## [1.55.0](https://github.com/kazi-org/kazi/compare/v1.54.0...v1.55.0) (2026-06-26)


### Features

* **blog:** T38.8 Post 3 — decisions need a home ([e782322](https://github.com/kazi-org/kazi/commit/e7823222732d9ab7a3c51ba996efd62cbe54b783))

## [1.54.0](https://github.com/kazi-org/kazi/compare/v1.53.0...v1.54.0) (2026-06-26)


### Features

* **blog:** T38.7 Post 2 — teach your agent to remember ([fea558e](https://github.com/kazi-org/kazi/commit/fea558eb6beb361b9837466a08088e5c0609d84e))

## [1.53.0](https://github.com/kazi-org/kazi/compare/v1.52.0...v1.53.0) (2026-06-26)


### Features

* **blog:** T38.6 Post 1 — the ceiling of "looks good to me" ([e7271b7](https://github.com/kazi-org/kazi/commit/e7271b7fc2949dfc7e1797a67d5c78d0994b93a3))

## [1.52.0](https://github.com/kazi-org/kazi/compare/v1.51.0...v1.52.0) (2026-06-26)


### Features

* **site:** T38.20 core series diagrams (loop, ladder, before/after) ([d2c771c](https://github.com/kazi-org/kazi/commit/d2c771c356b26ad5114a14df91175f01130916a3))
* **site:** T38.20 per-post header art + generator ([5b84b18](https://github.com/kazi-org/kazi/commit/5b84b186fae4e313aef0354b8dc2b9838b88c03c))
* **site:** T38.20 render series diagrams + per-post art with alt text ([c408383](https://github.com/kazi-org/kazi/commit/c40838348414bec0f4bc3c5c222c9613adb44139))

## [1.51.0](https://github.com/kazi-org/kazi/compare/v1.50.0...v1.51.0) (2026-06-26)


### Features

* **site:** T38.21 cookieless analytics, UTM, canonical instrumentation ([9f22a0f](https://github.com/kazi-org/kazi/commit/9f22a0f68ad66bdfa0fa3c9361211e3cc6756ee1))

## [1.50.0](https://github.com/kazi-org/kazi/compare/v1.49.0...v1.50.0) (2026-06-26)


### Features

* **site:** add blog RSS feed, sitemap, Blog nav + extend verb guard to .mdx ([b9cbfed](https://github.com/kazi-org/kazi/commit/b9cbfedf9017ff92aaaddf7280e6f656b0a523e0))

## [1.49.0](https://github.com/kazi-org/kazi/compare/v1.48.0...v1.49.0) (2026-06-26)


### Features

* **site:** add blog post route + layout (T38.3) ([c1dd7fe](https://github.com/kazi-org/kazi/commit/c1dd7fe69d8981236813c30dbcfa929c941fad41))

## [1.48.0](https://github.com/kazi-org/kazi/compare/v1.47.0...v1.48.0) (2026-06-26)


### Features

* **site:** add /blog index + series landing pages (T38.2) ([a0d6a87](https://github.com/kazi-org/kazi/commit/a0d6a8781e621e656a61f9daf765f8b5c46bf4c2))

## [1.47.0](https://github.com/kazi-org/kazi/compare/v1.46.2...v1.47.0) (2026-06-26)


### Features

* **site:** add blog content collection + frontmatter schema (T38.1) ([f7f1860](https://github.com/kazi-org/kazi/commit/f7f18600ae37ab8075b62e5a33f0b26a88a3eb4f))

## [1.46.2](https://github.com/kazi-org/kazi/compare/v1.46.1...v1.46.2) (2026-06-26)


### Bug Fixes

* **authoring:** pin custom_script config schema in drafting prompt ([4ac3a71](https://github.com/kazi-org/kazi/commit/4ac3a7114688896ef03525cf1c93a8c26265e375))

## [1.46.1](https://github.com/kazi-org/kazi/compare/v1.46.0...v1.46.1) (2026-06-26)


### Bug Fixes

* **harness:** tolerate stderr noise before the claude JSON envelope (T26.8) ([d6e1b9a](https://github.com/kazi-org/kazi/commit/d6e1b9aafdd87d401583a41e7e131218022c28f8))

## [1.46.0](https://github.com/kazi-org/kazi/compare/v1.45.0...v1.46.0) (2026-06-26)


### Features

* **harness:** add :gemini_cli profile ([8e59072](https://github.com/kazi-org/kazi/commit/8e59072d08eda519840157858344e56f71b5e686))

## [1.45.0](https://github.com/kazi-org/kazi/compare/v1.44.0...v1.45.0) (2026-06-26)


### Features

* **doc-freshness:** add doc-coverage + stale-task ratchet metrics (T31.6) ([cdfed44](https://github.com/kazi-org/kazi/commit/cdfed4438bf6ea51f6fe2ed749799632d851717d))
* **examples:** add doc-lifecycle standing goal (T31.6) ([d815a0c](https://github.com/kazi-org/kazi/commit/d815a0ce8026c8dd8d97486c451cfa57a3b7c1aa))

## [1.44.0](https://github.com/kazi-org/kazi/compare/v1.43.0...v1.44.0) (2026-06-26)


### Features

* **loader:** expose provider_kinds/0 as the single source of truth ([87a3c54](https://github.com/kazi-org/kazi/commit/87a3c543653a7778e0ac2958a6eb8b0236d9f31c))


### Bug Fixes

* **authoring:** accept nested/goal-file proposal shapes; map E32 providers ([0f9778a](https://github.com/kazi-org/kazi/commit/0f9778a5e2f7cbfbe24ca24492ef98811984c934))

## [1.43.0](https://github.com/kazi-org/kazi/compare/v1.42.1...v1.43.0) (2026-06-26)


### Features

* **scripts:** add gated knowledge-extraction tool (T31.3) ([2d91b14](https://github.com/kazi-org/kazi/commit/2d91b144edc91bd1265705d0f312d783560193f8))

## [1.42.1](https://github.com/kazi-org/kazi/compare/v1.42.0...v1.42.1) (2026-06-25)


### Bug Fixes

* **authoring:** extract JSON from fenced/prose harness output before decoding ([2be1c70](https://github.com/kazi-org/kazi/commit/2be1c709886ab26ad98ac84bd6322c9af3b9a70f))

## [1.42.0](https://github.com/kazi-org/kazi/compare/v1.41.1...v1.42.0) (2026-06-25)


### Features

* **plan:** deterministic, lossless plan-trim tool (T31.2) ([38cb252](https://github.com/kazi-org/kazi/commit/38cb25285fe04469a459d48e5ca85c72d175c8b6))

## [1.41.1](https://github.com/kazi-org/kazi/compare/v1.41.0...v1.41.1) (2026-06-25)


### Bug Fixes

* **cli:** keep the read-model repo running in the standalone binary ([077db2f](https://github.com/kazi-org/kazi/commit/077db2fa5ad705ee459a4cd1830b414aadbaec09))

## [1.41.0](https://github.com/kazi-org/kazi/compare/v1.40.1...v1.41.0) (2026-06-25)


### Features

* **app:** supervise the DAG-snapshot cache in the web tree (T23.7) ([d48846a](https://github.com/kazi-org/kazi/commit/d48846ad3c14ebc99ee2f9e990408f9dc3201c9b))
* **scheduler:** publish render-ready DAG snapshots on each transition (T23.7) ([1606130](https://github.com/kazi-org/kazi/commit/16061302ec335dd39ead39fb51c27cf13b64bb24))
* **web:** live dependency-DAG dashboard at /dag (T23.7, UC-038) ([7d12fdc](https://github.com/kazi-org/kazi/commit/7d12fdc643b52a3550b3d571b9acdaf87b7ed358))

## [1.40.1](https://github.com/kazi-org/kazi/compare/v1.40.0...v1.40.1) (2026-06-25)


### Bug Fixes

* **economy:** surface run-aggregate tokens in the --json economy object (T34.8) ([5501b1d](https://github.com/kazi-org/kazi/commit/5501b1dd254576a27e7c75d265fc5544f91770a2))

## [1.40.0](https://github.com/kazi-org/kazi/compare/v1.39.0...v1.40.0) (2026-06-25)


### Features

* **bench:** tier x surface arms + `mix kazi.bench --tier-surface` (T36.5) ([52dbb90](https://github.com/kazi-org/kazi/commit/52dbb90eb411096b837a944d32bc64eab04ceb40))
* **harness:** add :ambient dispatch-surface OFF switch (T36.5) ([f43005d](https://github.com/kazi-org/kazi/commit/f43005d9228f45e359e368b9fbd8fe86c067a492))

## [1.39.0](https://github.com/kazi-org/kazi/compare/v1.38.2...v1.39.0) (2026-06-25)


### Features

* **bench:** in-family tiering cost arms + `mix kazi.bench --tiering` (T19.7) ([4a348b8](https://github.com/kazi-org/kazi/commit/4a348b8817890889dfeed921e5453011f73fc7ee))

## [1.38.2](https://github.com/kazi-org/kazi/compare/v1.38.1...v1.38.2) (2026-06-25)


### Bug Fixes

* **site:** repair 9 Astro newline-stripped spacing bugs ([fb4c3d5](https://github.com/kazi-org/kazi/commit/fb4c3d5738c71a7ebf9f38563dd48f7384443e91))

## [1.38.1](https://github.com/kazi-org/kazi/compare/v1.38.0...v1.38.1) (2026-06-25)


### Bug Fixes

* **site:** repair "Afterkazi" spacing + drop the Context7 jargon ([722f055](https://github.com/kazi-org/kazi/commit/722f055012036ae32c9028b628b3587c580d3173))

## [1.38.0](https://github.com/kazi-org/kazi/compare/v1.37.0...v1.38.0) (2026-06-25)


### Features

* **site:** concrete /kazi plan -&gt; /kazi apply on-ramp step (T25.4) ([3f69a4c](https://github.com/kazi-org/kazi/commit/3f69a4cfdfb741a214f108ed388ab05f73f79c73))

## [1.37.0](https://github.com/kazi-org/kazi/compare/v1.36.0...v1.37.0) (2026-06-25)


### Features

* **site:** benefit-first &lt;title&gt;/OG + meta description (T25.4 follow-up) ([84e403f](https://github.com/kazi-org/kazi/commit/84e403f36dd1f8ddf2d1c91a360d035df0056412))
* **site:** lead the hero with the Claude Code benefit (T25.4) ([a50e170](https://github.com/kazi-org/kazi/commit/a50e170264d1c6601467909ba6168a1afa690db6))

## [1.36.0](https://github.com/kazi-org/kazi/compare/v1.35.0...v1.36.0) (2026-06-25)


### Features

* **context-store:** inner-prompt contract + inner-search-only gist (T35.9) ([1db6f35](https://github.com/kazi-org/kazi/commit/1db6f355207e85adaba218580f4e57bfcb432e46))

## [1.35.0](https://github.com/kazi-org/kazi/compare/v1.34.0...v1.35.0) (2026-06-25)


### Features

* **site:** lead with the 10-second on-ramp (T25.4) ([5b5ce70](https://github.com/kazi-org/kazi/commit/5b5ce709962900c4c31481e0c09371acc11e5a4b))

## [1.34.0](https://github.com/kazi-org/kazi/compare/v1.33.0...v1.34.0) (2026-06-25)


### Features

* **stuck-bundle:** compact escalation bundle on stuck (T35.6) ([998129e](https://github.com/kazi-org/kazi/commit/998129e8f12323f4d437bd1464076d9c9303b874))

## [1.33.0](https://github.com/kazi-org/kazi/compare/v1.32.0...v1.33.0) (2026-06-25)


### Features

* **cli:** kazi apply --context-store/--context-budget + additive stats (T35.5) ([19bb14d](https://github.com/kazi-org/kazi/commit/19bb14d0f5e8190288d24dfc191fa64c11a540ac))

## [1.32.0](https://github.com/kazi-org/kazi/compare/v1.31.0...v1.32.0) (2026-06-25)


### Features

* **loop:** wire context store for evidence compression (T35.4) ([82427d1](https://github.com/kazi-org/kazi/commit/82427d1c582b79a8f67d4502138e0b8465f77501))

## [1.31.0](https://github.com/kazi-org/kazi/compare/v1.30.0...v1.31.0) (2026-06-25)


### Features

* **context:** pure tier-escalation policy with stop rule (T36.4) ([fbec61e](https://github.com/kazi-org/kazi/commit/fbec61e06aac04253a76fa3cc5a9fa69538a7921))
* **loop:** escalate the active context tier on non-progress (T36.4) ([c3fa1b8](https://github.com/kazi-org/kazi/commit/c3fa1b8b8d0255dfae3e4ee9d0efe7bebd09f66e))

## [1.30.0](https://github.com/kazi-org/kazi/compare/v1.29.0...v1.30.0) (2026-06-25)


### Features

* **context-store:** redact content before indexing (T35.3) ([7030db0](https://github.com/kazi-org/kazi/commit/7030db0df7b0868d08d7c36bca7d6b104d3e6fe5))
* **prompt:** redact secrets in evidence before the harness (T35.3) ([7df95a2](https://github.com/kazi-org/kazi/commit/7df95a2ede8a0fe3126ef6ca25e668f043b35b9b))
* **redaction:** shared secret redactor for evidence egress (T35.3) ([88adeb0](https://github.com/kazi-org/kazi/commit/88adeb0e4925456f5e0732a776c95728cb24bf23))


### Bug Fixes

* **context-store:** unique gist staging filename (T35.3) ([b5eea80](https://github.com/kazi-org/kazi/commit/b5eea8050a75c404e0337777fcee815fdb953a86))

## [1.29.0](https://github.com/kazi-org/kazi/compare/v1.28.0...v1.29.0) (2026-06-25)


### Features

* **cli:** add `kazi context index|search|stats` wrapper (T35.7) ([3e38338](https://github.com/kazi-org/kazi/commit/3e38338e30f8d79dbcf0fc5ebca4a56b85c12451))

## [1.28.0](https://github.com/kazi-org/kazi/compare/v1.27.0...v1.28.0) (2026-06-25)


### Features

* **init:** add `kazi init --with-gist` to opt a repo into the Gist context store ([2a3a39e](https://github.com/kazi-org/kazi/commit/2a3a39eb494445ad49ed3d325a014bf94232ce2e))

## [1.27.0](https://github.com/kazi-org/kazi/compare/v1.26.0...v1.27.0) (2026-06-25)


### Features

* **context:** add context-budget tier ladder (T36.3) ([3e8552c](https://github.com/kazi-org/kazi/commit/3e8552c38b1b7883c57ea54738e6adeea1485553))
* **harness:** gate the graph MCP behind tier 2 in the dispatch surface (T36.3) ([57af522](https://github.com/kazi-org/kazi/commit/57af522cec0ab384c949f52d053eb7ec9102a294))
* **loop:** gate orientation prefix and record tier by context tier (T36.3) ([aeaed37](https://github.com/kazi-org/kazi/commit/aeaed37d4e59fd0ca4ad46eeead581a80596fc24))
* **loop:** record active context tier in the per-iteration envelope (T36.3) ([78f6ed9](https://github.com/kazi-org/kazi/commit/78f6ed9399f14fb71caaa4af947a395f3b5e2a16))

## [1.26.0](https://github.com/kazi-org/kazi/compare/v1.25.0...v1.26.0) (2026-06-25)


### Features

* **bench:** consume the economy KPIs in a per-arm breakdown table (T34.6) ([b55a5bb](https://github.com/kazi-org/kazi/commit/b55a5bba0b8b3d3bdca4ac71c6ca9543b3b43988))
* **cli:** surface the economy KPIs in the apply --json run result (T34.6) ([9125961](https://github.com/kazi-org/kazi/commit/9125961c03eed8b209469df29d167245998f5426))
* **economy:** pure run-end economy-KPI fold from iteration envelopes (T34.6) ([f4a4cb3](https://github.com/kazi-org/kazi/commit/f4a4cb30532281837e87ca3651a61fba688f9ff3))
* **mcp:** mirror the economy KPIs in the kazi_apply run result (T34.6) ([94fe9ff](https://github.com/kazi-org/kazi/commit/94fe9ff920e3e43ceb6b3e8582021dcd92f1eb19))

## [1.25.0](https://github.com/kazi-org/kazi/compare/v1.24.0...v1.25.0) (2026-06-25)


### Features

* **economy:** dated price map for cost_usd (T34.5) ([19d4254](https://github.com/kazi-org/kazi/commit/19d42548c2ededdb04616c96e11417ba4882e65e))
* **harness:** derive cost_usd from the price map when the harness omits it (T34.5) ([310b7e6](https://github.com/kazi-org/kazi/commit/310b7e6a3638e4479e302bda9d518029ad21a7ca))

## [1.24.0](https://github.com/kazi-org/kazi/compare/v1.23.0...v1.24.0) (2026-06-25)


### Features

* **budget:** discount cached reads in the token budget guard (T34.4) ([281f38c](https://github.com/kazi-org/kazi/commit/281f38c34bfd27485e5c550be8133f8986caa0c5))
* **goal:** accept budget.cached_read_weight config (T34.4) ([8bed21b](https://github.com/kazi-org/kazi/commit/8bed21ba3284d57b945d99c0c45c2ba0ffbf6b89))

## [1.23.0](https://github.com/kazi-org/kazi/compare/v1.22.0...v1.23.0) (2026-06-25)


### Features

* **harness:** surface claude tool-use names for per-iteration tool counters ([0447f36](https://github.com/kazi-org/kazi/commit/0447f36cdb6369183dcc9d9bc4cdc81acabc2dbc))
* **loop:** add Kazi.Loop.Counters for per-iteration context + tool counters ([619f19d](https://github.com/kazi-org/kazi/commit/619f19df369e274df96ec7761eb74425e89f8890))
* **loop:** record context + tool counters in the iteration event (T34.3) ([5089b58](https://github.com/kazi-org/kazi/commit/5089b580d65b824f443dd1296f6efa916d4fa3af))
* **read-model:** persist + round-trip per-iteration context + tool counters ([22a51f6](https://github.com/kazi-org/kazi/commit/22a51f68e534d8eac80ee32c2793768a98a4b49c))
* **runtime,cli:** project context + tool counters to read-model and stream ([129dace](https://github.com/kazi-org/kazi/commit/129dacef31c6af0248248bfef2c2f868a6b885a5))

## [1.22.0](https://github.com/kazi-org/kazi/compare/v1.21.0...v1.22.0) (2026-06-25)


### Features

* **enforcement:** add DiffGuard advisory diff-inspection scanner (T32.5) ([a0c9610](https://github.com/kazi-org/kazi/commit/a0c961097de3c586b69943a5660f7d2b07401901))
* **loop:** wire advisory diff-gaming guard with progress downgrade (T32.5) ([dc7c4d4](https://github.com/kazi-org/kazi/commit/dc7c4d43e5f5bfb29702fc5de6f24ccddda60c8f))

## [1.21.0](https://github.com/kazi-org/kazi/compare/v1.20.0...v1.21.0) (2026-06-25)


### Features

* **mcp:** canonical kazi mcp client config + `init --with-mcp` (T33.3) ([df9c8b9](https://github.com/kazi-org/kazi/commit/df9c8b93c20667823e61642336e39737c353754b))

## [1.20.0](https://github.com/kazi-org/kazi/compare/v1.19.0...v1.20.0) (2026-06-25)


### Features

* **context-store:** add GistCLI provider (T35.2) ([2acd9a9](https://github.com/kazi-org/kazi/commit/2acd9a99ae53c559b530adac0b4211ee92f6244d))

## [1.19.0](https://github.com/kazi-org/kazi/compare/v1.18.0...v1.19.0) (2026-06-25)


### Features

* **cli:** surface enforcement guarantees in `apply --json` (T32.4) ([4c197e6](https://github.com/kazi-org/kazi/commit/4c197e686fa91aa6be0b283f6e8440fb3436c17a))
* **enforcement:** Kazi.Enforcement profile + clean-tree isolation (T32.4) ([8ff7345](https://github.com/kazi-org/kazi/commit/8ff7345fa460a9b047f2f705e3104d0f303501fa))
* **goal:** carry the authored enforcement profile (T32.4) ([b1d3577](https://github.com/kazi-org/kazi/commit/b1d357758167be6904e2f85448d4eff8d928267f))
* **loader:** parse the [enforcement] goal-file table (T32.4) ([1686f15](https://github.com/kazi-org/kazi/commit/1686f152e3a4a4b36e4d85c8d18afbd6949fbbd8))
* **loop:** compose anti-gaming enforcement onto the reconcile tick (T32.4) ([88d901a](https://github.com/kazi-org/kazi/commit/88d901a34c3445851ad338ac94135a7c05e896bb))
* **runtime:** resolve enforcement + synthesize ratchet guards (T32.4) ([0e69a7a](https://github.com/kazi-org/kazi/commit/0e69a7aa7b876838088941123fbb8072fdfa519e))


### Bug Fixes

* **cli:** keep the usage envelope alongside enforcement in `apply --json` ([6be0c85](https://github.com/kazi-org/kazi/commit/6be0c850221844f4b6f65c7eb157b32826210aba))

## [1.18.0](https://github.com/kazi-org/kazi/compare/v1.17.0...v1.18.0) (2026-06-25)


### Features

* **ci:** add doc command-accuracy gate vs kazi CLI surface ([535f938](https://github.com/kazi-org/kazi/commit/535f938ce37c3e7e263b6d064ee273fac58dfbbc))

## [1.17.0](https://github.com/kazi-org/kazi/compare/v1.16.0...v1.17.0) (2026-06-25)


### Features

* **predicate:** :coverage first-class provider (T32.8) ([e5f3eab](https://github.com/kazi-org/kazi/commit/e5f3eabb6fef80aed211023d9acfd95812481137))
* **predicate:** :cve first-class provider (T32.8) ([daf85df](https://github.com/kazi-org/kazi/commit/daf85dfe9b468ba3c3e73ae79071fcdfdfc0dd68))
* **predicate:** :mutation first-class provider (T32.8) ([d776f9f](https://github.com/kazi-org/kazi/commit/d776f9fcdad8f486971ce624e62a5926467bac5d))
* **predicate:** :property first-class provider (T32.8) ([00b159a](https://github.com/kazi-org/kazi/commit/00b159a1573ce72ea9835cdedff8766963319728))

## [1.16.0](https://github.com/kazi-org/kazi/compare/v1.15.0...v1.16.0) (2026-06-25)


### Features

* **usage:** fold the per-field token split into the run-aggregate envelope (T34.2) ([53100c5](https://github.com/kazi-org/kazi/commit/53100c5e5c29e9be0bd7613e722a82090ff1026e))
* **usage:** map per-profile raw usage onto the economy envelope + fidelity (T34.2) ([d192ac5](https://github.com/kazi-org/kazi/commit/d192ac51c827f0e59b5498f0b24f891b3f131ce2))

## [1.15.0](https://github.com/kazi-org/kazi/compare/v1.14.0...v1.15.0) (2026-06-25)


### Features

* **harness:** minimal default dispatch surface (T36.2) ([c42b0d9](https://github.com/kazi-org/kazi/commit/c42b0d9a940532c1186c5932ab21719526cdba5b))

## [1.14.0](https://github.com/kazi-org/kazi/compare/v1.13.0...v1.14.0) (2026-06-25)


### Features

* **loader:** register + validate :static, add `kazi schema static` (T32.7) ([db6ba50](https://github.com/kazi-org/kazi/commit/db6ba502ee484418217bbc2909c95a090973261e))
* **predicate:** :static provider — Dialyzer-led analysis (T32.7) ([3456080](https://github.com/kazi-org/kazi/commit/3456080cf26d71c2a677dab5d62d37c42cabe005))

## [1.13.0](https://github.com/kazi-org/kazi/compare/v1.12.0...v1.13.0) (2026-06-25)


### Features

* **examples:** ship custom_script/ratchet recipes — contract/perf/secret/a11y/IaC/visual (T32.9) ([a7e5850](https://github.com/kazi-org/kazi/commit/a7e58504979d5d2fe027d5af20846dc5caafffeb))

## [1.12.0](https://github.com/kazi-org/kazi/compare/v1.11.0...v1.12.0) (2026-06-25)


### Features

* **predicate:** :metrics provider — windowed quantile + SLO burn-rate (T32.10) ([1551677](https://github.com/kazi-org/kazi/commit/155167786cd70a6c0447bc5a6d3cf2c3c07a384b))
* **predicate:** browser synthetic journey — X consecutive passes (T32.10) ([ea7445d](https://github.com/kazi-org/kazi/commit/ea7445d8ed8c46ef12118d79f617118a5c6abfad))
* **predicate:** http_probe sustained-health — N consecutive samples (T32.10) ([c98728b](https://github.com/kazi-org/kazi/commit/c98728bd30d86d0734ac1214fad951c4ed71aee5))

## [1.11.0](https://github.com/kazi-org/kazi/compare/v1.10.0...v1.11.0) (2026-06-25)


### Features

* **json:** add usage envelope renderer + schema descriptor (T34.1) ([5294c88](https://github.com/kazi-org/kazi/commit/5294c88b5cb321fdcb840a2983844157283004ea))
* **json:** render additive usage envelope + budget_spent.tokens (T34.1) ([85bcb3c](https://github.com/kazi-org/kazi/commit/85bcb3c2837a1c7f31f8040d667c85e1155a2fd7))
* **loop:** accumulate the run-aggregate usage envelope (T34.1) ([bcac448](https://github.com/kazi-org/kazi/commit/bcac448b31f5e512b238832f170e87d472bab282))
* **mcp:** mirror the usage envelope in the MCP run result (T34.1) ([e28250b](https://github.com/kazi-org/kazi/commit/e28250b2f794e13788133b7b6cf9ec97f04dd2d8))

## [1.10.0](https://github.com/kazi-org/kazi/compare/v1.9.0...v1.10.0) (2026-06-25)


### Features

* **cli:** add kazi mcp verb (T33.1) ([ed71107](https://github.com/kazi-org/kazi/commit/ed71107cae9d52574feee1f40e507fd3df32fe13))

## [1.9.0](https://github.com/kazi-org/kazi/compare/v1.8.1...v1.9.0) (2026-06-25)


### Features

* **predicate:** first-class ratchet provider, wiring + schema (T32.3) ([44830a6](https://github.com/kazi-org/kazi/commit/44830a6ce34a83d34dc50901df20a3d469ae1453))
* **predicate:** ratchet baseline-comparison machinery + store (T32.3) ([e1483e8](https://github.com/kazi-org/kazi/commit/e1483e835774ebb97f444dce7779683c0e5537f0))
* **predicate:** shared JSONPath + metric signal extraction (T32.3) ([ff848fa](https://github.com/kazi-org/kazi/commit/ff848fa6b60c8ff3eb283a917e8f29248dccccc9))

## [1.8.1](https://github.com/kazi-org/kazi/compare/v1.8.0...v1.8.1) (2026-06-25)


### Bug Fixes

* **site:** use kazi apply/plan verbs in Install + proof asset (T27.6) ([eb9db10](https://github.com/kazi-org/kazi/commit/eb9db1096d17988da8ee8e658fc9c37397bc7171))

## [1.8.0](https://github.com/kazi-org/kazi/compare/v1.7.0...v1.8.0) (2026-06-25)


### Features

* **harness:** advertise Claude economy opts in supported_opts (T36.1) ([dcc0569](https://github.com/kazi-org/kazi/commit/dcc056922782898cbeed2a714ff4d00d24db9138))
* **harness:** map Claude economy flags in build_args (T36.1) ([1006aa4](https://github.com/kazi-org/kazi/commit/1006aa4d10280e4dbaa576ba1ead009a3301d4a6))

## [1.7.0](https://github.com/kazi-org/kazi/compare/v1.6.0...v1.7.0) (2026-06-25)


### Features

* **loop:** held-out acceptance subset hidden from agent (T32.6) ([f8abf5c](https://github.com/kazi-org/kazi/commit/f8abf5cc1549f42b8f87d28472e22bad323d640b))

## [1.6.0](https://github.com/kazi-org/kazi/compare/v1.5.0...v1.6.0) (2026-06-25)


### Features

* **loader:** deprecate test_runner/prod_log provider names with a STDERR hint (T32.1b) ([f98ec15](https://github.com/kazi-org/kazi/commit/f98ec15145137a240214d6d2b50b0316bc526333))
* **schema:** document match_count verdict + match_regex/merge_stderr keys (T32.1b) ([7620dc6](https://github.com/kazi-org/kazi/commit/7620dc63b6fff4be593adbdb5a03f5a1d934fa1d))

## [1.5.0](https://github.com/kazi-org/kazi/compare/v1.4.0...v1.5.0) (2026-06-25)


### Features

* **site:** add command-accuracy scanner for removed kazi verbs ([3eaf0cf](https://github.com/kazi-org/kazi/commit/3eaf0cf07703bf346ce18f74a7a164349134578d))

## [1.4.0](https://github.com/kazi-org/kazi/compare/v1.3.0...v1.4.0) (2026-06-25)


### Features

* **site:** add Docs nav + community footer links (T25.12) ([3cfc635](https://github.com/kazi-org/kazi/commit/3cfc635bd09a5c7850a16a9ed18284fcfbfe7376))

## [1.3.0](https://github.com/kazi-org/kazi/compare/v1.2.0...v1.3.0) (2026-06-25)


### Features

* **cli:** emit additive envelope-v2 predicate fields under --json (T32.2) ([4a0dd63](https://github.com/kazi-org/kazi/commit/4a0dd63cdad0515df1c7f4854a2abe1c772f65b1))
* **evidence:** SARIF/JUnit parser + LSP-Diagnostic evidence item (T32.2) ([533dcbd](https://github.com/kazi-org/kazi/commit/533dcbd426ccbd0b553b12c14911d61e2c581375))
* **loop:** thread prior_score; stuck-detector reads the graded delta (T32.2) ([4b41f7a](https://github.com/kazi-org/kazi/commit/4b41f7ae6d9afd2dd1331a984d965220c78d7d90))
* **predicate:** envelope v2 — score/direction/prior_score/diagnostics (T32.2) ([9d9ad89](https://github.com/kazi-org/kazi/commit/9d9ad894654c723703e43b3a62001b67015fa47b))
* **read-model:** persist + round-trip envelope-v2 fields (T32.2) ([5b87e34](https://github.com/kazi-org/kazi/commit/5b87e3428c0c43daf3a7f8a831aec5ef78572011))

## [1.2.0](https://github.com/kazi-org/kazi/compare/v1.1.0...v1.2.0) (2026-06-25)


### Features

* **cli:** kazi schema custom_script provider-key schema (T32.1) ([bf2bb48](https://github.com/kazi-org/kazi/commit/bf2bb48839e57f3cf0740cf9592f76cd0aa176f4))
* **predicate:** custom_script generic command-runner provider (T32.1) ([371b1a7](https://github.com/kazi-org/kazi/commit/371b1a79a358456bd2d241b4d1e3b10f49c69a01))
* **predicate:** validate custom_script config keys in the loader (T32.1) ([af92813](https://github.com/kazi-org/kazi/commit/af92813ce6ee56755f01165acb9a669beda76f78))
* **site:** render decided tagline, invocation phrase + agent testimonial (T25.1/T25.5/T25.6) ([bdb3124](https://github.com/kazi-org/kazi/commit/bdb3124044aecc21bc6aa13db4e0fcd0c0b43579))
* **site:** wire decided tagline + invocation phrase into canonical strings (T25.1/T25.6) ([0a4e140](https://github.com/kazi-org/kazi/commit/0a4e14033ea6ab4d027d48a83df3cab706dfb2d8))
* **skill:** recognize + document the invocation phrase (T25.6) ([12f0f5a](https://github.com/kazi-org/kazi/commit/12f0f5aae7bf151c894f5a4f7186c39f38fd962e))

## [1.1.0](https://github.com/kazi-org/kazi/compare/v1.0.1...v1.1.0) (2026-06-25)


### Features

* **docs-freshness:** predicate (a) -- every CLI command in README (T31.4) ([9c11fbf](https://github.com/kazi-org/kazi/commit/9c11fbf22eaea3d5d1cd2cce78abc883471722f5))
* **docs-freshness:** predicate (b) -- no dead command refs in live docs (T31.4) ([66638dc](https://github.com/kazi-org/kazi/commit/66638dc3215063b130a40b7bd557f23478340dfb))
* **docs-freshness:** predicate (c) -- referenced ADRs exist (T31.4) ([bd925e1](https://github.com/kazi-org/kazi/commit/bd925e1c6857120004e15baf9205e0cbcfcd8990))
* **docs-freshness:** predicate (d) -- plan trimmed of released tasks (T31.4) ([73d12f8](https://github.com/kazi-org/kazi/commit/73d12f87ff003320b0c4a0eff0bd7cd3adc11211))
* **docs-freshness:** runner for the predicate set (T31.4) ([4f03bbd](https://github.com/kazi-org/kazi/commit/4f03bbd4105b887292015bce96beaf329211e862))
* **docs-freshness:** shared lib for doc-freshness predicates (T31.4) ([a458463](https://github.com/kazi-org/kazi/commit/a4584639bd4c722d9e62e90e7a6a55463be10c1c))
* **teach:** AGENTS.md defaults to in-family Claude tiering (T30.1) ([08d3af7](https://github.com/kazi-org/kazi/commit/08d3af7b76e6c38a6d90b17360d64c7339979310))
* **teach:** bounded escalate-on-stuck model ladder in the SKILL.md (T30.2) ([ac82f7b](https://github.com/kazi-org/kazi/commit/ac82f7bd258796716f5809a89abfee54ddb73af8))
* **teach:** SKILL.md template defaults to in-family Claude tiering (T30.1) ([37dac7f](https://github.com/kazi-org/kazi/commit/37dac7f9d8e8d8d32c36dfe12f5147e5e73e4dc6))


### Bug Fixes

* **ci:** doc-freshness WARN step must not errexit on a failing run ([9dc9d6d](https://github.com/kazi-org/kazi/commit/9dc9d6de0bdeeb62f3fb7e67d1bc153fb15bef0c))
* **docs-freshness:** exclude the freshness doc from (b)/(c) self-scan (T31.4) ([094df2f](https://github.com/kazi-org/kazi/commit/094df2f77c1c66a3c677cacd170508b64a2d07d9))

## [1.0.1](https://github.com/kazi-org/kazi/compare/v1.0.0...v1.0.1) (2026-06-25)


### Bug Fixes

* **release:** build on OTP 28.3 so `kazi version` prints no warning ([b68cc3f](https://github.com/kazi-org/kazi/commit/b68cc3f388d6e3d48c5e13f53bac6d6ad5f3eb73))

## [1.0.0](https://github.com/kazi-org/kazi/compare/v0.5.0...v1.0.0) (2026-06-24)


### ⚠ BREAKING CHANGES

* repoint run/propose to apply/plan in user-facing docs (T27.9)
* repoint run/propose to apply/plan; assert aliases now error (T27.9)
* mark run/propose aliases REMOVED in v1.0.0 (T27.9)
* **teach:** scrub run/propose from SKILL.md template and AGENTS.md (T27.9)
* **mcp:** MCP tools kazi_run/kazi_propose are removed; use kazi_apply/kazi_plan.
* **cli:** kazi schema run/propose no longer resolve.
* **cli:** kazi run/propose are removed; use kazi apply/plan.

### Features

* **cli:** drop run/propose schema aliases (T27.9) ([07a1578](https://github.com/kazi-org/kazi/commit/07a1578451b27771034a6b67d28ddcc0260378b5))
* **cli:** remove deprecated run/propose aliases (T27.9) ([160150e](https://github.com/kazi-org/kazi/commit/160150edecdcc2f8b17239cc788d2ecc028a444e))
* **mcp:** remove kazi_run/kazi_propose tool aliases (T27.9) ([9d11eb6](https://github.com/kazi-org/kazi/commit/9d11eb6d6ae1cd3bd9818c57f676d45f3bbd31f7))
* **site:** add 'by the team behind Sire' footer attribution link ([00ed31e](https://github.com/kazi-org/kazi/commit/00ed31e70891c615ef7cc38ed8122b012a5db669))
* **site:** dynamic version badge -- fetch latest release, never stale ([64a09c7](https://github.com/kazi-org/kazi/commit/64a09c7267efe65c2f55e40b05b443eb2dc4dcf9))
* **teach:** scrub run/propose from SKILL.md template and AGENTS.md (T27.9) ([433e915](https://github.com/kazi-org/kazi/commit/433e915fb0ac76218bf512fafaa18857d64ad461))


### Bug Fixes

* **oss-gates:** make the leak guard's full-tree mode actually scan ([f091b5d](https://github.com/kazi-org/kazi/commit/f091b5d8a89104dfe90a91551051a5ba452c9d06))


### Documentation

* mark run/propose aliases REMOVED in v1.0.0 (T27.9) ([0e2d537](https://github.com/kazi-org/kazi/commit/0e2d537209bea641f85b72d7e2d288aa6fe33231))
* repoint run/propose to apply/plan in user-facing docs (T27.9) ([f270548](https://github.com/kazi-org/kazi/commit/f2705485174bde495991110dceb4e945bb36d468))


### Tests

* repoint run/propose to apply/plan; assert aliases now error (T27.9) ([782aaaf](https://github.com/kazi-org/kazi/commit/782aaaf94be68f9ca9e57dbd5e5ffe4c080a3a57))

## [0.5.0](https://github.com/kazi-org/kazi/compare/v0.4.0...v0.5.0) (2026-06-24)


### Features

* **cli:** apply/plan primary verbs, run/propose deprecated aliases (T27.1) ([b000fc0](https://github.com/kazi-org/kazi/commit/b000fc0bf59489b7448b6383160109408fc97a90))
* **cli:** bump JSON result schema_version 1-&gt;2 + apply/plan command key (T27.3) ([aae6f84](https://github.com/kazi-org/kazi/commit/aae6f84627d083b7f45aa3ab32598a2d85b78d0e))
* **cli:** help --json marks apply/plan primary, run/propose deprecated (T27.4) ([bd5fba0](https://github.com/kazi-org/kazi/commit/bd5fba0667491666519c620a02181333b54f6698))
* **cli:** mix kazi.apply task + mix kazi.run deprecated alias (T27.2) ([1c63a8c](https://github.com/kazi-org/kazi/commit/1c63a8c5629f0ee17a474b4f52bb623bb150f2d1))
* **cli:** name the v0.5.0 removal in the deprecation hints (T27.7) ([aa42dd9](https://github.com/kazi-org/kazi/commit/aa42dd9a560df7e8f2b817a9f07e718ea83b2ba0))
* **cli:** schema resolves apply/plan; run/propose aliased (T27.4) ([4ca364a](https://github.com/kazi-org/kazi/commit/4ca364aca732c90eec1acfd1a59bd0c4d41a328d))
* **harness:** claude profile renders --model for in-family tiering (T19.6) ([302b18d](https://github.com/kazi-org/kazi/commit/302b18dd85862fa4f30843e2c7939edd9cf82cb8))
* **teach:** flesh out the `apply` sub-skill recipe (T26.3) ([389c1b1](https://github.com/kazi-org/kazi/commit/389c1b14b262ed560678d058c96071544ba299e4))
* **teach:** flesh out the `plan` sub-skill recipe (T26.2) ([d19a8e0](https://github.com/kazi-org/kazi/commit/d19a8e0d45b40e44dc1df506d8537066481c4dda))
* **teach:** flesh out the `status` + `adopt` sub-skill recipes (T26.4) ([b49736d](https://github.com/kazi-org/kazi/commit/b49736d63ed21e57884840dc726760d9db1b878d))
* **teach:** install-skill writes a plan/apply/status/adopt router SKILL.md (T26.1) ([360aeab](https://github.com/kazi-org/kazi/commit/360aeab63ebc34b4152ca28a67b8dbc9a7d80bb9))
* **teach:** rename MCP tools kazi_run-&gt;kazi_apply, kazi_propose-&gt;kazi_plan (T27.5) ([d0deee3](https://github.com/kazi-org/kazi/commit/d0deee357e8f0131ec8ede406fbac71fb8ce831a))


### Bug Fixes

* **cli:** deprecation hint names v1.0.0 as the removal version ([fa9c147](https://github.com/kazi-org/kazi/commit/fa9c147e14e34e5796fc17bfa09e7f1a37e76e18))

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
