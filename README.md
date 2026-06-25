<p align="center">
  <picture>
    <source media="(prefers-color-scheme: light)" srcset="./assets/openllm-light.svg">
    <img alt="OpenLLM" src="./assets/openllm.svg" width="300">
  </picture>
</p>

<p align="center"><b>openllmr</b> — the OpenLLM plugin / skill / setup registry.</p>

---

The installable extensions the OpenLLM gateway serves: **plugins**, Claude-Code
**skills**, and client **setup** targets. `main` mirrors the current source of
every bundleable `plugin/`, `skill/`, and `setup/` slug; each
`<area>/<slug>` also ships as its own GitHub **release**
(`<area>/<slug>@<version>`) with a reproducible `bundle.tar.gz` the gateway
redirects to (verified against a committed digest).

> **Read-only mirror.** Regenerated from the
> [openllm](https://github.com/quantidexyz/openllm) monorepo each release. PRs
> welcome — ingested upstream with your authorship preserved. See each area's
> `CONTRIBUTING`.
