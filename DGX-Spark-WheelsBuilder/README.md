# DGX-Spark Wheels Builder

Builds GPU wheels and **exports them to disk** (no Comfy, no runtime entrypoint).

## Automatic (script)

Runs build + export in one command:

```bash
./export_wheels.sh
```

Wheels will be here:

```text
DGX-Spark-WheelsBuilder/Wheels/
  flash-attn3/*.whl
  onnxruntime/*.whl
```

## Manual (docker buildx)

Build and export without the script:

```bash
docker buildx build -t dgx-spark-wheelsbuilder \
  -o type=local,dest=DGX-Spark-WheelsBuilder/Wheels \
  DGX-Spark-WheelsBuilder
```

## Notes

- Requires Docker with `buildx` enabled (default on recent Docker).
- Change image tag if needed: `IMAGE_TAG=my-tag ./export_wheels.sh`.
