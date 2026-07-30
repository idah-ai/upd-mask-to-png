# UPD Mask Annotation to PNG Converter

Extracts all `binary_mask` annotations from a UPD (Universal Portable Dataset) file and converts them to PNG mask images.

Each mask is saved as `<entry-name>__<category>.png` in the output directory.

## Requirements

- Ruby 3.0+
- `chunky_png` gem (optional, for faster PNG encoding)
- `updcli` binary — the [UPD CLI tool](https://github.com/idah-ai/updcli)

```bash
gem install chunky_png
```

## Usage

```bash
ruby main.rb \
  --input /path/to/export.upd \
  --output-dir ./mask_output
```

### Options

| Option         | Required | Description                                             |
| -------------- | -------- | ------------------------------------------------------- |
| `--input`      | Yes      | Path to the UPD file                                    |
| `--output-dir` | No       | Output directory for mask PNGs (default: ./mask_output) |
| `--updcli`     | No       | Path to `updcli` binary (default: `updcli`)             |

> **Note:** The `updcli` binary is distributed separately. Download the latest release from [github.com/idah-ai/updcli](https://github.com/idah-ai/updcli).

## How It Works

The script walks the UPD file structure automatically:

1. Lists all entries and annotations via `updcli`
2. Fetches entry names (for output filenames)
3. For each `binary_mask` annotation:
   - Extracts the shape data (tile keys with RLE-encoded binary masks)
   - Decodes each tile: Base64 → raw bytes → varint unpack → RLE → 128×128 pixel buffer
   - Assembles tiles into the full image grid
   - Saves as `<entry-name>__<category>.png`

## Decoding Pipeline

```
UPD file
   |
   v
entry list + annotation list
   |
   v
For each binary_mask annotation:
   annotation show → JSON shape
   |
   v
   JSON: { "tile-0x0": { "rle": "BQM=" }, ... }
   |
   v
   For each tile:
     Base64 decode
       |
       v
     Raw bytes
       |
       v
     Unpack varint (1 or 2 bytes per run)
       |
       v
     Run-length list [R0, R1, R2, ...]
       |
       v
     Reconstruct 128×128 pixel buffer (0/1)
       |
       v
   Assemble tiles into full image grid
       |
       v
   <entry-name>__<category>.png
```

## License

FSL-1.1-ALv2 — see [LICENSE.md](LICENSE.md).
