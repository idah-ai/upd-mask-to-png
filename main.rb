# frozen_string_literal: true

# UPD Mask Annotation to PNG Converter
#
# Extracts all binary_mask annotations from a UPD file and converts them
# to PNG mask images.
#
# Usage:
#   ruby scripts/upd_mask_to_png/main.rb \
#     --input /path/to/export.upd \
#     --output-dir /path/to/output_masks/

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

  # Decode an RLE base64 string back into a flat binary array (0s and 1s).
  def decode(rle, w, h)
    total = w * h
    return Array.new(total, 0) if total == 0 || rle.nil? || rle.empty?

    bytes = rle.unpack1("m0").bytes

    explicit_runs = unpack_run_lengths(bytes)
    sum_explicit = explicit_runs.sum
    implicit_len = total - sum_explicit

    if implicit_len < 0
      raise ArgumentError,
            "RLE data exceeds tile size: sum of explicit runs (#{sum_explicit}) > total pixels (#{total})"
    end

    buffer = Array.new(total, 0)
    offset = 0
    bit = 0

    explicit_runs.each do |run|
      if bit == 1
        run.times { |j| buffer[offset + j] = 1 }
      end
      offset += run
      bit = 1 - bit
    end

    if bit == 1 && implicit_len > 0
      implicit_len.times { |j| buffer[offset + j] = 1 }
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
  # Output format: "2026-... INFO - annotation.show: {"id":"...","entry_id":"...","shape_type":"...","annotation":{...}}"
  def show_annotation(upd_file, annotation_id)
    output = run_cmd("#{@cli} --input #{Shellwords.escape(upd_file)} annotation show --id #{Shellwords.escape(annotation_id)}")
    parse_json_from_log(output)
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
  #   2026-... INFO - annotation.list: {"id":"...","shape_type":"...","annotation":{...}}
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
end

# ─────────────────────────────────────────────────────────────────────────────
# Mask Decoder (tile assembly → full image)
# ─────────────────────────────────────────────────────────────────────────────
class MaskDecoder
  TILE_SIZE = 128

  def initialize
    @rle_decoder = RleDecoder.new
  end

  # Decode a binary mask annotation into a 2D pixel array.
  #
  # @param shape [Hash] tile data from the annotation shape
  #   Format: { "tile-0x0" => { "rle" => "base64..." }, ... }
  # @param width [Integer] full image width
  # @param height [Integer] full image height
  # @return [Array<Array<Integer>>] 2D array [y][x] of 0/1 values
  def decode(shape, width, height)
    image = Array.new(height) { Array.new(width, 0) }

    n_cols = (width.to_f / TILE_SIZE).ceil
    n_rows = (height.to_f / TILE_SIZE).ceil
    n_rows.times do |row|
      n_cols.times do |col|
        tile_key = "tile-#{col}x#{row}"

        tile_data = shape[tile_key]
        next if tile_data.nil?

        rle = tile_data.is_a?(Hash) ? tile_data["rle"] : tile_data

        next unless rle.is_a?(String) && !rle.empty?

        tile_pixels = @rle_decoder.decode(rle, TILE_SIZE, TILE_SIZE)

        TILE_SIZE.times do |py|
          img_y = row * TILE_SIZE + py
          next if img_y >= height

          TILE_SIZE.times do |px|
            img_x = col * TILE_SIZE + px
            next if img_x >= width

            image[img_y][img_x] = tile_pixels[py * TILE_SIZE + px]
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
  # Write a grayscale (binary) mask PNG.
  def write(image, path)
    height = image.length
    width = image[0].length

    if HAVE_CHUNKY_PNG
      write_with_chunky_png(image, width, height, path)
    else
      write_minimal_png(image, width, height, path)
    end
  end

  # Write a combined RGB mask where each category index maps to a distinct color.
  # The `combined_image` is a 2D array [y][x] of integer category indices (0 = background).
  def write_combined(combined_image, path)
    height = combined_image.length
    width = combined_image[0].length

    if HAVE_CHUNKY_PNG
      write_combined_chunky(combined_image, width, height, path)
    else
      write_combined_minimal(combined_image, width, height, path)
    end
  end

  private

  # Pre-defined palette of distinct colors (index 0 = background = black).
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
    [0, 255, 128],   # 9: spring green
    [255, 0, 128],   # 10: rose
    [128, 255, 0],   # 11: chartreuse
    [0, 128, 255],   # 12: azure
    [255, 128, 128], # 13: light red
    [128, 255, 128], # 14: light green
    [128, 128, 255], # 15: light blue
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
    "spring green",   # 9
    "rose",           # 10
    "chartreuse",     # 11
    "azure",          # 12
    "light red",      # 13
    "light green",    # 14
    "light blue",     # 15
  ].freeze

  def category_color(index)
    CATEGORY_COLORS[index % CATEGORY_COLORS.length]
  end

  def color_name(index)
    "#{COLOR_NAMES[index % COLOR_NAMES.length]} (#{CATEGORY_COLORS[index % CATEGORY_COLORS.length].inspect})"
  end

  def write_with_chunky_png(image, width, height, path)
    png = ChunkyPNG::Image.new(width, height)

    height.times do |y|
      width.times do |x|
        pixel = image[y][x]
        png[x, y] = pixel == 1 ? ChunkyPNG::Color.rgb(255, 255, 255) : ChunkyPNG::Color.rgb(0, 0, 0)
      end
    end

    png.save(path)
  end

  def write_combined_chunky(combined_image, width, height, path)
    png = ChunkyPNG::Image.new(width, height)

    height.times do |y|
      width.times do |x|
        idx = combined_image[y][x]
        r, g, b = category_color(idx)
        png[x, y] = ChunkyPNG::Color.rgb(r, g, b)
      end
    end

    png.save(path)
  end

  # Minimal PNG writer (no external dependencies).
  def write_minimal_png(image, width, height, path)
    signature = [137, 80, 78, 71, 13, 10, 26, 10].pack("C*")

    ihdr_data = [width, height].pack("N2") + [8, 0, 0, 0, 0].pack("C5") # 8-bit grayscale
    ihdr = build_chunk("IHDR", ihdr_data)

    raw_data = +""
    height.times do |y|
      raw_data << 0x00 # filter byte (none)
      width.times do |x|
        raw_data << (image[y][x] == 1 ? 255 : 0).chr
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

  def write_combined_minimal(combined_image, width, height, path)
    signature = [137, 80, 78, 71, 13, 10, 26, 10].pack("C*")

    # 8-bit truecolor (RGB)
    ihdr_data = [width, height].pack("N2") + [8, 2, 0, 0, 0].pack("C5")
    ihdr = build_chunk("IHDR", ihdr_data)

    raw_data = +""
    height.times do |y|
      raw_data << 0x00 # filter byte (none)
      width.times do |x|
        idx = combined_image[y][x]
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
# Binary mask annotations have type: "idah-image:mask"
SHAPE_TYPE_MASK = "idah-image:mask"

def main
  options = parse_options

  # Initialize components
  updcli = UpdCli.new(options[:updcli])
  decoder = MaskDecoder.new
  writer = PngWriter.new

  output_dir = options[:output_dir]
  FileUtils.mkdir_p(output_dir)

  # Step 1: List all entries and annotations
  entries = updcli.list_entry_ids(options[:input])
  annotation_ids = updcli.list_annotation_ids(options[:input])

  puts "  Found #{entries.length} entries, #{annotation_ids.length} annotations"

  # Step 2: Fetch entry metadata (build a map entry_id → name + dimensions)
  # The entry show output has: { "id" => "...", "metadata" => { "name" => "...", "width" => ..., "height" => ... } }
  entry_info = {}
  entries.each do |eid|
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

  # Step 3: Fetch and decode all mask annotations, grouped by entry_id
  # Each entry in the map: entry_id => { entry_name:, width:, height:, masks: [...] }
  entry_masks = {}
  skipped = 0

  annotation_ids.each do |aid|
    annotation = updcli.show_annotation(options[:input], aid)
    next unless annotation

    # Check if it's a mask annotation — the type is in "shape_type"
    shape_type = annotation["shape_type"] || ""
    unless shape_type == SHAPE_TYPE_MASK
      skipped += 1
      next
    end

    # Get entry_id directly from annotation response
    entry_id = annotation["entry_id"]
    unless entry_id
      warn "  ⚠ Skipping annotation #{aid}: no entry_id"
      skipped += 1
      next
    end

    info = entry_info[entry_id]
    entry_name = info ? info[:name] : entry_id

    # Determine category from annotation data
    ann_data = annotation["annotation"] || {}
    category = ann_data["category"] || ""

    # Get shape data — filter out non-tile keys (e.g. "points")
    shape = (annotation["shape_args"] || {}).select { |k, _| k.start_with?("tile-") }

    # Determine the full image dimensions.
    # Prefer the entry's dimensions from entry metadata (authoritative full image size),
    # then fall back to annotation metadata, then infer from tile keys.
    if info && info[:width] && info[:height] && info[:width] > 0 && info[:height] > 0
      width = info[:width]
      height = info[:height]
    else
      ann_metadata = annotation["metadata"] || {}
      width = normalize_dim_value(ann_metadata["width"]) || normalize_dim_value(ann_metadata["Width"])
      height = normalize_dim_value(ann_metadata["height"]) || normalize_dim_value(ann_metadata["Height"])

      if width.nil? || height.nil? || width <= 0 || height <= 0
        # Fallback: infer from tile keys
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
          width  = (max_col + 1) * 128
          height = (max_row + 1) * 128
        else
          warn "  ⚠ Skipping annotation #{aid}: no tile data found"
          skipped += 1
          next
        end
      end
    end

    # Decode mask at the full entry image dimensions
    puts "  Decoding mask for entry '#{entry_name}', category '#{category}' (#{width}x#{height})"
    begin
      image = decoder.decode(shape, width, height)

      # Group by entry_id
      entry_masks[entry_id] ||= { entry_name: entry_name, width: 0, height: 0, masks: [] }
      entry_masks[entry_id][:width] = [entry_masks[entry_id][:width], width].max
      entry_masks[entry_id][:height] = [entry_masks[entry_id][:height], height].max
      entry_masks[entry_id][:masks] << {
        category: category,
        image: image,
        width: width,
        height: height
      }
    rescue => e
      warn e.full_message
      skipped += 1
    end
  end

  # Step 4: Build a global category-to-index mapping for consistent colors across all entries
  all_categories = []
  entry_masks.each_value do |entry_data|
    entry_data[:masks].each do |m|
      cat = m[:category]
      if cat && !cat.empty? && !all_categories.include?(cat)
        all_categories << cat
      end
    end
  end
  global_category_indices = {}
  all_categories.each_with_index do |cat, idx|
    global_category_indices[cat] = idx + 1
  end

  # Write a reference file mapping each category to its assigned hex color
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

  # Step 5: Write individual mask files (per-category subfolders) and combined masks
  success = 0
  combined_count = 0

  entry_masks.each_value do |entry_data|
    entry_name = entry_data[:entry_name]
    masks = entry_data[:masks]

    # Write individual category masks into category-named subfolders
    masks.each do |mask_data|
      category = mask_data[:category]
      image = mask_data[:image]

      if category && !category.empty?
        safe_category = category.tr("/", "_")
        cat_dir = File.join(output_dir, safe_category)
        FileUtils.mkdir_p(cat_dir)
        output_path = File.join(cat_dir, "#{entry_name}.png")
      else
        output_path = File.join(output_dir, "#{entry_name}.png")
      end

      writer.write(image, output_path)
      puts "    → #{output_path}"
      success += 1
    end

    # Generate a combined mask with each category shown in a different color.
    # Every entry with at least one category gets a combined mask.
    categorized_masks = masks.select { |m| m[:category] && !m[:category].empty? }
    next if categorized_masks.empty?

    # Use the entry's full dimensions for the combined mask
    combined = Array.new(entry_data[:height]) { Array.new(entry_data[:width], 0) }

    # Merge each category mask into the combined image using its global color index
    categorized_masks.each do |m|
      idx = global_category_indices[m[:category]] || 1
      h = m[:height]
      w = m[:width]
      h.times do |y|
        next if y >= entry_data[:height]
        w.times do |x|
          next if x >= entry_data[:width]
          combined[y][x] = idx if m[:image][y][x] == 1
        end
      end
    end

    # Write combined mask in a combined/ subfolder
    combined_dir = File.join(output_dir, "combined")
    FileUtils.mkdir_p(combined_dir)
    combined_path = File.join(combined_dir, "#{entry_name}.png")
    writer.write_combined(combined, combined_path)
    puts "    → #{combined_path} (combined, #{categorized_masks.length} categories)"
    combined_count += 1
  end

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