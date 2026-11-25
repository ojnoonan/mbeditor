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

    class LimitExceededError < StandardError; end

    # Never useful to an assistant and often most of a bundle's bytes. Listed
    # in the index as skipped, so the assistant knows they exist.
    GENERATED = /(\A(package-lock\.json|yarn\.lock|pnpm-lock\.yaml)\z)|\.(lock|map)\z|\.min\.(js|css)\z/

    # Lossless by construction: file bytes are written exactly as they are, so a
    # diff made against the unpacked copy applies to the real workspace.
    #
    # The pieces below feed both the bundle's own header and .prompt, so the
    # two cannot drift.
    UNPACK_SNIPPET = <<~'PY'
      BUNDLE = "/mnt/data/bundle.md"
      import os, re, subprocess
      text = open(BUNDLE, encoding="utf-8", newline="").read()
      pat = re.compile(r"^=== FILE: (.+?) \((\d+) lines( no-eol)?\) ===\n(.*?)^=== END FILE: \1 ===$", re.S | re.M)
      for m in pat.finditer(text):
          body = m.group(4)[:-1] if m.group(3) else m.group(4)
          dest = os.path.join("project", m.group(1))
          os.makedirs(os.path.dirname(dest), exist_ok=True)
          with open(dest, "w", encoding="utf-8", newline="") as f:
              f.write(body)
      def git(*a): subprocess.run(["git", *a], cwd="project", check=True)
      git("init", "-q"); git("config", "core.autocrlf", "false"); git("add", "-A", "-f")
      git("-c", "user.name=bundle", "-c", "user.email=bundle@example.invalid", "commit", "-qm", "base")
    PY

    WORKFLOW = <<~'TEXT'
      - Find code with `grep -rn` and `sed -n 'A,Bp'`. Print only the lines you need.
      - Edit the files in ./project.
      - Reply with the `git diff` output in one ```diff block. If it is long, also save it as `changes.patch` for download.
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
    def self.prompt(filename)
      snippet = UNPACK_SNIPPET.sub(/^BUNDLE = .*$/) { "BUNDLE = #{"/mnt/data/#{filename}".to_json}" }
      "`#{filename}` is a large source bundle. Do not open, read or print it directly.\n" \
      "Load it only from your code sandbox with this snippet (adjust BUNDLE if the path differs):\n\n" \
      "```python\n#{snippet}```\n\nThen:\n#{WORKFLOW}\n#{DIFF_RULES}\n\nTASK: "
    end

    def initialize(workspace_root)
      @root = workspace_root.to_s.chomp("/")
    end

    # +full_paths+ are absolute, already through resolve_path. Returns
    # { markdown:, files:, bytes: } where +files+ counts included files.
    def build(full_paths)
      entries = ArchiveService.new(@root).collect(full_paths).uniq { |e| e[:name] }.sort_by { |e| e[:name] }
      raise "Nothing to bundle" if entries.empty?

      skipped, wanted = entries.partition { |e| GENERATED.match?(File.basename(e[:name])) }
      total = wanted.sum { |e| e[:size] }
      if total > MAX_BYTES
        raise LimitExceededError,
              "Selection is too large (#{human(total)}). Limit is #{human(MAX_BYTES)}."
      end

      included = []
      wanted.each do |e|
        text = read_text(e[:path])
        text ? included << [e[:name], text] : skipped << e.merge(binary: true)
      end

      markdown = render(included, skipped.sort_by { |e| e[:name] })
      { markdown: markdown, files: included.length, bytes: markdown.bytesize }
    end

    private

    def read_text(path)
      data = File.binread(path)
      return nil if data.byteslice(0, BINARY_PROBE_BYTES).include?("\0")

      data.force_encoding(Encoding::UTF_8)
      data.valid_encoding? ? data : nil
    rescue SystemCallError
      nil
    end

    def render(included, skipped)
      out = +"# #{File.basename(@root)}\n\n## Instructions\n\n#{INSTRUCTIONS}\n## Index\n\n"
      included.each { |name, text| out << "- #{name} (#{line_count(text)} lines, #{text.bytesize} bytes)\n" }
      skipped.each do |e|
        out << "- #{e[:name]} skipped (#{e[:binary] ? "binary or not UTF-8" : "generated"}, #{human(e[:size])})\n"
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
