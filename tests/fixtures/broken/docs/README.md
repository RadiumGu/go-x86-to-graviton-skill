# Benchmark harness

Documentation, not a build file. The command below is amd64-only and is worth a
note, but it is not a pinned build stage:

```bash
docker buildx build -t drill . --platform=linux/amd64
```
