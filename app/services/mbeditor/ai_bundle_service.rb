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
    # Gemfile.lock is kept: it pins the versions the assistant needs to know.
    GENERATED = /(\A(package-lock\.json|yarn\.lock|pnpm-lock\.yaml)\z)|(?<!\AGemfile)\.lock\z|\.map\z/

    # Third-party code: never the project's own, and often most of its bytes.
    # Counted in one summary line rather than listed, since there can be
    # thousands. The name pattern is anchored so chart_controller.js and
    # reactions.js are not caught.
    LIBRARY_NAMES = "react(-dom)?|material-ui|mui|jquery|lodash|moment|bootstrap|popper|d3|chart|axios|babel|monaco"
    # A Sprockets directory named after a library (app/assets/javascripts/react/)
    # holds that library, not the app's code.
    LIBRARY_DIRS = %r{(\A|/)vendor/|\A(public/(packs(-test)?|vite[^/]*)|app/assets/builds)/|
                      \Aapp/assets/javascripts/(.+/)?(#{LIBRARY_NAMES})/}x
    LIBRARY_FILE = /\A(#{LIBRARY_NAMES})
                    ([.-](v?\d[\w.]*|min|slim|bundle|esm|umd|cjs|production|development|standalone|full|dist))*
                    \.(js|css)\z/xi

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
    # A new upload gets a fresh ./project (no stale files or reply commits); a
    # re-run on the same upload keeps it, keyed by ./.mbbundle outside the repo. The pieces below feed both the bundle's own
    # header and .prompt, so the two cannot drift.
    UNPACK_SNIPPET = <<~'PY'
      BUNDLE = "/mnt/data/bundle.md"
      import glob, hashlib, os, re, shutil, subprocess, sys, zipfile
      if not os.path.exists(BUNDLE):
          BUNDLE = max(glob.glob(glob.escape(BUNDLE.rpartition("-bundle")[0]) + "-bundle*") or [BUNDLE], key=os.path.getmtime)
      if BUNDLE.endswith(".zip"):
          with zipfile.ZipFile(BUNDLE) as z: texts = [z.read(n).decode("utf-8") for n in sorted(z.namelist())]
      else:
          texts = [open(BUNDLE, encoding="utf-8", newline="").read()]
      hdr = re.compile(r"^=== FILE: ([^\n]+?) \((\d+) lines( no-eol)?\) ===\n", re.M)
      first = hdr.search(texts[0])
      tools = re.search(r"^=== TOOLS: mbtools.py ===\n(.*?)^=== END TOOLS ===\n", texts[0][:first.start()] if first else texts[0], re.M | re.S)
      st = os.stat(BUNDLE)
      key = hashlib.sha1(("\0".join(texts) + f"\0{st.st_mtime_ns}:{st.st_size}").encode()).hexdigest()
      keep = os.path.isdir("project/.git") and os.path.exists(".mbbundle") and open(".mbbundle").read() == key
      if not keep: shutil.rmtree("project", ignore_errors=True)
      n = 0
      for text in [] if keep else texts:
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
              n += 1
      def git(*a): return subprocess.run(["git", *a], cwd="project", check=True, capture_output=True)
      if not keep:
          git("init", "-q"); git("config", "core.autocrlf", "false"); git("add", "-A", "-f")
          git("-c", "user.name=bundle", "-c", "user.email=bundle@example.invalid", "commit", "-q", "--allow-empty", "-m", "base")
          open(".mbbundle", "w").write(key)
      if tools:
          open("mbtools.py", "w", encoding="utf-8", newline="").write(tools.group(1))
          sys.path.insert(0, os.getcwd()); sys.modules.pop("mbtools", None)
          from mbtools import *
      print(f"{'kept ./project (same upload)' if keep else f'unpacked {n} files into ./project'}; helper ready: defs() uses() tests_for() refs() show() rebuild()")
    PY

    # The search helper, written next to ./project by the snippet (never inside
    # it, so it cannot appear in a diff) and shipped in part 1 of the bundle.
    # Its text must never hold a line starting with "=== ".
    MBTOOLS = <<~'PY'
      import os,re,shutil,subprocess,collections as C
      R="project";F=[];T={};X=C.defaultdict(set);D=C.defaultdict(list)
      SK={".git","node_modules","vendor","tmp","log"}
      EXT=(".rb",".js",".jsx",".ts",".tsx",".py",".rake")
      DEF=re.compile(r"^\s*(?:export\s+(?:default\s+)?)?(?:(?:async\s+)?function\*?\s+(\w+)|(?:class|module|def|interface|type|enum)\s+(?:self\.)?([\w:]+[?!=]?)|(?:const|let|var)\s+(\w+)\s*=\s*(?:async\s*)?(?:\(|function|[\w.]+\s*=>|React\.|memo|forwardRef))")
      TOK=re.compile(r"[A-Za-z_]\w*")
      TST=re.compile(r"(^|/)(test|tests|spec|__tests__)/|[._](test|spec)\.")
      IMP=re.compile(r"require|import|from|render|include|load|src=|href=|_tag")
      __all__=["defs","uses","tests_for","refs","show","rebuild"]
      def rebuild():
          for z in (F,T,X,D): z.clear()
          for d,ds,fs in os.walk(R):
              if d==R: ds[:]=[x for x in ds if x not in SK]
              for n in fs:
                  p=os.path.join(d,n);f=os.path.relpath(p,R)
                  try:
                      if os.path.getsize(p)>10**6: continue
                      t=open(p,encoding="utf-8").read()
                  except Exception: continue
                  F.append(f);T[f]=t
                  for k in set(TOK.findall(t)): X[k].add(f)
                  if n.endswith(EXT):
                      for l,s in enumerate(t.split("\n"),1):
                          m=DEF.match(s)
                          if m: D[(m[1] or m[2] or m[3]).split("::")[-1]].append(f"{f}:{l}")
      def _p(l,m,cap=40):
          print("\n".join(l[:cap]) if l else m)
          if len(l)>cap: print(f"... {len(l)-cap} more, narrow it")
          return l
      def _n(a):
          a=a.split("::")[-1];s=os.path.basename(a).split(".")[0];pk=None
          if s.startswith("_") and "views/" in a:
              v=a.split("views/",1)[1];pk=os.path.join(os.path.dirname(v),s[1:])
          s=s.lstrip("_")
          return s,"".join(w[:1].upper()+w[1:] for w in re.split(r"[_-]",s)),pk,os.path.dirname(a)
      def _hit(f,s,c,pk,d):
          for l in T[f].split("\n"):
              if pk:
                  if "render" in l and (any(q==pk or (q==s and os.path.dirname(f)==d) for q in re.findall(r"[\"']([\w/]+)[\"']",l))
                          or os.path.dirname(f)==d and re.search(r"render\b(.*collection:.*%s|[ (]@?%ss?\b(?!:))"%(re.escape(s),re.escape(s)),l)): return 1
              elif re.search(r"\b%s\b"%re.escape(c),l) or (IMP.search(l) and re.search(r"[\"'/]%s[\"'.]"%re.escape(s),l)): return 1
      def defs(n): return _p(D.get(n.split("::")[-1],[]),"no matches")
      def refs(n):
          c=["rg","-nwF","--no-heading","--no-ignore","--hidden","-g","!.git","-g","!*.md","-e",n,"."] if shutil.which("rg") else ["git","grep","-nwF","--untracked","-e",n,"--",".",":(exclude)*.md"]
          o=subprocess.run(c,cwd=R,stdin=subprocess.DEVNULL,capture_output=True,text=True,errors="replace").stdout.splitlines()
          return _p(sorted(l.removeprefix("./")[:160] for l in o),"no matches")
      def uses(a):
          s,c,pk,d=_n(a)
          return _p(sorted(f for f in (X[s]|X[s+"s"] if pk else X[c]|X[s]) if f!=a and not f.endswith(".md") and not TST.search(f) and _hit(f,s,c,pk,d)),
                    "NO STATIC REFERENCES: check routes.rb, layouts, application.js require_tree and collection renders before treating it as dead")
      def tests_for(a):
          s,c,pk,d=_n(a);k=lambda x:re.sub(r"[_-]","",x.lower());o=[]
          for f in F:
              if f==a or f.endswith(".md") or not TST.search(f): continue
              b=re.sub(r"([._](test|spec))?\.\w+$","",os.path.basename(f)).lower().removeprefix("test_")
              r=0 if k(b)==k(s) else 1 if _hit(f,s,c,pk,d) else 2
              if r<2: o.append((r,f))
          return _p([f for _,f in sorted(o)][:15],"NO TESTS FOUND",15)
      def show(p,start=1,end=None):
          L=open(os.path.join(R,p),encoding="utf-8").read().split("\n");end=min(end or start+79,start+119,len(L))
          return _p([f"{i}: {L[i-1]}" for i in range(start,end+1)],"empty",120)
      rebuild()
    PY

    DIFF_RULES = "Diff rules: git's own format only (`diff --git a/p b/p`, paths relative to the project root). " \
                 "Never use another patch format: no `*** Begin Patch`, no apply_patch, no `...` elisions, " \
                 "no line-number-only hunks. No prose inside the block."

    # Generated, not editable: the steps that keep patches applying live here so
    # an old or edited prompt file can never lose them.
    PROTOCOL = <<~'TEXT'.chomp + "\n#{DIFF_RULES}"
      Protocol (generated; it wins over anything conflicting below). Work in ./project:
      1. At the start of every turn, if `git -C project status --porcelain` prints anything, those edits were already delivered: commit them (step 4's commit command) before anything else.
      2. Search with the helper (`defs`, `uses`, `tests_for`, `refs`, `show`) and `rg -n` inside ./project (`git -C project grep -n` if rg is missing). Never `grep -r`, never print whole files, read windows of at most ~80 lines.
      3. Edit the files in ./project.
      4. If `git -C project status --porcelain` prints nothing, write no patch and reply "no changes". Otherwise commit: `git -C project add -A && git -C project -c user.name=bundle -c user.email=bundle@example.invalid commit -qm reply`, then write the patch: `git -C project diff HEAD~1 HEAD > /mnt/data/mbeditor-N.patch` (N = 1, 2, 3 ... one per reply in this chat). Check it: `git -C project apply --check -R /mnt/data/mbeditor-N.patch`. If that fails, fix the files, amend the commit and write the patch again.
      5. Deliver only the patch, never replacement or whole files, a zip, or file contents. If it is 150 lines or fewer, paste it byte-for-byte in one ```diff block for me to copy. If it is longer, give it as the mbeditor-N.patch download instead.
      6. Each patch holds only the changes since the previous reply. When N > 1, say "apply after mbeditor-(N-1).patch".
      7. If I say a patch failed, I applied only part of it, or I edited files since, ask me to export and upload a fresh bundle. Never hand-edit a diff.
      8. If ./project or the uploaded bundle is no longer available to you (for example the sandbox reset), stop and ask me to re-upload it. Never guess file contents.
      9. Rerunning the snippet is harmless: ./project is kept unless the upload is new.
    TEXT

    STOP = "STOP. Do not read, open, print or summarise this file. " \
           "Load it only with the snippet below, then grep inside ./project."

    NO_SANDBOX = "With no sandbox, use the index below to pick files, and read only those between their " \
                 "`=== FILE: <path>` and `=== END FILE: <path> ===` lines."

    # The editable part of the prompt: seeded into the workspace on first use,
    # then read back verbatim. The unpack snippet, PROTOCOL, STOP and branch
    # lines stay generated because they must stay correct.
    PROMPT_FILE = "docs/mbeditor-ai-prompt.md"
    MAX_PROMPT_BYTES = 64 * 1024
    # The minimal-code bullet is condensed from the ponytail skill (MIT).
    DEFAULT_INSTRUCTIONS = <<~'TEXT'.chomp
      Guidance:
      - Before editing anything, find how it is actually used: run `uses()` on the file, component or partial and trace from the entry point (routes, layout, the page that renders it). With no static references it may be dead, but only after checking routes.rb, layouts, application.js `require_tree` and collection renders: then edit the live one instead and tell me about the dead one in one bullet.
      - Find tests with `tests_for()` for every file you change and update them in the same patch. If none exist, list the tests you would add (file path and case names) in your reply bullets and do not write them unless asked.
      - Write the least code that works: does it need to exist, reuse what the codebase already has, then stdlib, a native platform feature, an existing dependency, one line, and only then new code. No new abstractions, dependencies or files unless needed. Prefer deleting to adding. Fix the root cause, not the symptom: grep every caller of a function before changing it.
      - Change only what the task asks. No unrelated refactors, renames or reformatting.
      - If the task is ambiguous, ask one short question before editing.
      - Be fast: batch searches in one cell, use the helper instead of repeated greps, and stop searching once you have the live usage.
      - Reply format: the patch (pasted or downloaded, per step 5), then at most 3 one-line bullets (tests updated, tests suggested, dead code found, anything I must know). No restating the task, no walkthrough, no summary, no pasted code outside the patch.
    TEXT

    # Exactly what every earlier release seeded into PROMPT_FILE. A file still
    # equal to it was never edited, so it is upgraded to DEFAULT_INSTRUCTIONS.
    LEGACY_DEFAULT = <<~'TEXT'.chomp
      Then:
      - Find code with `grep -rn` and `sed -n 'A,Bp'`. Print only the lines you need.
      - Edit the files in ./project.
      - Make the diff only by running `git -C project add -A && git -C project diff --cached`. Paste its output byte-for-byte in one ```diff block. Never write, edit, renumber or trim a diff by hand.
      - Before replying, check it: `git -C project diff --cached > /tmp/c.patch && git -C project apply --check -R /tmp/c.patch`. Fix the files and regenerate if it fails.
      - After replying, run `git -C project -c user.name=bundle -c user.email=bundle@example.invalid commit -qm reply` so your next diff holds only new changes.
      - Change only what the task asks. No refactors, renames or reformatting it did not ask for.
      - If the task is ambiguous, ask one short question before editing instead of guessing.
      - Keep replies short: the diff, then at most 3 one-line bullets for anything I must know. No restating the task, no walkthrough of the code, no summary.
      - Never paste file contents or command output back to me.
      - Follow-ups in this chat reuse ./project; rerun the snippet only after a new upload.
      - If ./project or the uploaded bundle is no longer available to you (for example it fell out of your context or the sandbox reset), stop and ask me to re-upload it before doing anything else. Never guess file contents.

      Diff rules: git's own format only (`diff --git a/p b/p`, paths relative to the project root). Never use another patch format: no `*** Begin Patch`, no apply_patch, no `...` elisions, no line-number-only hunks. No prose inside the block.
    TEXT

    def initialize(workspace_root)
      @root = workspace_root.to_s.chomp("/")
    end

    # The bundle's own header, minus the TASK: line and the branch line. +parts+
    # > 1 means the single upload is the matching .zip.
    def header(parts = 1)
      attached = parts > 1 ? self.class.zip_filename(bundle_name) : bundle_name
      snippet = UNPACK_SNIPPET.sub(/^BUNDLE = .*$/) { "BUNDLE = #{"/mnt/data/#{attached}".to_json}" }
      what = parts > 1 ? "a zip of #{parts} markdown parts of one large source bundle" : "a large source bundle"
      "`#{attached}` is #{what}. Do not open, read or print it directly.\n" \
        "Load it only from your code sandbox with this snippet (adjust BUNDLE if the path differs):\n\n" \
        "```python\n#{snippet}```\n\n#{PROTOCOL}\n\n#{instructions}\n\n"
    end

    # Paste-ready message to send with the uploaded bundle. No files are read
    # beyond the prompt file.
    def prompt(parts = 1)
      "#{branch_line}#{header(parts)}TASK: "
    end

    # Stamped once per instance, so a download's .md, .zip and part names agree.
    def bundle_name
      @bundle_name ||= "#{File.basename(@root)}-bundle-#{Time.now.strftime("%Y%m%d-%H%M")}.md"
    end

    # +full_paths+ are absolute, already through resolve_path. Returns
    # { parts:, bytes: }. With +split+ the fewest parts (1..MAX_PARTS) that each
    # fit under MAX_BYTES, from the sizes the walk already has; otherwise always
    # one part, capped at MAX_BYTES * MAX_PARTS. Raises LimitExceededError when
    # the selection does not fit.
    def plan(full_paths, split: false)
      texty, = classify(full_paths)
      groups = choose_groups(texty, split)
      { parts: groups.length, bytes: texty.sum { |e| e[:size] } }
    end

    # Returns { data:, parts:, files:, bytes: }. +data+ is the markdown when
    # parts is 1, else a zip of parts markdown files named by part_filename.
    # +bytes+ is the rendered markdown size, summed over parts.
    #
    # Files are sorted by path and cut into contiguous runs of roughly equal
    # bytes, so the split is the same on every request and no file straddles
    # two parts. Lossless by construction: see UNPACK_SNIPPET.
    def build(full_paths, split: false)
      texty, skipped = classify(full_paths)
      groups = choose_groups(texty, split)
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

    # Seeds the default on first use. A write failure (read-only FS) just means
    # the default text is used, unedited.
    def instructions
      path = File.join(@root, PROMPT_FILE)
      unless File.exist?(path)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "#{DEFAULT_INSTRUCTIONS}\n")
      end
      text = File.read(path, MAX_PROMPT_BYTES, mode: "rb").to_s.force_encoding(Encoding::UTF_8).scrub.rstrip
      if text.delete_prefix("\uFEFF").gsub("\r\n", "\n") == LEGACY_DEFAULT
        File.write(path, "#{DEFAULT_INSTRUCTIONS}\n")
        return DEFAULT_INSTRUCTIONS
      end
      text.empty? ? DEFAULT_INSTRUCTIONS : text
    rescue SystemCallError
      DEFAULT_INSTRUCTIONS
    end

    # Nil outside a git repo and on a detached HEAD, where there is no branch to pin.
    def branch_line
      name = GitService.current_branch(@root)
      return "" if name.blank? || name == "HEAD"

      "Branch: `#{name}`. Do all work for this branch. Never create, switch to, or develop on another branch without asking me first.\n\n"
    end

    # Sorted, de-duplicated walk split into [text entries, skipped entries].
    # Only text counts toward the cap: a binary that is never written to the
    # bundle must not make the selection "too large".
    def classify(full_paths)
      walker = ArchiveService.new(@root)
      docs = walker.collect(doc_paths).reject { |e| doc_rank(e[:name]) > 3 }
      entries = (walker.collect(full_paths) + docs).uniq { |e| e[:name] }
                       .map { |e| e.merge(name: utf8(e[:name])) }
                       .reject { |e| e[:name] == PROMPT_FILE || earlier_bundle?(e[:name]) }
                       .sort_by { |e| [doc_rank(e[:name]), e[:name]] }
      raise "Nothing to bundle" if entries.empty?

      skipped = []
      wanted = []
      entries.each do |e|
        reason = skip_reason(e[:name])
        reason ? skipped << e.merge(reason: reason) : wanted << e
      end

      texty = []
      wanted.each { |e| (reason = probe_reason(e)) ? skipped << e.merge(reason: reason) : texty << e }
      [texty, skipped]
    end

    # Any bundle saved in the workspace root: stamped, unstamped, "(1)" copies, .md or .zip.
    def earlier_bundle?(name)
      name.match?(/\A#{Regexp.escape(File.basename(@root))}-bundle[^\/]*\.(md|zip)\z/)
    end

    # Root *.md and docs/ are always offered, selected or not: they say what
    # the project is. They still go through the walk's containment and
    # exclusions, and skip_reason's secret and size checks.
    def doc_paths
      root_md = Dir.children(@root).select { |n| n.end_with?(".md") }.map { |n| File.join(@root, n) }
      root_md << File.join(@root, "docs")
    rescue SystemCallError
      []
    end

    # AGENTS.md, CLAUDE.md, other root .md, docs/** and nested AGENTS/CLAUDE,
    # then everything else. Partitioning is contiguous, so docs land in part 1.
    def doc_rank(name)
      case name
      when "AGENTS.md" then 0
      when "CLAUDE.md" then 1
      when %r{\A[^/]+\.md\z} then 2
      when %r{\Adocs/.*\.md\z}, %r{/(AGENTS|CLAUDE)\.md\z} then 3
      else 4
      end
    end

    def choose_groups(texty, split)
      unless split
        total = texty.sum { |e| e[:size] }
        return [texty] if total <= MAX_BYTES * MAX_PARTS

        raise LimitExceededError,
              "Selection is too large (#{human(total)}). Limit is #{human(MAX_BYTES * MAX_PARTS)}. " \
              "Narrow the selection, or turn on splitting."
      end
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
      elsif LIBRARY_DIRS.match?(name) || LIBRARY_FILE.match?(File.basename(name)) || name.match?(/\.min\.(js|css)\z/)
        "library"
      elsif GENERATED.match?(File.basename(name)) then "generated"
      end
    end

    # Names come off the filesystem in default_external, which is US-ASCII when
    # LANG is unset; tag them UTF-8 so they join the UTF-8 document.
    def utf8(str)
      str.dup.force_encoding(Encoding::UTF_8).scrub
    end

    # Minified JS/CSS is any name: mostly lines too long to be hand-written.
    def probe_reason(entry)
      probe = File.open(entry[:path], "rb") { |f| f.read(BINARY_PROBE_BYTES).to_s }
      return "binary or not UTF-8" if probe.include?("\0")
      return unless entry[:name].match?(/\.(m?js|cjs|css)\z/) && probe.bytesize > 2048

      long = probe.each_line.sum { |l| l.bytesize > 500 ? l.bytesize : 0 }
      "library" if long * 2 > probe.bytesize
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
      out = +"#{title}\n\n#{STOP}\n\n#{branch_line}## Instructions\n\n#{note}#{header(parts)}#{NO_SANDBOX}\n\n## Index\n\n"
      included.each { |name, text| out << "- #{name} (#{line_count(text)} lines, #{text.bytesize} bytes)\n" }
      library, skipped = skipped.partition { |e| e[:reason] == "library" }
      unless library.empty?
        out << "- #{library.length} third-party library or minified files skipped (#{human(library.sum { |e| e[:size] })}; " \
               "vendor/, public/packs/, app/assets/builds/, library-named files and directories, minified code)\n"
      end
      skipped.each do |e|
        label = e[:name].match?(/[\r\n]/) ? e[:name].inspect : e[:name]
        detail = e[:reason] == "secret" ? "secret" : "#{e[:reason]}, #{human(e[:size])}"
        out << "- #{label} skipped (#{detail})\n"
      end
      out << "\n"
      out << "=== TOOLS: mbtools.py ===\n#{MBTOOLS}=== END TOOLS ===\n" if part == 1
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
