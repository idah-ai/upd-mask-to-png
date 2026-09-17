# frozen_string_literal: true

# UPD Annotation to PNG Mask Converter
#
# Extracts annotations from a UPD file and renders them as PNG mask images.
# Supports:
#   - idah-image:mask          (binary masks from tile-based RLE encoding)
#   - idah-image:bounding-box  (bounding box outlines)
#   - idah-image:circle        (circle outlines)
#   - idah-image:line          (line strokes)
#
# Per-category masks are grayscale (white = shape, black = background).
# A combined RGB mask is also generated showing each category in a distinct color.
#
# Usage:
#   ruby main.rb \
#     --input /path/to/export.upd \
#     --output-dir /path/to/output_masks/ \
#     --shape-types mask,bounding-box,circle,line

require "json"
require "base64"
require "optparse"
require "fileutils"
require "shellwords"
require "zlib"

# If chunky_png is available, use it. Otherwise fall back to a minimal
# PNG writer (for binary masks, a simple grayscale PNG is easy to produce).
begin
  require "chunky_png"
  HAVE_CHUNKY_PNG = true
rescue LoadError
  HAVE_CHUNKY_PNG = false
end

# ─────────────────────────────────────────────────────────────────────────────
# RLE Decoder (mirrors scripts/import_binary_masks/rle_encoder.rb)
# ─────────────────────────────────────────────────────────────────────────────
class RleDecoder
  MAX_RUN_LENGTH = 32_767

  # Decode an RLE base64 string back into a flat binary string of 0/1 bytes.
  def decode_to_string(rle, w, h)
    total = w * h
    return "\x00" * total if total == 0 || rle.nil? || rle.empty?

    bytes = rle.unpack1("m0").bytes

    explicit_runs = unpack_run_lengths(bytes)
    sum_explicit = explicit_runs.sum
    implicit_len = total - sum_explicit

    if implicit_len < 0
      raise ArgumentError,
            "RLE data exceeds tile size: sum of explicit runs (#{sum_explicit}) > total pixels (#{total})"
    end

    buffer = "\x00" * total
    offset = 0
    bit = 0

    explicit_runs.each do |run|
      if bit == 1
        run.times { |j| buffer.setbyte(offset + j, 1) }
      end
      offset += run
      bit = 1 - bit
    end

    if bit == 1 && implicit_len > 0
      implicit_len.times { |j| buffer.setbyte(offset + j, 1) }
    end

    buffer
  end

  private

  def unpack_run_lengths(bytes)
    runs = []
    i = 0
    while i < bytes.length
      b0 = bytes[i]
      if b0 & 0x80 != 0
        raise ArgumentError, "Truncated RLE data" if i + 1 >= bytes.length
        runs << (((b0 & 0x7f) << 8) | bytes[i + 1])
        i += 2
      else
        runs << b0
        i += 1
      end
    end
    runs
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# UPD CLI wrapper
# ─────────────────────────────────────────────────────────────────────────────
class UpdCli
  def initialize(path)
    @cli = find_updcli(path)
  end

  # List all entry IDs in the UPD file.
  def list_entry_ids(upd_file)
    output = run_cmd("#{@cli} --input #{Shellwords.escape(upd_file)} entry list")
    parse_id_list(output, json: true)
  end

  # List all annotation IDs in the UPD file.
  def list_annotation_ids(upd_file)
    output = run_cmd("#{@cli} --input #{Shellwords.escape(upd_file)} annotation list")
    parse_id_list(output, json: true)
  end

  # Show a single entry (returns its JSON).
  # Output format: "2026-... INFO - entry.show: {"id":"...","media_url":"local:..."}"
  def show_entry(upd_file, entry_id)
    output = run_cmd("#{@cli} --input #{Shellwords.escape(upd_file)} entry show --id #{Shellwords.escape(entry_id)}")
    parse_json_from_log(output)
  end

  # Show a single annotation (returns its JSON).
  # Output format: "2026-... INFO - annotation.show:
  # {"id":"...","entry_id":"...","shape_type":"...","shape_args":{...},"category":"...","properties":{...}}"
  def show_annotation(upd_file, annotation_id)
    output = run_cmd("#{@cli} --input #{Shellwords.escape(upd_file)} annotation show --id #{Shellwords.escape(annotation_id)}")
    parse_json_from_log(output)
  end
# List all annotations with full data in a single subprocess call.
  # Returns an array of annotation hashes with keys: id, entry_id, shape_type,
  # annotation (Hash), shape_args (Hash), metadata (Hash or nil).
  def list_annotations_full(upd_file)
    output = run_cmd("#{@cli} --input #{Shellwords.escape(upd_file)} annotation list")
    parse_full_annotation_list(output)
  end

  private

  def find_updcli(path)
    return path if File.file?(path)

    # Check common locations
    candidates = [
      path,
      "updcli-static",
      "/tmp/updcli-linux-amd64",
      "/tmp/updcli"
    ]

    candidates.each do |candidate|
      return candidate if File.file?(candidate)
    end

    # Try to find via PATH
    found = `which #{Shellwords.escape(path)} 2>/dev/null`.strip
    return found unless found.empty?

    raise <<~MSG
      updcli not found.

      The UPD CLI tool is required to read UPD files.
      It is distributed as a tarball in the IDAH repository:
        https://github.com/idah-ai/idah

      Download and extract it:
        curl -LO https://github.com/idah-ai/idah/releases/download/v0.1.0/updcli-linux-amd64.tar.gz
        tar -xzf updcli-linux-amd64.tar.gz
        mv updcli-linux-amd64 updcli

      Then run with --updcli ./updcli
    MSG
  end

  def run_cmd(cmd)
    output = `#{cmd} 2>&1`
    raise "updcli command failed:\n  #{cmd}\n#{output}" unless $?.success?
    output
  end

  # Parse JSON from a log-prefixed line:
  #   "2026-... INFO - entry.show: {"id":"...",...}"
  # Extracts everything after the first ": " that follows the log prefix.
  def parse_json_from_log(output)
    stripped = output.strip
    return nil if stripped.empty?

    # Find the first colon-space that separates the log prefix from the JSON
    # The log format is: "2026-... INFO - entry.show: {...}"
    colon_idx = stripped.index(": ")
    return nil unless colon_idx

    json_str = stripped[(colon_idx + 2)..]
    return nil if json_str.nil? || json_str.empty?

    JSON.parse(json_str)
  rescue JSON::ParserError
    nil
  end

  # Parse ID list from updcli output.
  #
  # For entry list, output is plain UUIDs per line.
  # For annotation list, output is JSON-per-line with log prefix:
  #   2026-... INFO - annotation.list: {"id":"...","shape_type":"...","shape_args":{...},"category":"...","properties":{...}}
  #
  # @param json [Boolean] if true, parse JSON from each line after the log prefix
  def parse_id_list(output, json: false)
    ids = []
    output.each_line do |line|
      stripped = line.strip
      next if stripped.empty?
      next if stripped.include?("No entries found") || stripped.include?("No annotation found") || stripped.include?("No datasets found")

      if json
        # Extract JSON after the log prefix
        colon_idx = stripped.index(": ")
        next unless colon_idx
        json_str = stripped[(colon_idx + 2)..]
        next if json_str.nil? || json_str.empty?
        begin
          data = JSON.parse(json_str)
          id = data["id"]
          ids << id if id
        rescue JSON::ParserError
          # skip unparseable lines
        end
      else
        # Plain UUID lines
        ids << stripped if stripped.match?(/^[0-9a-f-]+$/i)
      end
    end
    ids
  end
# Parse full annotation data from annotation list output.
  # Each line has format: "2026-... INFO - annotation.list: <json>"
  # Returns array of annotation hashes with all fields from the query.
  def parse_full_annotation_list(output)
    annotations = []
    output.each_line do |line|
      stripped = line.strip
      next if stripped.empty?
      next if stripped.include?("No annotation found") || stripped.include?("No entries found")

      colon_idx = stripped.index(": ")
      next unless colon_idx
      json_str = stripped[(colon_idx + 2)..]
      next if json_str.nil? || json_str.empty?

      begin
        data = JSON.parse(json_str)
        annotations << data if data["id"]
      rescue JSON::ParserError
        # skip unparseable lines
      end
    end
    annotations
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Mask Decoder (tile assembly → full image)
# ─────────────────────────────────────────────────────────────────────────────
# ─────────────────────────────────────────────────────────────────────────────
# Shape Renderer (bounding-box, circle, line → binary mask)
# ─────────────────────────────────────────────────────────────────────────────
class ShapeRenderer
  # Render a bounding box outline (border only, interior transparent).
  #
  # @param width  [Integer] image width in pixels
  # @param height [Integer] image height in pixels
  # @param points [Array<Array<Float>>] 4 normalized corner points [[x1,y1],[x2,y2],[x3,y3],[x4,y4]]
  # @return [String] flat byte string of length width*height (0 = bg, 1 = shape)
  def self.bounding_box(width, height, points)
    pixel_coords = points.map { |x, y| [ (x * width).round, (y * height).round ] }
    xs = pixel_coords.map(&:first)
    ys = pixel_coords.map(&:last)
    min_x = xs.min
    max_x = xs.max
    min_y = ys.min
    max_y = ys.max

    # Clamp to image bounds
    min_x = 0 if min_x < 0
    min_y = 0 if min_y < 0
    max_x = width - 1 if max_x >= width
    max_y = height - 1 if max_y >= height

    image = "\x00".b * (width * height)

    # Draw top 2 rows and bottom 2 rows
    (min_x..max_x).each do |x|
      y = min_y
      image.setbyte(y * width + x, 1) if y >= 0 && y < height
      y = min_y + 1
      image.setbyte(y * width + x, 1) if y >= 0 && y < height
      y = max_y - 1
      image.setbyte(y * width + x, 1) if y >= 0 && y < height
      y = max_y
      image.setbyte(y * width + x, 1) if y >= 0 && y < height
    end
    # Draw left 2 cols and right 2 cols
    (min_y..max_y).each do |y|
      x = min_x
      image.setbyte(y * width + x, 1) if x >= 0 && x < width
      x = min_x + 1
      image.setbyte(y * width + x, 1) if x >= 0 && x < width
      x = max_x - 1
      image.setbyte(y * width + x, 1) if x >= 0 && x < width
      x = max_x
      image.setbyte(y * width + x, 1) if x >= 0 && x < width
    end

    image
  end

  # Render a circle outline (border only, interior transparent).
  #
  # @param width  [Integer] image width in pixels
  # @param height [Integer] image height in pixels
  # @param center [Array<Float>] normalized center [cx, cy]
  # @param radius [Float] normalized radius
  # @return [String] flat byte string of length width*height (0 = bg, 1 = shape)
  def self.circle(width, height, center, radius)
    cx = (center[0] * width).round
    cy = (center[1] * height).round
    r  = (radius * [width, height].max).round
    r  = 1 if r < 1

    image = "\x00".b * (width * height)

    # Bounding box of the circle
    min_y = [cy - r, 0].max
    max_y = [cy + r, height - 1].min
    min_x = [cx - r, 0].max
    max_x = [cx + r, width - 1].min

    r2 = r * r
    inner2 = (r - 0.5) * (r - 0.5)
    outer2 = (r + 0.5) * (r + 0.5)
    # Draw only pixels within 1 pixel of the true radius (outline)
    (min_y..max_y).each do |y|
      dy = y - cy
      dy2 = dy * dy
      base = y * width
      (min_x..max_x).each do |x|
        dx = x - cx
        dist2 = dx * dx + dy2
        if dist2 >= inner2 && dist2 <= outer2
          image.setbyte(base + x, 1)
        end
      end
    end

    image
  end

  # Render a 2-pixel-wide line from two normalized endpoints.
  # Uses a distance-based approach for uniform thickness in all directions.
  #
  # @param width  [Integer] image width in pixels
  # @param height [Integer] image height in pixels
  # @param point_a [Array<Float>] normalized [x, y] start
  # @param point_b [Array<Float>] normalized [x, y] end
  # @return [String] flat byte string of length width*height (0 = bg, 1 = shape)
  def self.line(width, height, point_a, point_b)
    x0 = (point_a[0] * width).round
    y0 = (point_a[1] * height).round
    x1 = (point_b[0] * width).round
    y1 = (point_b[1] * height).round

    image = "\x00".b * (width * height)

    # Compute bounding box of the line with 2px margin
    min_x = [x0, x1].min - 2
    max_x = [x0, x1].max + 2
    min_y = [y0, y1].min - 2
    max_y = [y0, y1].max + 2

    # Clamp to image bounds
    min_x = 0 if min_x < 0
    min_y = 0 if min_y < 0
    max_x = width - 1 if max_x >= width
    max_y = height - 1 if max_y >= height

    dx = x1 - x0
    dy = y1 - y0
    len2 = dx * dx + dy * dy

    (min_y..max_y).each do |y|
      base = y * width
      (min_x..max_x).each do |x|
        # Distance from point (x,y) to line segment (x0,y0)-(x1,y1)
        if len2 == 0
          dist = Math.sqrt((x - x0) * (x - x0) + (y - y0) * (y - y0))
        else
          t = ((x - x0) * dx + (y - y0) * dy).to_f / len2
          t = 0.0 if t < 0.0
          t = 1.0 if t > 1.0
          proj_x = x0 + t * dx
          proj_y = y0 + t * dy
          dist = Math.sqrt((x - proj_x) * (x - proj_x) + (y - proj_y) * (y - proj_y))
        end
        image.setbyte(base + x, 1) if dist <= 1.5
      end
    end

    image
  end
end
class MaskDecoder
  TILE_SIZE = 128

  def initialize
    @rle_decoder = RleDecoder.new
  end

  # Decode a binary mask annotation into a flat byte string.
  #
  # @param shape [Hash] tile data from the annotation shape
  #   Format: { "tile-0x0" => { "rle" => "base64..." }, ... }
  # @param width [Integer] full image width
  # @param height [Integer] full image height
  # @return [String] flat byte string length width*height (0 = bg, 1 = shape)
  def decode(shape, width, height)
    total = width * height
    return "\x00".b * total if total == 0 || shape.nil? || shape.empty?

    image = "\x00".b * total

    n_cols = (width.to_f / TILE_SIZE).ceil
    n_rows = (height.to_f / TILE_SIZE).ceil
    n_rows.times do |row|
      n_cols.times do |col|
        tile_key = "tile-#{col}x#{row}"

        tile_data = shape[tile_key]
        next if tile_data.nil?

        rle = tile_data.is_a?(Hash) ? tile_data["rle"] : tile_data

        next unless rle.is_a?(String) && !rle.empty?

        tile_pixels = @rle_decoder.decode_to_string(rle, TILE_SIZE, TILE_SIZE)

        TILE_SIZE.times do |py|
          img_y = row * TILE_SIZE + py
          next if img_y >= height

          base_idx = img_y * width + col * TILE_SIZE
          tile_base = py * TILE_SIZE
          row_span = [TILE_SIZE, width - col * TILE_SIZE].min

          # Copy tile row bytes into the image buffer
          row_span.times do |px|
            image.setbyte(base_idx + px, 1) if tile_pixels.getbyte(tile_base + px) == 1
          end
        end
      end
    end

    image
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# PNG Writer
# ─────────────────────────────────────────────────────────────────────────────
class PngWriter
  # Write a grayscale (binary) mask PNG from a flat byte string.
  # @param image [String] flat byte string of length width*height (0 = bg, 1 = shape)
  # @param width [Integer] image width in pixels
  # @param height [Integer] image height in pixels
  def write(image, width, height, path)
    if HAVE_CHUNKY_PNG
      write_with_chunky_png(image, width, height, path)
    else
      write_minimal_png(image, width, height, path)
    end
  end

  # Write a combined RGB mask where each byte in the flat string is a category index.
  # @param combined_image [String] flat byte string of length width*height (0 = bg, 1+ = category)
  def write_combined(combined_image, width, height, path)
    if HAVE_CHUNKY_PNG
      write_combined_chunky(combined_image, width, height, path)
    else
      write_combined_minimal(combined_image, width, height, path)
    end
  end

  private

  # Pre-defined palette of maximally distinct colors (index 0 = background = black).
  CATEGORY_COLORS = [
    [0, 0, 0],       # 0: background (black)
    [255, 0, 0],     # 1: red
    [0, 255, 0],     # 2: green
    [0, 0, 255],     # 3: blue
    [255, 255, 0],   # 4: yellow
    [255, 0, 255],   # 5: magenta
    [0, 255, 255],   # 6: cyan
    [255, 128, 0],   # 7: orange
    [128, 0, 255],   # 8: purple
    [128, 255, 0],   # 9: lime
    [255, 0, 128],   # 10: deep pink
    [0, 200, 128],   # 11: teal
    [128, 64, 0],    # 12: brown
    [0, 128, 128],   # 13: dark cyan
    [128, 0, 0],     # 14: maroon
    [0, 0, 128],     # 15: navy
  ].freeze

  COLOR_NAMES = [
    "background",     # 0
    "red",            # 1
    "green",          # 2
    "blue",           # 3
    "yellow",         # 4
    "magenta",        # 5
    "cyan",           # 6
    "orange",         # 7
    "purple",         # 8
    "lime",           # 9
    "deep pink",      # 10
    "teal",           # 11
    "brown",          # 12
    "dark cyan",      # 13
    "maroon",         # 14
    "navy",           # 15
  ].freeze

  def category_color(index)
    CATEGORY_COLORS[index % CATEGORY_COLORS.length]
  end

  def write_with_chunky_png(image, width, height, path)
    png = ChunkyPNG::Image.new(width, height)
    total = width * height
    total.times do |i|
      y = i / width
      x = i % width
      pixel = image.getbyte(i)
      png[x, y] = pixel == 1 ? ChunkyPNG::Color.rgb(255, 255, 255) : ChunkyPNG::Color.rgb(0, 0, 0)
    end
    png.save(path)
  end

  def write_combined_chunky(combined_image, width, height, path)
    png = ChunkyPNG::Image.new(width, height)
    total = width * height
    total.times do |i|
      y = i / width
      x = i % width
      idx = combined_image.getbyte(i)
      r, g, b = category_color(idx)
      png[x, y] = ChunkyPNG::Color.rgb(r, g, b)
    end
    png.save(path)
  end

  # Minimal PNG writer (no external dependencies).
  # @param image [String] flat byte string of 0/1 values
  def write_minimal_png(image, width, height, path)
    signature = [137, 80, 78, 71, 13, 10, 26, 10].pack("C*")

    ihdr_data = [width, height].pack("N2") + [8, 0, 0, 0, 0].pack("C5") # 8-bit grayscale
    ihdr = build_chunk("IHDR", ihdr_data)

    raw_data = +""
    height.times do |y|
      raw_data << 0x00 # filter byte (none)
      row_start = y * width
      width.times do |x|
        raw_data << (image.getbyte(row_start + x) == 1 ? 255 : 0).chr
      end
    end

    compressed = Zlib::Deflate.deflate(raw_data)
    idat = build_chunk("IDAT", compressed)
    iend = build_chunk("IEND", "")

    File.open(path, "wb") do |f|
      f.write(signature)
      f.write(ihdr)
      f.write(idat)
      f.write(iend)
    end
  end

  # Write combined RGB PNG from a flat byte string of category indices.
  def write_combined_minimal(combined_image, width, height, path)
    signature = [137, 80, 78, 71, 13, 10, 26, 10].pack("C*")

    # 8-bit truecolor (RGB)
    ihdr_data = [width, height].pack("N2") + [8, 2, 0, 0, 0].pack("C5")
    ihdr = build_chunk("IHDR", ihdr_data)

    raw_data = +""
    height.times do |y|
      raw_data << 0x00 # filter byte (none)
      row_start = y * width
      width.times do |x|
        idx = combined_image.getbyte(row_start + x)
        r, g, b = category_color(idx)
        raw_data << r.chr << g.chr << b.chr
      end
    end

    compressed = Zlib::Deflate.deflate(raw_data)
    idat = build_chunk("IDAT", compressed)
    iend = build_chunk("IEND", "")

    File.open(path, "wb") do |f|
      f.write(signature)
      f.write(ihdr)
      f.write(idat)
      f.write(iend)
    end
  end

  def build_chunk(type, data)
    len = [data.bytesize].pack("N")
    crc = Zlib.crc32(type + data)
    len + type + data + [crc].pack("N")
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

# The UPD CLI stores the annotation type in the "shape_type" field of the JSON output.
SHAPE_TYPE_MASK          = "idah-image:mask"
SHAPE_TYPE_BOUNDING_BOX  = "idah-image:bounding-box"
SHAPE_TYPE_CIRCLE        = "idah-image:circle"
SHAPE_TYPE_LINE          = "idah-image:line"
SUPPORTED_SHAPE_TYPES    = [SHAPE_TYPE_MASK, SHAPE_TYPE_BOUNDING_BOX, SHAPE_TYPE_CIRCLE, SHAPE_TYPE_LINE].freeze

# Mapping of short names (for --shape-types CLI option) to full shape type strings.
SHAPE_TYPE_SHORT_NAMES = {
  "mask"          => SHAPE_TYPE_MASK,
  "bounding-box"  => SHAPE_TYPE_BOUNDING_BOX,
  "bb"            => SHAPE_TYPE_BOUNDING_BOX,
  "circle"        => SHAPE_TYPE_CIRCLE,
  "line"          => SHAPE_TYPE_LINE,
}.freeze

def main
  options = parse_options

  # Initialize components
  updcli = UpdCli.new(options[:updcli])
  decoder = MaskDecoder.new
  writer = PngWriter.new

  output_dir = options[:output_dir]
  FileUtils.mkdir_p(output_dir)

  # ───────────────────────────────────────────────────────────────────────
  # Step 1: Fetch all annotations in a single subprocess call (BIG WIN).
  # The `annotation list` command already returns all fields needed:
  # id, entry_id, shape_type, annotation (category), shape_args (tile RLE,
  # points, etc.), and metadata — no per-annotation subprocess needed.
  # ───────────────────────────────────────────────────────────────────────
  puts "  Fetching all annotations..."
  all_annotations = updcli.list_annotations_full(options[:input])
  puts "  Found #{all_annotations.length} annotations"

  # Filter out unsupported shape types early
  all_annotations = all_annotations.select do |ann|
    st = ann["shape_type"] || ""
    SUPPORTED_SHAPE_TYPES.include?(st)
  end

  # Filter by --shape-types when specified
  if options[:shape_types]
    all_annotations = all_annotations.select do |ann|
      options[:shape_types].include?(ann["shape_type"])
    end
  end

  # Filter by --entry-ids when specified
  if options[:entry_ids]
    selected = options[:entry_ids]
    all_annotations = all_annotations.select { |ann| selected.include?(ann["entry_id"]) }
  end

  puts "  Processing #{all_annotations.length} supported annotations..."

  # Group annotations by entry_id for per-entry processing
  annotations_by_entry = {}
  all_annotations.each do |ann|
    eid = ann["entry_id"]
    next unless eid
    annotations_by_entry[eid] ||= []
    annotations_by_entry[eid] << ann
  end

  # ───────────────────────────────────────────────────────────────────────
  # Step 2: Collect all entry IDs and fetch entry metadata
  # ───────────────────────────────────────────────────────────────────────
  entry_ids = annotations_by_entry.keys
  entry_info = {}
  entry_ids.each do |eid|
    entry_data = updcli.show_entry(options[:input], eid)
    next unless entry_data

    metadata = entry_data["metadata"] || {}
    name = metadata["Name"] || eid
    img_w = normalize_dim_value(metadata["Width"])
    img_h = normalize_dim_value(metadata["Height"])

    entry_info[eid] = {
      name: name,
      width: img_w,
      height: img_h
    }
  end

# ───────────────────────────────────────────────────────────────────────
  # Step 3: Build global category-to-index mapping for consistent colors
  # ───────────────────────────────────────────────────────────────────────
  all_categories = []
  all_annotations.each do |ann|
    cat = ann["category"] || ""
    if cat && !cat.empty? && !all_categories.include?(cat)
      all_categories << cat
    end
  end
  global_category_indices = {}
  all_categories.each_with_index do |cat, idx|
    global_category_indices[cat] = idx + 1
  end

  # Write category colors reference file
  colors_path = File.join(output_dir, "category_colors.txt")
  File.open(colors_path, "w") do |f|
    f.puts "Category-to-Color Mapping for Combined Masks"
    f.puts "Generated from UPD file: #{options[:input]}"
    f.puts "=" * 60
    f.puts ""
    all_categories.each_with_index do |cat, idx|
      color_idx = idx + 1
      rgb = PngWriter::CATEGORY_COLORS[color_idx % PngWriter::CATEGORY_COLORS.length]
      hex = "#%02x%02x%02x" % rgb
      f.puts "  #{cat.ljust(30)} → #{hex}"
    end
    f.puts ""
    f.puts "Note: Index 0 (black / #000000) is reserved for non-masked areas."
  end
  puts "  → #{colors_path}"

  # ───────────────────────────────────────────────────────────────────────
  # Step 4: Process each entry one at a time (memory-efficient).
  #
  # For each entry:
  #   1. Decode/render each annotation into a flat byte string
  #   2. Merge into per-category buffer (immediate OR, no individual storage)
  #   3. Collect shape info for combined mask (shape_type, category, image)
  #   4. Write per-category PNGs
  #   5. Build combined mask (filled shapes first, then outlines on top)
  #   6. Write combined PNG
  #   7. Free all memory for this entry before processing the next
  # ───────────────────────────────────────────────────────────────────────
  success = 0
  combined_count = 0
  skipped = 0

  annotations_by_entry.each do |entry_id, entry_annotations|
    info = entry_info[entry_id]
    entry_name = info ? info[:name] : entry_id

    # Per-category merged buffers: category_name => flat byte String
    cat_buffers = {}
    # Track shapes for combined mask: [{ category:, shape_type:, image: }]
    shapes_for_combined = []

    entry_annotations.each do |annotation|
      aid = annotation["id"]
      shape_type = annotation["shape_type"] || ""
      category = annotation["category"] || ""
      shape_args = annotation["shape_args"] || {}

      # Extract shape data (tile keys for masks, full args for others)
      if shape_type == SHAPE_TYPE_MASK
        shape = shape_args.select { |k, _| k.start_with?("tile-") }
      else
        shape = shape_args
      end

      # Determine image dimensions
      width, height = nil, nil
      if info && info[:width] && info[:height] && info[:width] > 0 && info[:height] > 0
        width = info[:width]
        height = info[:height]
      else
        ann_metadata = annotation["metadata"] || {}
        width = normalize_dim_value(ann_metadata["width"]) || normalize_dim_value(ann_metadata["Width"])
        height = normalize_dim_value(ann_metadata["height"]) || normalize_dim_value(ann_metadata["Height"])

        if width.nil? || height.nil? || width <= 0 || height <= 0
          if shape_type == SHAPE_TYPE_MASK
            tile_keys = shape.keys.select { |k| k.start_with?("tile-") }
            if tile_keys.any?
              max_col = 0
              max_row = 0
              tile_keys.each do |key|
                m = key.match(/tile-(\d+)x(\d+)/)
                next unless m
                max_col = m[1].to_i if m[1].to_i > max_col
                max_row = m[2].to_i if m[2].to_i > max_row
              end
              width = (max_col + 1) * 128
              height = (max_row + 1) * 128
            else
              warn "  ⚠ Skipping annotation #{aid}: no tile data found"
              skipped += 1
              next
            end
          else
            warn "  ⚠ Skipping annotation #{aid}: cannot determine image dimensions"
            skipped += 1
            next
          end
        end
      end

      puts "  [entry #{entry_name}] Processing #{shape_type} category '#{category}' (#{width}x#{height})"
      begin
        # Decode/render shape into flat byte string
        image = case shape_type
                when SHAPE_TYPE_MASK
                  decoder.decode(shape, width, height)
                when SHAPE_TYPE_BOUNDING_BOX
                  points = shape["points"] || []
                  ShapeRenderer.bounding_box(width, height, points)
                when SHAPE_TYPE_CIRCLE
                  center = shape["points"][0] || [0, 0]
                  radius = shape["radius"] || 0
                  ShapeRenderer.circle(width, height, center, radius)
                when SHAPE_TYPE_LINE
                  points = shape["points"] || []
                  point_a = points[0] || [0, 0]
                  point_b = points[1] || [0, 0]
                  ShapeRenderer.line(width, height, point_a, point_b)
                else
                  raise "Unsupported shape type: #{shape_type}"
                end

        # Merge into per-category buffer (OR operation)
        if category && !category.empty?
          cat_buffers[category] ||= "\x00".b * (width * height)
          cat_buf = cat_buffers[category]
          total = width * height
          total.times do |i|
            cat_buf.setbyte(i, 1) if image.getbyte(i) == 1
          end
        end

        # Store shape info for the combined mask (preserves process order,
        # which is used to draw filled masks before outline shapes)
        shapes_for_combined << {
          category: category,
          shape_type: shape_type,
          image: image,
          width: width,
          height: height
        }
      rescue => e
        warn e.full_message
        skipped += 1
      end
    end # entry_annotations.each

    # Determine effective entry dimensions (entry metadata, else from shapes)
    entry_width = info && info[:width] ? info[:width] : 0
    entry_height = info && info[:height] ? info[:height] : 0
    if entry_width == 0 || entry_height == 0
      if shapes_for_combined.any?
        entry_width = shapes_for_combined.first[:width]
        entry_height = shapes_for_combined.first[:height]
      end
    end

    # ───────────────────────────────────────────────────────────────────
    # Write per-category PNGs (each category is a fully merged grayscale mask)
    # ───────────────────────────────────────────────────────────────────
    cat_buffers.each do |category, buffer|
      if category && !category.empty?
        safe_category = category.tr("/", "_")
        cat_dir = File.join(output_dir, safe_category)
        FileUtils.mkdir_p(cat_dir)
        output_path = File.join(cat_dir, "#{entry_name}.png")
      else
        output_path = File.join(output_dir, "#{entry_name}.png")
      end

      writer.write(buffer, entry_width, entry_height, output_path)
      puts "    → #{output_path}"
      success += 1
    end

    # ───────────────────────────────────────────────────────────────────
    # Build and write combined RGB mask
    # ───────────────────────────────────────────────────────────────────
    categorized_shapes = shapes_for_combined.select { |s| s[:category] && !s[:category].empty? }
    if categorized_shapes.any?
      total = entry_width * entry_height
      combined = "\x00".b * total

      # Sort: filled masks first, outline shapes on top (overwrite masks)
      sorted_shapes = categorized_shapes.sort_by { |s| s[:shape_type] == SHAPE_TYPE_MASK ? 0 : 1 }

      sorted_shapes.each do |s|
        idx = global_category_indices[s[:category]] || 1
        img = s[:image]
        total.times do |i|
          combined.setbyte(i, idx) if img.getbyte(i) == 1
        end
      end

      combined_dir = File.join(output_dir, "combined")
      FileUtils.mkdir_p(combined_dir)
      combined_path = File.join(combined_dir, "#{entry_name}.png")
      writer.write_combined(combined, entry_width, entry_height, combined_path)
      puts "    → #{combined_path} (combined, #{categorized_shapes.length} shapes)"
      combined_count += 1
    end

    # Free memory for this entry before processing the next
    cat_buffers.clear
    shapes_for_combined.clear
  end # annotations_by_entry.each

  puts "\nDone: #{success} individual mask(s) extracted, #{combined_count} combined mask(s) generated, #{skipped} skipped"
end
def normalize_dim_value(val)
  return nil if val.nil?
  val = val.to_s.strip
  return nil if val.empty?
  val.to_i
end

def sanitize_filename(name)
  name.gsub(/[^a-zA-Z0-9_\-. ]/, "_")
end

# ─────────────────────────────────────────────────────────────────────────────
# CLI
# ─────────────────────────────────────────────────────────────────────────────
def parse_options
  options = {
    updcli: "updcli",
    output_dir: "./mask_output"
  }

  OptionParser.new do |opts|
    opts.banner = "Usage: #{$PROGRAM_NAME} [options]"

    opts.on("--input UPD_FILE", "Path to the UPD file") do |v|
      options[:input] = v
    end

    opts.on("--output-dir DIR", "Output directory for mask PNGs (default: ./mask_output)") do |v|
      options[:output_dir] = v
    end

    opts.on("--updcli PATH", "Path to updcli binary (default: updcli)") do |v|
      options[:updcli] = v
    end

    opts.on("--shape-types TYPES", "Comma-separated shape types to include (default: all). " \
                                   "Options: mask, bounding-box (bb), circle, line. " \
                                   "Example: --shape-types mask,bounding-box") do |v|
      selected = v.split(",").map(&:strip).map(&:downcase)
      types = selected.map { |s| SHAPE_TYPE_SHORT_NAMES[s] }
      missing = selected.zip(types).select { |_, t| t.nil? }.map(&:first)
      unless missing.empty?
        puts "Unknown shape type(s): #{missing.join(', ')}. Valid options: #{SHAPE_TYPE_SHORT_NAMES.keys.join(', ')}"
        exit 1
      end
      options[:shape_types] = types
    end

    opts.on("--entry-ids IDS", "Comma-separated entry IDs to process (default: all). " \
                               "Example: --entry-ids 019fc610-930c-713c-8783-82e91bbb35ef,019fc611-...") do |v|
      options[:entry_ids] = v.split(",").map(&:strip)
    end

    opts.on("-h", "--help", "Print help") do
      puts opts
      exit
    end
  end.parse!

  unless options[:input]
    puts "Missing required option: --input"
    puts "Usage: #{$PROGRAM_NAME} --input <upd_file> [--output-dir <dir>]"
    exit 1
  end

  unless File.exist?(options[:input])
    puts "Error: input file not found: #{options[:input]}"
    exit 1
  end

  options
end

main if $PROGRAM_NAME == __FILE__