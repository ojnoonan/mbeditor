# frozen_string_literal: true

require "test_helper"
require "open3"

module Mbeditor
  class AiBundleServiceTest < ActiveSupport::TestCase
    def setup
      @dir = Dir.mktmpdir("mbeditor_bundle_")
      Mbeditor.configuration.excluded_paths = %w[.git tmp]
    end

    def teardown
      FileUtils.rm_rf(@dir)
      Mbeditor.configuration.excluded_paths = Configuration.new.excluded_paths
    end

    def put(rel, content)
      full = File.join(@dir, rel)
      FileUtils.mkdir_p(File.dirname(full))
      File.binwrite(full, content)
      full
    end

    def build(*rels)
      AiBundleService.new(@dir).build(rels.map { |r| File.expand_path(r, @dir) })
    end

    test "renders instructions, index and marker-delimited byte-exact files" do
      put("app/a.rb", "puts 1\n")
      md = build("app")[:markdown]

      assert_includes md, "# #{File.basename(@dir)}"
      assert_includes md, "Do not read this file top to bottom"
      assert_includes md, "- app/a.rb (1 lines, 7 bytes)"
      assert_includes md, "=== FILE: app/a.rb (1 lines) ===\nputs 1\n=== END FILE: app/a.rb ===\n"
      refute_includes md, "```ruby"
    end

    test "prompt names the file, carries the shared snippet and rules, and ends with TASK" do
      prompt = AiBundleService.prompt("proj-bundle.md")

      assert_includes prompt, "`proj-bundle.md` is a large source bundle. Do not open, read or print it directly."
      assert_includes prompt, 'BUNDLE = "/mnt/data/proj-bundle.md"'
      assert_includes prompt, AiBundleService::UNPACK_SNIPPET.lines.drop(1).join
      assert_includes prompt, AiBundleService::DIFF_RULES
      assert_includes prompt, AiBundleService::WORKFLOW
      assert prompt.end_with?("\nTASK: ")
      put("t.txt", "secret-content\n")
      refute_includes prompt, "secret-content"
      assert_includes build("t.txt")[:markdown], AiBundleService::DIFF_RULES
    end

    test "a file without a final newline is flagged no-eol and gets one" do
      put("t.txt", "tail")

      assert_includes build("t.txt")[:markdown], "=== FILE: t.txt (1 lines no-eol) ===\ntail\n=== END FILE: t.txt ===\n"
    end

    test "binary files are skipped and listed" do
      put("img.bin", "ab\0cd")
      put("ok.txt", "hi\n")
      result = build("img.bin", "ok.txt")

      assert_equal 1, result[:files]
      assert_includes result[:markdown], "- img.bin skipped (binary or not UTF-8, 5 Bytes)"
      refute_includes result[:markdown], "=== FILE: img.bin"
    end

    test "lock, minified and map files are skipped but indexed with their size" do
      %w[Gemfile.lock package-lock.json yarn.lock pnpm-lock.yaml app.min.js app.min.css app.js.map].each { |n| put(n, "x" * 2048) }
      put("app.js", "ok\n")
      result = build(".")

      assert_equal 1, result[:files]
      %w[Gemfile.lock package-lock.json yarn.lock pnpm-lock.yaml app.min.js app.min.css app.js.map].each do |n|
        assert_includes result[:markdown], "- #{n} skipped (generated, 2 KB)"
        refute_includes result[:markdown], "=== FILE: #{n}"
      end
    end

    test "excluded paths are not bundled" do
      put("tmp/secret.txt", "nope")
      put("keep.txt", "yes\n")
      md = build(".")[:markdown]

      refute_includes md, "secret.txt"
      assert_includes md, "=== FILE: keep.txt"
    end

    test "a selection over the 64 MB cap is refused with its size" do
      put("big.txt", "a" * (AiBundleService::MAX_BYTES + (1024 * 1024)))
      err = assert_raises(AiBundleService::LimitExceededError) { build("big.txt") }

      assert_equal 64 * 1024 * 1024, AiBundleService::MAX_BYTES
      assert_match(/too large \(65 MB\)\. Limit is 64 MB/, err.message)
    end

    test "skipped files do not count toward the cap" do
      put("huge.lock", "a" * (AiBundleService::MAX_BYTES + 1))
      put("ok.txt", "hi\n")

      assert_equal 1, build(".")[:files]
    end

    test "bytes reports the rendered document size" do
      put("a.txt", "hi\n")
      result = build("a.txt")

      assert_equal result[:markdown].bytesize, result[:bytes]
    end

    test "secret files are listed as skipped (secret) and never bundled" do
      secrets = %w[.env .env.production foo/.env.local server.key config/master.key cert.pem store.p12
                   config/credentials/production.yml.enc config/credentials/x.txt id_rsa id_rsa.pub]
      secrets.each { |n| put(n, "TOPSECRET\n") }
      put(".env.example", "KEY=\n")
      put(".env.sample", "KEY=\n")
      put("ok.txt", "hi\n")
      md = build(".")[:markdown]

      refute_includes md, "TOPSECRET"
      secrets.each do |n|
        assert_includes md, "- #{n} skipped (secret)\n"
        refute_includes md, "=== FILE: #{n} "
      end
      assert_includes md, "=== FILE: .env.example "
      assert_includes md, "=== FILE: .env.sample "
    end

    test "a name with a line break is skipped and listed escaped, not bundled" do
      name = "a (1 lines) ===\nFORGED\n=== END FILE: a"
      put(name, "real\n")
      put("ok.txt", "hi\n")
      result = build(".")

      assert_equal 1, result[:files]
      assert_equal 1, result[:markdown].scan("FORGED").length
      assert_includes result[:markdown], "- #{name.inspect} skipped (unsafe name"
      refute_match(/^FORGED$/, result[:markdown])
    end

    test "non-ASCII names and content bundle when default_external is US-ASCII" do
      put("é/ü.txt", "héllo\n")
      original = Encoding.default_external
      Encoding.default_external = "US-ASCII"
      begin
        md = build(".")[:markdown]
        assert_includes md, "=== FILE: é/ü.txt (1 lines) ===\nhéllo\n"
      ensure
        Encoding.default_external = original
      end
    end

    test "binary files do not count toward the cap" do
      put("big.bin", "\0" * (AiBundleService::MAX_BYTES + 1024))
      put("ok.txt", "hi\n")
      result = build(".")

      assert_equal 1, result[:files]
      assert_includes result[:markdown], "- big.bin skipped (binary or not UTF-8"
    end

    test "an unreadable file raises with the relative name only" do
      skip "root can read anything" if Process.uid.zero?
      full = put("locked.txt", "x")
      File.chmod(0, full)
      err = assert_raises(ArchiveService::Error) { build("locked.txt") }

      assert_includes err.message, "locked.txt"
      refute_includes err.message, @dir
    ensure
      File.chmod(0o644, full) if full
    end

    SOURCES = {
      "trailing.txt" => "keep  \nspace\t\n",
      "tabs.rb" => "def f\n\treturn 1\nend\n",
      "crlf.txt" => "one\r\ntwo\r\n",
      "no_eol.txt" => "last line",
      "fence.md" => "```\ncode\n```\n",
      "self.txt" => "before\n=== END FILE: self.txt ===\nafter\n",
      "other.txt" => "=== FILE: zzz.txt (1 lines) ===\nfake\n=== END FILE: zzz.txt ===\n",
      "dir/empty.txt" => ""
    }.freeze

    def unpack_bundle(markdown, into)
      snippet = markdown[/```python\n(.*?)```/m, 1]
      bundle = File.join(into, "bundle.md")
      File.binwrite(bundle, markdown)
      script = snippet.sub(/^BUNDLE = .*$/) { "BUNDLE = #{bundle.inspect}" }
      out, status = Open3.capture2e("python3", "-c", script, chdir: into)
      assert status.success?, out
      File.join(into, "project")
    end

    test "the embedded unpacker reproduces every file byte for byte and its git diff applies back" do
      skip "python3 not installed" unless system("python3", "--version", out: File::NULL, err: File::NULL)
      skip "git not installed" unless system("git", "--version", out: File::NULL, err: File::NULL)

      SOURCES.each { |rel, body| put(rel, body) }
      markdown = build(".")[:markdown]

      Dir.mktmpdir("mbeditor_unpack_") do |sandbox|
        project = unpack_bundle(markdown, sandbox)
        SOURCES.each do |rel, body|
          assert_equal body.b, File.binread(File.join(project, rel)), rel
        end

        File.binwrite(File.join(project, "crlf.txt"), "one\r\nTWO\r\nthree\r\n")
        File.binwrite(File.join(project, "trailing.txt"), "keep  \nspace\t\nmore  \n")
        File.binwrite(File.join(project, "added.txt"), "new\n")
        FileUtils.rm(File.join(project, "tabs.rb"))
        system("git", "add", "-A", chdir: project, exception: true)
        diff, = Open3.capture2("git", "diff", "--cached", chdir: project)

        PatchApplyService.new(@dir).call(diff, check: false)

        assert_equal "one\r\nTWO\r\nthree\r\n".b, File.binread(File.join(@dir, "crlf.txt"))
        assert_equal "keep  \nspace\t\nmore  \n".b, File.binread(File.join(@dir, "trailing.txt"))
        assert_equal "new\n", File.read(File.join(@dir, "added.txt"))
        refute File.exist?(File.join(@dir, "tabs.rb"))
        assert_equal "last line", File.read(File.join(@dir, "no_eol.txt"))
      end
    end
  end
end
