# Architecture diagram provenance

`architecture.svg` is the editable source; `architecture.png` is its CPU-rendered 720 x 510 export. Both describe this repository's documented workflow, not a deployment or a record of the models used to author this documentation.

## Sources and meaning

- Source contract: [`SKILL.md`](../skills/luna-team-build/SKILL.md), [`planning-council.md`](../skills/luna-team-build/references/planning-council.md), and [`scheduler-v2.md`](../skills/luna-team-build/references/scheduler-v2.md), inspected at repository commit `412d983d23b369d6f2572c1916fc6dab29551133`.
- GPT-5.6 Sol remains the root conductor. The five Council views are planning lenses inside its thread: Strategist, Skeptic, Creative, Operator, and Audience Advocate. The Sol card represents all five together.
- Sol freezes contracts, ownership, task IDs, dependencies, handoffs, and checks in the Plan Card. `k` is the total selected Luna task/session count from zero through seven. At zero, Sol completes and verifies directly; no Luna worker runs.
- For positive `k`, isolated GPT-5.6 Luna `codex exec` sessions share the filesystem and provide terminal handoffs. Sol integrates successful results and owns combined verification. Failure skips the failed predecessor's descendants while unrelated branches continue.
- Schema v1 is the default independent ready wave. Schema v2 admits a frozen static DAG; its `concurrency_limit` is the simultaneous-active cap, separate from total task count. Rolling scheduling unlocks successors on success. Barrier mode is reserved for an A/B benchmark or documented compatibility investigation.
- The dashed `$council` branch is separate, full external planning advice and applies when explicitly invoked or required by a separately documented high-risk gate. It is not an automatically launched set of five workers. The diagram is an overview of the default and optional paths; high-risk gates remain governed by the source contract.

## Artwork and export

All sun, crescent moon, document/DAG, folder, and check symbols are original geometric artwork authored for this repository. They are conceptual Sol/Luna/function icons, not official OpenAI or model-brand logos. No external logo files, fonts, or images are embedded or fetched. The source artwork is covered by the repository's [MIT License](../LICENSE); model names remain descriptive references and imply no affiliation or endorsement.

The visual reference was the user-provided synthetic logo rendering compatibility image: a dark dotted canvas, light rounded cards, short names below icons, and curved gray directed connectors. Its example marks and example topology are not reused.

The SVG is self-contained and includes an accessible title and relationship description. The README carries an adjacent text explanation, an inline PNG, and links to this provenance and the editable SVG. Text uses the system Arial/Helvetica/sans-serif stack; the Linux CPU rasterizer may substitute an installed equivalent. Main labels are 28 source pixels (approximately 14 pixels when displayed at 360 pixels wide).

PNG export uses the already installed `rsvg-convert`; browser screenshots use the already installed Chrome with `--headless --disable-gpu`. No renderer installation, model/runtime change, credentials change, or GPU workload is needed.

Re-export from the repository root:

```sh
rsvg-convert --width 720 --height 510 assets/architecture.svg --output assets/architecture.png
```

Validation covers SVG XML parsing, PNG dimensions and actual pixels, README relative links, 360-pixel browser display, preserved benchmark artwork/caveats, and secret/private-host scans before publication. The architecture image contains no speedup or performance claim.
