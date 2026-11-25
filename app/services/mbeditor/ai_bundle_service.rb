# frozen_string_literal: true

module Mbeditor
  # Renders a selection of workspace files as one markdown document to hand to
  # a web chat, which replies with a unified diff for PatchApplyService.
  #
  # The walk is ArchiveService#collect, so containment, exclusions and the
  # symlink skip are identical to the tar download.
  class AiBundleService
    # A refusal, not a truncation: a bundle with files silently missing makes
    # the assistant edit against a project it has only partly seen. Large on
    # purpose: the consumer is a sandbox that greps it, not a context window.
    MAX_BYTES = 64 * 1024 * 1024
    BINARY_PROBE_BYTES = 8 * 1024
    # Copilot accepts three attachments at a time; parts travel as one zip, but
    # the cap per part is what keeps each member small enough to unpack.
    MAX_PARTS = 3
    EXCLUDE_FLAGS = File::FNM_PATHNAME | File::FNM_DOTMATCH | File::FNM_EXTGLOB

    class LimitExceededError < StandardError; end

    # Never useful to an assistant and often most of a bundle's bytes. Listed
    # in the index as skipped, so the assistant knows they exist.
    GENERATED = /(\A(package-lock\.json|yarn\.lock|pnpm-lock\.yaml)\z)|\.(lock|map)\z|\.min\.(js|css)\z/

    # Never sent to a third-party chat. Hard-coded on purpose: a bundle is
    # uploaded wholesale, so this is not something a config key should loosen.
    def self.secret?(rel)
      base = File.basename(rel).downcase
      return true if rel.start_with?("config/credentials/") || rel.include?("/config/credentials/")
      return false if %w[.env.example .env.sample].include?(base)

      base == ".env" || base.start_with?(".env.") || base.start_with?("id_rsa") ||
        base.end_with?(".key", ".pem", ".p12")
    end

    # config.ai_bundle_exclude: workspace-relative globs that are never sent. A
    # pattern without a "/" matches the basename at any depth. Only ever adds to
    # secret?.
    def self.excluded?(rel)
      Array(Mbeditor.configuration.ai_bundle_exclude).any? do |pat|
        pat = pat.to_s
        File.fnmatch?(pat, pat.include?("/") ? rel : File.basename(rel), EXCLUDE_FLAGS)
      end
    end

    # "<name>-bundle.md" -> "<name>-bundle-K-of-N.md"
    def self.part_filename(filename, part, parts)
      filename.sub(/\.md\z/, "-#{part}-of-#{parts}.md")
    end

    # "<name>-bundle.md" -> "<name>-bundle.zip"
    def self.zip_filename(filename)
      filename.sub(/\.md\z/, ".zip")
    end

    # Lossless by construction: file bytes are written exactly as they are, so a
    # diff made against the unpacked copy applies to the real workspace.
    #
    # The pieces below feed both the bundle's own header and .prompt, so the
    # two cannot drift.
    UNPACK_SNIPPET = <<~'PY'
      BUNDLE = "/mnt/data/bundle.md"
      import os, re, subprocess, zipfile
      if BUNDLE.endswith(".zip"):
          with zipfile.ZipFile(BUNDLE) as z: texts = [z.read(n).decode("utf-8") for n in sorted(z.namelist())]
      else:
          texts = [open(BUNDLE, encoding="utf-8", newline="").read()]
      hdr = re.compile(r"^=== FILE: ([^\n]+?) \((\d+) lines( no-eol)?\) ===\n", re.M)
      for text in texts:
          pos = 0
          while True:
              m = hdr.search(text, pos)
              if not m: break
              end = m.end()
              for _ in range(int(m.group(2))): end = text.index("\n", end) + 1
              body = text[m.end():end]
              if m.group(3): body = body[:-1]
              pos = end
              dest = os.path.join("project", m.group(1))
              os.makedirs(os.path.dirname(dest), exist_ok=True)
              with open(dest, "w", encoding="utf-8", newline="") as f:
                  f.write(body)
      def git(*a): return subprocess.run(["git", *a], cwd="project", check=True, capture_output=True)
      if not os.path.isdir("project/.git"): git("init", "-q"); git("config", "core.autocrlf", "false")
      git("add", "-A", "-f")
      amend = subprocess.run(["git", "rev-parse", "-q", "--verify", "HEAD"], cwd="project", capture_output=True).returncode == 0
      git("-c", "user.name=bundle", "-c", "user.email=bundle@example.invalid", "commit", "-q", "--allow-empty", "-m", "base", *(["--amend"] if amend else []))
    PY

    WORKFLOW = <<~'TEXT'
      - Find code with `grep -rn` and `sed -n 'A,Bp'`. Print only the lines you need.
      - Edit the files in ./project.
      - Reply with the `git diff` output in one ```diff block. If it is long, also save it as `changes.patch` for download.
      - Change only what the task asks. No refactors, renames or reformatting it did not ask for.
      - If the task is ambiguous, ask one short question before editing instead of guessing.
      - Keep replies short: the diff, then at most 3 one-line bullets for anything I must know. No restating the task, no walkthrough of the code, no summary.
      - Never paste file contents or command output back to me.
      - Follow-ups in this chat reuse ./project; rerun the snippet only after a new upload.
    TEXT

    DIFF_RULES = "Diff rules: `diff --git a/p b/p`, `--- a/p`, `+++ b/p`; paths relative to the project root; " \
                 "3 lines of context; never elide or summarise lines inside a hunk; new files `--- /dev/null`; " \
                 "deleted files `+++ /dev/null`; no prose inside the block."

    INSTRUCTIONS = "Do not read this file top to bottom. It is a source bundle.\n\n" \
                   "If you have a code sandbox, unpack it (set BUNDLE to the uploaded path):\n\n" \
                   "```python\n#{UNPACK_SNIPPET}```\n\nThen:\n#{WORKFLOW}\n" \
                   "With no sandbox, use the index below to pick files, and read only those between their " \
                   "`=== FILE: <path>` and `=== END FILE: <path> ===` lines.\n\n#{DIFF_RULES}\n"

    # Paste-ready message to send with the uploaded bundle. The chat may read
    # the whole file before it reaches the header, so this goes first. Needs
    # only the bundle's file name; no files are read.
    #
    # +filename+ is the unsplit .md name. With +parts+ > 1 the single upload is
    # the matching .zip.
    def self.prompt(filename, parts = 1)
      attached = parts > 1 ? zip_filename(filename) : filename
      snippet = UNPACK_SNIPPET.sub(/^BUNDLE = .*$/) { "BUNDLE = #{"/mnt/data/#{attached}".to_json}" }
      what = parts > 1 ? "a zip of #{parts} markdown parts of one large source bundle" : "a large source bundle"
      "`#{attached}` is #{what}. Do not open, read or print it directly.\n" \
        "Load it only from your code sandbox with this snippet (adjust BUNDLE if the path differs):\n\n" \
        "```python\n#{snippet}```\n\nThen:\n#{WORKFLOW}\n#{DIFF_RULES}\n\nTASK: "
    end

    def initialize(workspace_root)
      @root = workspace_root.to_s.chomp("/")
    end

    def bundle_name
      "#{File.basename(@root)}-bundle.md"
    end

    # +full_paths+ are absolute, already through resolve_path. Returns
    # { parts:, bytes: }: the fewest parts (1..MAX_PARTS) that each fit under
    # MAX_BYTES, from the sizes the walk already has. Raises LimitExceededError
    # when even MAX_PARTS parts do not fit.
    def plan(full_paths)
      texty, = classify(full_paths)
      groups = choose_groups(texty)
      { parts: groups.length, bytes: texty.sum { |e| e[:size] } }
    end

    # Returns { data:, parts:, files:, bytes: }. +data+ is the markdown when
    # parts is 1, else a zip of parts markdown files named by part_filename.
    # +bytes+ is the rendered markdown size, summed over parts.
    #
    # Files are sorted by path and cut into contiguous runs of roughly equal
    # bytes, so the split is the same on every request and no file straddles
    # two parts. Lossless by construction: see UNPACK_SNIPPET.
    def build(full_paths)
      texty, skipped = classify(full_paths)
      groups = choose_groups(texty)
      skipped = skipped.sort_by { |e| e[:name] }

      files = 0
      docs = groups.each_with_index.map do |group, i|
        included = []
        group.each do |e|
          text = read_text(e)
          text ? included << [e[:name], text] : skipped << e.merge(reason: "binary or not UTF-8")
        end
        files += included.length
        render(included, skipped.sort_by { |e| e[:name] }, i + 1, groups.length)
      end

      data = if docs.length == 1
               docs.first
             else
               ZipWriter.write(docs.each_with_index.map { |md, i| [self.class.part_filename(bundle_name, i + 1, docs.length), md] })
             end
      { data: data, parts: docs.length, files: files, bytes: docs.sum(&:bytesize) }
    end

    private

    # Sorted, de-duplicated walk split into [text entries, skipped entries].
    # Only text counts toward the cap: a binary that is never written to the
    # bundle must not make the selection "too large".
    def classify(full_paths)
      entries = ArchiveService.new(@root).collect(full_paths).uniq { |e| e[:name] }.sort_by { |e| e[:name] }
      raise "Nothing to bundle" if entries.empty?

      skipped = []
      wanted = []
      entries.each do |e|
        e = e.merge(name: utf8(e[:name]))
        reason = skip_reason(e[:name])
        reason ? skipped << e.merge(reason: reason) : wanted << e
      end

      texty = []
      wanted.each { |e| binary?(e) ? skipped << e.merge(reason: "binary or not UTF-8") : texty << e }
      [texty, skipped]
    end

    def choose_groups(texty)
      (1..MAX_PARTS).each do |n|
        groups = partition(texty, n)
        return groups if groups.all? { |g| g.sum { |e| e[:size] } <= MAX_BYTES }
      end
      raise LimitExceededError,
            "Selection is too large (#{human(texty.sum { |e| e[:size] })}) even split into #{MAX_PARTS} parts. " \
            "Limit is #{human(MAX_BYTES)} per part."
    end

    # Each file goes to the part holding its midpoint, which is monotonic in
    # path order (so runs stay contiguous) and balances bytes.
    def partition(entries, parts)
      total = entries.sum { |e| e[:size] }
      cum = 0
      groups = Array.new(parts) { [] }
      entries.each do |e|
        idx = total.zero? ? 0 : [((cum + (e[:size] / 2.0)) * parts / total).floor, parts - 1].min
        groups[idx] << e
        cum += e[:size]
      end
      groups
    end

    # A name with a line break would forge a bundle header; names are listed
    # escaped instead of being bundled.
    def skip_reason(name)
      if self.class.secret?(name) then "secret"
      elsif self.class.excluded?(name) then "excluded by config"
      elsif name.match?(/[\r\n]/) then "unsafe name"
      elsif GENERATED.match?(File.basename(name)) then "generated"
      end
    end

    # Names come off the filesystem in default_external, which is US-ASCII when
    # LANG is unset; tag them UTF-8 so they join the UTF-8 document.
    def utf8(str)
      str.dup.force_encoding(Encoding::UTF_8).scrub
    end

    def binary?(entry)
      File.open(entry[:path], "rb") { |f| f.read(BINARY_PROBE_BYTES).to_s.include?("\0") }
    rescue SystemCallError => e
      raise ArchiveService.read_error(entry[:name], e)
    end

    def read_text(entry)
      data = File.binread(entry[:path])
      data.force_encoding(Encoding::UTF_8)
      data.valid_encoding? ? data : nil
    rescue SystemCallError => e
      raise ArchiveService.read_error(entry[:name], e)
    end

    def render(included, skipped, part, parts)
      title = "# #{utf8(File.basename(@root))}#{" (part #{part} of #{parts})" if parts > 1}"
      note = parts > 1 ? "This is part #{part} of #{parts}, packed in one .zip with the others. Point BUNDLE at the .zip: the snippet unpacks every part into ./project.\n\n" : ""
      out = +"#{title}\n\n## Instructions\n\n#{note}#{INSTRUCTIONS}\n## Index\n\n"
      included.each { |name, text| out << "- #{name} (#{line_count(text)} lines, #{text.bytesize} bytes)\n" }
      skipped.each do |e|
        label = e[:name].match?(/[\r\n]/) ? e[:name].inspect : e[:name]
        detail = e[:reason] == "secret" ? "secret" : "#{e[:reason]}, #{human(e[:size])}"
        out << "- #{label} skipped (#{detail})\n"
      end
      out << "\n"
      included.each do |name, text|
        eol = text.empty? || text.end_with?("\n")
        out << "=== FILE: #{name} (#{line_count(text)} lines#{" no-eol" unless eol}) ===\n" \
               "#{text}#{"\n" unless eol}=== END FILE: #{name} ===\n"
      end
      out
    end

    def line_count(text)
      text.empty? ? 0 : text.count("\n") + (text.end_with?("\n") ? 0 : 1)
    end

    def human(bytes)
      ActiveSupport::NumberHelper.number_to_human_size(bytes)
    end
  end
end
