# UPD Mask Annotation to PNG Converter

Extracts all `binary_mask` annotations from a UPD (Universal Portable Dataset) file and converts them to PNG mask images.

## Output Structure

Masks are organized into category-named subfolders. For entries with at least one category, a combined RGB mask is also generated in a `combined/` subfolder.

```
mask_output/
  <category-1>/
    <entry-name-1>.png
    <entry-name-2>.png
  <category-2>/
    <entry-name-1>.png
  combined/
    <entry-name-1>.png   (combined, color-coded: category-1=red, category-2=green, ...)
    <entry-name-2>.png   (combined, color-coded: category-1=red)
```

- **Per-category masks**: Saved as `<output-dir>/<category>/<entry-name>.png` — grayscale (white = mask, black = background)
- **Combined masks**: Saved as `<output-dir>/combined/<entry-name>.png` — RGB, each category shown in a distinct color (16-color palette, cycles for more than 16 categories). Every entry with at least one categorized mask gets a combined mask.

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
   - Groups masks by entry and category
4. Writes per-category masks into `<category>/` subfolders
5. Generates combined RGB masks in a `combined/` subfolder (color-coded by category)

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
   Group by entry + category
       |
       v
   <category>/<entry-name>.png  (per-category grayscale)
   combined/<entry-name>.png    (combined RGB, color-coded)
```

## License

FSL-1.1-ALv2 — see [LICENSE.md](LICENSE.md).
