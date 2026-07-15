# experiments

Parked explorations. **Not part of the app** — nothing here is needed to build,
run, or use WhisperOwn. Kept because the findings were worth keeping.

- **`fluid-proto/`** — a Swift proto that runs the same Parakeet model on the Apple
  Neural Engine via [FluidAudio](https://github.com/FluidInference/FluidAudio)
  (CoreML/ANE) instead of the GPU via MLX. Built to answer "is the ANE faster?"
  Answer, measured: no — the warm MLX server was 2.6–3.6× faster as built, so the
  app ships MLX. See [docs/BENCHMARKS.md](../docs/BENCHMARKS.md).
