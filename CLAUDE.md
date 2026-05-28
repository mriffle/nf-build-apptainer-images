# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Maintaining this file

**Keep this file in sync with the code — as part of the change, not as a follow-up.** Whenever you change how the project is built, run, tested, structured, or conventionally written (commands, params, profiles, the image-name transform, conventions, dependencies, or the architecture), update the affected section here in the same commit/diff. When you fix or add a known issue, update the "Known issues / rough edges" checklist: check the box, date it, and note what was verified. A stale CLAUDE.md is worse than none.

## What this is

A Nextflow (DSL2) pipeline that **pre-builds Apptainer images on cluster compute nodes** so that a *subsequent, separate* Nextflow workflow can use them directly. It exists to work around a specific problem: when Nextflow is told to use Apptainer, it converts Docker images to Apptainer images on the machine running the Nextflow orchestrator — i.e. the cluster head node — which is CPU/RAM heavy and gets jobs killed by admins. This pipeline performs that conversion as scheduled jobs on the cluster nodes instead, caching the results. The real workflow is run afterward and finds the images already in its cache.

## Repository layout

- `main.nf` — entry workflow: param validation, the startup banner, the `wf_apptainer` call, and the `onComplete:` completion-email handler.
- `workflows/apptainer.nf` — the `wf_apptainer` subworkflow: image-map loading, base+override merge, the empty-merge guard, and channel fan-out (one image per item).
- `modules/check_build_apptainer.nf` — the single process (`CHECK_BUILD_APPTAINER`) that pulls/converts one image; has both a real `script:` and a faithful `stub:`.
- `lib/ImageConfig.groovy` — plain-Groovy helpers (`loadImagesMap`, `asFile`) that parse `params.images` from a file/URL. Kept in `lib/` so the imperative Groovy stays outside the strict `.nf` parser.
- `lib/EmailTemplate.groovy` + `assets/email_template.html` — the completion email.
- `nextflow.config` — params, profiles (`standard`, `sge_maccoss`), manifest, `process.shell`, and `process.resourceLimits` (per profile).
- `conf/base.config` — nf-core-style `process_*` resource labels, the default `resourceLimits`, and the default `errorStrategy`.
- `tests/run_tests.sh` — the self-contained test harness (see "Testing / verifying changes").
- `.github/workflows/ci.yml` — GitHub Actions CI: runs the harness on every push, one parallel job per Nextflow version.

Where to add things: a new process → a file under `modules/` (with a `stub:`); a new orchestration step → `workflows/apptainer.nf`; reusable/imperative Groovy → a class in `lib/`.

## Prerequisites

- **Nextflow** — the manifest requires `>=25.10.0`. The code uses the **new (strict) Nextflow language**, the default on Nextflow 26+. On Nextflow 25 (25.10+) you must request it: `export NXF_SYNTAX_PARSER=v2`. (25.10 is the first 25 release with the strict parser; earlier 25.x is unsupported.) Verified against 25.10.0 and 26.04.3.
- **Apptainer** — the `apptainer` CLI must be on `PATH` on whatever executor runs the tasks (the cluster nodes). Not needed for the test harness — the process `stub:` does the work.
- **Java 17+** — for Nextflow itself.
- **curl + internet** — only for the test harness's first run, to fetch the pinned Nextflow distributions.

## Running it

There is no automated build/lint/test suite (see "Testing / verifying changes"). The three directory/file params are all required.

```bash
nextflow run main.nf \
  -profile standard \                                   # or a cluster profile, see below
  --docker_images_file <path-or-URL-to-config> \        # required
  --apptainer_cache_dir <dir> \                         # required; MUST match the downstream run's cache dir
  --apptainer_tmp_dir <dir>                             # required; scratch for conversion
# optional: --docker_images_override_file <file>  --email <addr>
```

On Nextflow 25 (25.10+) prefix the command with `NXF_SYNTAX_PARSER=v2` (the strict parser is the default on Nextflow 26+). To validate a change without a cluster (a parse check plus a stubbed end-to-end run), see **Testing / verifying changes** below.

## Critical invariant: the image-name contract

`modules/check_build_apptainer.nf` derives the cached filename as:

```
<docker-uri with ':' and '/' replaced by '-'> + '.img'
```

**This must stay byte-for-byte identical to Nextflow's own `SingularityCache.simpleName()`** (strip `docker://`, replace `:` and `/` with `-`, append `.img`). The entire pipeline only works because the names it writes are exactly the names the downstream Nextflow run looks up. Changing this transform — or feeding image URIs that include a `docker://` prefix or a `.sif` suffix — silently produces cache *misses* downstream with no error. Treat this as a hard constraint when editing the naming logic.

## Cache-dir coupling (the whole point)

`--apptainer_cache_dir` is meaningful only if it is the **same directory the real downstream workflow uses as its Apptainer cache** (`apptainer.cacheDir` / `NXF_APPTAINER_CACHEDIR`). The two runs are linked solely by writing to / reading from that shared directory; nothing enforces this, so it must be kept consistent by the operator.

## Architecture / data flow

Three source files, top to bottom:

1. **`main.nf`** — entry point. Validates the three required params, then calls `wf_apptainer(...)`. Also wires up an optional completion email (`lib/EmailTemplate.groovy` + `assets/email_template.html`).
2. **`workflows/apptainer.nf`** (`wf_apptainer`) — the orchestration:
   - `ImageConfig.loadImagesMap` (in `lib/`) uses `ConfigSlurper` to parse a Groovy config and pull out its `params.images` map. The source can be a **local path or an `http(s)`/`file` URL** — it tries `new URL(...)` first and falls back to treating the input as a file. Note: `ConfigSlurper` *executes* the config as Groovy, so the source must be trusted.
   - Base and override maps are loaded eagerly, merged in plain Groovy (`base_map + override_map`, override wins **by key**), and **guarded**: if the merged map is empty the workflow `error`s (`No images to build…`) rather than silently building nothing. The merged values then feed `Channel.fromList(...).flatten()`, one Docker image URI per item.
   - Note: the "strict" base load does **not** reject a config that merely lacks `params.images` — `ConfigSlurper` coerces the missing key to an empty map, so that case yields an empty merge and is caught by the guard above, not by `loadImagesMap`.
3. **`modules/check_build_apptainer.nf`** (`CHECK_BUILD_APPTAINER`) — runs per image, on the executor (cluster node). Checks the cache/tmp dirs, exports `APPTAINER_CACHEDIR`/`APPTAINER_TMPDIR`, and **skips if the target `.img` already exists**, otherwise `apptainer pull` then `mv` into the cache.

**Input config format** (the `--docker_images_file`):
```groovy
params {
    images = [
        ubuntu: 'ubuntu:22.04',
        diann:  'quay.io/protio/diann:1.8.1',
    ]
}
```
This is intentionally the same `container_images.config` file the *target* pipeline already uses for its container definitions (single source of truth), e.g. `https://raw.githubusercontent.com/mriffle/nf-skyline-dia-ms/main/container_images.config`.

## Caching & execution model (non-obvious)

- **Caching is filesystem-based, not Nextflow-based.** The process declares no `output:`; idempotency comes from the in-script `[ -f cache/<name> ]` check, not from `-resume`. Re-runs are cheap because hits no-op in the shell.
- **Execution is serial by design.** Both profiles set `executor.queueSize = 1`, so images build one at a time. This is the implicit guard against concurrent `apptainer pull` operations corrupting the shared `APPTAINER_CACHEDIR` layer cache. Raising the queue size reintroduces that race.

## Config & profiles

- `nextflow.config` defines params + two profiles. `standard` (Nextflow's default profile name, so it applies when no `-profile` is given) runs `local`. `sge_maccoss` is a **template to copy and edit** for an SGE cluster — `process.queue` is a placeholder (`'your queue name'`) and `clusterOptions` computes per-CPU memory for `-l mfree=`.
- `conf/base.config` holds the nf-core-style `process_*` resource labels; the build process uses `process_low`. Task requests scale with `task.attempt` and are capped by **`process.resourceLimits`** (a default in `base.config`, overridden per profile in `nextflow.config`). This replaced the old nf-core `check_max()` helper (removed for Nextflow 26 / strict-parser compatibility). The error strategy retries on scheduler-kill exit codes (137/143/null/…) with escalating `task.attempt` resources.

## Conventions & patterns

- **DSL2 structure:** one process per file in `modules/` with `UPPER_SNAKE_CASE` names; subworkflows in `workflows/` with a `wf_` prefix; reusable Groovy classes in `lib/`. Params are `snake_case`.
- **New (strict) Nextflow language.** The `.nf` files must satisfy the strict parser (default on NF26; `NXF_SYNTAX_PARSER=v2` on NF25). Practical consequences: workflow event handlers are **sections inside the entry workflow** (`workflow { main: … onComplete: … }`), *not* a top-level `workflow.onComplete {}`; avoid C-style casts (`(Map) x` → `x as Map`); and keep imperative Groovy (ConfigSlurper, `new URL`/`File`, try/catch, multi-statement closures) **out of `.nf` bodies** — put it in a `lib/` class, which the strict parser does not govern. When unsure, run the harness on NF26: it surfaces strict-syntax errors.
- **Runtime locations use `val`, never `path`.** Host directories that already exist when tasks run (cache, tmp, scratch) are passed as `val` so the absolute path reaches the script verbatim; `path` would stage them as basename symlinks. See the High item under "Known issues" for the failure modes this caused.
- **Process script blocks:** compute Groovy vars (e.g. `image_ref`, `apptainer_image_name`) *above* the triple-quoted shell string, then interpolate with `${...}`. The shell runs under `bash -euo pipefail` (`process.shell` in `nextflow.config`), so commands fail loudly.
- **Every process implements a `stub:` block** that faithfully mirrors its real outputs/side effects and branches. `CHECK_BUILD_APPTAINER`'s stub reuses the name transform, runs the same directory existence/writability checks, and honors the same cache-skip-vs-build branch — only the `apptainer pull` + `mv` is replaced by `touch`. This keeps `-stub-run` exercising the real control flow (incl. missing/unwritable dirs and the already-cached skip) and underpins the planned stub-based harness — when you add a process, add a comparably faithful stub in the same change.
- **Resources** come from the nf-core `process_*` labels in `conf/base.config`, capped by `process.resourceLimits` (a default in `base.config`, overridden per profile). Reuse an existing label; add a `withName:` block only when a process needs something specific. Do **not** reintroduce the old `check_max()` helper — it was removed for strict-parser / NF26 compatibility.
- **Never diverge from Nextflow's own conventions** for anything the downstream run depends on — above all the image-name transform (see "Critical invariant").

## Testing / verifying changes

The repo ships a **self-contained harness**: `tests/run_tests.sh`. It runs the full scenario matrix via `nextflow -stub-run` against pinned Nextflow versions and asserts behavior. No Apptainer and no network are needed for the tests themselves (the process `stub:` does the work); only the first run needs internet, to fetch the Nextflow distributions.

```bash
tests/run_tests.sh                                 # all scenarios on the pinned versions (25.10.0 + 26.04.3)
NF_VERSIONS="25.10.5 26.04.3" tests/run_tests.sh   # override the version list
tests/run_tests.sh -k naming                       # only tests whose name contains "naming"
```

How it stays reproducible and clutter-free on any machine:
- Downloads the Nextflow launcher into `tests/.nf/` and uses a **local `NXF_HOME`** (`tests/.nf/home`), so version JARs cache there, never in `~/.nextflow`.
- Sets `NXF_SYNTAX_PARSER=v2` so the same code runs on NF25 (strict opt-in) and NF26 (strict default).
- Every run lives under `tests/.work/<version>/<test>/` (work dir, logs, configs, caches). Both `tests/.nf/` and `tests/.work/` are git-ignored.
- Exit status is 0 only if every scenario passes on every version.

**CI:** `.github/workflows/ci.yml` runs this harness on every push (and via manual dispatch). Each Nextflow version is a separate matrix job, so 25 and 26 run in parallel on their own runners (`fail-fast: false`); the matrix mirrors the harness's pinned versions, the distribution is cached per version, and `-stub-run` keeps each job within the 2-vCPU/7-GB runner limits. Keep the CI matrix and the harness's `NF_VERSIONS` default in sync when bumping supported versions.

Scenarios covered: the three required-param guards; base-config loading (local file, `file://` URL, nonexistent, missing/empty/non-map `params.images`); base+override merge (disjoint + overlapping keys → override wins); the image-name transform (bare tag, registry path, `docker://` prefix, untagged, registry-with-port); fan-out; shared-basename dirs (the `path`→`val` regression); a missing cache dir; and the pre-seeded cache-skip path. To add a scenario, write a `_t_<name>` function and list it in the `TESTS` array. Console output a scenario asserts on lives in the task's `.command.out` (use the `assert_taskout` helper), not the main Nextflow log.

Lower-level spot checks when iterating: `nextflow config -profile standard` (parse, set `NXF_SYNTAX_PARSER=v2` on NF25); a single `-stub-run` invocation; and inspecting `.command.sh` / `.command.out` in the work dir. To exercise the *real* `script:` path (not the stub), put a stub `apptainer` on `PATH` and run without `-stub-run`. Clean up scratch dirs afterward.

## Known issues / rough edges

Findings from a full audit (2026-05-28), captured so future sessions don't need to re-audit. Grouped by severity; each has a location and the suggested fix. None have been fixed yet unless this list says so. Verified empirically against Nextflow 25.10.4 where noted.

### High

- [x] **Cache/tmp dirs used the `path` qualifier instead of `val`** — `modules/check_build_apptainer.nf:6-7`. **FIXED 2026-05-28** (both inputs changed `path` → `val`). Declaring an output/cache *destination* as `path` made Nextflow stage it as a symlink under its **basename**, so in the rendered script `${apptainer_cache_directory}` became just `cache` (relative), not the absolute path. Consequences (all were confirmed by inspecting `.command.sh`, and the fix was verified to resolve all of them):
  - Error messages printed the basename, e.g. `ERROR: Apptainer cache directory does not exist: cache`.
  - `APPTAINER_CACHEDIR`/`APPTAINER_TMPDIR` were exported as relative strings (`cache`/`tmp`); worked only because CWD is the task dir and the symlink resolves.
  - The in-script existence/writability checks were effectively dead — Nextflow fails to *stage* a non-existent path before the script runs, yielding a cryptic staging error instead of the friendly one.
  - **Hard failure** when `apptainer_cache_dir` and `apptainer_tmp_dir` shared a basename (e.g. `/scratch/cache/apptainer` + `/scratch/tmp/apptainer`): `input file name collision -- multiple input files for ... apptainer` (reproduced, then verified fixed).
  - On executors that *copy* inputs instead of symlinking (`stageInMode 'copy'`), the symlink assumption broke entirely — the `mv` would have landed the image inside the ephemeral work dir, silently never reaching the cache. Also resolved by `val`.
  - With `val`, absolute paths pass through literally, messages are correct, env vars are absolute, the existence checks are meaningful, and the collision is gone. The caller (`workflows/apptainer.nf`) already passes these as `Channel.value(...)` of param strings, so no caller change was needed.

### Medium

- [x] **Wrong error messages for two of the three required params** — `main.nf:18-24`. **FIXED 2026-05-28** — the `apptainer_cache_dir` and `apptainer_tmp_dir` guards now name the correct param (verified: a missing `--apptainer_cache_dir` reports `ERROR: apptainer_cache_dir is not set`).
- [x] **`docker://`-prefix normalization in the name transform** — `modules/check_build_apptainer.nf`. **FIXED 2026-05-28** — a leading `docker://` is stripped (`image_ref = docker_image_location.replaceFirst('^docker://','')`) before computing the cached name *and* the pull URI, so a `docker://…` config entry now yields the correct `….img` name (matching Nextflow's lookup) and a single, non-doubled `docker://…` pull (both verified). Note: `.sif`-suffix and untagged-image handling from Nextflow's `simpleName` are *not* mirrored — `.sif` is N/A to `docker://` pulls, and for an untagged image this transform matches Nextflow's own naming anyway.
- [ ] **One unreachable image aborts the whole run** — a pull failure (auth/private registry/transient) retries 3× then `finish`es the entire pipeline. For a "pre-build everything I can" tool, per-image tolerance (`errorStrategy 'ignore'` or an `error_ignore` label on the process) may be preferable so one bad image doesn't block the rest.
- [ ] **`APPTAINER_CACHEDIR` points at the final-image directory** — `modules/check_build_apptainer.nf` (the `export APPTAINER_CACHEDIR=...` line). Apptainer's OCI blob/layer cache accumulates inside the same dir that holds the finished `.img` files, bloating it. Fix: point the layer cache under the tmp dir (or a dedicated dir) and keep only finished `.img` files in the cache dir.
- [x] **Cache↔downstream coupling documented** — **FIXED 2026-05-28** — README has a "Using the built images in your workflow" section documenting the coupling and the naming scheme. (`main.nf`'s startup banner briefly carried an explicit `apptainer.cacheDir` / `NXF_APPTAINER_CACHEDIR` reminder too, but that runtime message was removed on request; the banner now shows only the resolved param values.) Still *unenforced* in code (no hard failure on mismatch — there's nothing to check against at build time), but documented.
- [ ] **No per-process resource override; large pulls may OOM on first attempt** — `modules/check_build_apptainer.nf` uses `label 'process_low'` (8 GB) with no `withName:CHECK_BUILD_APPTAINER` block. Converting a large multi-GB image (e.g. ProteoWizard) can exceed 8 GB; the `errorStrategy` retry escalates to `task.attempt * 8.GB` so it recovers, but the first attempt and its cluster allocation are wasted. Fix: bump the label or add a `withName` override sized for the heaviest image.
- [ ] **`params.images` values assumed to be scalar strings** — `workflows/apptainer.nf` builds `docker_images_ch` from `merged_map.values()`, which only holds if every value is a single image URI. A nested Map or list value would `flatten()` into garbage names that then fail to pull. Fine for the documented `container_images.config` format, but unguarded. Fix: validate each value is a non-blank String.
- [x] **Silent zero-build when `params.images` is missing/empty** — **FIXED 2026-05-28** — `workflows/apptainer.nf` now `error`s with `No images to build…` if the merged map is empty (a base config lacking `params.images`, an empty/`[:]` map, or a wrong/empty file). Previously this "succeeded" with zero builds — the exact silent no-op the tool exists to prevent. Verified under `-stub-run`. (`ConfigSlurper` coerces a missing key to an empty map, so the old "strict" load never caught it.)

### Low / hygiene

- [ ] **`docker_images_override_file` defaults to a bare relative name** — `nextflow.config:13` (`'images-override.config'`), resolved against the launch dir, so an unrelated file with that name is silently picked up. Now *documented* in the README (2026-05-28), but the code fix — default to `null` — is still open.
- [x] **`ConfigSlurper` executes the config source as Groovy** — `workflows/apptainer.nf` (`loadImagesMap`). Effectively arbitrary code execution from the supplied file/URL on the head node. **Trust assumption now documented in the README (2026-05-28).** The behavior itself is inherent to `ConfigSlurper` and intentionally unchanged.
- [ ] **Leftover branding in the email template** — `assets/email_template.html` is still titled "TEI-REX DDA Pipeline", so completion emails are branded TEI-REX. Cosmetic. (The stale `nextflow.config` header was corrected 2026-05-28 during the resourceLimits migration.) (See "Provenance note".)
- [x] **Over-engineered map merge** — **FIXED 2026-05-28** — `workflows/apptainer.nf` now loads/merges the base and override maps eagerly in plain Groovy (`base_map + override_map`) and feeds `Channel.fromList(merged_map.values().toList()).flatten()`, dropping the `Channel.of(...).combine(...)` machinery. (Done as part of adding the empty-merge guard.)
- [ ] **`apptainer pull` stdout suppressed** — `modules/check_build_apptainer.nf` redirects the pull's stdout to `/dev/null`. Apptainer writes errors to stderr (still captured in `.command.err`), so failures aren't hidden, but progress/info is lost on a step that often fails (network, bad tag, OCI auth). Fix: drop the `> /dev/null` for better debuggability.
- [ ] **Cache write is not atomic across concurrent runs** — `modules/check_build_apptainer.nf` does check-not-exists → `apptainer pull --name X` (into the work dir) → `mv X cache/`. `queueSize = 1` serializes this *within* a run, but two separate runs targeting the same cache can both pull and the second `mv` clobbers. Low risk. Fix: `mv -n`, or pull to a temp name and atomically rename.
- [ ] **Retry list includes crash signals** — `conf/base.config:8` retries on exit `134` (SIGABRT) and `139` (SIGSEGV) alongside scheduler-kill codes. Retrying genuine crashes is questionable, but it's inherited nf-core boilerplate and bounded by `maxRetries`. Debatable / low priority; revisit only if crash-loops waste cluster time.
- [ ] **Dead `dummy` workflow** — near the end of `main.nf`. Harmless leftover; remove for clarity.
- [x] **`Path` not in Groovy's default imports** — **FIXED 2026-05-28** — the helper moved to `lib/ImageConfig.groovy` (during the strict-syntax migration) and that file has an explicit `import java.nio.file.Path`.
- [x] **`// TODO nf-core` markers left in from the template** — **FIXED 2026-05-28** — removed when `conf/base.config` was rewritten for `resourceLimits`.
- [ ] **Partial repo scaffolding** — **`.gitignore`, a test harness (`tests/run_tests.sh`), and GitHub Actions CI (`.github/workflows/ci.yml` — NF25+NF26 matrix on every push) added 2026-05-28.** Still missing: `manifest.version`, `nextflow_schema.json`, and a `report`/`timeline`/`trace`/`dag` config block (cheap and useful for a build job — consider adding one).
- [x] **README documentation gaps** — **FIXED 2026-05-28** — README now has a Parameters table (all params incl. the override and `email`), a "Using the built images in your workflow" section (cached-`.img` naming scheme + the downstream `apptainer.cacheDir` / `NXF_APPTAINER_CACHEDIR` coupling), and a Notes section (the `queueSize = 1` rationale and how to raise it, plus the `ConfigSlurper` trust caveat).

### Notes (not bugs)

- **`queueSize = 1` serialization** is intentional (the guard against concurrent `apptainer pull` corrupting the shared layer cache, and it avoids hammering registries / blowing up tmp space), not a defect — but it does forgo cluster parallelism, so a 30-image config pulls one at a time. See "Caching & execution model". Raise it via `executor.queueSize`; parallelizing safely would also require per-task cache dirs. This trade-off should be documented in the README (see the README-gaps item).
- **Nextflow version & language support** — floor is **25.10** (first release with the strict parser); developed against 25.10.x and 26.04.3. The strict (new) language is the default on 26+ and opt-in on 25 via `NXF_SYNTAX_PARSER=v2`. The harness pins 25.10.0 + 26.04.3 and passes on both.
- **Work in progress on branch `nextflow26`** — uncommitted at time of writing: the `check_max`→`resourceLimits` migration, the strict-syntax conversion (`main.nf` `onComplete:` section, `lib/ImageConfig.groovy`), and the test harness. (This branch is no longer identical to `main`.)

## Provenance note

`lib/EmailTemplate.groovy`, `assets/email_template.html`, and the `conf/base.config` resource labels are adapted from the nf-core template and other MacCoss-lab pipelines; some strings (e.g. "TEI-REX", "nf-maccoss-trex" header) are leftover branding, not indicators of this pipeline's purpose.
