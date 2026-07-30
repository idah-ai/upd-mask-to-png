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
  def write(image, path)
    height = image.length
    width = image[0].length

    if HAVE_CHUNKY_PNG
      write_with_chunky_png(image, width, height, path)
    else
      write_minimal_png(image, width, height, path)
    end
  end

  private

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

  # Step 2: Fetch entry metadata (build a map entry_id → name)
  entry_names = {}
  entries.each do |eid|
    entry_data = updcli.show_entry(options[:input], eid)

    next unless entry_data

    # The entry show output has: { "id" => "...", "media_url" => "local:...?name=..." }
    # Extract the entry name from the media_url query param
    media_url = entry_data["media_url"] || ""
    name_from_url = media_url[/[?&]name=([^&]+)/, 1]
    entry_names[eid] = name_from_url || eid
  end

  # Step 3: Process each annotation
  success = 0
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

    # Get entry_id from annotation data
    # The exporter now embeds _entry_id and _metadata in the annotation field
    # since `annotation show` doesn't return the top-level entry_id or metadata
    ann_data = annotation["annotation"] || {}
    entry_id = ann_data["_entry_id"] || annotation["entry_id"]
    entry_name = entry_names[entry_id] || entry_id || annotation["id"] || "unknown"

    # Determine category from annotation annotation data
    category = ann_data["category"] || ""

    # Build output filename: <entry_name>__<category>.png
    if category && !category.empty?
      safe_category = category.tr("/", "_")
      output_path = File.join(output_dir, "#{entry_name}__#{safe_category}.png")
    else
      output_path = File.join(output_dir, "#{entry_name}__mask.png")
    end

    # Get shape data — the shape is stored under "shape_args" key
    # For mask annotations, the shape contains tile keys like "tile-0x0"
    # Filter out non-tile keys (e.g. "points" which is an array)
    shape = (annotation["shape_args"] || {}).select { |k, _| k.start_with?("tile-") }

    # Determine dimensions from metadata
    metadata = annotation["metadata"] || {}
    width = normalize_dim_value(metadata["width"]) || normalize_dim_value(metadata["Width"])
    height = normalize_dim_value(metadata["height"]) || normalize_dim_value(metadata["Height"])

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

    # Decode mask
    puts "  Decoding: #{File.basename(output_path)} (#{width}x#{height})"
    begin
      image = decoder.decode(shape, width, height)
      writer.write(image, output_path)
      puts "    → #{output_path}"
      success += 1
    rescue => e
      # warn "  ✗ Failed to decode annotation #{aid}: #{e.message}"
      warn e.full_message
      skipped += 1
    end
  end

  puts "\nDone: #{success} mask(s) extracted, #{skipped} skipped"
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