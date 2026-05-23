# frozen_string_literal: true

require "test_helper"

module Mbeditor
  class EditorStateServiceTest < ActiveSupport::TestCase
    test "instantiates with a workspace_root Pathname" do
      Dir.mktmpdir do |dir|
        service = EditorStateService.new(Pathname.new(dir))
        assert_instance_of EditorStateService, service
      end
    end

    test "read_state returns empty hash when workspace state file does not exist" do
      Dir.mktmpdir do |dir|
        service = EditorStateService.new(Pathname.new(dir))
        assert_equal({}, service.read_state)
      end
    end
    test "write_state / read_state round-trips data" do
      Dir.mktmpdir do |dir|
        service = EditorStateService.new(Pathname.new(dir))
        data = { "openFiles" => ["a.rb"], "activeFile" => "a.rb" }
        service.write_state(data)
        assert_equal data, service.read_state
      end
    end

    test "read_branch_state returns empty hash when branch states file does not exist" do
      Dir.mktmpdir do |dir|
        service = EditorStateService.new(Pathname.new(dir))
        assert_equal({}, service.read_branch_state("main"))
      end
    end

    test "read_branch_state returns empty hash when branch key is absent from file" do
      Dir.mktmpdir do |dir|
        service = EditorStateService.new(Pathname.new(dir))
        service.write_branch_state("other", { "x" => 1 })
        assert_equal({}, service.read_branch_state("main"))
      end
    end

    test "write_branch_state / read_branch_state round-trips data for a given branch" do
      Dir.mktmpdir do |dir|
        service = EditorStateService.new(Pathname.new(dir))
        data = { "leftPane" => "a.rb", "rightPane" => nil }
        service.write_branch_state("main", data)
        assert_equal data, service.read_branch_state("main")
      end
    end

    test "write_branch_state does not overwrite other branches" do
      Dir.mktmpdir do |dir|
        service = EditorStateService.new(Pathname.new(dir))
        service.write_branch_state("main", { "a" => 1 })
        service.write_branch_state("feature/x", { "b" => 2 })
        assert_equal({ "a" => 1 }, service.read_branch_state("main"))
        assert_equal({ "b" => 2 }, service.read_branch_state("feature/x"))
      end
    end

    test "write_branch_state raises InvalidBranchError on invalid branch name" do
      Dir.mktmpdir do |dir|
        service = EditorStateService.new(Pathname.new(dir))
        assert_raises(EditorStateService::InvalidBranchError) do
          service.write_branch_state("bad name!", { "x" => 1 })
        end
      end
    end

    test "write_branch_state raises PayloadTooLargeError when payload exceeds STATE_MAX_BYTES" do
      Dir.mktmpdir do |dir|
        service = EditorStateService.new(Pathname.new(dir))
        oversized = { "x" => "y" * (EditorStateService::STATE_MAX_BYTES + 1) }
        assert_raises(EditorStateService::PayloadTooLargeError) do
          service.write_branch_state("main", oversized)
        end
      end
    end

    test "prune_branch_states returns empty array when no branch states file exists" do
      Dir.mktmpdir do |dir|
        service = EditorStateService.new(Pathname.new(dir))
        assert_equal [], service.prune_branch_states(active_branches: ["main"])
      end
    end

    test "prune_branch_states removes branches absent from active_branches and returns their names" do
      Dir.mktmpdir do |dir|
        service = EditorStateService.new(Pathname.new(dir))
        service.write_branch_state("main", { "a" => 1 })
        service.write_branch_state("old-feature", { "b" => 2 })
        service.write_branch_state("another-old", { "c" => 3 })

        pruned = service.prune_branch_states(active_branches: ["main"])
        assert_equal %w[old-feature another-old].sort, pruned.sort
        assert_equal({ "a" => 1 }, service.read_branch_state("main"))
        assert_equal({}, service.read_branch_state("old-feature"))
      end
    end

    test "prune_branch_states returns empty array when all branches are still active" do
      Dir.mktmpdir do |dir|
        service = EditorStateService.new(Pathname.new(dir))
        service.write_branch_state("main", { "a" => 1 })
        pruned = service.prune_branch_states(active_branches: ["main"])
        assert_equal [], pruned
      end
    end

    test "write_state raises PayloadTooLargeError when payload exceeds STATE_MAX_BYTES" do
      Dir.mktmpdir do |dir|
        service = EditorStateService.new(Pathname.new(dir))
        oversized = { "x" => "y" * (EditorStateService::STATE_MAX_BYTES + 1) }
        assert_raises(EditorStateService::PayloadTooLargeError) do
          service.write_state(oversized)
        end
      end
    end
    test "STATE_MAX_BYTES is defined on the service class" do
      assert_equal 1 * 1024 * 1024, EditorStateService::STATE_MAX_BYTES
    end

    test "SAFE_BRANCH_NAME is defined on the service class" do
      assert_match EditorStateService::SAFE_BRANCH_NAME, "main"
      refute_match EditorStateService::SAFE_BRANCH_NAME, "bad name!"
    end
  end
end
