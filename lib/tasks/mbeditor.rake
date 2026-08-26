# frozen_string_literal: true

namespace :mbeditor do
  desc "Scan the workspace for files that contain a duplicated copy of themselves"
  task scan_duplicates: :environment do
    root = ENV["MBEDITOR_WORKSPACE_ROOT"] || Mbeditor::WorkspaceRootResolver.call
    findings = Mbeditor::DuplicateContentScanner.new(root).call

    if findings.empty?
      puts "No duplicated files found under #{root}."
      next
    end

    puts "Possible duplicated content under #{root}:"
    findings.each do |f|
      label = f.reason == :exact ? "DUPLICATED (whole file appears twice)" : "suspect (opening block repeats)"
      puts format("  %-60s %s at line %d of %d", f.path, label, f.line, f.lines)
    end
    puts
    puts "Files marked DUPLICATED are byte-for-byte X+X — check `git diff` and delete the second half."
    puts "Files marked suspect need a look; the repeat may be legitimate."
  end
end
