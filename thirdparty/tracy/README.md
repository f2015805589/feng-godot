# Tracy (vendored)

Tracy Profiler client sources, vendored for the `feng_godottracy` engine module.

- Upstream: <https://github.com/wolfpld/tracy>
- Version: `v0.11.1` (protocol 69), see `VERSION.txt`
- Contents: `public/` and `LICENSE`, copied verbatim from the upstream tag.
- License: BSD 3-Clause, see `LICENSE`.

Only the client is vendored. The profiler GUI (`tracy-profiler.exe`) is a
separate program, available from the upstream releases page:
<https://github.com/wolfpld/tracy/releases>.

Refresh or change the vendored version with:

```powershell
python misc/scripts/install_tracy.py --version v0.11.1 --force
```

The script replaces `public/`, `LICENSE` and `VERSION.txt` only, so this file
survives an update.

Like every other `thirdparty/` dependency, this directory is excluded from the
repository's pre-commit hooks, so upstream formatting is preserved.

`core/profiling/SCsub` compiles `public/TracyClient.cpp` when the Tracy backend
is selected, which is what the `feng_godottracy` module sets up; see
`modules/feng_godottracy/README.md`.
