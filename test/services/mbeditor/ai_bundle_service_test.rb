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
      Mbeditor.configuration.ai_bundle_exclude = []
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
      md = build("app")[:data]

      assert_includes md, "# #{File.basename(@dir)}"
      assert_includes md, "STOP. Do not read, open, print or summarise this file."
      assert_includes md, AiBundleService.header(AiBundleService.new(@dir).bundle_name)
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
      assert_includes build("t.txt")[:data], AiBundleService::DIFF_RULES
    end

    test "a file without a final newline is flagged no-eol and gets one" do
      put("t.txt", "tail")

      assert_includes build("t.txt")[:data], "=== FILE: t.txt (1 lines no-eol) ===\ntail\n=== END FILE: t.txt ===\n"
    end

    test "binary files are skipped and listed" do
      put("img.bin", "ab\0cd")
      put("ok.txt", "hi\n")
      result = build("img.bin", "ok.txt")

      assert_equal 1, result[:files]
      assert_includes result[:data], "- img.bin skipped (binary or not UTF-8, 5 Bytes)"
      refute_includes result[:data], "=== FILE: img.bin"
    end

    test "lock, minified and map files are skipped but indexed with their size" do
      %w[package-lock.json yarn.lock pnpm-lock.yaml app.min.js app.min.css app.js.map].each { |n| put(n, "x" * 2048) }
      put("app.js", "ok\n")
      result = build(".")

      assert_equal 1, result[:files]
      %w[package-lock.json yarn.lock pnpm-lock.yaml app.js.map].each do |n|
        assert_includes result[:data], "- #{n} skipped (generated, 2 KB)"
      end
      assert_includes result[:data], "- 2 third-party library or minified files skipped ("
      assert_equal ["app.js"], result[:data].scan(/^=== FILE: (\S+)/).flatten
    end

    test "Gemfile, Gemfile.lock and gemspecs are bundled" do
      %w[Gemfile Gemfile.lock x.gemspec].each { |n| put(n, "a\n") }

      assert_equal 3, build(".")[:files]
    end

    test "third-party library files are counted in one line, not bundled or listed" do
      put("vendor/assets/javascripts/react.js", "lib\n")
      put("public/packs/app-1.js", "lib\n")
      put("public/vite-dev/a.js", "lib\n")
      put("app/assets/builds/x.js", "lib\n")
      put("app/jquery-3.6.0.min.js", "lib\n")
      put("app/react-dom.production.min.js", "lib\n")
      put("app/d3.v7.js", "lib\n")
      put("app/assets/javascripts/react/components/x.js", "lib\n")
      put("app/assets/javascripts/bundle.js", "#{"a" * 3000}\n")
      put("app/assets/javascripts/long_data.rb", "#{"a" * 3000}\n")
      %w[chart_controller.js reactions.js chart-utils.js reactor.js].each { |n| put("app/#{n}", "ok\n") }
      result = build(".")

      assert_equal 5, result[:files]
      assert_includes result[:data], "- 9 third-party library or minified files skipped ("
      refute_includes result[:data], "=== FILE: vendor/"
      refute_includes result[:data], "react-dom.production"
      assert_includes result[:data], "=== FILE: app/chart_controller.js"
    end

    test "docs come first: root md, docs/**, AGENTS.md before CLAUDE.md, even when not selected" do
      put("AGENTS.md", "a\n")
      put("CLAUDE.md", "c\n")
      put("README.md", "r\n")
      put("docs/z.md", "z\n")
      put("docs/a/b.md", "b\n")
      put("docs/img.png", "x\n")
      put("app/a.rb", "x\n")
      put("app/CLAUDE.md", "n\n")
      md = build("app")[:data]

      order = md.scan(/^=== FILE: (\S+)/).flatten
      assert_equal %w[AGENTS.md CLAUDE.md README.md app/CLAUDE.md docs/a/b.md docs/z.md app/a.rb], order
    end

    test "docs are not duplicated when selected and the bundle's own name is left out" do
      put("README.md", "r\n")
      put("#{File.basename(@dir)}-bundle.md", "old\n")

      assert_equal %w[README.md], build(".")[:data].scan(/^=== FILE: (\S+)/).flatten
    end

    test "excluded paths are not bundled" do
      put("tmp/secret.txt", "nope")
      put("keep.txt", "yes\n")
      md = build(".")[:data]

      refute_includes md, "secret.txt"
      assert_includes md, "=== FILE: keep.txt"
    end

    test "a selection too big even for three parts is refused with its size" do
      put("big.txt", "a" * 20)
      with_max_bytes(10) do
        err = assert_raises(AiBundleService::LimitExceededError) { build("big.txt") }

        assert_match(/Selection is too large \(20 Bytes\) even split into 3 parts\. Limit is 10 Bytes per part/, err.message)
      end
      assert_equal 64 * 1024 * 1024, AiBundleService::MAX_BYTES
    end

    test "skipped files do not count toward the cap" do
      put("huge.lock", "a" * (AiBundleService::MAX_BYTES + 1))
      put("ok.txt", "hi\n")

      assert_equal 1, build(".")[:files]
    end

    test "bytes reports the rendered document size" do
      put("a.txt", "hi\n")
      result = build("a.txt")

      assert_equal result[:data].bytesize, result[:bytes]
    end

    test "secret files are listed as skipped (secret) and never bundled" do
      secrets = %w[.env .env.production foo/.env.local server.key config/master.key cert.pem store.p12
                   config/credentials/production.yml.enc config/credentials/x.txt id_rsa id_rsa.pub]
      secrets.each { |n| put(n, "TOPSECRET\n") }
      put(".env.example", "KEY=\n")
      put(".env.sample", "KEY=\n")
      put("ok.txt", "hi\n")
      md = build(".")[:data]

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
      assert_equal 1, result[:data].scan("FORGED").length
      assert_includes result[:data], "- #{name.inspect} skipped (unsafe name"
      refute_match(/^FORGED$/, result[:data])
    end

    test "non-ASCII names and content bundle when default_external is US-ASCII" do
      put("é/ü.txt", "héllo\n")
      original = Encoding.default_external
      Encoding.default_external = "US-ASCII"
      begin
        md = build(".")[:data]
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
      assert_includes result[:data], "- big.bin skipped (binary or not UTF-8"
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

    def files_in(md)
      md.scan(/^=== FILE: (.+?) \(\d+ lines/).flatten
    end

    def seed_parts
      put("a.txt", "a" * 100)
      put("b.txt", "b" * 100)
      put("c/d.txt", "d" * 300)
      put("e.txt", "e" * 100)
      put("f.txt", "f" * 200)
    end

    # { member name => text }, read back by Python's zipfile after testzip.
    def zip_members(data)
      Tempfile.create(["bundle", ".zip"], binmode: true) do |f|
        f.write(data)
        f.flush
        script = "import zipfile, sys, json\nz = zipfile.ZipFile(sys.argv[1])\n" \
                 "assert z.testzip() is None\nprint(json.dumps({n: z.read(n).decode('utf-8') for n in z.namelist()}))"
        out, status = Open3.capture2e("python3", "-I", "-c", script, f.path)
        assert status.success?, out
        JSON.parse(out)
      end
    end

    test "plan picks the fewest parts that fit" do
      seed_parts
      plan = ->(limit) { with_max_bytes(limit) { AiBundleService.new(@dir).plan([@dir]) } }

      assert_equal({ parts: 1, bytes: 800 }, plan.call(800))
      assert_equal 2, plan.call(799)[:parts]
      assert_equal 2, plan.call(500)[:parts]
      assert_equal 3, plan.call(499)[:parts]
      assert_equal 3, plan.call(300)[:parts]
      assert_raises(AiBundleService::LimitExceededError) { plan.call(299) }
    end

    test "plan decides from sizes alone and ignores skipped and binary files" do
      put("a.txt", "a" * 10)
      put("x.lock", "z" * 1000)
      put("img.bin", "\0" * 1000)

      assert_equal({ parts: 1, bytes: 10 }, with_max_bytes(20) { AiBundleService.new(@dir).plan([@dir]) })
    end

    test "a selection that fits is one markdown file" do
      seed_parts
      result = build(".")

      assert_equal 1, result[:parts]
      assert_equal 5, result[:files]
      assert_includes result[:data], "=== FILE: a.txt "
      refute_includes result[:data], "part 1 of"
    end

    test "too big for one file builds a valid zip of the minimum number of parts" do
      skip "python3 not installed" unless system("python3", "--version", out: File::NULL, err: File::NULL)

      seed_parts
      result = with_max_bytes(500) { build(".") }
      members = zip_members(result[:data])
      name = "#{File.basename(@dir)}-bundle"

      assert_equal 2, result[:parts]
      assert_equal 5, result[:files]
      assert_equal %W[#{name}-1-of-2.md #{name}-2-of-2.md], members.keys
      assert_equal %w[a.txt b.txt c/d.txt], files_in(members.values[0])
      assert_equal %w[e.txt f.txt], files_in(members.values[1])
      assert_includes members.values[1], "(part 2 of 2)"
      assert_equal members.values.sum(&:bytesize), result[:bytes]
    end

    test "the split is deterministic" do
      seed_parts
      first = with_max_bytes(500) { build(".")[:data] }

      assert_equal first, with_max_bytes(500) { build(".")[:data] }
    end

    test "three parts cover every file exactly once, in path order" do
      skip "python3 not installed" unless system("python3", "--version", out: File::NULL, err: File::NULL)

      seed_parts
      result = with_max_bytes(350) { build(".") }

      assert_equal 3, result[:parts]
      assert_equal %w[a.txt b.txt c/d.txt e.txt f.txt], zip_members(result[:data]).values.flat_map { |md| files_in(md) }
    end

    test "the zip passes the system unzip -t" do
      skip "unzip not installed" unless system("unzip", "-v", out: File::NULL, err: File::NULL)

      seed_parts
      data = with_max_bytes(350) { build(".")[:data] }
      Tempfile.create(["bundle", ".zip"], binmode: true) do |f|
        f.write(data)
        f.flush
        out, status = Open3.capture2e("unzip", "-t", f.path)

        assert status.success?, out
        assert_match(/No errors detected/, out)
      end
    end

    test "ZipWriter handles empty and non-ASCII content" do
      skip "python3 not installed" unless system("python3", "--version", out: File::NULL, err: File::NULL)

      members = zip_members(ZipWriter.write([["é.md", "héllo\n"], ["empty.md", ""]]))

      assert_equal({ "é.md" => "héllo\n", "empty.md" => "" }, members)
    end

    test "prompt for a selection that fits names the .md and says it is one file" do
      prompt = AiBundleService.prompt("proj-bundle.md", 1)

      assert_includes prompt, "`proj-bundle.md` is a large source bundle"
      assert_includes prompt, 'BUNDLE = "/mnt/data/proj-bundle.md"'
    end

    test "prompt for a split names the one .zip, never several files" do
      prompt = AiBundleService.prompt("proj-bundle.md", 2)

      assert_includes prompt, "`proj-bundle.zip` is a zip of 2 markdown parts"
      assert_includes prompt, 'BUNDLE = "/mnt/data/proj-bundle.zip"'
      refute_match(/of-2\.md|Upload all|once per part/, prompt)
      assert prompt.end_with?("\nTASK: ")
    end

    test "ai_bundle_exclude: basename glob matches at any depth and wins over an explicit tick" do
      Mbeditor.configuration.ai_bundle_exclude = ["*.sql"]
      put("dump.sql", "SECRETROWS\n")
      put("db/deep/x.sql", "SECRETROWS\n")
      put("ok.txt", "hi\n")
      result = build("dump.sql", "db", "ok.txt")

      assert_equal 1, result[:files]
      refute_includes result[:data], "SECRETROWS"
      assert_includes result[:data], "- dump.sql skipped (excluded by config, 11 Bytes)"
      assert_includes result[:data], "- db/deep/x.sql skipped (excluded by config"
    end

    test "ai_bundle_exclude: a slashed pattern matches the relative path only" do
      Mbeditor.configuration.ai_bundle_exclude = ["config/*.yml", "private/**/*"]
      put("config/a.yml", "NOPE\n")
      put("other/config/a.yml", "keepme\n")
      put("private/x/y.txt", "NOPE\n")
      md = build(".")[:data]

      refute_includes md, "NOPE"
      assert_includes md, "- config/a.yml skipped (excluded by config"
      assert_includes md, "=== FILE: other/config/a.yml "
      assert_includes md, "- private/x/y.txt skipped (excluded by config"
    end

    test "ai_bundle_exclude never loosens secret?" do
      Mbeditor.configuration.ai_bundle_exclude = ["nothing"]
      put(".env", "TOPSECRET\n")

      refute_includes build(".env", ".")[:data], "TOPSECRET"
      assert AiBundleService.secret?(".env")
    end

    test "the snippet unpacks a real 2-part zip into one project with a single base commit" do
      skip "python3 not installed" unless system("python3", "--version", out: File::NULL, err: File::NULL)
      skip "git not installed" unless system("git", "--version", out: File::NULL, err: File::NULL)

      seed_parts
      result = with_max_bytes(500) { build(".") }
      assert_equal 2, result[:parts]
      first_md = zip_members(result[:data]).values.first

      Dir.mktmpdir("mbeditor_parts_") do |sandbox|
        project = unpack_bundle(first_md, sandbox, zip: result[:data])
        files = Open3.capture2("git", "ls-tree", "-r", "--name-only", "HEAD", chdir: project).first.split("\n")

        assert_equal "1", Open3.capture2("git", "rev-list", "--count", "HEAD", chdir: project).first.strip
        assert_equal %w[a.txt b.txt c/d.txt e.txt f.txt], files
        assert_equal "d" * 300, File.read(File.join(project, "c/d.txt"))
        unpack_bundle(first_md, sandbox, zip: result[:data])
        assert_equal "1", Open3.capture2("git", "rev-list", "--count", "HEAD", chdir: project).first.strip
      end
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

    def unpack_bundle(markdown, into, zip: nil)
      snippet = markdown[/```python\n(.*?)```/m, 1]
      bundle = File.join(into, zip ? "bundle.zip" : "bundle.md")
      File.binwrite(bundle, zip || markdown)
      script = snippet.sub(/^BUNDLE = .*$/) { "BUNDLE = #{bundle.inspect}" }
      out, status = Open3.capture2e("python3", "-c", script, chdir: into)
      assert status.success?, out
      File.join(into, "project")
    end

    test "the embedded unpacker reproduces every file byte for byte and its git diff applies back" do
      skip "python3 not installed" unless system("python3", "--version", out: File::NULL, err: File::NULL)
      skip "git not installed" unless system("git", "--version", out: File::NULL, err: File::NULL)

      SOURCES.each { |rel, body| put(rel, body) }
      markdown = build(".")[:data]

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
