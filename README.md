# UPD Annotation to PNG Mask Converter

Extracts annotations from a UPD (Universal Portable Dataset) file and renders them as PNG mask images. Supports the following annotation shape types:

- **`idah-image:mask`** — Binary masks from tile-based RLE encoding (filled)
- **`idah-image:bounding-box`** — Bounding box outlines (2px border)
- **`idah-image:circle`** — Circle outlines (2px border)
- **`idah-image:line`** — Line strokes (1px wide)

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

- **Per-category masks**: Saved as `<output-dir>/<category>/<entry-name>.png` — grayscale (white = shape, black = background). All shapes of the same category are merged into a single image. Filled masks are drawn first, outline shapes on top.
- **Combined masks**: Saved as `<output-dir>/combined/<entry-name>.png` — RGB, each category shown in a distinct color (16-color palette, cycles for more than 16 categories). Every entry with at least one categorized mask gets a combined mask.
- **`category_colors.txt`**: A reference file mapping each category name to its assigned hex color.

## Requirements

- Ruby 3.0+
- `chunky_png` gem (optional, for faster PNG encoding)
- `updcli` binary — the [UPD CLI tool](https://github.com/idah-ai/updcli)

```bash
gem install chunky_png
```

## Usage

```bash
# Process all supported shape types (mask, bounding-box, circle, line)
ruby main.rb \
  --input /path/to/export.upd \
  --output-dir ./mask_output

# Process only masks and bounding boxes
ruby main.rb \
  --input /path/to/export.upd \
  --output-dir ./mask_output \
  --shape-types mask,bounding-box

# Process only circles
ruby main.rb \
  --input /path/to/export.upd \
  --output-dir ./mask_output \
  --shape-types circle

# Process only specific entries by ID
ruby main.rb \
  --input /path/to/export.upd \
  --output-dir ./mask_output \
  --entry-ids 019fc610-930c-713c-8783-82e91bbb35ef,019fc611-930c-713c-8783-82e91bbb35ef
```

### Options

| Option              | Required | Description                                                          |
| ------------------- | -------- | -------------------------------------------------------------------- |
| `--input`           | Yes      | Path to the UPD file                                                 |
| `--output-dir`      | No       | Output directory for mask PNGs (default: ./mask_output)              |
| `--updcli`          | No       | Path to `updcli` binary (default: `updcli`)                          |
| `--shape-types`     | No       | Comma-separated shape types to process (default: all). Options: `mask`, `bounding-box` (or `bb`), `circle`, `line` |
| `--entry-ids`       | No       | Comma-separated entry IDs to process (default: all). Example: `--entry-ids id1,id2` |

> **Note:** The `updcli` binary is distributed separately. Download the latest release from [github.com/idah-ai/updcli](https://github.com/idah-ai/updcli).

## How It Works

The script walks the UPD file structure automatically:

1. Lists all entries and annotations via `updcli`
2. Fetches entry names (for output filenames)
3. For each annotation with a supported shape type:
   - **`idah-image:mask`**: Extracts tile keys with RLE-encoded binary masks → decodes each tile (Base64 → raw bytes → varint unpack → RLE → 128×128 pixel buffer) → assembles tiles into the full image grid
   - **`idah-image:bounding-box`**: Extracts normalized corner points → renders a 2px border rectangle on the image
   - **`idah-image:circle`**: Extracts center point and radius → renders a 2px border circle on the image
   - **`idah-image:line`**: Extracts start/end points → renders a 1px line using Bresenham's algorithm
   - Groups masks by entry and category
4. Writes per-category masks into `<category>/` subfolders (all shapes merged, filled masks under outlines)
5. Generates combined RGB masks in a `combined/` subfolder (color-coded by category)
6. Writes `category_colors.txt` reference file

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
