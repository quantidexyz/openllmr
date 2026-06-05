# openllmr — OpenLLM bundle registry

Public release host for OpenLLM's **setup / skill / plugin** bundles.

Each GitHub Release here carries one bundle's reproducible `bundle.tar.gz`
(+ `.sha256`), tagged `area/slug@version` (e.g. `skill/image-generation@1.0.0`).

These are **not** the source of truth. The committed
`packages/registry/registry.ts` manifest in the main `openllm` repo pins each
bundle's `sha256` — a two-origin integrity anchor. The OpenLLM gateway
302-redirects `/api/{plugins,skills,setup}/<slug>/bundle.tar.gz` to the asset
here; the install script verifies the download against the committed digest
before extracting, so the digest gates exactly what runs.

Published by `packages/registry/scripts/pack.ts` in the main repo. Do not
push by hand.
